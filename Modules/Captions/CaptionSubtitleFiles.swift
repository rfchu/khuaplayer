import Foundation

/// Create the dedicated utility queue on first demand. Enumeration, reading and
/// parsing return value results to the window without blocking MainActor on file I/O.
enum CaptionSubtitleFiles {
    static let maximumFileBytes = 32 * 1024 * 1024
    private static let ioQueue = DispatchQueue(label: "dev.khuaplayer.captions.files", qos: .utility)

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private static func onIOQueue<Value: Sendable>(cancelledResult: Value,
                                                   _ operation: @escaping @Sendable (Cancellation) -> Value) async -> Value {
        guard !Task.isCancelled else { return cancelledResult }
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                ioQueue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: cancelledResult)
                        return
                    }
                    let value = operation(cancellation)
                    continuation.resume(returning: cancellation.isCancelled ? cancelledResult : value)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// True pauses background I/O in place; cancellation can still terminate the wait.
    static func sidecars(for mediaURL: URL, shouldPause: (@Sendable () -> Bool)? = nil) async -> [URL] {
        await onIOQueue(cancelledResult: []) { cancellation in
            let directory: URL
            let baseKey: String
            if mediaURL.isFileURL {
                directory = mediaURL.deletingLastPathComponent()
                baseKey = mediaURL.lastPathComponent
            } else {
                directory = CaptionSRT.networkCaptionsDirectory
                baseKey = CaptionSRT.mediaBaseKey(for: mediaURL)
            }
            let prefix = baseKey + ".ai."
            guard waitForIO(cancellation: cancellation, shouldPause: shouldPause),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                  !cancellation.isCancelled else { return [] }
            return names.filter { $0.hasPrefix(prefix) && CaptionOutputName.parse($0)?.mediaFileName == baseKey }
                .sorted().map { directory.appendingPathComponent($0, isDirectory: false) }
        }
    }

    static func cues(from url: URL, shouldPause: (@Sendable () -> Bool)? = nil) async -> [CaptionSRT.ParsedCue]? {
        await onIOQueue(cancelledResult: nil) { cancellation in
            guard let text = readText(url, cancellation: cancellation, shouldPause: shouldPause), !cancellation.isCancelled else { return nil }
            let ext = url.pathExtension.lowercased()
            let cues = ext == "ass" || ext == "ssa" ? CaptionSRT.parseASS(text) : CaptionSRT.parseSRT(text)
            return cues.isEmpty ? nil : cues
        }
    }

    static func generatedEvents(from url: URL, bilingual: Bool,
                                shouldPause: (@Sendable () -> Bool)? = nil) async -> [CaptionRenderEvent]? {
        await onIOQueue(cancelledResult: nil) { cancellation in
            guard let text = readText(url, cancellation: cancellation, shouldPause: shouldPause), !cancellation.isCancelled else { return nil }
            let events = parseGenerated(text, bilingual: bilingual)
            return events.isEmpty ? nil : events
        }
    }

    /// Metadata is only an early rejection: the file may grow afterward. Read at
    /// most limit + 1 bytes and validate again instead of loading an unbounded file.
    private static func readText(_ url: URL, cancellation: Cancellation, shouldPause: (@Sendable () -> Bool)?) -> String? {
        guard waitForIO(cancellation: cancellation, shouldPause: shouldPause) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > maximumFileBytes { return nil }
        guard waitForIO(cancellation: cancellation, shouldPause: shouldPause),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(size ?? 65_536, maximumFileBytes + 1))
        do {
            while !cancellation.isCancelled {
                guard waitForIO(cancellation: cancellation, shouldPause: shouldPause) else { return nil }
                let remaining = maximumFileBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= maximumFileBytes else { return nil }
            }
        } catch { return nil }
        guard !cancellation.isCancelled else { return nil }
        // UTF-16 must have a BOM or the alternating NUL pattern of the ASCII
        // timecode syntax. Merely accepting arbitrary bytes as UTF-16 corrupts
        // valid Western subtitles and prevents the legacy fallback.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.contains(0) {
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                if let text = String(data: data, encoding: encoding),
                   (text.contains("-->") || text.contains("Dialogue:")), !text.contains("\0") { return text }
            }
            return nil
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // DOS text files may end in a single ^Z (optionally followed by CR/LF).
        // Strip only that terminal marker, after the Unicode paths: 0x1A can
        // be part of a UTF-16 code unit. An interior ^Z remains invalid below.
        var textEnd = data.endIndex
        while textEnd > data.startIndex, data[textEnd - 1] == 0x0D || data[textEnd - 1] == 0x0A {
            textEnd -= 1
        }
        if textEnd > data.startIndex, data[textEnd - 1] == 0x1A {
            data.remove(at: textEnd - 1)
        }
        // Legacy subtitles need statistical detection: decoding every non-UTF
        // byte as Windows-1252 silently turns GBK/Big5/Shift-JIS into mojibake.
        // Do not bias source text with the UI language, allow replacement bytes,
        // or fall back to an arbitrary single-byte encoding when detection fails.
        // This is still a heuristic: a short byte sequence can be valid in more
        // than one encoding, including UTF-8. A BOM remains authoritative.
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false],
                                               convertedString: &converted, usedLossyConversion: &lossy)
        // Do not require a byte-for-byte round trip: legacy encodings such as
        // CP932 contain multiple valid byte sequences for the same character.
        guard !cancellation.isCancelled, encoding != 0, !lossy.boolValue,
              let text = converted as String?,
              !text.unicodeScalars.contains(where: {
                  ($0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r") ||
                  (0x7F...0x9F).contains($0.value) || $0.value == 0xFFFD
              }) else { return nil }
        return text
    }

    private static func waitForIO(cancellation: Cancellation, shouldPause: (@Sendable () -> Bool)?) -> Bool {
        while !cancellation.isCancelled {
            if shouldPause?() != true { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// Generated cues contain translation above source text; preserve that two-line structure.
    private static func parseGenerated(_ text: String, bilingual: Bool) -> [CaptionRenderEvent] {
        var events: [CaptionRenderEvent] = []
        var block: [String] = []
        func flush() {
            defer { block.removeAll(keepingCapacity: true) }
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let timing = block[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2, let start = CaptionSRT.parseTime(timing[0]),
                  let end = CaptionSRT.parseTime(String(timing[1].split(whereSeparator: { $0.isWhitespace }).first ?? "")),
                  end > start else { return }
            let lines = block[(timingIndex + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let source = lines.last else { return }
            if bilingual, lines.count >= 2 {
                events.append(CaptionRenderEvent(start: start, end: end, source: source,
                                                 translation: lines.dropLast().joined(separator: " ")))
            } else {
                events.append(CaptionRenderEvent(start: start, end: end, source: lines.joined(separator: " "), translation: nil))
            }
        }
        for line in CaptionSRT.logicalLines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { block.append(line) }
        }
        flush()
        return events
    }

    static func effectiveTargetTag(sourceTag: String?, targetTag: String?) -> String? {
        guard sourceTag != targetTag else { return nil }
        return targetTag
    }

    /// Match filenames against a directory snapshot; an explicit source language
    /// must match the complete tag.
    static func matchingOutputs(sidecars: [URL], mediaURL: URL, sourceTag: String?, targetTag: String?) -> [URL] {
        let target = effectiveTargetTag(sourceTag: sourceTag, targetTag: targetTag)
        return sidecars.filter { url in
            guard let tags = outputTags(url, mediaURL: mediaURL) else { return false }
            if let target {
                return tags.count == 2 && tags[0] == target && (sourceTag == nil || tags[1] == sourceTag)
            }
            return tags.count == 1 && (sourceTag == nil || tags[0] == sourceTag)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isBilingualOutput(url: URL, mediaURL: URL) -> Bool {
        outputTags(url, mediaURL: mediaURL)?.count == 2
    }

    private static func outputTags(_ url: URL, mediaURL: URL) -> [String]? {
        let expectedBase = CaptionSRT.mediaBaseKey(for: mediaURL)
        guard let output = CaptionOutputName.parse(url.lastPathComponent),
              output.mediaFileName == expectedBase else { return nil }
        return output.tags
    }
}
