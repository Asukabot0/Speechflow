import AVFoundation
import Foundation

public protocol AudioEngineServicing: AnyObject {
    func setBufferHandler(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func clearBufferHandler()
    func updateRecognitionTuning(_ tuning: RecognitionTuning)
    func updateInputSource(_ inputSource: AudioInputSource)
    func startCapture() throws
    func pauseCapture()
    func stopCapture()
}

public protocol LocalASRServicing: AnyObject {
    func updateLocaleIdentifier(_ localeIdentifier: String)
    func startStreaming(eventSink: @escaping (SpeechflowEvent) -> Void) throws
    func stopStreaming()
}

public protocol NetworkMonitoring: AnyObject {
    func start(eventSink: @escaping (SpeechflowEvent) -> Void)
    func stop()
}

public protocol PermissionServicing: AnyObject {
    func requestPermissions(
        for inputSource: AudioInputSource,
        eventSink: @escaping (SpeechflowEvent) -> Void
    )
}

public protocol TranscriptBuffering: AnyObject {
    var snapshot: TranscriptSnapshot { get }
    func updateLanguagePair(_ pair: LanguagePair)
    func applyPartial(_ text: String) -> TranscriptBufferMutation
    func commitCurrentDraft(reason: CommitReason, now: Date) -> TranscriptBufferMutation?
    func markTranslationStarted(for segmentID: UUID) -> TranscriptSnapshot
    func applyTranslationResult(_ result: TranslationResult, at: Date) -> TranscriptSnapshot
    func markTranslationFailure(for segmentID: UUID, message: String) -> TranscriptSnapshot
    func reset()
}

public protocol TranslateServicing: AnyObject {
    func start(eventSink: @escaping (SpeechflowEvent) -> Void)
    func updateLanguagePair(_ pair: LanguagePair)
    func updatePolicy(_ policy: TranslationPolicy)
    func updateNetworkQuality(_ quality: NetworkQuality)
    func updateBackendPreference(_ backendPreference: TranslationBackendPreference)
    func enqueue(_ segment: TranscriptSegment)
    func cancelAll()
}

public extension TranslateServicing {
    func updateBackendPreference(_ backendPreference: TranslationBackendPreference) {
        _ = backendPreference
    }
}

public protocol OverlayRendering: AnyObject {
    func render(snapshot: OverlayRenderModel)
    func setVisibility(_ isVisible: Bool)
}

public protocol SettingsStoring: AnyObject {
    func load() -> SpeechflowSettings
    func save(_ settings: SpeechflowSettings)
}

public protocol TimeProviding: AnyObject {
    var now: Date { get }
}

public protocol SpeechflowCoordinating: AnyObject {
    var state: AppState { get }
    func handle(_ event: SpeechflowEvent)
}
