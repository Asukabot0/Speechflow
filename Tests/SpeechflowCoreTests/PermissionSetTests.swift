import Foundation
import Testing
@testable import SpeechflowCore

@Suite("PermissionSet Tests")
struct PermissionSetTests {
    @Test("麦克风模式需要麦克风和 speech 权限")
    func testMicrophoneModeRequiresBothPermissions() {
        let missingSpeech = PermissionSet(
            microphoneGranted: true,
            speechRecognitionGranted: false
        )
        let missingMicrophone = PermissionSet(
            microphoneGranted: false,
            speechRecognitionGranted: true
        )
        let ready = PermissionSet(
            microphoneGranted: true,
            speechRecognitionGranted: true
        )

        #expect(missingSpeech.isReady(for: .microphone) == false)
        #expect(missingSpeech.missingRequirementsMessage(for: .microphone) == "Speech recognition permission is required.")
        #expect(missingMicrophone.isReady(for: .microphone) == false)
        #expect(missingMicrophone.missingRequirementsMessage(for: .microphone) == "Microphone permission is required.")
        #expect(ready.isReady(for: .microphone) == true)
        #expect(ready.isReadyForMVP == true)
    }

    @Test("系统音频模式只在 speech 权限缺失时失败")
    func testSystemAudioRequiresSpeechPermission() {
        let missingSpeech = PermissionSet(
            microphoneGranted: false,
            speechRecognitionGranted: false
        )
        let ready = PermissionSet(
            microphoneGranted: false,
            speechRecognitionGranted: true
        )

        #expect(missingSpeech.isReady(for: .systemAudio) == false)
        #expect(missingSpeech.missingRequirementsMessage(for: .systemAudio) == "Speech recognition permission is required.")
        #expect(ready.isReady(for: .systemAudio) == true)
    }

    @Test("麦克风模式缺两个权限时应返回组合提示")
    func testMicrophoneMissingBothPermissionsMessage() {
        let permissions = PermissionSet(
            microphoneGranted: false,
            speechRecognitionGranted: false
        )

        #expect(
            permissions.missingRequirementsMessage(for: .microphone) ==
                "Microphone and speech recognition permissions are required."
        )
    }
}
