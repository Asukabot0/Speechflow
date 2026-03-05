import Foundation

public struct OverlayLine: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let isCommitted: Bool

    public init(id: UUID, text: String, isCommitted: Bool) {
        self.id = id
        self.text = text
        self.isCommitted = isCommitted
    }
}

public struct OverlayRenderModel: Equatable, Sendable {
    public let originalLines: [OverlayLine]
    public let translatedLines: [OverlayLine]
    public let assistantLines: [OverlayLine]
    public let assistantStatus: AssistantResponseStatus

    public init(
        originalLines: [OverlayLine],
        translatedLines: [OverlayLine],
        assistantLines: [OverlayLine],
        assistantStatus: AssistantResponseStatus
    ) {
        self.originalLines = originalLines
        self.translatedLines = translatedLines
        self.assistantLines = assistantLines
        self.assistantStatus = assistantStatus
    }
}
