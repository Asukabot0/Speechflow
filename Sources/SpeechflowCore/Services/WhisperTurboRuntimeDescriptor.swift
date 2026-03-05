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
    public static let defaultModelName = "Qwen/Qwen3-ASR-1.7B"

    public let pythonPath: String
    public let runnerPath: String
    public let modelName: String
    public let downloadRoot: String
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
            modelName: environment["SPEECHFLOW_ASR_MODEL"]
                ?? environment["SPEECHFLOW_FASTER_WHISPER_MODEL"]
                ?? defaultModelName,
            downloadRoot: resolvedDownloadRoot(from: environment),
            localModelPath: resolvedLocalModelPath(from: environment),
            sampleRate: Self.intValue(
                for: "SPEECHFLOW_WHISPER_SAMPLE_RATE",
                defaultValue: defaultSampleRate,
                environment: environment
            ),
            pollingInterval: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_POLL_SECONDS",
                defaultValue: 0.5,
                environment: environment
            ),
            minimumStartingWindowSeconds: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_MIN_START_SECONDS",
                defaultValue: 1.0,
                environment: environment
            ),
            minimumIncrementalWindowSeconds: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_MIN_INCREMENT_SECONDS",
                defaultValue: 0.6,
                environment: environment
            ),
            maximumRetainedWindowSeconds: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_MAX_WINDOW_SECONDS",
                defaultValue: 4.5,
                environment: environment
            ),
            startupTimeout: Self.doubleValue(
                for: "SPEECHFLOW_FASTER_WHISPER_STARTUP_TIMEOUT_SECONDS",
                defaultValue: 120,
                environment: environment
            ),
            requestTimeout: Self.doubleValue(
                for: "SPEECHFLOW_FASTER_WHISPER_REQUEST_TIMEOUT_SECONDS",
                defaultValue: 45,
                environment: environment
            )
        )
    }

    func languageCode(for localeIdentifier: String) -> String {
        if #available(macOS 13.0, *) {
            let locale = Locale(identifier: localeIdentifier)
            if let identifier = locale.language.languageCode?.identifier,
               !identifier.isEmpty {
                return identifier
            }
        }

        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        if let languageComponent = normalized.split(separator: "-").first,
           !languageComponent.isEmpty {
            return String(languageComponent)
        }

        return "auto"
    }

    func runnerEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base

        if let localModelPath {
            if environment["SPEECHFLOW_ASR_MODEL_PATH"] == nil,
               environment["SPEECHFLOW_FASTER_WHISPER_MODEL_PATH"] == nil {
                environment["SPEECHFLOW_ASR_MODEL_PATH"] = localModelPath
            }
        } else if environment["SPEECHFLOW_ASR_MODEL"] == nil,
                  environment["SPEECHFLOW_FASTER_WHISPER_MODEL"] == nil {
            environment["SPEECHFLOW_ASR_MODEL"] = modelName
        }

        if environment["SPEECHFLOW_ASR_DOWNLOAD_ROOT"] == nil,
           environment["SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT"] == nil {
            environment["SPEECHFLOW_ASR_DOWNLOAD_ROOT"] = downloadRoot
        }

        if environment["SPEECHFLOW_ASR_DEVICE"] == nil,
           environment["SPEECHFLOW_FASTER_WHISPER_DEVICE"] == nil {
            environment["SPEECHFLOW_ASR_DEVICE"] = "cpu"
        }

        if environment["SPEECHFLOW_ASR_COMPUTE_TYPE"] == nil,
           environment["SPEECHFLOW_FASTER_WHISPER_COMPUTE_TYPE"] == nil {
            environment["SPEECHFLOW_ASR_COMPUTE_TYPE"] = "int8"
        }

        return environment
    }

    private static func resolvedPythonPath(from environment: [String: String]) -> String {
        if let override = environment["SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH"],
           let resolved = resolveExecutableCandidate(override, environment: environment) {
            return resolved
        }

        let candidates = [
            "python3",
            "/opt/homebrew/Caskroom/miniconda/base/bin/python3",
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
            forResource: "faster_whisper_runner",
            withExtension: "py"
        )?.path {
            return bundled
        }

        // Keep fallback logic identical to original for safety
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        return URL(fileURLWithPath: packageRoot)
            .appendingPathComponent("Resources/faster_whisper_runner.py")
            .path
    }

    private static func resolvedLocalModelPath(
        from environment: [String: String]
    ) -> String? {
        guard let override = environment["SPEECHFLOW_ASR_MODEL_PATH"]
            ?? environment["SPEECHFLOW_FASTER_WHISPER_MODEL_PATH"],
              !override.isEmpty else {
            return nil
        }

        return expandedPath(for: override)
    }

    private static func resolvedDownloadRoot(
        from environment: [String: String]
    ) -> String {
        if let override = environment["SPEECHFLOW_ASR_DOWNLOAD_ROOT"]
            ?? environment["SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT"],
           !override.isEmpty {
            return expandedPath(for: override)
        }

        return expandedPath(
            for: "~/Library/Application Support/Speechflow/Models/ASR"
        )
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
        for key: String,
        defaultValue: TimeInterval,
        environment: [String: String]
    ) -> TimeInterval {
        guard let rawValue = environment[key],
              let value = TimeInterval(rawValue),
              value > 0 else {
            return defaultValue
        }

        return value
    }

    private static func intValue(
        for key: String,
        defaultValue: Int,
        environment: [String: String]
    ) -> Int {
        guard let rawValue = environment[key],
              let value = Int(rawValue),
              value > 0 else {
            return defaultValue
        }

        return value
    }
}
