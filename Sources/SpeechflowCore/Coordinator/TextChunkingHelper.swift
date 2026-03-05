import Foundation

enum TextChunkingHelper {
    static let terminalPunctuation: Set<Character> = [
        ".",
        "!",
        "?",
        "。",
        "！",
        "？"
    ]

    static let clauseBoundaryPunctuation: Set<Character> = [
        ",",
        ";",
        ":",
        "，",
        "、",
        "；",
        "："
    ]

    static let weakTrailingConnectors: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "by", "for", "from",
        "if", "in", "into", "is", "of", "on", "or", "so", "the", "to",
        "was", "were", "with", "yet"
    ]

    static func splitIntoTranslationChunks(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var sentences: [String] = []
        var current = ""

        for char in trimmed {
            current.append(char)
            if terminalPunctuation.contains(char) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        var result: [String] = []
        for sentence in sentences {
            if sentence.count > 80 {
                let subChunks = splitAtClauseBoundaries(sentence, maxChars: 80)
                result.append(contentsOf: subChunks)
            } else {
                result.append(sentence)
            }
        }

        return result.isEmpty ? [trimmed] : result
    }

    static func splitAtClauseBoundaries(_ text: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if current.count >= maxChars, clauseBoundaryPunctuation.contains(char) {
                let chunk = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty {
                    chunks.append(chunk)
                }
                current = ""
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            if let lastChunk = chunks.last, lastChunk.count + remaining.count <= maxChars {
                chunks[chunks.count - 1] = lastChunk + " " + remaining
            } else {
                chunks.append(remaining)
            }
        }

        return chunks.isEmpty ? [text] : chunks
    }

    static func endsWithTerminalPunctuation(_ text: String) -> Bool {
        guard let lastCharacter = text.last else {
            return false
        }
        return terminalPunctuation.contains(lastCharacter)
    }

    static func endsWithClauseBoundaryPunctuation(_ text: String) -> Bool {
        guard let lastCharacter = text.last else {
            return false
        }
        return clauseBoundaryPunctuation.contains(lastCharacter)
    }

    static func isRealtimeSubtitleCommitCandidate(_ text: String) -> Bool {
        if endsWithTerminalPunctuation(text) || endsWithClauseBoundaryPunctuation(text) {
            return true
        }
        return isSemanticChunkCandidate(text, minimumTokens: 3, minimumCharacters: 8)
    }

    static func isSemanticChunkCandidate(
        _ text: String,
        minimumTokens: Int,
        minimumCharacters: Int
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        guard !endsWithWeakTrailingConnector(trimmed) else {
            return false
        }
        let tokenCount = wordTokenCount(in: trimmed)
        if tokenCount >= minimumTokens && trimmed.count >= minimumCharacters {
            return true
        }
        if tokenCount <= 1 {
            return trimmed.count >= minimumCharacters
        }
        return false
    }

    static func endsWithWeakTrailingConnector(_ text: String) -> Bool {
        guard let lastToken = text
            .split(whereSeparator: \.isWhitespace)
            .last?
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters) else {
            return false
        }
        guard !lastToken.isEmpty else {
            return false
        }
        return weakTrailingConnectors.contains(lastToken)
    }

    static func wordTokenCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
