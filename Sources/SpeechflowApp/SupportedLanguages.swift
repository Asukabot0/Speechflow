import Foundation

struct SupportedLanguageOption: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
}

enum SupportedLanguages {
    private static let baseInputOptions: [SupportedLanguageOption] = [
        SupportedLanguageOption(code: "en-US", name: "English (US)"),
        SupportedLanguageOption(code: "zh-CN", name: "Chinese (Simplified)"),
        SupportedLanguageOption(code: "ja-JP", name: "Japanese"),
        SupportedLanguageOption(code: "ko-KR", name: "Korean"),
        SupportedLanguageOption(code: "es-ES", name: "Spanish"),
        SupportedLanguageOption(code: "fr-FR", name: "French"),
        SupportedLanguageOption(code: "de-DE", name: "German")
    ]

    private static let baseOutputOptions: [SupportedLanguageOption] = [
        SupportedLanguageOption(code: "zh-Hans", name: "Chinese (Simplified)"),
        SupportedLanguageOption(code: "zh-Hant", name: "Chinese (Traditional)"),
        SupportedLanguageOption(code: "en-US", name: "English (US)"),
        SupportedLanguageOption(code: "ja-JP", name: "Japanese"),
        SupportedLanguageOption(code: "ko-KR", name: "Korean"),
        SupportedLanguageOption(code: "es-ES", name: "Spanish"),
        SupportedLanguageOption(code: "fr-FR", name: "French"),
        SupportedLanguageOption(code: "de-DE", name: "German")
    ]

    static func inputOptions(including currentCode: String) -> [SupportedLanguageOption] {
        options(from: baseInputOptions, including: currentCode)
    }

    static func outputOptions(including currentCode: String) -> [SupportedLanguageOption] {
        options(from: baseOutputOptions, including: currentCode)
    }

    private static func options(
        from baseOptions: [SupportedLanguageOption],
        including currentCode: String
    ) -> [SupportedLanguageOption] {
        guard !baseOptions.contains(where: { $0.code == currentCode }) else {
            return baseOptions
        }

        return [SupportedLanguageOption(code: currentCode, name: currentCode)] + baseOptions
    }
}
