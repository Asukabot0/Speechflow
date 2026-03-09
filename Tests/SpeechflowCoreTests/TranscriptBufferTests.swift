import Foundation
import Testing
@testable import SpeechflowCore

@Suite("TranscriptBuffer Tests")
struct TranscriptBufferTests {

    @Test("初始快照应该为空")
    func testInitialSnapshot() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        let snapshot = buffer.snapshot
        #expect(snapshot.partialText == "")
        #expect(snapshot.committedSegments.isEmpty)
    }

    @Test("applyPartial 应该更新 partialText")
    func testApplyPartial() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        let mutation = buffer.applyPartial("hello")
        
        #expect(mutation.snapshot.partialText == "hello")
        #expect(buffer.snapshot.partialText == "hello")
        #expect(mutation.committedSegment == nil)
    }

    @Test("commitCurrentDraft 应该创建 segment 并清空 partial")
    func testCommitDraft() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("hello world")
        
        let now = Date()
        let mutation = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: now)
        
        #expect(mutation != nil)
        #expect(mutation?.commitReason == .finalResult)
        
        let segment = mutation?.committedSegment
        #expect(segment?.sourceText == "hello world")
        #expect(segment?.status == .committed)
        #expect(segment?.committedAt == now)
        
        let snapshot = buffer.snapshot
        #expect(snapshot.partialText == "")
        #expect(snapshot.committedSegments.count == 1)
        #expect(snapshot.committedSegments.first?.id == segment?.id)
    }

    @Test("空文本不应该被 commit")
    func testEmptyCommit() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("   ")
        let mutation = buffer.commitCurrentDraft(reason: CommitReason.silenceTimeout, now: Date())
        #expect(mutation == nil)
    }

    @Test("应该抑制短时间内的重复提交")
    func testDuplicateCommitSuppression() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        let text = "duplicate"
        
        _ = buffer.applyPartial(text)
        let now = Date()
        let mutation1 = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: now)
        #expect(mutation1 != nil)
        #expect(mutation1?.committedSegment != nil)
        
        // Setup same text again
        _ = buffer.applyPartial(text)
        
        // Commit immediately -> should be suppressed (mutation returned but without a new segment)
        let mutation2 = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: now.addingTimeInterval(0.1))
        #expect(mutation2 != nil)
        #expect(mutation2?.committedSegment == nil)
        
        // Commit after window -> should pass and create new segment
        _ = buffer.applyPartial(text)
        let mutation3 = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: now.addingTimeInterval(5.0))
        #expect(mutation3 != nil)
        #expect(mutation3?.committedSegment != nil)
    }

    @Test("markTranslationStarted 应该更新状态")
    func testMarkTranslationStarted() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("test")
        let mutation = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: Date())
        let id = mutation!.committedSegment!.id
        
        let snapshot = buffer.markTranslationStarted(for: id)
        #expect(snapshot.committedSegments.first?.status == .translating)
        #expect(snapshot.committedSegments.first?.assistantStatus == .asking)
    }

    @Test("applyTranslationResult 应该写入结果并更新状态")
    func testApplyTranslationResult() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("test")
        let mutation = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: Date())
        let id = mutation!.committedSegment!.id
        
        let result = TranslationResult(
            segmentID: id,
            text: "测试",
            backend: .localOllama,
            isDegraded: false,
            appliedPolish: false
        )
        
        let now = Date()
        let snapshot = buffer.applyTranslationResult(result, at: now)
        
        let segment = snapshot.committedSegments.first!
        #expect(segment.translatedText == "测试")
        #expect(segment.status == .translated)
        #expect(segment.translatedAt == now)
    }

    @Test("markTranslationFailure 应该标记失败")
    func testMarkTranslationFailure() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("test")
        let mutation = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: Date())
        let id = mutation!.committedSegment!.id
        
        let snapshot = buffer.markTranslationFailure(for: id, message: "Error")
        #expect(snapshot.committedSegments.first?.status == .failed)
    }

    @Test("尾部 refinement 替换：包含关系")
    func testTrailingRefinementReplacementSubtring() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        
        _ = buffer.applyPartial("hello")
        let m1 = buffer.commitCurrentDraft(reason: CommitReason.partialStabilized, now: Date())
        #expect(m1 != nil)
        
        _ = buffer.applyPartial("hello world")
        let m2 = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: Date())
        #expect(m2 != nil)
        
        let snapshot = buffer.snapshot
        #expect(snapshot.committedSegments.count == 1) // "hello" was replaced by "hello world"
        #expect(snapshot.committedSegments.first?.sourceText == "hello world")
    }

    @Test("partialStabilized commit 应写入 provisional 标记")
    func testPartialCommitIsProvisional() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("stable partial")

        let mutation = buffer.commitCurrentDraft(reason: .partialStabilized, now: Date())

        #expect(mutation?.committedSegment?.isProvisional == true)
        #expect(buffer.snapshot.committedSegments.first?.isProvisional == true)
    }

    @Test("confirmSegments 应仅确认 provisional 段并保留已有译文")
    func testConfirmSegmentsPreservesTranslation() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("hello")
        let mutation = buffer.commitCurrentDraft(reason: .partialStabilized, now: Date())
        let id = mutation!.committedSegment!.id

        _ = buffer.markTranslationStarted(for: id)
        _ = buffer.applyTranslationResult(
            TranslationResult(
                segmentID: id,
                text: "你好",
                backend: .system,
                isDegraded: false,
                appliedPolish: false
            ),
            at: Date()
        )

        let snapshot = buffer.confirmSegments(ids: [id])
        let segment = snapshot.committedSegments.first
        #expect(segment?.isProvisional == false)
        #expect(segment?.translatedText == "你好")
        #expect(segment?.status == .translated)
    }

    @Test("removeSegments 应删除已翻译 provisional 段，迟到结果不会重新插回")
    func testRemoveSegmentsDropsTranslatedProvisional() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("hello")
        let mutation = buffer.commitCurrentDraft(reason: .partialStabilized, now: Date())
        let id = mutation!.committedSegment!.id

        _ = buffer.markTranslationStarted(for: id)
        _ = buffer.applyTranslationResult(
            TranslationResult(
                segmentID: id,
                text: "你好",
                backend: .system,
                isDegraded: false,
                appliedPolish: false
            ),
            at: Date()
        )

        let removedSnapshot = buffer.removeSegments(ids: [id])
        #expect(removedSnapshot.committedSegments.isEmpty)

        let lateSnapshot = buffer.applyTranslationResult(
            TranslationResult(
                segmentID: id,
                text: "迟到的结果",
                backend: .system,
                isDegraded: false,
                appliedPolish: false
            ),
            at: Date()
        )
        #expect(lateSnapshot.committedSegments.isEmpty)
    }

    @Test("reset 应该清空所有状态")
    func testReset() {
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en", targetCode: "zh"))
        _ = buffer.applyPartial("test")
        _ = buffer.commitCurrentDraft(reason: CommitReason.finalResult, now: Date())
        _ = buffer.applyPartial("pending")
        
        buffer.reset()
        
        let snapshot = buffer.snapshot
        #expect(snapshot.partialText == "")
        #expect(snapshot.committedSegments.isEmpty)
    }
}
