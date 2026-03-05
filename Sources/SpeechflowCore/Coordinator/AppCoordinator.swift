import Combine
import Dispatch
import Foundation

public final class AppCoordinator: SpeechflowCoordinating, ObservableObject {
    @Published public private(set) var state: AppState = .idle

    @Published public private(set) var settings: SpeechflowSettings
    public private(set) var networkQuality: NetworkQuality = .unknown
    @Published public private(set) var activeInputSource: AudioInputSource?

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
    private var pendingTranslationSegments: [TranscriptSegment] = []
    private let maxTranslationAccumulationCharacters = 50

    private let minimumStableCommitCharacters = 4
    private let minimumSemanticChunkCharacters = 8
    private let minimumSemanticChunkTokens = 3

    private let autoCommitScheduler = AutoCommitScheduler()

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
        self.translateService.updateOpenRouterAPIKey(self.settings.openRouterAPIKey)
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
            let preview = result.text ?? result.assistantText ?? "nil"
            print("[Coordinator] .translationFinished: \"\(preview.prefix(40))\"")
            if let text = result.text, !text.isEmpty {
                logToFile(text, prefix: "Translated")
            }
            if let assistantText = result.assistantText, !assistantText.isEmpty {
                logToFile(assistantText, prefix: "Assistant")
            }
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
        flushPendingTranslation()
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
        flushPendingTranslation()
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

        let chunks = TextChunkingHelper.splitIntoTranslationChunks(text)
        for chunk in chunks {
            _ = transcriptBuffer.applyPartial(chunk)
            commitCurrentDraft(reason: .finalResult)
        }
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

        accumulateForTranslation(segment)
    }

    private func accumulateForTranslation(_ segment: TranscriptSegment) {
        pendingTranslationSegments.append(segment)

        let accumulatedText = pendingTranslationSegments
            .map(\.sourceText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if TextChunkingHelper.endsWithTerminalPunctuation(accumulatedText)
            || accumulatedText.count >= maxTranslationAccumulationCharacters {
            flushPendingTranslation()
        }
    }

    private func flushPendingTranslation() {
        guard !pendingTranslationSegments.isEmpty else {
            return
        }

        let mergedText = pendingTranslationSegments
            .map(\.sourceText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !mergedText.isEmpty,
              let lastSegment = pendingTranslationSegments.last else {
            pendingTranslationSegments.removeAll()
            return
        }

        logToFile(mergedText, prefix: "Original")

        guard settings.translationEnabledByDefault else {
            pendingTranslationSegments.removeAll()
            return
        }

        let normalizedMergedText = mergedText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()

        let translationSegment = TranscriptSegment(
            id: lastSegment.id,
            sourceText: mergedText,
            normalizedSourceText: normalizedMergedText,
            status: .committed,
            createdAt: lastSegment.createdAt,
            committedAt: lastSegment.committedAt,
            sourceLanguage: lastSegment.sourceLanguage,
            targetLanguage: lastSegment.targetLanguage
        )

        pendingTranslationSegments.removeAll()

        _ = transcriptBuffer.markTranslationStarted(for: lastSegment.id)
        renderCurrentSnapshot()
        translateService.enqueue(translationSegment)
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
        translateService.updateOpenRouterAPIKey(newSettings.openRouterAPIKey)
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
        autoCommitScheduler.schedule(
            for: trimmed,
            pauseCommitDelay: configuredPauseCommitDelay,
            onSilenceTimeout: { [weak self] in
                self?.handle(.silenceTimeoutTriggered)
            },
            onStableTimeout: { [weak self] in
                guard let self = self else { return }
                guard case .listening = self.state else { return }
                let currentPartial = self.transcriptBuffer.snapshot.partialText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentPartial == trimmed else { return }
                self.handle(.partialStableTimeoutTriggered)
            }
        )
    }

    private func cancelAutoCommitTimers() {
        autoCommitScheduler.cancelAll()
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

    private func logToFile(_ text: String, prefix: String) {
        DispatchQueue.global(qos: .utility).async {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsURL.appendingPathComponent("Speechflow_Transcript.txt")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timestamp = formatter.string(from: Date())
            let logEntry = "[\(timestamp)] \(prefix): \(text)\n"

            if let data = logEntry.data(using: .utf8) {
                if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
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
