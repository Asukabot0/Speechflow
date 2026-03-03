import Foundation

public struct PermissionSet: Equatable, Sendable {
    public var microphoneGranted: Bool
    public var speechRecognitionGranted: Bool
    public var accessibilityGranted: Bool

    public init(
        microphoneGranted: Bool,
        speechRecognitionGranted: Bool,
        accessibilityGranted: Bool = false
    ) {
        self.microphoneGranted = microphoneGranted
        self.speechRecognitionGranted = speechRecognitionGranted
        self.accessibilityGranted = accessibilityGranted
    }

    public var isReadyForMVP: Bool {
        microphoneGranted && speechRecognitionGranted
    }
}

public enum SpeechflowEvent {
    case startRequested
    case pauseRequested
    case resumeRequested
    case stopRequested
    case permissionsResolved(PermissionSet)
    case permissionRequestFailed(message: String)
    case networkQualityChanged(NetworkQuality)
    case localASRFailed(message: String)
    case asrPartialReceived(String)
    case asrFinalReceived(String)
    case silenceTimeoutTriggered
    case partialStableTimeoutTriggered
    case translationFinished(TranslationResult)
    case translationFailed(segmentID: UUID, message: String)
    case settingsUpdated(SpeechflowSettings)
    case overlayToggled(Bool)
    case translationToggled(Bool)
}
