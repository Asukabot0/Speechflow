import Foundation

enum LocaleIdentifierNormalizer {
    static func normalizedInputLocaleIdentifier(_ identifier: String) -> String {
        switch normalizedScriptIdentifier(identifier) {
        case "zh-Hans":
            return "zh-CN"
        case "zh-Hant":
            return "zh-TW"
        default:
            return identifier
        }
    }

    static func translationLocaleIdentifier(for code: String) -> String {
        normalizedInputLocaleIdentifier(code)
    }

    static func qwenLanguage(for identifier: String) -> String? {
        let normalizedIdentifier = normalizedInputLocaleIdentifier(identifier)

        if #available(macOS 13.0, *) {
            let locale = Locale(identifier: normalizedIdentifier)
            if let languageCode = locale.language.languageCode?.identifier {
                return qwenLanguage(forLanguageCode: languageCode)
            }
        }

        let components = normalizedScriptIdentifier(normalizedIdentifier)
            .split(separator: "-")
            .map(String.init)
        guard let languageCode = components.first else {
            return nil
        }

        return qwenLanguage(forLanguageCode: languageCode)
    }

    private static func normalizedScriptIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    private static func qwenLanguage(forLanguageCode languageCode: String) -> String? {
        switch languageCode.lowercased() {
        case "ar":
            return "Arabic"
        case "cs":
            return "Czech"
        case "da":
            return "Danish"
        case "de":
            return "German"
        case "el":
            return "Greek"
        case "en":
            return "English"
        case "es":
            return "Spanish"
        case "fa":
            return "Persian"
        case "fi":
            return "Finnish"
        case "fil", "tl":
            return "Filipino"
        case "fr":
            return "French"
        case "hi":
            return "Hindi"
        case "hu":
            return "Hungarian"
        case "id":
            return "Indonesian"
        case "it":
            return "Italian"
        case "ja":
            return "Japanese"
        case "ko":
            return "Korean"
        case "mk":
            return "Macedonian"
        case "ms":
            return "Malay"
        case "nl":
            return "Dutch"
        case "pl":
            return "Polish"
        case "pt":
            return "Portuguese"
        case "ro":
            return "Romanian"
        case "ru":
            return "Russian"
        case "sv":
            return "Swedish"
        case "th":
            return "Thai"
        case "tr":
            return "Turkish"
        case "vi":
            return "Vietnamese"
        case "yue":
            return "Cantonese"
        case "zh":
            return "Chinese"
        default:
            return nil
        }
    }
}
