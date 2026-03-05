import Foundation
import Testing
@testable import SpeechflowCore

@Suite("AppCoordinator Tests", .serialized)
struct AppCoordinatorTests {

    func makeTestCoordinator() -> (
        coordinator: AppCoordinator,
        asr: StubASRService,
        translate: StubTranslateService,
        renderer: StubOverlayRenderer,
        audio: StubAudioEngineService
    ) {
        let asr = StubASRService()
        let translate = StubTranslateService()
        let renderer = StubOverlayRenderer()
        let audio = StubAudioEngineService()
        
        // 我们需要传递一个有效的 LanguagePair
        let buffer = TranscriptBuffer(languagePair: LanguagePair(sourceCode: "en-US", targetCode: "zh-Hans"))
        
        let coordinator = AppCoordinator(
            audioService: audio,
            asrService: asr,
            networkMonitor: StubNetworkMonitor(),
            permissionService: StubPermissionService(
                permissions: PermissionSet(
                    microphoneGranted: true,
                    speechRecognitionGranted: true,
                    accessibilityGranted: true
                )
            ),
            transcriptBuffer: buffer,
            translateService: translate,
            overlayRenderer: renderer,
            settingsStore: InMemorySettingsStore(),
            clock: SystemClock()
        )
        return (coordinator, asr, translate, renderer, audio)
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
}
