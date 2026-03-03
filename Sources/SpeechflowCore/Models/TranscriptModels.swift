import Foundation

public enum SegmentStatus: String, Codable, Sendable {
    case draft
    case committed
    case translating
    case translated
    case skipped
    case failed
}

public enum CommitReason: String, Codable, Sendable {
    case finalResult
    case silenceTimeout
    case partialStabilized
    case manualFlush
}

public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var sourceText: String
    public var normalizedSourceText: String
    public var translatedText: String?
    public var status: SegmentStatus
    public var createdAt: Date
    public var committedAt: Date?
    public var translatedAt: Date?
    public var sourceLanguage: String
    public var targetLanguage: String

    public init(
        id: UUID = UUID(),
        sourceText: String,
        normalizedSourceText: String,
        translatedText: String? = nil,
        status: SegmentStatus,
        createdAt: Date = Date(),
        committedAt: Date? = nil,
        translatedAt: Date? = nil,
        sourceLanguage: String,
        targetLanguage: String
    ) {
        self.id = id
        self.sourceText = sourceText
        self.normalizedSourceText = normalizedSourceText
        self.translatedText = translatedText
        self.status = status
        self.createdAt = createdAt
        self.committedAt = committedAt
        self.translatedAt = translatedAt
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public struct TranscriptSnapshot: Equatable, Sendable {
    public let partialText: String
    public let committedSegments: [TranscriptSegment]

    public init(partialText: String, committedSegments: [TranscriptSegment]) {
        self.partialText = partialText
        self.committedSegments = committedSegments
    }
}

public struct TranscriptBufferMutation: Equatable, Sendable {
    public let snapshot: TranscriptSnapshot
    public let committedSegment: TranscriptSegment?
    public let commitReason: CommitReason?

    public init(
        snapshot: TranscriptSnapshot,
        committedSegment: TranscriptSegment? = nil,
        commitReason: CommitReason? = nil
    ) {
        self.snapshot = snapshot
        self.committedSegment = committedSegment
        self.commitReason = commitReason
    }
}
