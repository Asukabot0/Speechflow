import Foundation
import Translation

@available(macOS 15.0, *)
@MainActor
func test() async {
    let source = Locale.Language(identifier: "en-US")
    let target = Locale.Language(identifier: "zh-CN")
    let session = TranslationSession(configuration: TranslationSession.Configuration(source: source, target: target))
}
