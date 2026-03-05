import Foundation
import Testing
@testable import SpeechflowCore

@Suite("TranslationOutputNormalizer Tests")
struct TranslationOutputNormalizerTests {
    
    @Test("应该保持普通文本不变")
    func preservesNormalText() {
        let text = "Hello"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text) == "Hello")
    }

    @Test("应该去除代码围栏")
    func removesCodeFences() {
        let text = "```翻译```"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text) == "翻译")
    }

    @Test("应该去除 translation: 前缀不区分大小写")
    func removesTranslationPrefix() {
        let text1 = "Translation: 你好"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text1) == "你好")
        
        let text2 = "translation: Hello"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text2) == "Hello")
        
        let text3 = "translated text: Test"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text3) == "Test")
    }

    @Test("应该去除 answer: 前缀不区分大小写")
    func removesAnswerPrefix() {
        let text = "Answer: Test"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text) == "Test")
    }

    @Test("应该去除外层双引号")
    func removesOuterQuotes() {
        let text = "\"Hello\""
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text) == "Hello")
        
        // 不应该影响内部引号
        let text2 = "\"He said \"Hi\"\""
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text2) == "He said \"Hi\"")
    }

    @Test("应该处理混合前缀和代码围栏")
    func handlesMixedCleanup() {
        let text = "```translation: \"Hi\"```"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text) == "Hi")
        
        let text2 = "```\nAnswer: \"Hello World\"\n```"
        #expect(TranslationOutputNormalizer.normalizeModelOutput(text2) == "Hello World")
    }

    @Test("空字符串应该仍然为空")
    func handlesEmptyString() {
        #expect(TranslationOutputNormalizer.normalizeModelOutput("") == "")
    }

    @Test("仅空白字符应该返回空")
    func handlesWhitespaceOnly() {
        #expect(TranslationOutputNormalizer.normalizeModelOutput("  \n  ") == "")
    }
}
