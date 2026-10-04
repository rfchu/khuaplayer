import Foundation
import Darwin
import CryptoKit

// Sidecar SRT files and renderer-ready ASS events. Transcription writes
// Movie.mkv.ai.<src>.srt; translation writes Movie.mkv.ai.<dst>.<src>.srt.
// Bilingual cues place translation above the original text. A sentence spanning
// multiple cues repeats its translation so standalone subtitle readers can show it.

struct CaptionRenderEvent: Hashable, Sendable {
    var start: Double
    var end: Double
    /// Source-language line.
    var source: String
    /// Translated line, or nil for transcription only.
    var translation: String?
}

/// The generated-file grammar, shared by discovery and reuse. A literal `.ai.`
/// in a movie title is not enough to identify a generated subtitle. File tags
/// follow CaptionLanguageTags: ISO language codes, with Chinese script retained.
enum CaptionOutputName {
    struct Parsed {
        let mediaFileName: String
        let tags: [String]
        let isPartial: Bool
    }

    private static let languageCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))

    private static func isFileTag(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        if lower == "zh-hans" || lower == "zh-hant" { return true }
        return languageCodes.contains(lower)
    }

    static func parse(_ name: String) -> Parsed? {
        guard (name as NSString).pathExtension.lowercased() == "srt" else { return nil }
        var base = (name as NSString).deletingPathExtension
        let isPartial = base.lowercased().hasSuffix(".part")
        if isPartial {
            base = (base as NSString).deletingPathExtension
        }
        guard let marker = base.range(of: ".ai.", options: [.backwards, .caseInsensitive]),
              marker.lowerBound != base.startIndex else { return nil }
        let tags = base[marker.upperBound...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(tags.count), tags.allSatisfy(isFileTag) else { return nil }
        return Parsed(mediaFileName: String(base[..<marker.lowerBound]), tags: tags, isPartial: isPartial)
    }
}

enum CaptionSRT {
    enum OutputError: LocalizedError {
        case filenameTooLong(URL)
        case notRegularFile(URL)
        case noContent(URL)

        var errorDescription: String? {
            switch self {
            case .filenameTooLong:
                return NSLocalizedString("captions.output.nameTooLong", comment: "Generated subtitle output name exceeds the destination filesystem limit")
            case .notRegularFile:
                return NSLocalizedString("captions.output.notRegularFile", comment: "Generated subtitle destination is a directory, symlink or other nonregular file")
            case .noContent:
                return NSLocalizedString("captions.output.noContent", comment: "There are no valid subtitle cues to save")
            }
        }
    }

