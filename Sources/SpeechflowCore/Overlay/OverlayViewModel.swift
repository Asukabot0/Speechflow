import Foundation

public enum OverlayViewModelBuilder {
    private static let maxCharsPerLine = 50
    private static let maxCharsPerLineTranslated = 30
    private static let assistantSummaryPrefix = "__assistant_summary__:"

    private static let partialBaseUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    private static let nsOriginal: UInt8 = 0x01
    private static let nsTranslated: UInt8 = 0x02
    private static let nsTranslatedSpace: UInt8 = 0x03
    private static let nsAssistant: UInt8 = 0x04
    private static let nsAssistantSpace: UInt8 = 0x05
    private static let nsAssistantLabel: UInt8 = 0x06
    private static let nsAssistantSummary: UInt8 = 0x07
    private static let nsPartial: UInt8 = 0x08

    static func stableLineID(base: UUID, namespace: UInt8, lineIndex: Int) -> UUID {
        var bytes = base.uuid
        bytes.0 ^= namespace
        let idx = UInt32(truncatingIfNeeded: lineIndex)
        bytes.12 = bytes.12 &+ UInt8(idx & 0xFF)
        bytes.13 = bytes.13 &+ UInt8((idx >> 8) & 0xFF)
        bytes.14 = bytes.14 &+ UInt8((idx >> 16) & 0xFF)
        bytes.15 = bytes.15 &+ UInt8((idx >> 24) & 0xFF)
        return UUID(uuid: bytes)
    }

    public static func makeRenderModel(
        from snapshot: TranscriptSnapshot,
        maxLines: Int
    ) -> OverlayRenderModel {
        var originalLines: [OverlayLine] = []
        for segment in snapshot.committedSegments {
            let visualLines = splitIntoVisualLines(segment.sourceText, maxChars: maxCharsPerLine)
            for (i, line) in visualLines.enumerated() {
                originalLines.append(
                    OverlayLine(
                        id: stableLineID(base: segment.id, namespace: nsOriginal, lineIndex: i),
                        text: line,
                        isCommitted: true
                    )
                )
            }
        }

        let trimmedPartial = snapshot.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            let visualLines = splitIntoVisualLines(trimmedPartial, maxChars: maxCharsPerLine)
            for (i, line) in visualLines.enumerated() {
                originalLines.append(
                    OverlayLine(
                        id: stableLineID(base: partialBaseUUID, namespace: nsPartial, lineIndex: i),
                        text: line,
                        isCommitted: false
                    )
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
                    OverlayLine(
                        id: stableLineID(base: segment.id, namespace: nsTranslatedSpace, lineIndex: 0),
                        text: " ",
                        isCommitted: true
                    )
                )
            }
            let visualLines = splitIntoVisualLines(translatedText, maxChars: maxCharsPerLineTranslated)
            for (i, line) in visualLines.enumerated() {
                translatedLines.append(
                    OverlayLine(
                        id: stableLineID(base: segment.id, namespace: nsTranslated, lineIndex: i),
                        text: line,
                        isCommitted: true
                    )
                )
            }
            translatedSegmentCount += 1
        }

        var assistantLines: [OverlayLine] = []
        let assistantEntries = snapshot.committedSegments.compactMap { segment -> (id: UUID, summary: String?, body: String)? in
            guard let assistantText = segment.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !assistantText.isEmpty else {
                return nil
            }
            let summary = segment.assistantQuestionSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (segment.id, summary?.isEmpty == false ? summary : nil, assistantText)
        }
        for (index, assistantEntry) in assistantEntries.enumerated() {
            if index > 0 {
                assistantLines.append(
                    OverlayLine(
                        id: stableLineID(base: assistantEntry.id, namespace: nsAssistantSpace, lineIndex: 0),
                        text: " ",
                        isCommitted: true
                    )
                )
            }
            assistantLines.append(
                OverlayLine(
                    id: stableLineID(base: assistantEntry.id, namespace: nsAssistantLabel, lineIndex: 0),
                    text: "Q\(index + 1)",
                    isCommitted: true
                )
            )
            if let summary = assistantEntry.summary {
                assistantLines.append(
                    OverlayLine(
                        id: stableLineID(base: assistantEntry.id, namespace: nsAssistantSummary, lineIndex: 0),
                        text: "\(assistantSummaryPrefix)\(summary)",
                        isCommitted: true
                    )
                )
            }
            let visualLines = splitIntoVisualLines(
                assistantEntry.body,
                maxChars: maxCharsPerLineTranslated
            )
            for (i, line) in visualLines.enumerated() {
                assistantLines.append(
                    OverlayLine(
                        id: stableLineID(base: assistantEntry.id, namespace: nsAssistant, lineIndex: i),
                        text: line,
                        isCommitted: true
                    )
                )
            }
        }

        let assistantStatus = snapshot.committedSegments.last?.assistantStatus ?? .idle
        let visibleOriginalLines = cappedLines(originalLines, maxLines: maxLines)
        let visibleTranslatedLines = cappedLines(translatedLines, maxLines: maxLines)
        let visibleAssistantLines = cappedLines(assistantLines, maxLines: maxLines)
        return OverlayRenderModel(
            originalLines: visibleOriginalLines,
            translatedLines: visibleTranslatedLines,
            assistantLines: visibleAssistantLines,
            assistantStatus: assistantStatus
        )
    }

    private static func cappedLines(_ lines: [OverlayLine], maxLines: Int) -> [OverlayLine] {
        guard maxLines > 0 else {
            return []
        }

        guard lines.count > maxLines else {
            return lines
        }

        return Array(lines.suffix(maxLines))
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
