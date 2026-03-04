import SwiftUI
import AppKit
import SpeechflowCore

@main
struct SpeechflowApp: App {
    @StateObject private var appViewModel: AppViewModel
    private let originalOverlayController: OverlayWindowController
    private let translatedOverlayController: OverlayWindowController
    #if canImport(Translation)
    private let translationWorkerController: TranslationWorkerWindowController?
    #endif

    init() {
        // Force the app to run as an accessory app so it doesn't require a main window
        // and its Menu Bar item successfully registers immediately when launched from Terminal.
        NSApplication.shared.setActivationPolicy(.accessory)
        
        let viewModel = OverlayViewModel()
        let originalOverlayController = OverlayWindowController(viewModel: viewModel, subtitleType: .original)
        let translatedOverlayController = OverlayWindowController(viewModel: viewModel, subtitleType: .translated)
        let overlayRenderer = RealOverlayRenderer(
            originalController: originalOverlayController,
            translatedController: translatedOverlayController,
            viewModel: viewModel
        )
        
        // Replicate bootstrap with real renderer
        let settingsStore = InMemorySettingsStore()
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
        
        let translateServiceRef: TranslateServicing
        var nativeTranslateRef: Any?
        #if canImport(Translation)
        var translationWorkerController: TranslationWorkerWindowController?
        #endif
        
        if #available(macOS 15.0, *) {
            let native = NativeTranslationService()
            translateServiceRef = TranslationRouterService(
                preferredBackend: settings.translationBackendPreference,
                systemProvider: native
            )
            nativeTranslateRef = native
            #if canImport(Translation)
            translationWorkerController = TranslationWorkerWindowController(nativeTranslationService: native)
            #endif
        } else {
            translateServiceRef = TranslationRouterService(
                preferredBackend: settings.translationBackendPreference,
                systemProvider: StubTranslateService()
            )
        }
        
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
        #if canImport(Translation)
        self.translationWorkerController = translationWorkerController
        #endif
        let appVM = AppViewModel(
            coordinator: coordinator,
            nativeTranslationService: nativeTranslateRef
        )
        _appViewModel = StateObject(wrappedValue: appVM)
        
        // Bridge the lifecycle
        originalOverlayController.setupTranslationEnvironment(appViewModel: appVM)
        translatedOverlayController.setupTranslationEnvironment(appViewModel: appVM)
    }

    var body: some Scene {
        MenuBarExtra("Speechflow", systemImage: "mic") {
            MenuBarView(viewModel: appViewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