    static var networkCaptionsDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("Captions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func networkMediaKey(for url: URL) -> String {
        var title = (url.deletingPathExtension().lastPathComponent as NSString).lastPathComponent
        if title.isEmpty || title == "/" {
            title = url.host ?? "stream"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeScalars = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleanTitle = String(safeScalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let prefixTitle = String(cleanTitle.prefix(32))
        let finalTitle = prefixTitle.isEmpty ? "stream" : prefixTitle

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let volatileKeys: Set<String> = ["token", "sign", "signature", "expires", "auth_key", "t", "timestamp", "key", "access_token"]
        if let items = components?.queryItems {
            let filtered = items.filter { !volatileKeys.contains($0.name.lowercased()) }
            components?.queryItems = filtered.isEmpty ? nil : filtered
        }
        let canonical = components?.string ?? url.absoluteString
        let hash = SHA256.hash(data: Data(canonical.utf8))
        let hashStr = hash.prefix(6).map { String(format: "%02x", $0) }.joined()

        return "\(hashStr)_\(finalTitle)"
    }

    static func mediaBaseKey(for mediaURL: URL) -> String {
        mediaURL.isFileURL ? mediaURL.lastPathComponent : networkMediaKey(for: mediaURL)
    }

    /// Generate the media-adjacent transcription or bilingual sidecar filename.
    static func sidecarURL(for mediaURL: URL, sourceTag: String, targetTag: String?) -> URL {
        let base = mediaBaseKey(for: mediaURL)
        var name = base + ".ai"
        if let targetTag { name += "." + targetTag }
        name += "." + sourceTag + ".srt"
        if mediaURL.isFileURL {
            return mediaURL.deletingLastPathComponent().appendingPathComponent(name)
        } else {
            return networkCaptionsDirectory.appendingPathComponent(name)
        }
    }

    /// Generate the media-adjacent partial sidecar filename for interrupted or stopped tasks.
    static func partialSidecarURL(for mediaURL: URL, sourceTag: String, targetTag: String?) -> URL {
        let base = mediaBaseKey(for: mediaURL)
        var name = base + ".ai"
        if let targetTag { name += "." + targetTag }
        name += "." + sourceTag + ".part.srt"
        if mediaURL.isFileURL {
            return mediaURL.deletingLastPathComponent().appendingPathComponent(name)
        } else {
            return networkCaptionsDirectory.appendingPathComponent(name)
        }
    }

    /// Prune cached network captions if total directory size exceeds maxBytes or files are older than maxAge.
    static func pruneNetworkCaptions(maxTotalBytes: Int64 = 100 * 1024 * 1024,
                                     maxAge: TimeInterval = 30 * 86400) {
        let dir = networkCaptionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey],
                                                                       options: [.skipsHiddenFiles]) else { return }
        let now = Date()
        struct Entry {
            let url: URL
            let size: Int64
            let date: Date
        }
        var entries: [Entry] = []
        var totalSize: Int64 = 0
        for file in files {
            guard file.pathExtension.lowercased() == "srt" else { continue }
            guard let vals = try? file.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
            let size = Int64(vals.fileSize ?? 0)
            let date = vals.contentAccessDate ?? vals.contentModificationDate ?? now
            if now.timeIntervalSince(date) > maxAge {
                try? FileManager.default.removeItem(at: file)
            } else {
                entries.append(Entry(url: file, size: size, date: date))
                totalSize += size
            }
        }
        if totalSize > maxTotalBytes {
            entries.sort { $0.date < $1.date }
            for entry in entries {
                try? FileManager.default.removeItem(at: entry.url)
                totalSize -= entry.size
                if totalSize <= maxTotalBytes { break }
            }
        }
    }

