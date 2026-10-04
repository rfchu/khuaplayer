import Foundation

// Caption generation proceeds from the beginning of the media, independently
// of playback position and seeks. Reader I/O yields to foreground playback
// without discarding completed work. Sidecars are written only after completion.
//
// The engine is created on demand. File reads run on a dedicated serial utility
// queue with throttled disk I/O; recognition and translation run in a detached
// task. Public callbacks return to the main thread. The playback integration
// consists of a read-only admission probe and delivery of subtitle events.
@available(macOS 26.0, *)
final class CaptionEngine: @unchecked Sendable {
    struct Configuration: Sendable {
        var mediaURL: URL
        var audioStreamIndex: Int
        var sourceLocale: Locale
        var targetLanguage: Locale.Language?
        var durationSeconds: Double
        /// Non-nil means translate existing cues without speech recognition.
        var existingCues: [CaptionSRT.ParsedCue]? = nil
        /// Source file identity distinguishes tasks that would produce the same filename.
        var sourceFileURL: URL? = nil
        /// A nonnegative container stream index selects an embedded text subtitle track.
        /// Read its cues sequentially from the beginning, yielding I/O to playback.
        var embeddedSubtitleStream: Int = -1
        /// The player's timeline origin in microseconds. Readers use the same signed
        /// origin so generated cue times align with playback and embedded subtitles.
        var timelineOriginUs: Int64 = 0
    }

    enum Phase: Equatable, Sendable {
        case preparing
        case downloadingModel(Double)
        /// doneSeconds is the completed media frontier; eta is estimated remaining
        /// wall-clock time in seconds, or nil until a complete-window estimate exists.
        case transcribing(doneSeconds: Double, eta: Double?)
        case translating
        case saving
        case finished
        case failed(String)
    }

    let configuration: Configuration
    /// The primary sidecar contains bilingual cues when a target language is selected.
    let sidecarURL: URL
    /// Speech translation also writes a source-language transcription sidecar so
    /// another target language can reuse it without running recognition again.
    let transcriptURL: URL?
    let sourceTag: String
    let targetTag: String?
    /// Track or file identity prevents reuse across distinct subtitle sources.
    let sourceKey: String

    /// A thread-safe, read-only admission probe. False pauses reader I/O at block
    /// boundaries until playback is idle; nil permits background work.
    var yieldProbe: (@Sendable () -> Bool)?

    /// Callbacks execute on the main thread.
    var onEvents: (([CaptionRenderEvent]) -> Void)?
    var onProgress: ((Double, Phase) -> Void)?
    var onFinished: ((Error?) -> Void)?
    var onPlaybackWaitChanged: ((Bool) -> Void)?

