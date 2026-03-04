import Foundation

public final class TranscriptBuffer: TranscriptBuffering {
    public var snapshot: TranscriptSnapshot {
        TranscriptSnapshot(
            partialText: partialText,
            committedSegments: committedSegments
        )
    }

    private var partialText = ""
    private var committedSegments: [TranscriptSegment] = []
    private var languagePair: LanguagePair
    private let maxRetainedSegments: Int
    private let duplicateCommitSuppressionWindow: TimeInterval = 4.0
    private let refinementReplacementWindow: TimeInterval = 12.0
    private let maximumTrailingRefinementReplacements = 4

    public init(
        languagePair: LanguagePair,
        maxRetainedSegments: Int = 200
    ) {
        self.languagePair = languagePair
        self.maxRetainedSegments = max(1, maxRetainedSegments)
    }

    public func updateLanguagePair(_ pair: LanguagePair) {
        languagePair = pair
    }

    public func applyPartial(_ text: String) -> TranscriptBufferMutation {
        partialText = text
        return TranscriptBufferMutation(snapshot: snapshot)
    }

    public func commitCurrentDraft(reason: CommitReason, now: Date) -> TranscriptBufferMutation? {
        let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized = Self.normalize(trimmed)
        if shouldSuppressDuplicateCommit(normalizedSourceText: normalized, at: now) {
            partialText = ""
            return TranscriptBufferMutation(
                snapshot: snapshot,
                commitReason: reason
            )
        }

        replaceRecentRefinementsIfNeeded(
            sourceText: trimmed,
            normalizedSourceText: normalized,
            at: now
        )

        let segment = TranscriptSegment(
            sourceText: trimmed,
            normalizedSourceText: normalized,
            status: .committed,
            createdAt: now,
            committedAt: now,
            sourceLanguage: languagePair.sourceCode,
            targetLanguage: languagePair.targetCode
        )

        committedSegments.append(segment)
        if committedSegments.count > maxRetainedSegments {
            committedSegments.removeFirst(committedSegments.count - maxRetainedSegments)
        }
        partialText = ""

        return TranscriptBufferMutation(
            snapshot: snapshot,
            committedSegment: segment,
            commitReason: reason
        )
    }

    public func markTranslationStarted(for segmentID: UUID) -> TranscriptSnapshot {
        guard let index = committedSegments.firstIndex(where: { $0.id == segmentID }) else {
            return snapshot
        }

        committedSegments[index].status = .translating
        return snapshot
    }

    public func applyTranslationResult(_ result: TranslationResult, at: Date) -> TranscriptSnapshot {
        guard let index = committedSegments.firstIndex(where: { $0.id == result.segmentID }) else {
            return snapshot
        }

        committedSegments[index].translatedAt = at

        if let text = result.text, !text.isEmpty {
            committedSegments[index].translatedText = text
            committedSegments[index].status = .translated
        } else {
            committedSegments[index].translatedText = nil
            committedSegments[index].status = .skipped
        }

        return snapshot
    }

    public func markTranslationFailure(for segmentID: UUID, message: String) -> TranscriptSnapshot {
        guard let index = committedSegments.firstIndex(where: { $0.id == segmentID }) else {
            return snapshot
        }

        committedSegments[index].translatedText = "Translation failed: \(message)"
        committedSegments[index].status = .failed
        return snapshot
    }

    public func reset() {
        partialText = ""
        committedSegments.removeAll(keepingCapacity: true)
    }

    private static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private func shouldSuppressDuplicateCommit(
        normalizedSourceText: String,
        at now: Date
    ) -> Bool {
        guard let lastSegment = committedSegments.last,
              lastSegment.normalizedSourceText == normalizedSourceText,
              lastSegment.sourceLanguage == languagePair.sourceCode,
              lastSegment.targetLanguage == languagePair.targetCode,
              let committedAt = lastSegment.committedAt else {
            return false
        }

        return now.timeIntervalSince(committedAt) <= duplicateCommitSuppressionWindow
    }

    private func replaceRecentRefinementsIfNeeded(
        sourceText: String,
        normalizedSourceText: String,
        at now: Date
    ) {
        var replacementsRemaining = maximumTrailingRefinementReplacements

        while replacementsRemaining > 0,
              let lastSegment = committedSegments.last,
              lastSegment.sourceLanguage == languagePair.sourceCode,
              lastSegment.targetLanguage == languagePair.targetCode,
              let committedAt = lastSegment.committedAt,
              now.timeIntervalSince(committedAt) <= refinementReplacementWindow,
              shouldReplaceRecentSegment(
                previousSourceText: lastSegment.sourceText,
                previousNormalizedSourceText: lastSegment.normalizedSourceText,
                newSourceText: sourceText,
                newNormalizedSourceText: normalizedSourceText
              ) {
            committedSegments.removeLast()
            replacementsRemaining -= 1
        }
    }

    private func shouldReplaceRecentSegment(
        previousSourceText: String,
        previousNormalizedSourceText: String,
        newSourceText: String,
        newNormalizedSourceText: String
    ) -> Bool {
        if previousNormalizedSourceText.contains(newNormalizedSourceText) ||
            newNormalizedSourceText.contains(previousNormalizedSourceText) {
            return true
        }

        let previousCharacters = Array(previousSourceText)
        let newCharacters = Array(newSourceText)
        let overlap = max(
            commonPrefixLength(previousCharacters, newCharacters),
            commonSuffixLength(previousCharacters, newCharacters),
            longestCommonSubstringLength(previousCharacters, newCharacters)
        )

        let shorterLength = min(previousCharacters.count, newCharacters.count)
        guard shorterLength >= 3 else {
            return false
        }

        return Double(overlap) / Double(shorterLength) >= 0.5
    }

    private func commonPrefixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var count = 0

        while count < limit, lhs[count] == rhs[count] {
            count += 1
        }

        return count
    }

    private func commonSuffixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var count = 0

        while count < limit,
              lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count] {
            count += 1
        }

        return count
    }

    private func longestCommonSubstringLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }

        var previousRow = Array(repeating: 0, count: rhs.count + 1)
        var best = 0

        for lhsIndex in 0..<lhs.count {
            var currentRow = Array(repeating: 0, count: rhs.count + 1)

            for rhsIndex in 0..<rhs.count {
                if lhs[lhsIndex] == rhs[rhsIndex] {
                    let matchLength = previousRow[rhsIndex] + 1
                    currentRow[rhsIndex + 1] = matchLength
                    best = max(best, matchLength)
                }
            }

            previousRow = currentRow
        }

        return best
    }
}
