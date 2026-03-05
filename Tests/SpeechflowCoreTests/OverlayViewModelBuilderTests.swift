import Foundation
import Testing
@testable import SpeechflowCore

@Suite("OverlayViewModelBuilder Tests")
struct OverlayViewModelBuilderTests {
    
    @Test("对于空的 snapshot，应当返回空的渲染数据")
    func testEmptySnapshot() {
        let snapshot = TranscriptSnapshot(partialText: "", committedSegments: [])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        #expect(model.originalLines.isEmpty)
        #expect(model.translatedLines.isEmpty)
        #expect(model.assistantLines.isEmpty)
        #expect(model.assistantStatus == .idle)
    }

    @Test("对于只有 partial 的 snapshot，应当生成只有原文字幕且 isCommitted 为 false 的渲染行")
    func testOnlyPartialText() {
        let snapshot = TranscriptSnapshot(partialText: "hello partial", committedSegments: [])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        #expect(model.originalLines.count == 1)
        #expect(model.originalLines[0].text == "hello partial")
        #expect(model.originalLines[0].isCommitted == false)
        #expect(model.translatedLines.isEmpty)
    }

    @Test("混合 partial 和 committed 的情况")
    func testMixedPartialAndCommitted() {
        let segment = TranscriptSegment(
            sourceText: "committed text.",
            normalizedSourceText: "committed text.",
            status: .committed,
            sourceLanguage: "en-US",
            targetLanguage: "zh-Hans"
        )
        let snapshot = TranscriptSnapshot(partialText: "partial", committedSegments: [segment])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        #expect(model.originalLines.count == 2)
        #expect(model.originalLines[0].text == "committed text.")
        #expect(model.originalLines[0].isCommitted == true)
        #expect(model.originalLines[1].text == "partial")
        #expect(model.originalLines[1].isCommitted == false)
    }

    @Test("文本超过 maxChars 应该被换行")
    func testLineWrapping() {
        let longText = String(repeating: "A", count: 60)
        let segment = TranscriptSegment(
            sourceText: longText,
            normalizedSourceText: longText,
            status: .committed,
            sourceLanguage: "en-US",
            targetLanguage: "zh-Hans"
        )
        let snapshot = TranscriptSnapshot(partialText: "", committedSegments: [segment])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        // original lines 超过 50 后应当折行
        #expect(model.originalLines.count > 1)
    }

    @Test("翻译行应该使用译文并正确换行")
    func testTranslatedLines() {
        let segment = TranscriptSegment(
            sourceText: "hello",
            normalizedSourceText: "hello",
            translatedText: "你好",
            status: .translated,
            sourceLanguage: "en-US",
            targetLanguage: "zh-Hans"
        )
        let snapshot = TranscriptSnapshot(partialText: "", committedSegments: [segment])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        #expect(model.translatedLines.count == 1)
        #expect(model.translatedLines[0].text == "你好")
        #expect(model.translatedLines[0].isCommitted == true)
    }

    @Test("多个有翻译的 segment 之间应该插入空行")
    func testTranslatedLinesSpacing() {
        let segment1 = TranscriptSegment(
            sourceText: "hello",
            normalizedSourceText: "hello",
            translatedText: "你好",
            status: .translated,
            sourceLanguage: "en-US",
            targetLanguage: "zh-Hans"
        )
        let segment2 = TranscriptSegment(
            sourceText: "world",
            normalizedSourceText: "world",
            translatedText: "世界",
            status: .translated,
            sourceLanguage: "en-US",
            targetLanguage: "zh-Hans"
        )
        let snapshot = TranscriptSnapshot(partialText: "", committedSegments: [segment1, segment2])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        #expect(model.translatedLines.count == 3)
        #expect(model.translatedLines[0].text == "你好")
        #expect(model.translatedLines[1].text == " ")
        #expect(model.translatedLines[2].text == "世界")
    }

    @Test("assistant 问答文本和状态的渲染")
    func testAssistantLinesAndStatus() {
        let segment = TranscriptSegment(
            sourceText: "hello",
            normalizedSourceText: "hello",
            assistantText: "这里是 assistant 的回答",
            assistantQuestionSummary: "问题摘要",
            assistantStatus: .answered,
            status: .translated,
            sourceLanguage: "en-US",
            targetLanguage: "zh-Hans"
        )
        let snapshot = TranscriptSnapshot(partialText: "", committedSegments: [segment])
        let model = OverlayViewModelBuilder.makeRenderModel(from: snapshot, maxLines: 5)
        
        // Assistant status is driven by the last committed segment
        #expect(model.assistantStatus == .answered)
        
        // Format should be Q1 -> summary -> chunks
        let lines = model.assistantLines
        #expect(lines.count >= 3)
        #expect(lines[0].text == "Q1")
        #expect(lines[1].text.hasPrefix("__assistant_summary__:问题摘要"))
        #expect(lines[2].text == "这里是 assistant 的回答")
    }
}