    // Validate before every floating-point -> integer boundary, including callers
    // that construct events without going through the text parser.
    static func microseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int64(exactly: (seconds * 1_000_000).rounded(.towardZero))
    }

    static func timing(_ event: CaptionRenderEvent) -> (start: Int64, duration: Int64)? {
        guard event.end > event.start, let start = microseconds(event.start),
              let end = microseconds(event.end), end > start else { return nil }
        return (start, end - start)
    }

    /// Extend only ASR-created cues, and never beyond the next known cue or
    /// the media tail. Existing subtitle timings (including intentional overlap)
    /// are preserved rather than guessing which dialogue/title should be lost.
    static func paddedEnd(start: Double, end: Double, nextStart: Double?, total: Double) -> Double {
        let limit = min(total, nextStart ?? total)
        return max(end, min(max(end, start + 0.3), limit))
    }

    static func hasContent(_ events: [CaptionRenderEvent]) -> Bool {
        events.contains {
            timing($0) != nil && (!$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        guard microseconds(seconds) != nil,
              let total = Int64(exactly: (seconds * 1000).rounded()) else { return "00:00:00,000" }
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60000) % 60
        let h = total / 3_600_000
        return String(format: "%02lld:%02lld:%02lld,%03lld", h, m, s, ms)
    }

    static func render(_ events: [CaptionRenderEvent]) -> String {
        var out = ""
        out.reserveCapacity(events.count * 80)
        var index = 0
        for e in events where timing(e) != nil {
            index += 1
            out += "\(index)\n\(timestamp(e.start)) --> \(timestamp(e.end))\n"
            if let t = e.translation, !t.isEmpty { out += t + "\n" }
            out += e.source + "\n\n"
        }
        return out
    }

    private static func outputIOError(_ code: Int32, url: URL) -> Error {
        if code == ENAMETOOLONG { return OutputError.filenameTooLong(url) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
    }

    /// Call on a background worker before expensive generation and again before
    /// committing. Ask the actual filesystem instead of imposing a byte limit:
    /// APFS accepts 255 UTF-16 units even when their UTF-8 representation is longer.
    /// lstat deliberately rejects symlinks rather than following their targets.
    static func validateOutputURL(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        var info = stat()
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return lstat(path, &info) == 0 ? 0 : errno
        }
        if code == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw OutputError.notRegularFile(url) }
        } else {
            guard code == ENOENT else { throw outputIOError(code, url: url) }
        }
    }

    private static func checkOutputMetadata(_ result: Int32, url: URL,
                                            unsupportedAttribute: Bool = false) throws {
        guard result != 0 else { return }
        let code = errno
        // These operations are optional only when the filesystem lacks the
        // capability. Never hide permission, capacity or actual I/O failures.
        if code == ENOTSUP || code == EOPNOTSUPP { return }
        if unsupportedAttribute && code == EINVAL { return }
        throw outputIOError(code, url: url)
    }

    private static func preserveOutputMetadata(_ url: URL, temporaryFD: Int32) throws {
        // Opening without O_TRUNC checks the existing file's write permission,
        // including ACLs, without changing its data. O_NONBLOCK also prevents a
        // raced-in FIFO from blocking this background worker.
        let sourceFD = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if sourceFD < 0 {
            let code = errno
            guard code == ENOENT else { throw outputIOError(code, url: url) }
            return
        }
        defer { Darwin.close(sourceFD) }
        var original = stat(), fresh = stat()
        guard fstat(sourceFD, &original) == 0, fstat(temporaryFD, &fresh) == 0 else {
            throw outputIOError(errno, url: url)
        }
        guard (original.st_mode & S_IFMT) == S_IFREG else { throw OutputError.notRegularFile(url) }
        // Protected outputs cannot be replaced. Never copy protection flags to
        // a temporary file, where they would obstruct failure cleanup as well.
        guard original.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else {
            throw outputIOError(EPERM, url: url)
        }
        try checkOutputMetadata(fcopyfile(sourceFD, temporaryFD, nil, copyfile_flags_t(COPYFILE_STAT)), url: url)
        try checkOutputMetadata(fcopyfile(sourceFD, temporaryFD, nil, copyfile_flags_t(COPYFILE_XATTR)), url: url)
        // Preserve ownership, mode, ACLs, xattrs and creation time, but this is
        // new subtitle content: its access/modification timestamps stay fresh.
        var times = [fresh.st_atimespec, fresh.st_mtimespec]
        try checkOutputMetadata(futimens(temporaryFD, &times), url: url)
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var created = original.st_birthtimespec
        // Older/non-native volumes may reject this particular optional
        // attribute with EINVAL rather than ENOTSUP.
        try checkOutputMetadata(fsetattrlist(temporaryFD, &attributes, &created, MemoryLayout<timespec>.size, 0),
                                url: url, unsupportedAttribute: true)
        if fpathconf(sourceFD, _PC_EXTENDED_SECURITY_NP) != 0 {
            try checkOutputMetadata(fcopyfile(sourceFD, temporaryFD, nil, copyfile_flags_t(COPYFILE_ACL)), url: url)
        }
    }

    /// Write a complete sibling temporary file, then atomically rename it. The
    /// fixed-length, exclusively created temporary name does not depend on the
    /// movie name; every failure removes it and leaves the old destination alone.
    static func write(_ events: [CaptionRenderEvent], to url: URL) throws {
        guard hasContent(events) else { throw OutputError.noContent(url) }
        try validateOutputURL(url)
        let data = Data(render(events).utf8)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".khuaplayer-caption-\(UUID().uuidString).tmp")
        // Let the kernel apply this process's existing umask and directory ACL;
        // reading umask via a set/reset pair would race unrelated app writes.
        let fd = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        }
        guard fd >= 0 else { throw outputIOError(errno, url: url) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var writableOpen = true
        var cleanupFD: Int32 = -1
        var committed = false
        defer {
            if !committed {
                // A copied ACL may deny deletion. Remove restrictions only on
                // our still-open, uncommitted temporary inode before unlinking.
                let metadataFD = cleanupFD >= 0 ? cleanupFD : fd
                _ = fchflags(metadataFD, 0)
                if let acl = acl_init(0) { _ = acl_set_fd(metadataFD, acl); acl_free(UnsafeMutableRawPointer(acl)) }
                _ = fchmod(metadataFD, 0o600)
            }
            if writableOpen { Darwin.close(fd) }
            if cleanupFD >= 0 { Darwin.close(cleanupFD) }
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        // A separate non-writing handle keeps cleanup possible after checked
        // close(), even if a preserved ACL denies reopening or deleting the file.
        cleanupFD = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return Darwin.open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard cleanupFD >= 0 else { throw outputIOError(errno, url: url) }
        try handle.write(contentsOf: data)
        try validateOutputURL(url)
        try preserveOutputMetadata(url, temporaryFD: fd)
        // Foundation's FileHandle.close() does not reliably propagate a failing
        // close(2). Check the actual write descriptor before publishing, so a
        // delayed network/disk error cannot turn into a successful replacement.
        let closeResult = Darwin.close(fd)
        let closeError = errno
        writableOpen = false
        guard closeResult == 0 else { throw outputIOError(closeError, url: url) }
        let code = temporary.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return EINVAL }
                return Darwin.rename(source, destination) == 0 ? 0 : errno
            }
        }
        guard code == 0 else { throw outputIOError(code, url: url) }
        committed = true
    }

    // MARK: Parsing existing subtitle files

    struct ParsedCue: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    /// Treat CRLF as one newline. Splitting both characters independently creates
    /// empty lines that incorrectly separate timestamps from their cue text.
    /// Preserve real blank lines as cue delimiters.
    static func logicalLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func parseTime(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let m = Int(parts[parts.count - 2]), let s = Double(parts[parts.count - 1]),
              (0..<60).contains(m), s.isFinite, s >= 0, s < 60 else { return nil }
        // WebVTT accepts two- or three-component timestamps; SRT/ASS remain compatible.
        let h: Int
        if parts.count == 3 {
            guard let hours = Int(parts[0]), hours >= 0 else { return nil }
            h = hours
        } else { h = 0 }
        let seconds = Double(h) * 3600 + Double(m) * 60 + s
        return microseconds(seconds) == nil ? nil : seconds
    }

    /// Parse SRT/WebVTT, removing inline markup, SDH annotations and empty cues.
    static func parseSRT(_ text: String) -> [ParsedCue] {
        var cues: [ParsedCue] = []
        var block: [String] = []
        func flush() {
            defer { block.removeAll() }
            guard let ti = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let tl = block[ti].components(separatedBy: "-->")
            guard tl.count == 2, let a = parseTime(tl[0]),
                  let b = parseTime(String(tl[1].split(whereSeparator: { $0.isWhitespace }).first ?? "")),
                  b > a else { return }
            let body = block[(ti + 1)...].joined(separator: "\n")
            let cleaned = cleanSubtitleText(body)
            if !cleaned.isEmpty { cues.append(ParsedCue(start: a, end: b, text: cleaned)) }
        }
        for line in logicalLines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(line) }
        }
        flush()
        return cues
    }

    /// Parse ASS/SSA Dialogue fields, remove override tags and expand ASS line breaks.
    static func parseASS(_ text: String) -> [ParsedCue] {
        var cues: [ParsedCue] = []
        for line in logicalLines(text) where line.hasPrefix("Dialogue:") {
            let body = line.dropFirst("Dialogue:".count)
            let parts = body.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard parts.count == 10, let a = parseTime(String(parts[1])),
                  let b = parseTime(String(parts[2])), b > a else { continue }
            let raw = String(parts[9]).replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            let cleaned = cleanSubtitleText(raw)
            if !cleaned.isEmpty { cues.append(ParsedCue(start: a, end: b, text: cleaned)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func cleanSubtitleText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\0", with: "")
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\s*-\\s*", with: "", options: [.regularExpression])
        s = s.replacingOccurrences(of: "♪", with: "")
        let lines = logicalLines(s).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: " ")
    }
}

enum CaptionASS {
    /// ASS styles: Trans for translation, Src for smaller source text, Solo for transcription.
    static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1280
    PlayResY: 720
    WrapStyle: 0

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Solo,Arial,55,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,0,2,25,25,22,1
    Style: Trans,Arial,52,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,0,2,25,25,22,1
    Style: Src,Arial,42,&H30E8E8E8,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,25,25,22,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

    /// Escape braces so text cannot become ASS override tags; encode line breaks as ASS escapes.
    static func escape(_ text: String) -> String {
        CaptionSRT.logicalLines(text).joined(separator: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    /// Matroska ASS payload: ReadOrder, Layer, Style, Name, margins, Effect and Text.
    static func event(readOrder: Int, _ e: CaptionRenderEvent) -> String {
        if let t = e.translation, !t.isEmpty {
            return "\(readOrder),0,Trans,,0,0,0,,\(escape(t))\\N{\\rSrc}\(escape(e.source))"
        }
        return "\(readOrder),0,Solo,,0,0,0,,\(escape(e.source))"
    }
}
