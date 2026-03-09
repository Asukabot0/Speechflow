import Foundation
import Testing
@testable import SpeechflowCore

@Suite("AppCoordinator Tests", .serialized)
struct AppCoordinatorTests {

    func makeTestCoordinator(
        translateService: StubTranslateService = StubTranslateService(),
        permissions: PermissionSet = PermissionSet(
            microphoneGranted: true,
            speechRecognitionGranted: true,
            accessibilityGranted: true
        )
    ) -> (
        coordinator: AppCoordinator,
        asr: StubASRService,
        translate: StubTranslateService,
        renderer: StubOverlayRenderer,
        audio: StubAudioEngineService,
        buffer: TranscriptBuffer
    ) {
        let asr = StubASRService()
        let translate = translateService
        let renderer = StubOverlayRenderer()
        let audio = StubAudioEngineService()
        
        // 我们需要传递一个有效的 LanguagePair
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en-US", targetCode: "zh-Hans"))
        
        let coordinator = AppCoordinator(
            audioService: audio,
            asrService: asr,
            networkMonitor: StubNetworkMonitor(),
            permissionService: StubPermissionService(permissions: permissions),
            transcriptBuffer: buffer,
            translateService: translate,
            overlayRenderer: renderer,
            settingsStore: InMemorySettingsStore(),
            clock: SystemClock()
        )
        return (coordinator, asr, translate, renderer, audio, buffer)
    }
    
    // Helper to wait for async state changes since coordinator dispatches
    func waitForCondition(timeout: TimeInterval = 2.0, condition: @escaping () -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        Issue.record("Condition timed out after \(timeout) seconds.")
    }

    @Test("初始状态应该是 idle")
    func testInitialState() {
        let env = makeTestCoordinator()
        #expect(env.coordinator.state == .idle)
    }

    @Test("startRequested 应该经过权限检查后进入 listening 状态")
    func testStartSession() async throws {
        let env = makeTestCoordinator()
        
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        
        #expect(env.coordinator.state == .listening)
        #expect(env.audio.isCapturing == true)
    }

    @Test("pauseRequested 应该进入 paused 状态并停止捕获")
    func testPauseSession() async throws {
        let env = makeTestCoordinator()
        
        // 先启动
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        #expect(env.coordinator.state == .listening)
        
        // 然后暂停
        env.coordinator.handle(.pauseRequested)
        try await waitForCondition { env.coordinator.state == .paused }
        
        #expect(env.coordinator.state == .paused)
        #expect(env.audio.isCapturing == false)
    }

    @Test("resumeRequested 应该从 paused 恢复到 listening")
    func testResumeSession() async throws {
        let env = makeTestCoordinator()
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        
        env.coordinator.handle(.pauseRequested)
        try await waitForCondition { env.coordinator.state == .paused }
        
        env.coordinator.handle(.resumeRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        
        #expect(env.coordinator.state == .listening)
        #expect(env.audio.isCapturing == true)
    }

    @Test("stopRequested 应该切回 idle 状态全量清理")
    func testStopSession() async throws {
        let env = makeTestCoordinator()
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        
        env.coordinator.handle(.stopRequested)
        try await waitForCondition { env.coordinator.state == .idle }
        
        #expect(env.coordinator.state == .idle)
        #expect(env.audio.isCapturing == false)
        #expect(env.renderer.lastSnapshot.originalLines.isEmpty == true)
    }

    @Test("partial/final 应该驱动 TranscriptBuffer 并触发渲染")
    func testASRFlow() async throws {
        let env = makeTestCoordinator()
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        
        // 传递 partial
        env.coordinator.handle(.asrPartialReceived("hello"))
        try await waitForCondition { env.renderer.lastSnapshot.originalLines.count == 1 }
        
        // 验证 renderer 被触发，此时有 lines
        #expect(env.renderer.lastSnapshot.originalLines.count == 1)
        #expect(env.renderer.lastSnapshot.originalLines[0].text == "hello")
        #expect(env.renderer.lastSnapshot.originalLines[0].isCommitted == false)
        
        // 传递 final
        env.coordinator.handle(.asrFinalReceived("hello world"))
        try await waitForCondition { env.renderer.lastSnapshot.originalLines.first?.isCommitted == true }
        
        // renderer 应该更新 commit 状态
        #expect(env.renderer.lastSnapshot.originalLines.count == 1)
        #expect(env.renderer.lastSnapshot.originalLines[0].text == "hello world")
        #expect(env.renderer.lastSnapshot.originalLines[0].isCommitted == true)
    }

    @Test("partial 含完整句子时应逐步提交已完成部分")
    func testProgressivePartialCommit() async throws {
        let env = makeTestCoordinator()
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        // Partial with a completed sentence followed by in-progress text
        env.coordinator.handle(.asrPartialReceived("Hello world. How are"))
        try await waitForCondition { env.renderer.lastSnapshot.originalLines.count >= 2 }

        let lines = env.renderer.lastSnapshot.originalLines
        // "Hello world." should be committed, "How are" should be partial
        #expect(lines.count == 2)
        #expect(lines[0].text == "Hello world.")
        #expect(lines[0].isCommitted == true)
        #expect(lines[1].text == "How are")
        #expect(lines[1].isCommitted == false)
    }

    @Test("final 只提交 partial 中尚未提交的部分")
    func testFinalAfterProgressiveCommit() async throws {
        let env = makeTestCoordinator()
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        // Partial commits "First."
        env.coordinator.handle(.asrPartialReceived("First. Second"))
        try await waitForCondition {
            env.renderer.lastSnapshot.originalLines.first?.isCommitted == true
        }

        // Final arrives with full text
        env.coordinator.handle(.asrFinalReceived("First. Second sentence."))
        try await waitForCondition {
            let lines = env.renderer.lastSnapshot.originalLines
            return lines.count >= 2 && lines.allSatisfy(\.isCommitted)
        }

        let lines = env.renderer.lastSnapshot.originalLines
        // Should have "First." and "Second sentence." both committed, no duplication
        #expect(lines.count == 2)
        #expect(lines[0].text == "First.")
        #expect(lines[1].text == "Second sentence.")
    }

    @Test("翻译失败时不应该导致应用崩溃，只显示错误事件")
    func testTranslationFailureHandling() async throws {
        let env = makeTestCoordinator()
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }
        
        // 我们直接抛出一个 translationFailed
        env.coordinator.handle(.translationFailed(segmentID: UUID(), message: "Ollama Error"))
        
        // Give it a moment to process
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // 状态必须仍然是 listening
        #expect(env.coordinator.state == .listening)
    }

