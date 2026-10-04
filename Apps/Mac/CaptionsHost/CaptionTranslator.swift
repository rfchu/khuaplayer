import AppKit
import Foundation
import Translation

// Translation adapter for macOS 26 and later. The headless session requires
// installed language packs; downloads use a separately loaded UI framework.
// Prefer high-fidelity translation where supported, batch complete sentences,
// and normalize Chinese output to the requested writing system.
@available(macOS 26.0, *)
final class CaptionTranslator {
    enum TranslatorError: Error {
        case notInstalled
        case unsupported
    }

    let source: Locale.Language
    let target: Locale.Language
    private var session: TranslationSession?
    private let normalizeTransform: StringTransform?

    init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        self.target = target
        let t = target.minimalIdentifier.lowercased()
        if t == "zh" || t.hasPrefix("zh-hans") || t == "zh-cn" {
            normalizeTransform = StringTransform("Hant-Hans")
        } else if t.hasPrefix("zh-hant") || t == "zh-tw" || t == "zh-hk" {
            normalizeTransform = StringTransform("Hans-Hant")
        } else {
            normalizeTransform = nil
        }
    }

    static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    static func status(source: Locale.Language, target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    private func makeSession() -> TranslationSession {
        TranslationSession(installedSource: source, target: target)
    }

    /// Create and warm a session on demand. Missing assets throw notInstalled so
    /// the caller can present the download host.
    func prepare() async throws {
        try Task.checkCancellation()
        if session != nil { return }
        let st = await Self.status(source: source, target: target)
        try Task.checkCancellation()
        switch st {
        case .installed: break
        case .supported: throw TranslatorError.notInstalled
        default: throw TranslatorError.unsupported
        }
        // The job owns this session; framework cancellation is the only concurrent operation.
        nonisolated(unsafe) let s = makeSession()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await s.prepareTranslation()
            try Task.checkCancellation()
        } onCancel: {
            s.cancel()
        }
        session = s
    }

    /// Translate in input order, using batches of at most 200 sentences.
    func translate(_ texts: [String]) async throws -> [String] {
        try await prepare()
        guard let session else { throw TranslatorError.notInstalled }
        nonisolated(unsafe) let cancellableSession = session
        var out: [String] = []
        out.reserveCapacity(texts.count)
        var i = 0
        while i < texts.count {
            try Task.checkCancellation()
            let end = min(texts.count, i + 200)
            let reqs = texts[i..<end].enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)")
            }
            let resps = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let result = try await session.translations(from: reqs)
                try Task.checkCancellation()
                return result
            } onCancel: {
                cancellableSession.cancel()
            }
            for r in resps { out.append(normalize(r.targetText)) }
            i = end
        }
        return out
    }

    func normalize(_ text: String) -> String {
        guard let normalizeTransform else { return text }
        return text.applyingTransform(normalizeTransform, reverse: false) ?? text
    }
}

// The download UI framework is embedded but not linked into the startup path.
// Load it on demand and invoke its Objective-C download entry point.
@available(macOS 26.0, *)
enum CaptionDownloadHostLoader {
    enum LoadError: Error { case frameworkMissing, classMissing }

    private typealias DownloadIMP = @convention(c) (AnyObject, Selector, NSString, NSString, NSWindow?, NSString,
                                                    @escaping (NSError?) -> Void) -> Void
    private typealias CancelIMP = @convention(c) (AnyObject, Selector, NSString) -> Void

    @MainActor
    private static func cancel(_ requestID: String) {
        guard let cls = NSClassFromString("SPCaptionDownloadHost") else { return }
        let sel = NSSelectorFromString("cancelWithRequestID:")
        guard let method = class_getClassMethod(cls, sel) else { return }
        let imp = unsafeBitCast(method_getImplementation(method), to: CancelIMP.self)
        imp(cls, sel, requestID as NSString)
    }

    @MainActor
    static func download(source: Locale.Language, target: Locale.Language, window: NSWindow?) async throws {
        try Task.checkCancellation()
        guard let url = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("KhuaPlayerCaptionsUI.framework"),
              let bundle = Bundle(url: url) else { throw LoadError.frameworkMissing }
        if !bundle.isLoaded { try bundle.loadAndReturnError() }
        guard let cls = bundle.classNamed("SPCaptionDownloadHost") ?? NSClassFromString("SPCaptionDownloadHost")
        else { throw LoadError.classMissing }
        let sel = NSSelectorFromString("downloadWithSource:target:window:requestID:completion:")
        guard let method = class_getClassMethod(cls, sel) else { throw LoadError.classMissing }
        let imp = unsafeBitCast(method_getImplementation(method), to: DownloadIMP.self)
        let requestID = UUID().uuidString
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                imp(cls, sel, source.minimalIdentifier as NSString, target.minimalIdentifier as NSString, window,
                    requestID as NSString) { err in
                    if let err, err.domain == NSCocoaErrorDomain, err.code == NSUserCancelledError {
                        cont.resume(throwing: CancellationError())
                    } else if let err {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in cancel(requestID) }
        }
        try Task.checkCancellation()
    }
}