    private let readerQueue = DispatchQueue(label: "dev.khuaplayer.captions.audio", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var outputCommitStarted = false
    private var playbackWait = CaptionPlaybackWaitState()
    private var task: Task<Void, Never>?
    private var reader: SPCaptionAudioReader?
    private var subtitleReader: SPCaptionSubtitleReader?

    // Only the run task mutates engine state. The event snapshot remains locked
    // because the main thread may read it concurrently.
    private var words: [CaptionWord] = []
    /// Completed cells form the contiguous range [0, doneCells).
    private var doneCells = 0
    private var translations: [String: String] = [:]
    private var nextSegment = 0
    private var emittedKeys: Set<String> = []
    private var committedEventsStorage: [CaptionRenderEvent] = []
    private let policy: CaptionSegmentationPolicy

    init(configuration: Configuration) {
        self.configuration = configuration
        sourceTag = CaptionLanguageTags.fileTag(forTranscriberLocale: configuration.sourceLocale)
        targetTag = configuration.targetLanguage.map {
            CaptionLanguageTags.fileTag(forTargetLanguage: $0.minimalIdentifier)
        }
        sidecarURL = CaptionSRT.sidecarURL(for: configuration.mediaURL, sourceTag: sourceTag, targetTag: targetTag)
        let speech = configuration.existingCues == nil && configuration.embeddedSubtitleStream < 0
        transcriptURL = (speech && targetTag != nil)
            ? CaptionSRT.sidecarURL(for: configuration.mediaURL, sourceTag: sourceTag, targetTag: nil) : nil
        policy = .forScript(CaptionScript.forLocale(configuration.sourceLocale))
        sourceKey = Self.sourceKey(for: configuration)
    }

    static func sourceKey(for c: Configuration) -> String {
        if let f = c.sourceFileURL { return "f:" + f.standardizedFileURL.path }
        if c.existingCues != nil { return "f:?" }
        if c.embeddedSubtitleStream >= 0 { return "s:\(c.embeddedSubtitleStream)" }
        return "a:\(c.audioStreamIndex)"
    }

    /// Snapshot of committed events for reattaching a subtitle display.
    var committedEvents: [CaptionRenderEvent] {
        lock.lock(); defer { lock.unlock() }
        return committedEventsStorage
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    var isSaving: Bool { lock.withLock { outputCommitStarted } }

    func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [self] in
                let outcome: Error?
                do {
                    try await run()
                    outcome = nil
                } catch {
                    outcome = isStopped || Task.isCancelled ? CancellationError() : error
                }
                // Complete only after run, system analysis and background reader cleanup finish.
                releaseReaders()
                words.removeAll(keepingCapacity: false)
                translations.removeAll(keepingCapacity: false)
                emittedKeys.removeAll(keepingCapacity: false)
                await finish(outcome)
            }
        }
    }

    /// Nonblocking and idempotent. Request cancellation without releasing the
    /// app-wide execution slot early. Once final publication starts, finish it.
    @discardableResult
    func stop() -> Bool {
        let pending = lock.withLock { () -> (SPCaptionAudioReader?, SPCaptionSubtitleReader?, Task<Void, Never>?)? in
            guard !outputCommitStarted else { return nil }
            stopped = true
            return (reader, subtitleReader, task)
        }
        pending?.0?.abort()
        pending?.1?.abort()
        pending?.2?.cancel()
        return pending != nil
    }

    /// Asynchronously await I/O, system inference and the single terminal callback.
    func waitUntilStopped() async {
        let pending = lock.withLock { task }
        await pending?.value
    }

    func stopAndWait() async {
        stop()
        await waitUntilStopped()
    }

    private func checkCancellation() throws {
        if isStopped { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func releaseReaders() {
        // Keep a local strong reference so file-closing destruction occurs outside the lock.
        let held = lock.withLock {
            let held = (reader, subtitleReader)
            reader = nil
            subtitleReader = nil
            return held
        }
        withExtendedLifetime(held) {}
    }

    // MARK: - Execution

    private func report(_ progress: Double, _ phase: Phase) {
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            onProgress?(progress, phase)
        }
    }

    private func publish(_ events: [CaptionRenderEvent]) {
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            onEvents?(events)
        }
    }

    /// Called by the sole execution task after success, failure or cancellation.
    private func finish(_ error: Error?) async {
        if spDebugEnabled {
            if let error { NSLog("[Captions] 结束（失败）：%@", error.localizedDescription) }
            else { NSLog("[Captions] 结束：%d 条 → %@", committedEvents.count, sidecarURL.lastPathComponent) }
        }
        await withCheckedContinuation { cont in
            DispatchQueue.main.async { [self] in
                if let error, !(error is CancellationError) {
                    onProgress?(progressFraction(CaptionScheduler.cellCount(totalSeconds: configuration.durationSeconds)),
                                .failed(error.localizedDescription))
                } else if error == nil {
                    onProgress?(1, .finished)
                }
                onFinished?(error)
                cont.resume()
            }
        }
    }

    /// Start final publication only after all computation; cancellation wins until then.
    private func finishRun() throws {
        try checkCancellation()
        let snapshot = committedEvents
        guard CaptionSRT.hasContent(snapshot) else {
            throw CaptionNoContentError(speech: configuration.existingCues == nil && configuration.embeddedSubtitleStream < 0)
        }
        try lock.withLock {
            if stopped { throw CancellationError() }
            outputCommitStarted = true
        }
        report(1, .saving)
        do { try CaptionSRT.write(snapshot, to: sidecarURL) }
        catch { throw CaptionSaveError(url: sidecarURL, underlying: error) }
        if let transcriptURL {
            do {
                try CaptionSRT.write(snapshot.map { CaptionRenderEvent(start: $0.start, end: $0.end, source: $0.source, translation: nil) },
                                     to: transcriptURL)
            } catch { throw CaptionSaveError(url: transcriptURL, underlying: error) }
        }
    }

    private var startedAt = Date()

    /// Preserve the inter-window playback protection delay; cancellation ends it promptly.
    private func waitBetweenJobs(remote: Bool) async throws {
        let sinceStart = Date().timeIntervalSince(startedAt)
        if sinceStart < 12 { try await Task.sleep(for: .seconds(12 - sinceStart)) }
        try await Task.sleep(for: .seconds(remote ? 3 : 2))
    }

    private var shouldPause: @Sendable () -> Bool {
        let probe = yieldProbe
        return { [weak self] in
            let paused = probe.map { !$0() } ?? false
            guard let self else { return paused }
            let transition = lock.withLock {
                playbackWait.update(paused: paused, now: paused ? ProcessInfo.processInfo.systemUptime : 0)
            }
            if let transition {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !isStopped else { return }
                    onPlaybackWaitChanged?(transition)
                }
            }
            return paused
        }
    }

    private func readError(_ error: Error?) -> Error {
        error ?? CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: configuration.mediaURL])
    }

    private func run() async throws {
        try checkCancellation()
        startedAt = Date()
        report(0, .preparing)
        // Metadata-only preflight stays off the main thread and honors the same
        // playback demand as reading. Actual commit revalidates against races.
        let preflightPause = shouldPause
        while preflightPause() {
            try checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        for url in [sidecarURL, transcriptURL].compactMap({ $0 }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readerQueue.async {
                    do {
                        try CaptionSRT.validateOutputURL(url)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: CaptionSaveError(url: url, underlying: error))
                    }
                }
            }
            try checkCancellation()
        }
        if let cues = configuration.existingCues {
            try await runTranslateOnly(cues: cues)
            return
        }
        if configuration.embeddedSubtitleStream >= 0 {
            try await runEmbeddedTrack()
            return
        }
        // Configuration completes before publication. Open/read use only readerQueue;
        // abort() is the sole cross-thread write and uses the reader's atomic state.
        nonisolated(unsafe) let r = SPCaptionAudioReader(path: configuration.mediaURL.isFileURL ? configuration.mediaURL.path : configuration.mediaURL.absoluteString,
                                     audioStreamIndex: Int32(configuration.audioStreamIndex))
        r.timelineOriginUs = configuration.timelineOriginUs
        setReader(r)
        try checkCancellation()
        let pause = shouldPause
        let opened: Bool = await withCheckedContinuation { cont in
            readerQueue.async { cont.resume(returning: r.open(shouldPause: pause)) }
        }
        try checkCancellation()
        guard opened else { throw readError(r.lastError) }

        let transcriber = CaptionTranscriber(locale: configuration.sourceLocale)
        do {
            try await transcriber.prepare { [weak self] p in self?.report(p, .downloadingModel(p)) }
            try checkCancellation()
            var translator: CaptionTranslator?
            if let target = configuration.targetLanguage {
                let t = CaptionTranslator(source: Locale.Language(identifier: sourceTag), target: target)
                try await t.prepare()
                try checkCancellation()
                translator = t
            }
            let total = configuration.durationSeconds
            let cellCount = CaptionScheduler.cellCount(totalSeconds: total)
            report(0, .transcribing(doneSeconds: 0, eta: nil))
            let remote = r.remoteVolume
            let fileSize = Double(r.fileSize)
            let bytesPerSecond = fileSize / max(1, total)
            let steadyCells = remote ? 1 : (bytesPerSecond > 4_000_000 ? 2 : CaptionScheduler.steadyCells)
            if spDebugEnabled {
                NSLog("[Captions] 文件 %.1f GB，%.1f MB/s，%@，窗 %d 格，从 0 s 起线性", fileSize / 1e9, bytesPerSecond / 1e6,
                      remote ? "远程卷" : "本地卷", steadyCells)
            }
            var firstJob = true
            var estimate = CaptionWorkEstimate()
            while let job = CaptionScheduler.nextJob(doneCells: doneCells, totalSeconds: total, steadyCells: steadyCells) {
                let jobStarted = ProcessInfo.processInfo.systemUptime
                if !firstJob { try await waitBetweenJobs(remote: remote) }
                try checkCancellation()
                firstJob = false
                let a0 = max(0, job.start - CaptionScheduler.overlapSeconds)
                let a1 = min(total, job.end + CaptionScheduler.overlapSeconds)
                let pcmOpt = await readPCM(r, start: a0, duration: a1 - a0, shouldPause: shouldPause)
                try checkCancellation()
                guard var pcm = pcmOpt else { throw readError(r.lastError) }
                // Empty non-nil data is a valid EOF or empty interval, not a read failure.
            // Do not manufacture input by padding silence past the real stream end.
                if !pcm.isEmpty {
                    pcm.append(Data(count: Int(1.5 * 16000) * 2))
#if !SP_APP_STORE
                    if spDebugEnabled, let dir = ProcessInfo.processInfo.environment["SP_CAPTIONS_DUMP"] {
                        try? pcm.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "job_%06.1f.s16", a0)))
                    }
