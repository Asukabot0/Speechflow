import Foundation
import Testing
@testable import SpeechflowCore

@Suite("WhisperTurboRuntimeDescriptor Tests")
struct WhisperTurboRuntimeDescriptorTests {
    @Test("默认 Qwen 模型名与语言映射应正确")
    func testDefaultModelNameAndLanguageMapping() {
        let descriptor = WhisperTurboRuntimeDescriptor.preferred(environment: ["PATH": ""])

        #expect(WhisperTurboRuntimeDescriptor.defaultModelName == "mlx-community/Qwen3-ASR-1.7B-4bit")
        #expect(descriptor.modelName == "mlx-community/Qwen3-ASR-1.7B-4bit")
        #expect(descriptor.runnerLanguage(for: "en-US") == "English")
        #expect(descriptor.runnerLanguage(for: "zh-Hans") == "Chinese")
        #expect(descriptor.runnerLanguage(for: "ja-JP") == "Japanese")
        #expect(descriptor.runnerLanguage(for: "zz-ZZ") == "auto")
    }

    @Test("应兼容旧环境变量别名")
    func testLegacyEnvironmentAliases() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pythonPath = tempDirectory.appendingPathComponent("python3").path
        FileManager.default.createFile(atPath: pythonPath, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonPath)

        let modelPath = tempDirectory.appendingPathComponent("model").path
        try FileManager.default.createDirectory(atPath: modelPath, withIntermediateDirectories: true)

        let descriptor = WhisperTurboRuntimeDescriptor.preferred(
            environment: [
                "PATH": "",
                "SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH": pythonPath,
                "SPEECHFLOW_FASTER_WHISPER_MODEL": "legacy-model",
                "SPEECHFLOW_FASTER_WHISPER_MODEL_PATH": modelPath,
                "SPEECHFLOW_WHISPER_POLL_SECONDS": "0.75",
                "SPEECHFLOW_WHISPER_MIN_START_SECONDS": "1.5",
                "SPEECHFLOW_WHISPER_MIN_INCREMENT_SECONDS": "0.9",
                "SPEECHFLOW_WHISPER_MAX_WINDOW_SECONDS": "8.0",
                "SPEECHFLOW_FASTER_WHISPER_STARTUP_TIMEOUT_SECONDS": "10",
                "SPEECHFLOW_FASTER_WHISPER_REQUEST_TIMEOUT_SECONDS": "20"
            ]
        )

        #expect(descriptor.pythonPath == pythonPath)
        #expect(descriptor.modelName == "legacy-model")
        #expect(descriptor.localModelPath == modelPath)
        #expect(descriptor.pollingInterval == 0.75)
        #expect(descriptor.minimumStartingWindowSeconds == 1.5)
        #expect(descriptor.minimumIncrementalWindowSeconds == 0.9)
        #expect(descriptor.maximumRetainedWindowSeconds == 8.0)
        #expect(descriptor.startupTimeout == 10)
        #expect(descriptor.requestTimeout == 20)
    }

    @Test("新环境变量应优先于旧别名")
    func testPreferredEnvironmentVariablesWin() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyPythonPath = tempDirectory.appendingPathComponent("legacy-python3").path
        let preferredPythonPath = tempDirectory.appendingPathComponent("preferred-python3").path
        FileManager.default.createFile(atPath: legacyPythonPath, contents: Data())
        FileManager.default.createFile(atPath: preferredPythonPath, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyPythonPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preferredPythonPath)

        let descriptor = WhisperTurboRuntimeDescriptor.preferred(
            environment: [
                "PATH": "",
                "SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH": legacyPythonPath,
                "SPEECHFLOW_ASR_PYTHON_PATH": preferredPythonPath,
                "SPEECHFLOW_FASTER_WHISPER_MODEL": "legacy-model",
                "SPEECHFLOW_ASR_MODEL": "preferred-model",
                "SPEECHFLOW_WHISPER_POLL_SECONDS": "0.9",
                "SPEECHFLOW_ASR_POLL_SECONDS": "0.4"
            ]
        )

        #expect(descriptor.pythonPath == preferredPythonPath)
        #expect(descriptor.modelName == "preferred-model")
        #expect(descriptor.pollingInterval == 0.4)
    }
}
