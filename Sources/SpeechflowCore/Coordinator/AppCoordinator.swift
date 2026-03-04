import Dispatch
import Foundation

public final class AppCoordinator: SpeechflowCoordinating {
    public private(set) var state: AppState = .idle

    public private(set) var settings: SpeechflowSettings
    public private(set) var networkQuality: NetworkQuality = .unknown
    public private(set) var activeInputSource: AudioInputSource?

    private let audioService: AudioEngineServicing
    private let asrService: LocalASRServicing
    private let networkMonitor: NetworkMonitoring
    private let permissionService: PermissionServicing
    private let transcriptBuffer: TranscriptBuffering
    private let translateService: TranslateServicing
    private let overlayRenderer: OverlayRendering
    private let settingsStore: SettingsStoring
    private let clock: TimeProviding
    private var pendingInputSource: AudioInputSource = .microphone
    private var isAwaitingPermissions = false
    private var shouldStartWhenPermissionsResolve = false
    private var pendingSilenceCommit: DispatchWorkItem?
    private var pendingStableCommit: DispatchWorkItem?

    private let minimumStableCommitCharacters = 6
    private let minimumSemanticChunkCharacters = 14
    private let minimumSemanticChunkTokens = 4
    private let shortFragmentTokenLimit = 2
    private let shortPhraseExtraCommitDelay: TimeInterval = 0.4
    private let minimumPunctuatedCommitDelay: TimeInterval = 0.45
    private let minimumStableCommitDelay: TimeInterval = 0.35
    private let minimumClauseCommitDelay: TimeInterval = 0.5
    private let minimumSemanticCommitDelay: TimeInterval = 0.65

    public init(
        audioService: AudioEngineServicing,
        asrService: LocalASRServicing,
        networkMonitor: NetworkMonitoring,
        permissionService: PermissionServicing,
        transcriptBuffer: TranscriptBuffering,
        translateService: TranslateServicing,
        overlayRenderer: OverlayRendering,
        settingsStore: SettingsStoring,
        clock: TimeProviding
    ) {
        self.audioService = audioService
        self.asrService = asrService
        self.networkMonitor = networkMonitor
        self.permissionService = permissionService
        self.transcriptBuffer = transcriptBuffer
        self.translateService = translateService
        self.overlayRenderer = overlayRenderer
        self.settingsStore = settingsStore
        self.clock = clock
        self.settings = settingsStore.load()
        self.transcriptBuffer.updateLanguagePair(self.settings.languagePair)
        self.asrService.updateLocaleIdentifier(self.settings.languagePair.sourceCode)
        self.audioService.updateRecognitionTuning(self.settings.recognitionTuning)
        self.translateService.updateLanguagePair(self.settings.languagePair)
        self.translateService.updatePolicy(self.settings.translationPolicy)
        self.translateService.updateBackendPreference(self.settings.translationBackendPreference)
        self.translateService.updateNetworkQuality(networkQuality)
        self.overlayRenderer.setVisibility(self.settings.overlayVisibleByDefault)
    }

    public func handle(_ event: SpeechflowEvent) {
        switch event {
        case .startRequested:
            print("[Coordinator] .startRequested")
            requestPermissionsThenStartIfNeeded(for: .microphone)
        case .startMicrophoneRequested:
            print("[Coordinator] .startMicrophoneRequested")
            requestPermissionsThenStartIfNeeded(for: .microphone)
        case .startSystemAudioRequested:
            print("[Coordinator] .startSystemAudioRequested")
            requestPermissionsThenStartIfNeeded(for: .systemAudio)
        case .pauseRequested:
            pauseSession()
        case .resumeRequested:
            resumeSession()
        case .stopRequested:
            stopSession()
        case .permissionsResolved(let permissions):
            print("[Coordinator] .permissionsResolved mic=\(permissions.microphoneGranted) speech=\(permissions.speechRecognitionGranted) ready=\(permissions.isReadyForMVP)")
            handlePermissionsResolved(permissions)
        case .permissionRequestFailed(let message):
            print("[Coordinator] .permissionRequestFailed: \(message)")
            enterError(code: "permission_request_failed", message: message)
        case .networkQualityChanged(let quality):
            networkQuality = quality
            translateService.updateNetworkQuality(quality)
        case .localASRFailed(let message):
            print("[Coordinator] .localASRFailed: \(message)")
            enterError(code: "local_asr_failed", message: message)
        case .asrPartialReceived(let text):
            print("[Coordinator] .asrPartialReceived: \"\(text.prefix(40))\"")
            handlePartial(text)
        case .asrFinalReceived(let text):
            print("[Coordinator] .asrFinalReceived: \"\(text.prefix(40))\"")
            handleFinal(text)
        case .silenceTimeoutTriggered:
            commitCurrentDraft(reason: .silenceTimeout)
        case .partialStableTimeoutTriggered:
            commitCurrentDraft(reason: .partialStabilized)
        case .translationFinished(let result):
            print("[Coordinator] .translationFinished: \"\(result.text?.prefix(40) ?? "nil")\"")
            _ = transcriptBuffer.applyTranslationResult(
                result,
                at: clock.now
            )
            renderCurrentSnapshot()
        case .translationFailed(let segmentID, let message):
            print("[Coordinator] .translationFailed id=\(segmentID) msg=\(message)")
            _ = transcriptBuffer.markTranslationFailure(for: segmentID, message: message)
            renderCurrentSnapshot()
        case .settingsUpdated(let newSettings):
            applySettings(newSettings)
        case .overlayToggled(let isVisible):
            settings.overlayVisibleByDefault = isVisible
            settingsStore.save(settings)
            overlayRenderer.setVisibility(isVisible)
        case .translationToggled(let isEnabled):
            settings.translationEnabledByDefault = isEnabled
            settingsStore.save(settings)
            renderCurrentSnapshot()
        }
    }

