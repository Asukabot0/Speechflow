import Foundation
@preconcurrency import Translation

@available(macOS 15.0, *)
public final class NativeTranslationService: ObservableObject, TranslateServicing, @unchecked Sendable {
    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var policy: TranslationPolicy = .defaultValue
    private var networkQuality: NetworkQuality = .unknown

    @Published public private(set) var configuration: TranslationSession.Configuration?
    
    // The stream continuation where we push new segments to translate
    private var queueContinuation: AsyncStream<TranscriptSegment>.Continuation?
    
    // Make the stream available to the SwiftUI translationTask closure
    public private(set) var segmentStream: AsyncStream<TranscriptSegment>?
    private var isQueueActive = false
    
    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptSegment.self)
        self.segmentStream = stream
        self.queueContinuation = continuation
    }
    
    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        self.eventSink = eventSink
    }

    /// Call this after SwiftUI views have mounted so that `.translationTask`
    /// sees a nil → non-nil transition and fires its action closure.
    @MainActor
    public func retriggerConfiguration() {
        let current = configuration
        debugLog("[Translation] retriggerConfiguration called, current config: \(current != nil ? "non-nil" : "nil")")
        configuration = nil
        // Yield to the next turn so SwiftUI can observe nil, then restore.
        Task { @MainActor in
            await Task.yield()
            debugLog("[Translation] retriggerConfiguration restoring config")
            self.configuration = current
        }
    }

    public func updateLanguagePair(_ pair: LanguagePair) {
        let source = Locale.Language(identifier: translationLocaleIdentifier(for: pair.sourceCode))
        let target = Locale.Language(identifier: translationLocaleIdentifier(for: pair.targetCode))
        configuration = TranslationSession.Configuration(source: source, target: target)
    }
    
    public func updatePolicy(_ policy: TranslationPolicy) {
        self.policy = policy
    }
    
    public func updateNetworkQuality(_ quality: NetworkQuality) {
        self.networkQuality = quality
    }
    
    public func enqueue(_ segment: TranscriptSegment) {
        debugLog("[Translation] enqueue called, text=\"\(segment.sourceText.prefix(30))\", config=\(configuration != nil), queueActive=\(isQueueActive), hasContinuation=\(queueContinuation != nil), hasEventSink=\(eventSink != nil)")
        guard configuration != nil else {
            eventSink?(
                .translationFailed(
                    segmentID: segment.id,
                    message: "Translation is not configured."
                )
            )
            return
        }

        // Queue segments even before the worker comes online; AsyncStream buffers
        // them until `processQueue` starts consuming.
        queueContinuation?.yield(segment)
    }
    
    public func cancelAll() {
        // We could technically recreate the stream to drop old items
        // For MVP, just dropping them on the UI side or discarding them is fine.
    }
    
    // This method is called from inside the `.translationTask` closure in SwiftUI.
    // IMPORTANT: When SwiftUI cancels and re-invokes this (e.g. on configuration retrigger),
    // the Swift structured-concurrency cancellation propagates into `for await`, which causes
    // the runtime to `finish` the AsyncStream's iterator — making the stream permanently dead.
    // To handle this, we always create a FRESH AsyncStream at the start of each invocation so
    // the new call gets a live, open stream regardless of what happened to the previous one.
    @MainActor
    public func processQueue(with session: TranslationSession) async {
        debugLog("[Translation] processQueue ENTERED — recreating AsyncStream")

        // Create a brand-new stream for this invocation. Any segments yielded into the
        // old (now-dead) stream are lost, but that is acceptable for live-speech MVP use.
        let (freshStream, freshContinuation) = AsyncStream.makeStream(of: TranscriptSegment.self)
        self.segmentStream = freshStream
        self.queueContinuation = freshContinuation

        isQueueActive = true
        defer {
            debugLog("[Translation] processQueue EXITED")
            isQueueActive = false
        }

        var isPrepared = false
        for await segment in freshStream {
            debugLog("[Translation] processQueue: got segment \"\(segment.sourceText.prefix(30))\", eventSink=\(eventSink != nil)")
            do {
                if !isPrepared {
                    debugLog("[Translation] processQueue: preparing session...")
                    try await session.prepareTranslation()
                    isPrepared = true
                    debugLog("[Translation] processQueue: session prepared")
                }

                let response = try await session.translate(segment.sourceText)
                let translatedText = response.targetText
                debugLog("[Translation] processQueue: translated \"\(segment.sourceText.prefix(20))\" → \"\(translatedText.prefix(30))\"")
                
                let result = TranslationResult(
                    segmentID: segment.id,
                    text: translatedText,
                    backend: .system,
                    isDegraded: false,
                    appliedPolish: false
                )
                
                eventSink?(.translationFinished(result))
            } catch {
                debugLog("[Translation] processQueue: ERROR \(error.localizedDescription)")
                eventSink?(.translationFailed(segmentID: segment.id, message: error.localizedDescription))
            }
        }
    }

    private func translationLocaleIdentifier(for code: String) -> String {
        switch code {
        case "zh-Hans":
            return "zh-CN"
        case "zh-Hant":
            return "zh-TW"
        default:
            return code
        }
    }
}
