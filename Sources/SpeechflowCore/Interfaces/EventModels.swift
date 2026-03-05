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

    public func isReady(for inputSource: AudioInputSource) -> Bool {
        switch inputSource {
        case .microphone:
            return microphoneGranted && speechRecognitionGranted
        case .systemAudio:
            return speechRecognitionGranted
        }
    }

    public func missingRequirementsMessage(for inputSource: AudioInputSource) -> String {
        switch inputSource {
        case .microphone:
            return "Microphone and speech recognition permissions are required."
        case .systemAudio:
            return "Speech recognition permission is required before starting system audio translation."
        }
    }
}

public enum SpeechflowEvent: Sendable {
    case startRequested
    case startMicrophoneRequested
    case startSystemAudioRequested
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