    private func startSession() {
        guard canStartSession else {
            print("[Coordinator] startSession() — cannot start, state=\(state)")
            return
        }

        do {
            audioService.updateInputSource(pendingInputSource)
            try asrService.startStreaming { [weak self] event in
                self?.handle(event)
            }
            try audioService.startCapture()
            networkMonitor.start { [weak self] event in
                self?.handle(event)
            }
            translateService.start { [weak self] event in
                self?.handle(event)
            }
            activeInputSource = pendingInputSource
            state = .listening
            print("[Coordinator] startSession() — now listening")
            renderCurrentSnapshot()
        } catch {
            print("[Coordinator] startSession() — FAILED: \(error)")
            state = .error(
                AppErrorContext(
                    code: "startup_failed",
                    message: error.localizedDescription
                )
            )
            audioService.stopCapture()
            asrService.stopStreaming()
            networkMonitor.stop()
            translateService.cancelAll()
            activeInputSource = nil
        }
    }

    private func pauseSession() {
        guard case .listening = state else {
            return
        }

        cancelAutoCommitTimers()
        audioService.pauseCapture()
        asrService.stopStreaming()
        networkMonitor.stop()
        translateService.cancelAll()
        state = .paused
    }

    private func resumeSession() {
        guard case .paused = state else {
            return
        }

        do {
            if let activeInputSource {
                audioService.updateInputSource(activeInputSource)
            }
            try asrService.startStreaming { [weak self] event in
                self?.handle(event)
            }
            try audioService.startCapture()
            networkMonitor.start { [weak self] event in
                self?.handle(event)
            }
            state = .listening
            renderCurrentSnapshot()
        } catch {
            state = .error(
                AppErrorContext(
                    code: "resume_failed",
                    message: error.localizedDescription
                )
            )
            audioService.stopCapture()
            asrService.stopStreaming()
            networkMonitor.stop()
            translateService.cancelAll()
        }
    }

    private func stopSession() {
        isAwaitingPermissions = false
        shouldStartWhenPermissionsResolve = false
        cancelAutoCommitTimers()
        audioService.stopCapture()
        asrService.stopStreaming()
        networkMonitor.stop()
        translateService.cancelAll()
        transcriptBuffer.reset()
        activeInputSource = nil
        state = .idle
        renderCurrentSnapshot()
    }

    private func handlePermissionsResolved(_ permissions: PermissionSet) {
        isAwaitingPermissions = false

        guard permissions.isReady(for: pendingInputSource) else {
            shouldStartWhenPermissionsResolve = false
            state = .error(
                AppErrorContext(
                    code: "permissions_missing",
                    message: permissions.missingRequirementsMessage(for: pendingInputSource)
                )
            )
            activeInputSource = nil
            return
        }

        if shouldStartWhenPermissionsResolve {
            shouldStartWhenPermissionsResolve = false
            if case .error = state {
                state = .idle
            }
            startSession()
            return
        }

        if case .error = state {
            state = .idle
        }
    }

    private func handlePartial(_ text: String) {
        guard case .listening = state else {
            return
        }

        _ = transcriptBuffer.applyPartial(text)
        renderCurrentSnapshot()
        scheduleAutoCommit(for: text)
    }

    private func handleFinal(_ text: String) {
        guard case .listening = state else {
            return
        }

        cancelAutoCommitTimers()
        _ = transcriptBuffer.applyPartial(text)
        commitCurrentDraft(reason: .finalResult)
    }