#endif
                    let segs = try await transcriber.transcribe(pcm16k: pcm, startSeconds: a0, segmentBase: nextSegment)
                    try checkCancellation()
                    nextSegment += segs.count
                    var added: [CaptionWord] = []
                    for s in segs where CaptionScheduler.owns(job: job, segmentStart: s.start, segmentEnd: s.end) {
                        for var w in s.words {
                            guard w.start.isFinite, w.end.isFinite else { continue }
                            w.end = min(w.end, a1)
                            w.start = max(a0, w.start)
                            guard w.end > w.start else { continue }
                            added.append(w)
                        }
                    }
                    if spDebugEnabled {
                        NSLog("[Captions] 作业 cells %d+%d [%.1f,%.1f) 音频 [%.1f,%.1f) %.1fs 段=%d 归属词=%d",
                              job.firstCell, job.cellCount, job.start, job.end, a0, a1,
                              Double(pcm.count / 2) / 16000, segs.count, added.count)
                    }
                    words.append(contentsOf: added)
                }
                doneCells = job.cells.upperBound
                // Even an empty final window releases the cue held behind the frontier margin.
                try await commit(translator: translator)
                estimate.record(cells: job.cellCount, elapsed: ProcessInfo.processInfo.systemUptime - jobStarted)
                report(progressFraction(cellCount),
                       .transcribing(doneSeconds: doneSeconds(total), eta: estimate.remaining(cells: cellCount - doneCells)))
            }
        } catch {
            await transcriber.close()
            throw error
        }
        await transcriber.close()
        try finishRun()
    }

    // MARK: - Progress and end-to-end estimates

    private func progressFraction(_ cellCount: Int) -> Double {
        Double(doneCells) / Double(max(1, cellCount))
    }

    /// Completed media time at the contiguous frontier.
    private func doneSeconds(_ total: Double) -> Double {
        min(total, Double(doneCells) * CaptionScheduler.cellSeconds)
    }

    private func readPCM(_ r: SPCaptionAudioReader, start: Double, duration: Double,
                         shouldPause: @escaping @Sendable () -> Bool) async -> Data? {
        nonisolated(unsafe) let queuedReader = r
        return await withCheckedContinuation { cont in
            readerQueue.async {
                cont.resume(returning: queuedReader.readMonoPCM(fromSeconds: start, durationSeconds: duration, shouldPause: shouldPause))
            }
        }
    }

    /// Translate and cache a sentence batch, retrying one transient failure.
    /// Propagate a second failure so missing translations cannot count as success.
    private func translateAndCache(_ needed: [String], translator: CaptionTranslator) async throws {
        guard !needed.isEmpty else { return }
        var out: [String]
        do {
            out = try await translator.translate(needed)
        } catch {
            if error is CancellationError { throw error }
            try checkCancellation()
            try await Task.sleep(for: .seconds(1))
            out = try await translator.translate(needed)
        }
        try checkCancellation()
        guard out.count == needed.count else {
            throw NSError(domain: "dev.khuaplayer.captions", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("captions.error.translationIncomplete", comment: "")])
        }
        for (src, dst) in zip(needed, out) { translations[src] = dst }
    }

    /// Segment words, translate new sentences and publish finalized cues before
    /// the frontier. Sidecar publication waits for completion; translation errors propagate.
    private func commit(translator: CaptionTranslator?) async throws {
        let total = configuration.durationSeconds
        let (sentences, segmentedCues) = CaptionSegmenter.segment(words, policy: policy)
        // Window ownership is based on segment midpoints, so an overlapping
        // segment received later can start earlier than the last appended cue.
        // Sort only the display view; sentence membership/word order stay intact.
        let cues = segmentedCues.sorted { $0.start < $1.start }
        // The next ASR input starts overlapSeconds before this frontier. Hold
        // that tail until the next window, including any minimum-duration
        // padding, so a newly owned segment cannot start inside a committed cue.
        let committable = cues.enumerated().compactMap { index, cue -> (cue: CaptionCue, end: Double)? in
            let end = CaptionSRT.paddedEnd(start: cue.start, end: cue.end,
                nextStart: index + 1 < cues.count ? cues[index + 1].start : nil, total: total)
            guard CaptionScheduler.committable(start: cue.start, end: end, margin: CaptionScheduler.overlapSeconds,
                doneCells: doneCells, totalSeconds: total) else { return nil }
            return (cue, end)
        }
        guard !committable.isEmpty else { return }
        var sentenceText: [Int: String] = [:]
        for s in sentences { sentenceText[s.id] = s.text }
        if let translator {
            let needed = Array(Set(committable.compactMap { sentenceText[$0.cue.sentenceID] })
                .filter { translations[$0] == nil }).sorted()
            if !needed.isEmpty {
                report(progressFraction(CaptionScheduler.cellCount(totalSeconds: total)), .translating)
                try await translateAndCache(needed, translator: translator)
            }
        }
        var fresh: [CaptionRenderEvent] = []
        for (c, end) in committable {
            let key = "\(Int((c.start * 1000).rounded()))|\(Int((c.end * 1000).rounded()))|\(c.text)"
            if emittedKeys.contains(key) { continue }
            let tr = translator != nil ? sentenceText[c.sentenceID].flatMap { translations[$0] } : nil
            if translator != nil, tr == nil { continue } // Wait for the complete sentence translation before publishing its cues.
            emittedKeys.insert(key)
            fresh.append(CaptionRenderEvent(start: c.start, end: end,
                                            source: c.text, translation: tr))
        }
        guard !fresh.isEmpty else { return }
        _ = appendCommitted(fresh, sorted: true)
        publish(fresh)
    }

    // Synchronous lock wrapper for use from asynchronous code.
    private func setReader(_ r: SPCaptionAudioReader) {
        let cancel = lock.withLock { reader = r; return stopped }
        if cancel { r.abort() }
    }

    private func appendCommitted(_ fresh: [CaptionRenderEvent], sorted: Bool) -> [CaptionRenderEvent] {
        lock.withLock {
            committedEventsStorage.append(contentsOf: fresh)
            if sorted { committedEventsStorage.sort { $0.start < $1.start } }
            return committedEventsStorage
        }
    }

    // MARK: - Sequential embedded subtitle translation

    private func runEmbeddedTrack() async throws {
        guard let target = configuration.targetLanguage else { throw CaptionTranslator.TranslatorError.unsupported }
        // Use the same serial-queue and atomic-abort contract as the audio reader.
        nonisolated(unsafe) let sr = SPCaptionSubtitleReader(path: configuration.mediaURL.isFileURL ? configuration.mediaURL.path : configuration.mediaURL.absoluteString,
                                         subtitleStreamIndex: Int32(configuration.embeddedSubtitleStream))
        sr.timelineOriginUs = configuration.timelineOriginUs
        let cancelled = lock.withLock { subtitleReader = sr; return stopped }
        if cancelled { sr.abort() }
        try checkCancellation()
        let pause = shouldPause
        let opened: Bool = await withCheckedContinuation { cont in
            readerQueue.async { cont.resume(returning: sr.open(shouldPause: pause)) }
        }
        try checkCancellation()
        guard opened else { throw readError(sr.lastError) }
        let translator = CaptionTranslator(source: Locale.Language(identifier: sourceTag), target: target)
        try await translator.prepare()
        try checkCancellation()
        let total = configuration.durationSeconds
        let cellCount = CaptionScheduler.cellCount(totalSeconds: total)
        var cues: [CaptionSRT.ParsedCue] = []
        var seen: Set<String> = []
        report(0, .translating)
        var firstJob = true
        while let job = CaptionScheduler.nextJob(doneCells: doneCells, totalSeconds: total) {
            if !firstJob { try await waitBetweenJobs(remote: false) }
            try checkCancellation()
            firstJob = false
            let got: [CaptionSRT.ParsedCue]? = await withCheckedContinuation { cont in
                readerQueue.async {
                    let raw = sr.readCues(fromSeconds: job.start, durationSeconds: job.end - job.start, shouldPause: pause)
                    cont.resume(returning: raw?.map {
                        CaptionSRT.ParsedCue(start: $0.start, end: $0.end, text: CaptionSRT.cleanSubtitleText($0.text))
                    })
                }
            }
            try checkCancellation()
            guard let got else { throw readError(sr.lastError) }
            for c in got {
                let key = "\(Int((c.start * 1000).rounded()))|\(c.text)"
                if seen.insert(key).inserted { cues.append(c) }
            }
            doneCells = job.cells.upperBound
            try await commitCues(cues.filter { !$0.text.isEmpty }, translator: translator)
            report(progressFraction(cellCount), .translating)
        }
        try finishRun()
    }

    /// Group the growing cue sequence into sentences, translate new sentences and
    /// publish finalized cues before the frontier. Translation failures propagate.
    private func commitCues(_ all: [CaptionSRT.ParsedCue], translator: CaptionTranslator) async throws {
        let sorted = all.sorted { $0.start < $1.start }
        let pseudo = sorted.map { CaptionWord(start: $0.start, end: $0.end, text: $0.text, confidence: 1, segment: 0) }
        let sentences = CaptionSegmenter.groupSentences(pseudo, policy: policy)
        // Map cues by sentence membership, not overlapping timestamp boundaries.
        let cueSentence = CaptionSegmenter.sentenceIndex(forWords: pseudo, sentences: sentences)
        let total = configuration.durationSeconds
        var needed: [String] = []
        for (i, c) in sorted.enumerated()
        where CaptionScheduler.committable(start: c.start, end: c.end, margin: 1.0, doneCells: doneCells, totalSeconds: total) {
            guard let si = cueSentence[i] else { continue }
            let t = sentences[si].text
            if translations[t] == nil, !needed.contains(t) { needed.append(t) }
        }
        try await translateAndCache(needed, translator: translator)
        var fresh: [CaptionRenderEvent] = []
        for (i, c) in sorted.enumerated()
        where CaptionScheduler.committable(start: c.start, end: c.end, margin: 1.0, doneCells: doneCells, totalSeconds: total) {
            let key = "\(Int((c.start * 1000).rounded()))|\(c.text)"
            if emittedKeys.contains(key) { continue }
            guard let si = cueSentence[i], let tr = translations[sentences[si].text] else { continue }
            emittedKeys.insert(key)
            fresh.append(CaptionRenderEvent(start: c.start, end: c.end, source: c.text, translation: tr))
        }
        guard !fresh.isEmpty else { return }
        _ = appendCommitted(fresh, sorted: true)
        publish(fresh)
    }

    // MARK: - Existing subtitle translation

    /// Group adjacent cues by punctuation and pauses, then emit bilingual events.
    private func runTranslateOnly(cues: [CaptionSRT.ParsedCue]) async throws {
        guard let target = configuration.targetLanguage else { throw CaptionTranslator.TranslatorError.unsupported }
        let translator = CaptionTranslator(source: Locale.Language(identifier: sourceTag), target: target)
        try await translator.prepare()
        try checkCancellation()
        // Treat each cue as one word in a shared segment; punctuation and pauses split sentences.
        let sorted = cues.sorted { $0.start < $1.start }
        let pseudo = sorted.map { CaptionWord(start: $0.start, end: $0.end, text: $0.text, confidence: 1, segment: 0) }
        let sentences = CaptionSegmenter.groupSentences(pseudo, policy: policy)
        // Map cues by sentence membership; blank cues belong to no sentence.
        let cueSentence = CaptionSegmenter.sentenceIndex(forWords: pseudo, sentences: sentences)
        report(0, .translating)
        let texts = sentences.map(\.text)
        var i = 0
        while i < texts.count {
            try checkCancellation()
            let end = min(texts.count, i + 100)
            let needed = Array(Set(texts[i..<end].filter { translations[$0] == nil })).sorted()
            try await translateAndCache(needed, translator: translator)
            i = end
            // Publish the cues for each completed translation batch immediately.
            var fresh: [CaptionRenderEvent] = []
            for (ci, c) in sorted.enumerated() {
                guard let si = cueSentence[ci], si < i, let tr = translations[texts[si]] else { continue }
                let key = "\(ci)"
                if emittedKeys.contains(key) { continue }
                emittedKeys.insert(key)
                fresh.append(CaptionRenderEvent(start: c.start, end: c.end, source: c.text, translation: tr))
            }
            if !fresh.isEmpty {
                _ = appendCommitted(fresh, sorted: false)
                publish(fresh)
            }
            report(Double(i) / Double(max(1, texts.count)), .translating)
        }
        try finishRun()
    }

    // MARK: - Content-based language detection

    /// Sample up to five 60-second intervals from the beginning, independently of
    /// playback. The at parameter is retained for call compatibility. Nil means
    /// unrecognized language; read errors and cancellation remain errors.
    static func detectLanguage(mediaURL: URL, audioStreamIndex: Int, timelineOriginUs: Int64 = 0,
                               at _: Double, candidates: [Locale],
                               progress: @escaping @Sendable (Double) -> Void) async throws -> Locale? {
        try Task.checkCancellation()
        guard !candidates.isEmpty else { return nil }
        nonisolated(unsafe) let r = SPCaptionAudioReader(path: mediaURL.isFileURL ? mediaURL.path : mediaURL.absoluteString, audioStreamIndex: Int32(audioStreamIndex))
        r.timelineOriginUs = timelineOriginUs
        let q = DispatchQueue(label: "dev.khuaplayer.captions.probe", qos: .utility)
        var fallback: Locale?
        for attempt in 0..<5 {
            try Task.checkCancellation()
            let start = Double(attempt) * 60
            let pcm: Data? = await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    q.async {
                        cont.resume(returning: r.readMonoPCM(fromSeconds: start, durationSeconds: 60,
                                                             shouldPause: { !CaptionProbeRegistry.idle() }))
                    }
                }
            } onCancel: {
                r.abort()
            }
            try Task.checkCancellation()
            guard let pcm else {
                throw r.lastError ?? CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: mediaURL])
            }
            if pcm.count < 16000 * 2 * 3 { break }
            guard let hit = try await CaptionLanguageProbe.detect(pcm16k: pcm, startSeconds: start,
                                                                  candidates: candidates, progress: progress)
            else { continue }
            try Task.checkCancellation()
            if hit.confidence >= 0.45 { return hit.locale }
            fallback = fallback ?? hit.locale
        }
        try Task.checkCancellation()
        return fallback
    }

}

/// A completed caption result could not be written to its destination.
struct CaptionSaveError: LocalizedError, Sendable {
    var url: URL
    var underlying: Error
    var errorDescription: String? {
        String(format: NSLocalizedString("captions.error.saveOutput", comment: ""), url.lastPathComponent)
    }
}
