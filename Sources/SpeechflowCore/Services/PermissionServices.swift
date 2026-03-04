import AVFoundation
import Foundation
import Speech

public final class SystemPermissionService: PermissionServicing {
    private final class EventSinkBox: @unchecked Sendable {
        private let handler: (SpeechflowEvent) -> Void

        init(handler: @escaping (SpeechflowEvent) -> Void) {
            self.handler = handler
        }

        func send(_ event: SpeechflowEvent) {
            handler(event)
        }
    }

    public init() {}

    public func requestPermissions(
        for inputSource: AudioInputSource,
        eventSink: @escaping (SpeechflowEvent) -> Void
    ) {
        guard Self.canPromptForProtectedResourcesInCurrentProcess else {
            let permissions = Self.currentPermissionSnapshot

            if permissions.isReady(for: inputSource) {
                eventSink(.permissionsResolved(permissions))
            } else {
                eventSink(
                    .permissionRequestFailed(
                        message: "Speechflow is running as a raw SwiftPM executable, not a bundled .app. macOS TCC can abort the process when requesting microphone or speech permissions in this mode. Build and launch the packaged Speechflow.app to grant permissions safely."
                    )
                )
            }
            return
        }

        let sinkBox = EventSinkBox(handler: eventSink)
        Self.requestMicrophoneIfNeeded(for: inputSource) {
            Self.requestSpeechIfNeeded {
                let permissions = Self.currentPermissionSnapshot
                DispatchQueue.main.async {
                    sinkBox.send(.permissionsResolved(permissions))
                }
            }
        }
    }

    private static var currentMicrophonePermissionGranted: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static var currentSpeechPermissionGranted: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static var canPromptForProtectedResourcesInCurrentProcess: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var currentPermissionSnapshot: PermissionSet {
        PermissionSet(
            microphoneGranted: Self.currentMicrophonePermissionGranted,
            speechRecognitionGranted: Self.currentSpeechPermissionGranted,
            accessibilityGranted: false
        )
    }

    private static func requestMicrophoneIfNeeded(
        for inputSource: AudioInputSource,
        completion: @escaping @Sendable () -> Void
    ) {
        guard inputSource == .microphone else {
            completion()
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            completion()
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in
            completion()
        }
    }

    private static func requestSpeechIfNeeded(completion: @escaping @Sendable () -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            completion()
            return
        }

        SFSpeechRecognizer.requestAuthorization { _ in
            completion()
        }
    }
}
