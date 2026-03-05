import Foundation
import Testing
@testable import SpeechflowCore

@Suite("AutoCommitScheduler Tests")
struct AutoCommitSchedulerTests {
    
    // 我们在这个测试里使用更小的 delays 来加速测试
    let config = AutoCommitScheduler.Configuration(
        shortFragmentTokenLimit: 1,
        shortPhraseExtraCommitDelay: 0.04,
        minimumPunctuatedCommitDelay: 0.045,
        minimumStableCommitDelay: 0.035,
        minimumClauseCommitDelay: 0.05,
        minimumSemanticCommitDelay: 0.065,
        minimumSemanticChunkCharacters: 8
    )

    @Test("对于拥有句末标点的句子，silenceCommit 延迟较短")
    func testSilenceCommitDelayForTerminalPunctuation() {
        let scheduler = AutoCommitScheduler(configuration: config)
        let delay = scheduler.silenceCommitDelay(for: "Done.", pauseCommitDelay: 0.1)
        #expect(delay == max(config.minimumPunctuatedCommitDelay, 0.1 * 0.64))
    }

    @Test("对于拥有子句标点的句子，silenceCommit 延迟适中")
    func testSilenceCommitDelayForClausePunctuation() {
        let scheduler = AutoCommitScheduler(configuration: config)
        let delay = scheduler.silenceCommitDelay(for: "Hello,", pauseCommitDelay: 0.1)
        #expect(delay == max(config.minimumClauseCommitDelay, 0.1 * 0.74))
    }

    @Test("对于超短片段，额外增加延迟")
    func testSilenceCommitDelayForShortFragments() {
        let scheduler = AutoCommitScheduler(configuration: config)
        let delay = scheduler.silenceCommitDelay(for: "hi", pauseCommitDelay: 0.1)
        #expect(delay == 0.1 + config.shortPhraseExtraCommitDelay)
    }

    @Test("对于达到语义块条件的无标点文本，延迟介于短和长之间")
    func testSilenceCommitDelayForSemanticChunks() {
        let scheduler = AutoCommitScheduler(configuration: config)
        let delay = scheduler.silenceCommitDelay(for: "This is good", pauseCommitDelay: 0.1)
        #expect(delay == max(config.minimumSemanticCommitDelay, 0.1 * 0.82))
    }

    @Test("对于一般的不满足上述条件的文本，增加固定容忍延迟")
    func testSilenceCommitDelayForDefault() {
        let scheduler = AutoCommitScheduler(configuration: config)
        let delay = scheduler.silenceCommitDelay(for: "running smoothly", pauseCommitDelay: 0.1)
        #expect(delay == 0.1 + 0.2)
    }

    @Test("对于拥有句末标点的句子，stableCommit 延迟最短")
    func testStableCommitDelayForTerminalPunctuation() {
        let scheduler = AutoCommitScheduler(configuration: config)
        let delay = scheduler.stableCommitDelay(for: "Done.", pauseCommitDelay: 0.5)
        // tunedDelay = 0.5 * 0.42 = 0.21
        // max(0.035, min(0.21, 0.5 - 0.18 = 0.32)) = 0.21
        #expect(delay == 0.21)
    }
    
    @Test("调度空字符串应当取消所有未来的提交并立即返回")
    func testScheduleEmptyString() {
        let scheduler = AutoCommitScheduler(configuration: config)
        var stableFired = false
        var silenceFired = false
        
        // 我们需要先触发一次带延迟的，马上再传一个空字符串取消它
        scheduler.schedule(
            for: "hello world",
            pauseCommitDelay: 0.1,
            onSilenceTimeout: { silenceFired = true },
            onStableTimeout: { stableFired = true }
        )
        
        scheduler.schedule(
            for: "   ",
            pauseCommitDelay: 0.1,
            onSilenceTimeout: { silenceFired = true },
            onStableTimeout: { stableFired = true }
        )
        
        // Wait long enough for timeouts to fire if they weren't cancelled
        Thread.sleep(forTimeInterval: 0.2)
        
        #expect(stableFired == false)
        #expect(silenceFired == false)
    }
    
    @Test("cancelAll 应当取消排队的任务")
    func testCancelAll() {
        let scheduler = AutoCommitScheduler(configuration: config)
        var didFire = false
        
        scheduler.schedule(
            for: "hello.",
            pauseCommitDelay: 0.1,
            onSilenceTimeout: { didFire = true },
            onStableTimeout: { didFire = true }
        )
        
        scheduler.cancelAll()
        
        Thread.sleep(forTimeInterval: 0.2)
        #expect(didFire == false)
    }
}
