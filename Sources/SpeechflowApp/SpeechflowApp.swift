import SwiftUI
import AppKit
import SpeechflowCore

@main
struct SpeechflowApp: App {
    @StateObject private var appViewModel: AppViewModel
    private let originalOverlayController: OverlayWindowController
    private let translatedOverlayController: OverlayWindowController
    private let assistantOverlayController: OverlayWindowController
    private let translationWorkerController: NSObject?

    init() {
        // Force the app to run as an accessory app so it doesn't require a main window
        // and its Menu Bar item successfully registers immediately when launched from Terminal.
        NSApplication.shared.setActivationPolicy(.accessory)
        
        let viewModel = OverlayViewModel()
        let originalOverlayController = OverlayWindowController(viewModel: viewModel, subtitleType: .original)
        let translatedOverlayController = OverlayWindowController(viewModel: viewModel, subtitleType: .translated)
        let assistantOverlayController = OverlayWindowController(viewModel: viewModel, subtitleType: .assistant)
        let overlayRenderer = RealOverlayRenderer(
            originalController: originalOverlayController,
            translatedController: translatedOverlayController,
            assistantController: assistantOverlayController,
            viewModel: viewModel
        )
        
        // Replicate bootstrap with real renderer
        let settingsStore = UserDefaultsSettingsStore()
        let settings = settingsStore.load()

        let audioService = SelectableAudioCaptureService(
            microphoneService: SystemAudioEngineService(),
            systemAudioService: ScreenCaptureSystemAudioService()
        )
        let asrService = PreferredLocalASRService(
            primary: WhisperTurboASRService(
                audioService: audioService,
                localeIdentifier: settings.languagePair.sourceCode
            ),
            fallback: SpeechFrameworkASRService(
                audioService: audioService,
                localeIdentifier: settings.languagePair.sourceCode
            )
        )
        let networkMonitor = StubNetworkMonitor()
        let permissionService = SystemPermissionService()
        let subtitleTranslationProvider: TranslateServicing
        var translationWorkerController: NSObject?
        if #available(macOS 15.0, *) {
            let nativeTranslationService = NativeTranslationService()
            subtitleTranslationProvider = TranslationRouterService(
                preferredBackend: settings.translationBackendPreference,
                systemProvider: nativeTranslationService
            )
            translationWorkerController = TranslationWorkerWindowController(
                nativeTranslationService: nativeTranslationService
            )
        } else {
            subtitleTranslationProvider = TranslationRouterService(
                preferredBackend: settings.translationBackendPreference,
                systemProvider: LocalOllamaTranslationService()
            )
            translationWorkerController = nil
        }
        let assistantProvider = OpenRouterTranslationService()
        assistantProvider.updateOpenRouterAPIKey(settings.openRouterAPIKey)
        let translateServiceRef = ParallelTranslateService(
            translationProvider: subtitleTranslationProvider,
            assistantProvider: assistantProvider
        )
        
        let transcriptBuffer = TranscriptBuffer(
            languagePair: settings.languagePair,
            maxRetainedSegments: 200
        )

        let coordinator = AppCoordinator(
            audioService: audioService,
            asrService: asrService,
            networkMonitor: networkMonitor,
            permissionService: permissionService,
            transcriptBuffer: transcriptBuffer,
            translateService: translateServiceRef,
            overlayRenderer: overlayRenderer,
            settingsStore: settingsStore,
            clock: SystemClock()
        )
        self.originalOverlayController = originalOverlayController
        self.translatedOverlayController = translatedOverlayController
        self.assistantOverlayController = assistantOverlayController
        self.translationWorkerController = translationWorkerController
        let appVM = AppViewModel(
            coordinator: coordinator
        )
        _appViewModel = StateObject(wrappedValue: appVM)
        
        // Bridge the lifecycle
        originalOverlayController.setupTranslationEnvironment(appViewModel: appVM)
        translatedOverlayController.setupTranslationEnvironment(appViewModel: appVM)
        assistantOverlayController.setupTranslationEnvironment(appViewModel: appVM)
    }

    var body: some Scene {
        MenuBarExtra("Speechflow", systemImage: "mic") {
            MenuBarView(viewModel: appViewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
