import Foundation

public enum NetworkQuality: String, Codable, Sendable {
    case unknown
    case good
    case constrained
    case offline
}

public enum TranslationBackend: String, Codable, Sendable, Equatable, Hashable {
    case remote
    case system
    case originalOnly
    case localOllama
}

public enum TranslationBackendPreference: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case system
    case localOllama
}

public enum TranslationStrategy: String, Codable, Sendable {
    case remotePreferred
    case systemOnly
    case originalOnly
}

public struct TranslationPolicy: Equatable, Codable, Sendable {
    public var strategy: TranslationStrategy
    public var enableRemotePolish: Bool
    public var allowSystemFallback: Bool
    public var allowOriginalOnlyFallback: Bool

    public init(
        strategy: TranslationStrategy = .remotePreferred,
        enableRemotePolish: Bool = true,
        allowSystemFallback: Bool = true,
        allowOriginalOnlyFallback: Bool = true
    ) {
        self.strategy = strategy
        self.enableRemotePolish = enableRemotePolish
        self.allowSystemFallback = allowSystemFallback
        self.allowOriginalOnlyFallback = allowOriginalOnlyFallback
    }

    public static let defaultValue = TranslationPolicy()
}

public enum LocalModelInstallState: String, Codable, Sendable, Equatable, Hashable {
    case notInstalled
    case ready
    case failed
}

public enum LocalModelRuntimePreference: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case ollama
}

public struct LocalModelDescriptor: Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let version: String
    public let quantization: String
    public let modelName: String
    public let endpoint: String
    public let estimatedSizeInBytes: Int64
    public let runtimePreference: LocalModelRuntimePreference

    public init(
        id: String,
        displayName: String,
        version: String,
        quantization: String,
        modelName: String,
        endpoint: String,
        estimatedSizeInBytes: Int64,
        runtimePreference: LocalModelRuntimePreference = .ollama
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.quantization = quantization
        self.modelName = modelName
        self.endpoint = endpoint
        self.estimatedSizeInBytes = estimatedSizeInBytes
        self.runtimePreference = runtimePreference
    }

    public static func qwen3_5_0_8B(
        endpoint: String,
        runtimePreference: LocalModelRuntimePreference = .ollama
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: "qwen3.5:0.8b",
            displayName: "Qwen3.5:0.8B",
            version: "3.5",
            quantization: "ollama",
            modelName: "qwen3.5:0.8b",
            endpoint: endpoint,
            estimatedSizeInBytes: 1_000_000_000,
            runtimePreference: runtimePreference
        )
    }

    public static func qwen3_5_2B(
        endpoint: String,
        runtimePreference: LocalModelRuntimePreference = .ollama
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: "qwen3.5:2b",
            displayName: "Qwen3.5:2B",
            version: "3.5",
            quantization: "ollama",
            modelName: "qwen3.5:2b",
            endpoint: endpoint,
            estimatedSizeInBytes: 2_700_000_000,
            runtimePreference: runtimePreference
        )
    }
}

public struct TranslationExecutionMetadata: Equatable, Sendable {
    public let requestedBackendPreference: TranslationBackendPreference
    public let resolvedBackend: TranslationBackend
    public let didFallback: Bool
    public let fallbackReason: String?
    public let localModelID: String?
    public let latencyMilliseconds: Int?

    public init(
        requestedBackendPreference: TranslationBackendPreference,
        resolvedBackend: TranslationBackend,
        didFallback: Bool,
        fallbackReason: String? = nil,
        localModelID: String? = nil,
        latencyMilliseconds: Int? = nil
    ) {
        self.requestedBackendPreference = requestedBackendPreference
        self.resolvedBackend = resolvedBackend
        self.didFallback = didFallback
        self.fallbackReason = fallbackReason
        self.localModelID = localModelID
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public struct TranslationResult: Equatable, Sendable {
    public let segmentID: UUID
    public let text: String?
    public let backend: TranslationBackend
    public let isDegraded: Bool
    public let appliedPolish: Bool
    public let metadata: TranslationExecutionMetadata?

    public init(
        segmentID: UUID,
        text: String?,
        backend: TranslationBackend,
        isDegraded: Bool,
        appliedPolish: Bool,
        metadata: TranslationExecutionMetadata? = nil
    ) {
        self.segmentID = segmentID
        self.text = text
        self.backend = backend
        self.isDegraded = isDegraded
        self.appliedPolish = appliedPolish
        self.metadata = metadata
    }
}
