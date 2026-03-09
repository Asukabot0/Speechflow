import Foundation

internal protocol WhisperTurboRuntime: AnyObject, Sendable {
    var pollingInterval: DispatchTimeInterval { get }
    var minimumStartingSampleCount: Int { get }
    var minimumIncrementSampleCount: Int { get }
    var maximumRetainedSampleCount: Int { get }

    func validateAvailability() throws
    func transcribe(samples: [Float], localeIdentifier: String) throws -> FasterWhisperTranscriptionResponse
    func stop()
}

public struct WhisperTurboRuntimeDescriptor {
    public static let defaultSampleRate = 16_000
    public static let defaultModelName = "mlx-community/Qwen3-ASR-1.7B-4bit"

    public let pythonPath: String
    public let runnerPath: String
    public let modelName: String
    public let localModelPath: String?
    public let sampleRate: Int
    public let pollingInterval: TimeInterval
    public let minimumStartingWindowSeconds: TimeInterval
    public let minimumIncrementalWindowSeconds: TimeInterval
    public let maximumRetainedWindowSeconds: TimeInterval
    public let startupTimeout: TimeInterval
    public let requestTimeout: TimeInterval

    public static func preferred(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WhisperTurboRuntimeDescriptor {
        WhisperTurboRuntimeDescriptor(
            pythonPath: resolvedPythonPath(from: environment),
            runnerPath: resolvedRunnerPath(),
            modelName: stringValue(
                preferredKey: "SPEECHFLOW_ASR_MODEL",
                legacyKey: "SPEECHFLOW_FASTER_WHISPER_MODEL",
                environment: environment
            ) ?? defaultModelName,
            localModelPath: resolvedLocalModelPath(from: environment),
            sampleRate: Self.intValue(
                preferredKey: "SPEECHFLOW_ASR_SAMPLE_RATE",
                legacyKey: nil,
                defaultValue: defaultSampleRate,
                environment: environment
            ),
            pollingInterval: Self.doubleValue(
                preferredKey: "SPEECHFLOW_ASR_POLL_SECONDS",
                legacyKey: "SPEECHFLOW_WHISPER_POLL_SECONDS",
                defaultValue: 0.5,
                environment: environment
            ),
            minimumStartingWindowSeconds: Self.doubleValue(
                preferredKey: "SPEECHFLOW_ASR_MIN_START_SECONDS",
                legacyKey: "SPEECHFLOW_WHISPER_MIN_START_SECONDS",
                defaultValue: 1.0,
                environment: environment
            ),
            minimumIncrementalWindowSeconds: Self.doubleValue(
                preferredKey: "SPEECHFLOW_ASR_MIN_INCREMENT_SECONDS",
                legacyKey: "SPEECHFLOW_WHISPER_MIN_INCREMENT_SECONDS",
                defaultValue: 0.6,
                environment: environment
            ),
            maximumRetainedWindowSeconds: Self.doubleValue(
                preferredKey: "SPEECHFLOW_ASR_MAX_WINDOW_SECONDS",
                legacyKey: "SPEECHFLOW_WHISPER_MAX_WINDOW_SECONDS",
                defaultValue: 4.5,
                environment: environment
            ),
            startupTimeout: Self.doubleValue(
                preferredKey: "SPEECHFLOW_ASR_STARTUP_TIMEOUT_SECONDS",
                legacyKey: "SPEECHFLOW_FASTER_WHISPER_STARTUP_TIMEOUT_SECONDS",
                defaultValue: 120,
                environment: environment
            ),
            requestTimeout: Self.doubleValue(
                preferredKey: "SPEECHFLOW_ASR_REQUEST_TIMEOUT_SECONDS",
                legacyKey: "SPEECHFLOW_FASTER_WHISPER_REQUEST_TIMEOUT_SECONDS",
                defaultValue: 45,
                environment: environment
            )
        )
    }

    func runnerLanguage(for localeIdentifier: String) -> String {
        LocaleIdentifierNormalizer.qwenLanguage(for: localeIdentifier) ?? "auto"
    }

    func runnerEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base

        if let localModelPath {
            if environment["SPEECHFLOW_ASR_MODEL_PATH"] == nil {
                environment["SPEECHFLOW_ASR_MODEL_PATH"] = localModelPath
            }
        } else if environment["SPEECHFLOW_ASR_MODEL"] == nil {
            environment["SPEECHFLOW_ASR_MODEL"] = modelName
        }

        return environment
    }

    private static func resolvedPythonPath(from environment: [String: String]) -> String {
        if let override = stringValue(
            preferredKey: "SPEECHFLOW_ASR_PYTHON_PATH",
            legacyKey: "SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH",
            environment: environment
        ),
           let resolved = resolveExecutableCandidate(override, environment: environment) {
            return resolved
        }

        let candidates = [
            "/opt/homebrew/Caskroom/miniconda/base/bin/python3",
            "python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for candidate in candidates {
            if let resolved = resolveExecutableCandidate(candidate, environment: environment) {
                return resolved
            }
        }

        return "/usr/bin/python3"
    }

    private static func resolvedRunnerPath() -> String {
        if let bundled = Bundle.module.url(
            forResource: "qwen_asr_runner",
            withExtension: "py"
        )?.path {
            return bundled
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        return URL(fileURLWithPath: packageRoot)
            .appendingPathComponent("Resources/qwen_asr_runner.py")
            .path
    }

    private static func resolvedLocalModelPath(
        from environment: [String: String]
    ) -> String? {
        guard let override = stringValue(
            preferredKey: "SPEECHFLOW_ASR_MODEL_PATH",
            legacyKey: "SPEECHFLOW_FASTER_WHISPER_MODEL_PATH",
            environment: environment
        ),
              !override.isEmpty else {
            return nil
        }

        return expandedPath(for: override)
    }

    private static func resolveExecutableCandidate(
        _ candidate: String,
        environment: [String: String]
    ) -> String? {
        let expandedCandidate = expandedPath(for: candidate)
        let fileManager = FileManager.default

        if expandedCandidate.contains("/") {
            return fileManager.isExecutableFile(atPath: expandedCandidate) ? expandedCandidate : nil
        }

        let searchPaths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        for searchPath in searchPaths {
            let path = URL(fileURLWithPath: searchPath)
                .appendingPathComponent(expandedCandidate)
                .path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func expandedPath(for path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func doubleValue(
        preferredKey: String,
        legacyKey: String?,
        defaultValue: TimeInterval,
        environment: [String: String]
    ) -> TimeInterval {
        guard let rawValue = stringValue(
            preferredKey: preferredKey,
            legacyKey: legacyKey,
            environment: environment
        ),
              let value = TimeInterval(rawValue),
              value > 0 else {
            return defaultValue
        }

        return value
    }

    private static func intValue(
        preferredKey: String,
        legacyKey: String?,
        defaultValue: Int,
        environment: [String: String]
    ) -> Int {
        guard let rawValue = stringValue(
            preferredKey: preferredKey,
            legacyKey: legacyKey,
            environment: environment
        ),
              let value = Int(rawValue),
              value > 0 else {
            return defaultValue
        }

        return value
    }

    private static func stringValue(
        preferredKey: String,
        legacyKey: String?,
        environment: [String: String]
    ) -> String? {
        if let value = environment[preferredKey], !value.isEmpty {
            return value
        }

        guard let legacyKey,
              let legacyValue = environment[legacyKey],
              !legacyValue.isEmpty else {
            return nil
        }

        return legacyValue
    }
}
