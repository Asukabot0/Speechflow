import SwiftUI
import SpeechflowCore
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    private let coordinator: AppCoordinator
    private var pollTask: Task<Void, Never>?

    @Published var state: AppState
    @Published var settings: SpeechflowSettings
    @Published var activeInputSource: AudioInputSource?
    
    let nativeTranslationService: Any?

    init(coordinator: AppCoordinator, nativeTranslationService: Any? = nil) {
        self.coordinator = coordinator
        self.state = coordinator.state
        self.settings = coordinator.settings
        self.activeInputSource = coordinator.activeInputSource
        self.nativeTranslationService = nativeTranslationService

        // Simple polling mechanism since AppCoordinator is not ObservableObject currently
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                if self.state != self.coordinator.state {
                    self.state = self.coordinator.state
                }
                if self.settings != self.coordinator.settings {
                    self.settings = self.coordinator.settings
                }
                if self.activeInputSource != self.coordinator.activeInputSource {
                    self.activeInputSource = self.coordinator.activeInputSource
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    func start() {
        coordinator.handle(.startRequested)
    }

    func startMicrophoneTranslation() {
        coordinator.handle(.startMicrophoneRequested)
    }

    func startSystemAudioTranslation() {
        coordinator.handle(.startSystemAudioRequested)
    }

    func pause() {
        coordinator.handle(.pauseRequested)
    }

    func resume() {
        coordinator.handle(.resumeRequested)
    }

    func stop() {
        coordinator.handle(.stopRequested)
    }

    func toggleTranslation(isEnabled: Bool) {
        coordinator.handle(.translationToggled(isEnabled))
    }

    func toggleOverlay(isVisible: Bool) {
        coordinator.handle(.overlayToggled(isVisible))
    }

    func updateSettings(_ newSettings: SpeechflowSettings) {
        self.settings = newSettings
        coordinator.handle(.settingsUpdated(newSettings))
    }

    func updateSourceLanguage(_ sourceCode: String) {
        guard settings.languagePair.sourceCode != sourceCode else {
            return
        }

        var newSettings = settings
        newSettings.languagePair.sourceCode = sourceCode
        updateSettings(newSettings)
    }

    func updateTargetLanguage(_ targetCode: String) {
        guard settings.languagePair.targetCode != targetCode else {
            return
        }

        var newSettings = settings
        newSettings.languagePair.targetCode = targetCode
        updateSettings(newSettings)
    }

    func updateRecognitionInputGain(_ gain: Double) {
        var newSettings = settings
        newSettings.recognitionTuning.inputGain = gain
        updateSettings(newSettings)
    }

    func setVoiceProcessingEnabled(_ isEnabled: Bool) {
        var newSettings = settings
        newSettings.recognitionTuning.voiceProcessingEnabled = isEnabled
        if !isEnabled {
            newSettings.recognitionTuning.automaticGainControlEnabled = false
        }
        updateSettings(newSettings)
    }

    func setAutomaticGainControlEnabled(_ isEnabled: Bool) {
        var newSettings = settings
        newSettings.recognitionTuning.automaticGainControlEnabled = isEnabled
        if isEnabled {
            newSettings.recognitionTuning.voiceProcessingEnabled = true
        }
        updateSettings(newSettings)
    }

    func updatePauseCommitDelay(_ delay: Double) {
        var newSettings = settings
        newSettings.recognitionTuning.pauseCommitDelay = delay
        updateSettings(newSettings)
    }

    func updateTranslationBackendPreference(_ backendPreference: TranslationBackendPreference) {
        guard settings.translationBackendPreference != backendPreference else {
            return
        }

        var newSettings = settings
        newSettings.translationBackendPreference = backendPreference
        updateSettings(newSettings)
    }

    func updateSourceBackgroundColor(_ color: Color) {
        if let components = color.colorComponents {
            var newSettings = settings
            newSettings.sourceBackgroundColor = components
            updateSettings(newSettings)
        }
    }

    func updateTargetBackgroundColor(_ color: Color) {
        if let components = color.colorComponents {
            var newSettings = settings
            newSettings.targetBackgroundColor = components
            updateSettings(newSettings)
        }
    }

    func updateSourceTextColor(_ color: Color) {
        if let components = color.colorComponents {
            var newSettings = settings
            newSettings.sourceTextColor = components
            updateSettings(newSettings)
        }
    }

    func updateTargetTextColor(_ color: Color) {
        if let components = color.colorComponents {
            var newSettings = settings
            newSettings.targetTextColor = components
            updateSettings(newSettings)
        }
    }
}

extension ColorComponents {
    var suColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

#if canImport(AppKit)
import AppKit

extension Color {
    var colorComponents: ColorComponents? {
        // Must convert via NSColor for native macOS
        guard let nsColor = NSColor(self).usingColorSpace(.extendedSRGB) else { return nil }
        return ColorComponents(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: Double(nsColor.alphaComponent)
        )
    }
}
#endif