    private func commitCurrentDraft(reason: CommitReason) {
        guard case .listening = state else {
            return
        }

        cancelAutoCommitTimers()

        guard let mutation = transcriptBuffer.commitCurrentDraft(
            reason: reason,
            now: clock.now
        ) else {
            return
        }

        render(snapshot: mutation.snapshot)

        guard settings.translationEnabledByDefault,
              let segment = mutation.committedSegment else {
            return
        }

        _ = transcriptBuffer.markTranslationStarted(for: segment.id)
        renderCurrentSnapshot()
        translateService.enqueue(segment)
    }

    private func renderCurrentSnapshot() {
        render(snapshot: transcriptBuffer.snapshot)
    }

    private func render(snapshot: TranscriptSnapshot) {
        let renderModel = OverlayViewModelBuilder.makeRenderModel(
            from: snapshot,
            maxLines: settings.maxVisibleLines
        )
        overlayRenderer.render(snapshot: renderModel)
    }

    private func applySettings(_ newSettings: SpeechflowSettings) {
        let sourceLanguageChanged = settings.languagePair.sourceCode != newSettings.languagePair.sourceCode
        let audioInputConfigurationChanged = hasAudioInputConfigurationChange(
            from: settings.recognitionTuning,
            to: newSettings.recognitionTuning
        )
        settings = newSettings
        settingsStore.save(newSettings)
        transcriptBuffer.updateLanguagePair(newSettings.languagePair)
        audioService.updateRecognitionTuning(newSettings.recognitionTuning)
        refreshRecognitionPipelineIfNeeded(
            localeIdentifier: newSettings.languagePair.sourceCode,
            sourceLanguageChanged: sourceLanguageChanged,
            audioInputConfigurationChanged: audioInputConfigurationChanged
        )
        translateService.updateLanguagePair(newSettings.languagePair)
        translateService.updatePolicy(newSettings.translationPolicy)
        translateService.updateBackendPreference(newSettings.translationBackendPreference)
        overlayRenderer.setVisibility(newSettings.overlayVisibleByDefault)
        renderCurrentSnapshot()
    }

    private func hasAudioInputConfigurationChange(
        from oldTuning: RecognitionTuning,
        to newTuning: RecognitionTuning
    ) -> Bool {
        _ = oldTuning
        _ = newTuning
        return false
    }

    private func refreshRecognitionPipelineIfNeeded(
        localeIdentifier: String,
        sourceLanguageChanged: Bool,
        audioInputConfigurationChanged: Bool
    ) {
        asrService.updateLocaleIdentifier(localeIdentifier)

        guard sourceLanguageChanged || audioInputConfigurationChanged else {
            return
        }

        guard case .listening = state else {
            return
        }

        cancelAutoCommitTimers()
        asrService.stopStreaming()

        if audioInputConfigurationChanged {
            audioService.stopCapture()
        }

        do {
            try asrService.startStreaming { [weak self] event in
                self?.handle(event)
            }

            if audioInputConfigurationChanged {
                try audioService.startCapture()
            }
        } catch {
            enterError(code: "recognition_pipeline_update_failed", message: error.localizedDescription)
        }
    }

    private func enterError(code: String, message: String) {
        isAwaitingPermissions = false
        shouldStartWhenPermissionsResolve = false
        cancelAutoCommitTimers()
        audioService.stopCapture()
        asrService.stopStreaming()
        networkMonitor.stop()
        translateService.cancelAll()
        state = .error(
            AppErrorContext(
                code: code,
                message: message
            )
        )
        activeInputSource = nil
    }

    private func scheduleAutoCommit(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelAutoCommitTimers()
            return
        }

        pendingStableCommit?.cancel()
        pendingStableCommit = nil

        if shouldScheduleStableCommit(for: trimmed) {
            let stableSnapshot = trimmed
            let stableCommit = DispatchWorkItem { [weak self] in
                guard let self = self else {
                    return
                }

                guard case .listening = self.state else {
                    return
                }

                let currentPartial = self.transcriptBuffer.snapshot.partialText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentPartial == stableSnapshot else {
                    return
                }

                self.handle(.partialStableTimeoutTriggered)
            }
            pendingStableCommit = stableCommit
            DispatchQueue.main.asyncAfter(
                deadline: .now() + stableCommitDelay(for: trimmed),
                execute: stableCommit
            )
        }

