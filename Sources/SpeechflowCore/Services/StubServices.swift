import AVFoundation
import Foundation
import AVFoundation

public final class StubAudioEngineService: AudioEngineServicing {
    public private(set) var isCapturing = false
    public private(set) var inputSource: AudioInputSource = .microphone
    public private(set) var recognitionTuning: RecognitionTuning = .defaultValue
    private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    public init() {}

    public func setBufferHandler(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        bufferHandler = handler
    }

    public func clearBufferHandler() {
        bufferHandler = nil
    }

    public func updateRecognitionTuning(_ tuning: RecognitionTuning) {
        recognitionTuning = tuning
    }

    public func updateInputSource(_ inputSource: AudioInputSource) {
        self.inputSource = inputSource
    }

    public func startCapture() throws {
        isCapturing = true
    }

    public func pauseCapture() {
        isCapturing = false
    }

    public func stopCapture() {
        isCapturing = false
    }
}

public final class StubASRService: LocalASRServicing {
    private var eventSink: ((SpeechflowEvent) -> Void)?
    public private(set) var localeIdentifier: String

    public init(localeIdentifier: String = Locale.current.identifier) {
        self.localeIdentifier = localeIdentifier
    }

    public func updateLocaleIdentifier(_ localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    public func startStreaming(eventSink: @escaping (SpeechflowEvent) -> Void) throws {
        self.eventSink = eventSink
    }

    public func stopStreaming() {
        eventSink = nil
    }

    public func injectPartial(_ text: String) {
        eventSink?(.asrPartialReceived(text))
    }

    public func injectFinal(_ text: String) {
        eventSink?(.asrFinalReceived(text))
    }
}

public final class StubNetworkMonitor: NetworkMonitoring {
    private var eventSink: ((SpeechflowEvent) -> Void)?
    public private(set) var currentQuality: NetworkQuality

    public init(initialQuality: NetworkQuality = .good) {
        currentQuality = initialQuality
    }

    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        self.eventSink = eventSink
        eventSink(.networkQualityChanged(currentQuality))
    }

    public func stop() {
        eventSink = nil
    }

    public func inject(_ quality: NetworkQuality) {
        currentQuality = quality
        eventSink?(.networkQualityChanged(quality))
    }
}

public final class StubPermissionService: PermissionServicing {
    public var permissions: PermissionSet

    public init(
        permissions: PermissionSet = PermissionSet(
            microphoneGranted: true,
            speechRecognitionGranted: true,
            accessibilityGranted: false
        )
    ) {
        self.permissions = permissions
    }

    public func requestPermissions(
        for inputSource: AudioInputSource,
        eventSink: @escaping (SpeechflowEvent) -> Void
    ) {
        _ = inputSource
        eventSink(.permissionsResolved(permissions))
    }
}

public final class StubTranslateService: TranslateServicing {
    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var policy: TranslationPolicy = .defaultValue
    private var networkQuality: NetworkQuality = .unknown

    public init() {}

    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        self.eventSink = eventSink
    }

    public func updateLanguagePair(_ pair: LanguagePair) {}

    public func updatePolicy(_ policy: TranslationPolicy) {
        self.policy = policy
    }

    public func updateNetworkQuality(_ quality: NetworkQuality) {
        networkQuality = quality
    }

    public func enqueue(_ segment: TranscriptSegment) {
        let result = makeResult(for: segment)
        switch result {
        case .success(let translationResult):
            eventSink?(.translationFinished(translationResult))
        case .failure(let error):
            eventSink?(.translationFailed(segmentID: segment.id, message: error.localizedDescription))
        }
    }

    public func cancelAll() {}

    struct StubError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private func makeResult(for segment: TranscriptSegment) -> Result<TranslationResult, Error> {
        switch policy.strategy {
        case .systemOnly:
            return .success(
                TranslationResult(
                    segmentID: segment.id,
                    text: segment.sourceText,
                    backend: .system,
                    isDegraded: false,
                    appliedPolish: false
                )
            )
        case .originalOnly:
            return .success(
                TranslationResult(
                    segmentID: segment.id,
                    text: nil,
                    backend: .originalOnly,
                    isDegraded: false,
                    appliedPolish: false
                )
            )
        case .remotePreferred:
            switch networkQuality {
            case .good, .unknown:
                return .success(
                    TranslationResult(
                        segmentID: segment.id,
                        text: segment.sourceText,
                        backend: .remote,
                        isDegraded: false,
                        appliedPolish: policy.enableRemotePolish
                    )
                )
            case .constrained, .offline:
                if policy.allowSystemFallback {
                    return .success(
                        TranslationResult(
                            segmentID: segment.id,
                            text: segment.sourceText,
                            backend: .system,
                            isDegraded: true,
                            appliedPolish: false
                        )
                    )
                }

                if policy.allowOriginalOnlyFallback {
                    return .success(
                        TranslationResult(
                            segmentID: segment.id,
                            text: nil,
                            backend: .originalOnly,
                            isDegraded: true,
                            appliedPolish: false
                        )
                    )
                }

                return .failure(StubError(message: "No translation fallback route is available."))
            }
        }
    }
}

public final class StubOverlayRenderer: OverlayRendering {
    public private(set) var lastSnapshot = OverlayRenderModel(
        originalLines: [],
        translatedLines: []
    )
    public private(set) var isVisible = false

    public init() {}

    public func render(snapshot: OverlayRenderModel) {
        lastSnapshot = snapshot
    }

    public func setVisibility(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
}

public final class SystemClock: TimeProviding {
    public init() {}

    public var now: Date {
        Date()
    }
}
