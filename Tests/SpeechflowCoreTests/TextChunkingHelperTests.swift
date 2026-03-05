import Foundation
import Testing
@testable import SpeechflowCore

@Suite("TextChunkingHelper Tests")
struct TextChunkingHelperTests {

    @Test("应该保持空字符串不切分")
    func emptyString() {
        #expect(TextChunkingHelper.splitIntoTranslationChunks("") == [])
        #expect(TextChunkingHelper.splitIntoTranslationChunks("   \n ") == [])
    }

    @Test("应该保持单句完整")
    func singleSentence() {
        #expect(TextChunkingHelper.splitIntoTranslationChunks("Hello world.") == ["Hello world."])
        #expect(TextChunkingHelper.splitIntoTranslationChunks("没有标点") == ["没有标点"])
    }

    @Test("应该按句末标点切分")
    func splitByTerminalPunctuation() {
        let text = "First sentence. Second sentence! Third one?"
        let expected = ["First sentence.", "Second sentence!", "Third one?"]
        #expect(TextChunkingHelper.splitIntoTranslationChunks(text) == expected)
    }

    @Test("应该按中文半角全角句末标点切分")
    func splitByChineseTerminalPunctuation() {
        let text = "你好。世界！测试？"
        let expected = ["你好。", "世界！", "测试？"]
        #expect(TextChunkingHelper.splitIntoTranslationChunks(text) == expected)
    }

    @Test("应该按子句边界对过长的句子切分")
    func splitLongSentenceByClauseBoundaries() {
        let part1 = String(repeating: "A", count: 80) + ","
        let part2 = String(repeating: "B", count: 80) + ";"
        let text = part1 + " " + part2
        
        // This function forces splitting at clause boundaries if the text exceeds 80 characters without sentences boundaries
        let chunks = TextChunkingHelper.splitIntoTranslationChunks(text)
        #expect(chunks.count == 2)
        #expect(chunks[0] == part1)
        #expect(chunks[1] == part2)
    }

    @Test("应该检测句子是否以终止标点结尾")
    func testEndsWithTerminalPunctuation() {
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("Hello.") == true)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("Hello!") == true)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("Hello?") == true)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("你好。") == true)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("你好！") == true)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("你好？") == true)
        
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("Hello,") == false)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("Hello") == false)
        #expect(TextChunkingHelper.endsWithTerminalPunctuation("你好") == false)
    }

    @Test("应该检测句子是否以子句标点结尾")
    func testEndsWithClauseBoundaryPunctuation() {
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("Hello,") == true)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("Hello;") == true)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("Hello:") == true)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("你好，") == true)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("你好、") == true)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("你好；") == true)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("你好：") == true)
        
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("Hello.") == false)
        #expect(TextChunkingHelper.endsWithClauseBoundaryPunctuation("Hello") == false)
    }

    @Test("应该检测词汇连接词结尾")
    func testEndsWithWeakTrailingConnector() {
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("this is a") == true)
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("you and") == true)
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("wait for") == true)
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("go to") == true)
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("I am with") == true)
        
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("hello world") == false)
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("done") == false)
        // Ignoring punctuation attached to connectors (like comma)
        #expect(TextChunkingHelper.endsWithWeakTrailingConnector("this is a,") == true)
    }

    @Test("应该正确评估是否为语义块")
    func testIsSemanticChunkCandidate() {
        // Needs at least N tokens and chars
        #expect(TextChunkingHelper.isSemanticChunkCandidate("This is enough text", minimumTokens: 3, minimumCharacters: 10) == true)
        
        // Too few tokens and chars
        #expect(TextChunkingHelper.isSemanticChunkCandidate("hi", minimumTokens: 3, minimumCharacters: 10) == false)
        
        // Ends with weak connector -> false
        #expect(TextChunkingHelper.isSemanticChunkCandidate("This is a long sentence but", minimumTokens: 3, minimumCharacters: 10) == false)
        
        // CJK handling: tokens might be 1 string but character length covers it
        #expect(TextChunkingHelper.isSemanticChunkCandidate("这是一个很长的中文句子没有空格", minimumTokens: 3, minimumCharacters: 10) == true)
    }

    @Test("应该正确评估实时提词提交候选")
    func testIsRealtimeSubtitleCommitCandidate() {
        // Punctuated endings are strong candidates
        #expect(TextChunkingHelper.isRealtimeSubtitleCommitCandidate("Done.") == true)
        #expect(TextChunkingHelper.isRealtimeSubtitleCommitCandidate("Well,") == true)
        
        // Semantic chunks without punctuation are fallback candidates
        #expect(TextChunkingHelper.isRealtimeSubtitleCommitCandidate("This is a good chunk") == true)
        
        // Weak connectors or too short fragments are not
        #expect(TextChunkingHelper.isRealtimeSubtitleCommitCandidate("wait for") == false)
        #expect(TextChunkingHelper.isRealtimeSubtitleCommitCandidate("hi") == false)
    }

    @Test("应该正确计算英文词数")
    func testWordTokenCount() {
        #expect(TextChunkingHelper.wordTokenCount(in: "one two three") == 3)
        #expect(TextChunkingHelper.wordTokenCount(in: "  one    two ") == 2)
        #expect(TextChunkingHelper.wordTokenCount(in: "one") == 1)
        #expect(TextChunkingHelper.wordTokenCount(in: "") == 0)
    }
}
