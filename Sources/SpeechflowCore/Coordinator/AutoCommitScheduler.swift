import Foundation

final class AutoCommitScheduler {
    struct Configuration {
        let shortFragmentTokenLimit: Int
        let shortPhraseExtraCommitDelay: TimeInterval
        let minimumPunctuatedCommitDelay: TimeInterval
        let minimumStableCommitDelay: TimeInterval
        let minimumClauseCommitDelay: TimeInterval
        let minimumSemanticCommitDelay: TimeInterval
        let minimumSemanticChunkCharacters: Int

        static let `default` = Configuration(
            shortFragmentTokenLimit: 1,
            shortPhraseExtraCommitDelay: 0.4,
            minimumPunctuatedCommitDelay: 0.45,
            minimumStableCommitDelay: 0.35,
            minimumClauseCommitDelay: 0.5,
            minimumSemanticCommitDelay: 0.65,
            minimumSemanticChunkCharacters: 8
        )
    }

    private let config: Configuration
    private var pendingSilenceCommit: DispatchWorkItem?
    private var pendingStableCommit: DispatchWorkItem?

    init(configuration: Configuration = .default) {
        self.config = configuration
    }

    func schedule(
        for text: String,
        pauseCommitDelay: TimeInterval,
        onSilenceTimeout: @escaping () -> Void,
        onStableTimeout: @escaping () -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelAll()
            return
        }

        pendingStableCommit?.cancel()
        pendingStableCommit = nil

        if TextChunkingHelper.isRealtimeSubtitleCommitCandidate(trimmed) {
            let stableCommit = DispatchWorkItem {
                onStableTimeout()
            }
            pendingStableCommit = stableCommit
            DispatchQueue.main.asyncAfter(
                deadline: .now() + stableCommitDelay(for: trimmed, pauseCommitDelay: pauseCommitDelay),
                execute: stableCommit
            )
        }

        pendingSilenceCommit?.cancel()
        let silenceCommit = DispatchWorkItem {
            onSilenceTimeout()
        }
        pendingSilenceCommit = silenceCommit
        DispatchQueue.main.asyncAfter(
            deadline: .now() + silenceCommitDelay(for: trimmed, pauseCommitDelay: pauseCommitDelay),
            execute: silenceCommit
        )
    }

    func cancelAll() {
        pendingStableCommit?.cancel()
        pendingStableCommit = nil
        pendingSilenceCommit?.cancel()
        pendingSilenceCommit = nil
    }

    func silenceCommitDelay(for text: String, pauseCommitDelay: TimeInterval) -> TimeInterval {
        if TextChunkingHelper.endsWithTerminalPunctuation(text) {
            return max(config.minimumPunctuatedCommitDelay, pauseCommitDelay * 0.64)
        }

        if TextChunkingHelper.endsWithClauseBoundaryPunctuation(text) {
            return max(config.minimumClauseCommitDelay, pauseCommitDelay * 0.74)
        }

        let tokenCount = TextChunkingHelper.wordTokenCount(in: text)
        if tokenCount <= config.shortFragmentTokenLimit && text.count < config.minimumSemanticChunkCharacters {
            return pauseCommitDelay + config.shortPhraseExtraCommitDelay
        }

        if TextChunkingHelper.isSemanticChunkCandidate(
            text,
            minimumTokens: 3,
            minimumCharacters: config.minimumSemanticChunkCharacters
        ) {
            return max(config.minimumSemanticCommitDelay, pauseCommitDelay * 0.82)
        }

        return pauseCommitDelay + 0.2
    }

    func stableCommitDelay(for text: String, pauseCommitDelay: TimeInterval) -> TimeInterval {
        if TextChunkingHelper.endsWithTerminalPunctuation(text) {
            let tunedDelay = pauseCommitDelay * 0.42
            return max(config.minimumStableCommitDelay, min(tunedDelay, pauseCommitDelay - 0.18))
        }

        if TextChunkingHelper.endsWithClauseBoundaryPunctuation(text) {
            let tunedDelay = pauseCommitDelay * 0.5
            return max(0.42, min(tunedDelay, pauseCommitDelay - 0.12))
        }

        if TextChunkingHelper.isSemanticChunkCandidate(
            text,
            minimumTokens: 3,
            minimumCharacters: config.minimumSemanticChunkCharacters
        ) {
            let tunedDelay = pauseCommitDelay * 0.62
            return max(0.55, min(tunedDelay, pauseCommitDelay + 0.05))
        }

        let tunedDelay = pauseCommitDelay * 0.72
        return max(0.7, min(tunedDelay, pauseCommitDelay + 0.18))
    }
}