    @Test("麦克风启动缺少 speech 权限时应在启动前报错")
    func testMicrophoneStartFailsBeforeASRWhenSpeechPermissionMissing() async throws {
        let env = makeTestCoordinator(
            permissions: PermissionSet(
                microphoneGranted: true,
                speechRecognitionGranted: false,
                accessibilityGranted: true
            )
        )

        env.coordinator.handle(.startMicrophoneRequested)
        try await waitForCondition {
            if case .error = env.coordinator.state {
                return true
            }
            return false
        }

        guard case .error(let context) = env.coordinator.state else {
            Issue.record("Coordinator did not enter the error state.")
            return
        }

        #expect(context.code == "permissions_missing")
        #expect(context.message == "Speech recognition permission is required.")
        #expect(env.audio.isCapturing == false)
        #expect(env.asr.isStreaming == false)
    }

    @Test("系统音频启动缺少 speech 权限时应在启动前报错")
    func testSystemAudioStartFailsBeforeASRWhenSpeechPermissionMissing() async throws {
        let env = makeTestCoordinator(
            permissions: PermissionSet(
                microphoneGranted: false,
                speechRecognitionGranted: false,
                accessibilityGranted: true
            )
        )

        env.coordinator.handle(.startSystemAudioRequested)
        try await waitForCondition {
            if case .error = env.coordinator.state {
                return true
            }
            return false
        }

        guard case .error(let context) = env.coordinator.state else {
            Issue.record("Coordinator did not enter the error state.")
            return
        }

        #expect(context.code == "permissions_missing")
        #expect(context.message == "Speech recognition permission is required.")
        #expect(env.audio.isCapturing == false)
        #expect(env.asr.isStreaming == false)
    }

    @Test("多个 committed 段应分别入队翻译并绑定到各自 segment")
    func testCommittedSegmentsTranslateIndividually() async throws {
        let translate = StubTranslateService(mode: .manual)
        let env = makeTestCoordinator(translateService: translate)
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        env.coordinator.handle(.asrFinalReceived("First sentence. Second sentence."))
        try await waitForCondition { env.translate.enqueuedSegments.count == 2 }

        #expect(env.translate.enqueuedSegments.map(\.sourceText) == ["First sentence.", "Second sentence."])

        #expect(env.translate.completeNext() == true)
        #expect(env.translate.completeNext() == true)

        try await waitForCondition {
            env.buffer.snapshot.committedSegments.allSatisfy { $0.translatedText != nil }
        }

        let segments = env.buffer.snapshot.committedSegments
        #expect(segments.map(\.translatedText) == ["First sentence.", "Second sentence."])
    }

