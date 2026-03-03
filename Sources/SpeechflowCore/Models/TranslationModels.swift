import Foundation

public enum NetworkQuality: String, Codable, Sendable {
    case unknown
    case good
    case constrained
    case offline
}

public enum TranslationBackend: String, Codable, Sendable {
    case remote
    case system
    case originalOnly
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

public struct TranslationResult: Equatable, Sendable {
    public let segmentID: UUID
    public let text: String?
    public let backend: TranslationBackend
    public let isDegraded: Bool
    public let appliedPolish: Bool

    public init(
        segmentID: UUID,
        text: String?,
        backend: TranslationBackend,
        isDegraded: Bool,
        appliedPolish: Bool
    ) {
        self.segmentID = segmentID
        self.text = text
        self.backend = backend
        self.isDegraded = isDegraded
        self.appliedPolish = appliedPolish
    }
}
