import Foundation

public enum OverlayViewModelBuilder {
    public static func makeRenderModel(
        from snapshot: TranscriptSnapshot,
        maxLines: Int
    ) -> OverlayRenderModel {
        let lineLimit = max(1, maxLines)

        var originalLines = snapshot.committedSegments.map {
            OverlayLine(
                id: $0.id,
                text: $0.sourceText,
                isCommitted: true
            )
        }

        let trimmedPartial = snapshot.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            originalLines.append(
                OverlayLine(
                    id: UUID(),
                    text: snapshot.partialText,
                    isCommitted: false
                )
            )
        }

        let translatedLines = snapshot.committedSegments.compactMap { segment -> OverlayLine? in
            guard let translatedText = segment.translatedText else {
                return nil
            }

            return OverlayLine(
                id: segment.id,
                text: translatedText,
                isCommitted: true
            )
        }

        return OverlayRenderModel(
            originalLines: Array(originalLines.suffix(lineLimit)),
            translatedLines: Array(translatedLines.suffix(lineLimit))
        )
    }
}
