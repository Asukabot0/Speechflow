import Foundation

public enum OverlayViewModelBuilder {
    private static let maxCharsPerLine = 50
    private static let maxCharsPerLineTranslated = 30
    private static let maxOriginalVisibleLines = 3
    private static let maxTranslatedVisibleLines = 8
    private static let assistantSummaryPrefix = "__assistant_summary__:"

    public static func makeRenderModel(
        from snapshot: TranscriptSnapshot,
        maxLines: Int
    ) -> OverlayRenderModel {
        _ = maxLines

        var originalLines: [OverlayLine] = []
        for segment in snapshot.committedSegments {
            let visualLines = splitIntoVisualLines(segment.sourceText, maxChars: maxCharsPerLine)
            for line in visualLines {
                originalLines.append(
                    OverlayLine(id: UUID(), text: line, isCommitted: true)
                )
            }
        }

        let trimmedPartial = snapshot.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            let visualLines = splitIntoVisualLines(trimmedPartial, maxChars: maxCharsPerLine)
            for line in visualLines {
                originalLines.append(
                    OverlayLine(id: UUID(), text: line, isCommitted: false)
                )
            }
        }

        var translatedLines: [OverlayLine] = []
        var translatedSegmentCount = 0
        for segment in snapshot.committedSegments {
            guard let translatedText = segment.translatedText else {
                continue
            }
            if translatedSegmentCount > 0 {
                translatedLines.append(
                    OverlayLine(id: UUID(), text: " ", isCommitted: true)
                )
            }
            let visualLines = splitIntoVisualLines(translatedText, maxChars: maxCharsPerLineTranslated)
            for line in visualLines {
                translatedLines.append(
                    OverlayLine(id: UUID(), text: line, isCommitted: true)
                )
            }
            translatedSegmentCount += 1
        }

        var assistantLines: [OverlayLine] = []
        let assistantEntries = snapshot.committedSegments.compactMap { segment -> (summary: String?, body: String)? in
            guard let assistantText = segment.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !assistantText.isEmpty else {
                return nil
            }
            let summary = segment.assistantQuestionSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (summary?.isEmpty == false ? summary : nil, assistantText)
        }
        for (index, assistantEntry) in assistantEntries.enumerated() {
            if index > 0 {
                assistantLines.append(
                    OverlayLine(id: UUID(), text: " ", isCommitted: true)
                )
            }
            assistantLines.append(
                OverlayLine(id: UUID(), text: "Q\(index + 1)", isCommitted: true)
            )
            if let summary = assistantEntry.summary {
                assistantLines.append(
                    OverlayLine(
                        id: UUID(),
                        text: "\(assistantSummaryPrefix)\(summary)",
                        isCommitted: true
                    )
                )
            }
            let visualLines = splitIntoVisualLines(
                assistantEntry.body,
                maxChars: maxCharsPerLineTranslated
            )
            for line in visualLines {
                assistantLines.append(
                    OverlayLine(id: UUID(), text: line, isCommitted: true)
                )
            }
        }

        let assistantStatus = snapshot.committedSegments.last?.assistantStatus ?? .idle
        return OverlayRenderModel(
            originalLines: originalLines,
            translatedLines: translatedLines,
            assistantLines: assistantLines,
            assistantStatus: assistantStatus
        )
    }

    private static func splitIntoVisualLines(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        // 1. 优先按句末标点强制换行，保留标点
        var sentences: [String] = []
        var currentSentence = ""
        let terminals: Set<Character> = [".", "!", "?", "。", "！", "？"]

        for char in trimmed {
            currentSentence.append(char)
            if terminals.contains(char) {
                sentences.append(currentSentence.trimmingCharacters(in: .whitespaces))
                currentSentence = ""
            }
        }
        let remainingSentence = currentSentence.trimmingCharacters(in: .whitespaces)
        if !remainingSentence.isEmpty {
            sentences.append(remainingSentence)
        }

        // 2. 对于超过最大长度的句子，再按单词/标点换行
        var lines: [String] = []
        for sentence in sentences {
            guard sentence.count > maxChars else {
                if !sentence.isEmpty {
                    lines.append(sentence)
                }
                continue
            }

            var currentLine = ""
            for character in sentence {
                currentLine.append(character)

                if currentLine.count >= maxChars {
                    if let breakIndex = currentLine.lastIndex(where: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == "、" || $0 == ";" || $0 == "；" }) {
                        let before = String(currentLine[currentLine.startIndex...breakIndex]).trimmingCharacters(in: .whitespaces)
                        let after = String(currentLine[currentLine.index(after: breakIndex)...]).trimmingCharacters(in: .whitespaces)
                        if !before.isEmpty {
                            lines.append(before)
                        }
                        currentLine = after
                    } else {
                        let line = currentLine.trimmingCharacters(in: .whitespaces)
                        if !line.isEmpty {
                            lines.append(line)
                        }
                        currentLine = ""
                    }
                }
            }

            let remaining = currentLine.trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty {
                lines.append(remaining)
            }
        }

        return lines
    }
}
