public enum TranslationOutputNormalizer: Sendable {
    public static func normalizeModelOutput(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = [
            "translation:",
            "translated text:",
            "answer:"
        ]

        for prefix in prefixes {
            if normalized.lowercased().hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if normalized.hasPrefix("\""), normalized.hasSuffix("\""), normalized.count >= 2 {
            normalized.removeFirst()
            normalized.removeLast()
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