    @Test("pause 时已有 in-flight translation 仍可完成")
    func testPauseDoesNotCancelInflightTranslation() async throws {
        let translate = StubTranslateService(mode: .manual)
        let env = makeTestCoordinator(translateService: translate)
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        env.coordinator.handle(.asrFinalReceived("hello world"))
        try await waitForCondition { env.translate.pendingSegments.count == 1 }

        env.coordinator.handle(.pauseRequested)
        try await waitForCondition { env.coordinator.state == .paused }
        #expect(env.translate.cancelAllCallCount == 0)

        #expect(env.translate.completeNext() == true)
        try await waitForCondition {
            env.buffer.snapshot.committedSegments.first?.status == .translated
        }

        #expect(env.coordinator.state == .paused)
    }

    @Test("partial 提前提交后，final 前缀一致时应确认 provisional 段且不重复提交")
    func testFinalConfirmsMatchingProvisionalSegments() async throws {
        let translate = StubTranslateService(mode: .manual)
        let env = makeTestCoordinator(translateService: translate)
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        env.coordinator.handle(.asrPartialReceived("First. Second"))
        try await waitForCondition { env.translate.enqueuedSegments.count == 1 }
        #expect(env.buffer.snapshot.committedSegments.first?.isProvisional == true)

        #expect(env.translate.completeNext() == true)
        try await waitForCondition {
            env.buffer.snapshot.committedSegments.first?.status == .translated
        }

        env.coordinator.handle(.asrFinalReceived("First. Second sentence."))
        try await waitForCondition { env.translate.enqueuedSegments.count == 2 }

        let segments = env.buffer.snapshot.committedSegments
        #expect(segments.count == 2)
        #expect(segments[0].sourceText == "First.")
        #expect(segments[0].isProvisional == false)
        #expect(segments[0].translatedText == "First.")
        #expect(segments[1].sourceText == "Second sentence.")
        #expect(env.translate.enqueuedSegments.map(\.sourceText) == ["First.", "Second sentence."])
    }

    @Test("partial 提前提交后，final 修正前缀时应删除旧 provisional 段")
    func testFinalRemovesCorrectedProvisionalSegments() async throws {
        let translate = StubTranslateService(mode: .manual)
        let env = makeTestCoordinator(translateService: translate)
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        env.coordinator.handle(.asrPartialReceived("Hello world. How are"))
        try await waitForCondition { env.translate.enqueuedSegments.count == 1 }
        #expect(env.translate.completeNext() == true)
        try await waitForCondition {
            env.buffer.snapshot.committedSegments.first?.translatedText == "Hello world."
        }

        env.coordinator.handle(.asrFinalReceived("Hello there. How are you."))
        try await waitForCondition { env.translate.enqueuedSegments.count == 3 }

        let segments = env.buffer.snapshot.committedSegments
        #expect(segments.map(\.sourceText) == ["Hello there.", "How are you."])
        #expect(segments.contains(where: { $0.sourceText == "Hello world." }) == false)
        #expect(env.buffer.snapshot.partialText == "")
    }

    @Test("final 无 remainder 时应清空旧 partial")
    func testFinalClearsStalePartialWithoutRemainder() async throws {
        let translate = StubTranslateService(mode: .manual)
        let env = makeTestCoordinator(translateService: translate)
        env.coordinator.handle(.startRequested)
        try await waitForCondition { env.coordinator.state == .listening }

        env.coordinator.handle(.asrPartialReceived("First. Second"))
        try await waitForCondition { env.renderer.lastSnapshot.originalLines.count == 2 }

        env.coordinator.handle(.asrFinalReceived("First."))
        try await waitForCondition {
            env.buffer.snapshot.partialText.isEmpty && env.renderer.lastSnapshot.originalLines.count == 1
        }

        #expect(env.renderer.lastSnapshot.originalLines[0].text == "First.")
        #expect(env.renderer.lastSnapshot.originalLines[0].isCommitted == true)
        #expect(env.buffer.snapshot.partialText == "")
    }

    @Test("settingsUpdated 传入 zh-Hans source 时应规范化为 zh-CN")
    func testSettingsUpdatedNormalizesChineseSourceLocale() async throws {
        let env = makeTestCoordinator()
        var settings = env.coordinator.settings
        settings.languagePair.sourceCode = "zh-Hans"

        env.coordinator.handle(.settingsUpdated(settings))
        try await waitForCondition { env.asr.localeIdentifier == "zh-CN" }

        #expect(env.asr.localeIdentifier == "zh-CN")
        #expect(env.coordinator.settings.languagePair.sourceCode == "zh-CN")
    }
}