        pendingSilenceCommit?.cancel()
        let silenceCommit = DispatchWorkItem { [weak self] in
            self?.handle(.silenceTimeoutTriggered)
        }
        pendingSilenceCommit = silenceCommit
        DispatchQueue.main.asyncAfter(
            deadline: .now() + silenceCommitDelay(for: trimmed),
            execute: silenceCommit
        )
    }

    private func shouldScheduleStableCommit(for text: String) -> Bool {
        isRealtimeSubtitleCommitCandidate(text)
    }

    private func silenceCommitDelay(for text: String) -> TimeInterval {
        if endsWithTerminalPunctuation(text) {
            return max(minimumPunctuatedCommitDelay, configuredPauseCommitDelay * 0.64)
        }

        if endsWithClauseBoundaryPunctuation(text) {
            return max(minimumClauseCommitDelay, configuredPauseCommitDelay * 0.74)
        }

        let tokenCount = wordTokenCount(in: text)
        if tokenCount <= shortFragmentTokenLimit && text.count < minimumSemanticChunkCharacters {
            return configuredPauseCommitDelay + shortPhraseExtraCommitDelay
        }

        if isSemanticChunkCandidate(text) {
            return max(minimumSemanticCommitDelay, configuredPauseCommitDelay * 0.82)
        }

        return configuredPauseCommitDelay + 0.2
    }

    private func endsWithTerminalPunctuation(_ text: String) -> Bool {
        guard let lastCharacter = text.last else {
            return false
        }

        return Self.terminalPunctuation.contains(lastCharacter)
    }

    private func endsWithClauseBoundaryPunctuation(_ text: String) -> Bool {
        guard let lastCharacter = text.last else {
            return false
        }

        return Self.clauseBoundaryPunctuation.contains(lastCharacter)
    }

    private static let terminalPunctuation: Set<Character> = [
        ".",
        "!",
        "?",
        "。",
        "！",
        "？"
    ]

    private static let clauseBoundaryPunctuation: Set<Character> = [
        ",",
        ";",
        ":",
        "，",
        "、",
        "；",
        "："
    ]

    private static let weakTrailingConnectors: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "by", "for", "from",
        "if", "in", "into", "is", "of", "on", "or", "so", "the", "to",
        "was", "were", "with", "yet"
    ]

    private func cancelAutoCommitTimers() {
        pendingStableCommit?.cancel()
        pendingStableCommit = nil
        pendingSilenceCommit?.cancel()
        pendingSilenceCommit = nil
    }

    private func requestPermissionsThenStartIfNeeded(for inputSource: AudioInputSource) {
        switch state {
        case .idle, .error:
            break
        case .listening, .paused:
            return
        }

        guard !isAwaitingPermissions else {
            return
        }

        pendingInputSource = inputSource
        shouldStartWhenPermissionsResolve = true
        isAwaitingPermissions = true
        permissionService.requestPermissions(for: inputSource) { [weak self] event in
            self?.handle(event)
        }
    }

    private var configuredPauseCommitDelay: TimeInterval {
        max(0.6, settings.recognitionTuning.pauseCommitDelay)
    }

    private func stableCommitDelay(for text: String) -> TimeInterval {
        if endsWithTerminalPunctuation(text) {
            let tunedDelay = configuredPauseCommitDelay * 0.42
            return max(minimumStableCommitDelay, min(tunedDelay, configuredPauseCommitDelay - 0.18))
        }

        if endsWithClauseBoundaryPunctuation(text) {
            let tunedDelay = configuredPauseCommitDelay * 0.5
            return max(0.42, min(tunedDelay, configuredPauseCommitDelay - 0.12))
        }

        if isSemanticChunkCandidate(text) {
            let tunedDelay = configuredPauseCommitDelay * 0.62
            return max(0.55, min(tunedDelay, configuredPauseCommitDelay + 0.05))
        }

        let tunedDelay = configuredPauseCommitDelay * 0.72
        return max(0.7, min(tunedDelay, configuredPauseCommitDelay + 0.18))
    }

    private func isRealtimeSubtitleCommitCandidate(_ text: String) -> Bool {
        if endsWithTerminalPunctuation(text) || endsWithClauseBoundaryPunctuation(text) {
            return true
        }

        return isSemanticChunkCandidate(text)
    }

    private func isSemanticChunkCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard !endsWithWeakTrailingConnector(trimmed) else {
            return false
        }

        let tokenCount = wordTokenCount(in: trimmed)
        if tokenCount >= minimumSemanticChunkTokens && trimmed.count >= minimumSemanticChunkCharacters {
            return true
        }

        if tokenCount <= 1 {
            return trimmed.count >= minimumSemanticChunkCharacters
        }

        return false
    }

    private func endsWithWeakTrailingConnector(_ text: String) -> Bool {
        guard let lastToken = text
            .split(whereSeparator: \.isWhitespace)
            .last?
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters) else {
            return false
        }

        guard !lastToken.isEmpty else {
            return false
        }

        return Self.weakTrailingConnectors.contains(lastToken)
    }

    private func wordTokenCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var canStartSession: Bool {
        switch state {
        case .idle:
            return true
        case .listening, .paused, .error:
            return false
        }
    }
}
