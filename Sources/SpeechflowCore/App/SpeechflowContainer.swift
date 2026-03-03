public struct SpeechflowContainer {
    public let coordinator: AppCoordinator
    public let audioService: AudioEngineServicing
    public let asrService: LocalASRServicing
    public let networkMonitor: NetworkMonitoring
    public let permissionService: PermissionServicing
    public let translateService: TranslateServicing
    public let overlayRenderer: OverlayRendering
    public let settingsStore: SettingsStoring
    public let transcriptBuffer: TranscriptBuffering

    public init(
        coordinator: AppCoordinator,
        audioService: AudioEngineServicing,
        asrService: LocalASRServicing,
        networkMonitor: NetworkMonitoring,
        permissionService: PermissionServicing,
        translateService: TranslateServicing,
        overlayRenderer: OverlayRendering,
        settingsStore: SettingsStoring,
        transcriptBuffer: TranscriptBuffering
    ) {
        self.coordinator = coordinator
        self.audioService = audioService
        self.asrService = asrService
        self.networkMonitor = networkMonitor
        self.permissionService = permissionService
        self.translateService = translateService
        self.overlayRenderer = overlayRenderer
        self.settingsStore = settingsStore
        self.transcriptBuffer = transcriptBuffer
    }
}

public enum SpeechflowBootstrap {
    public static func makeDefaultContainer() -> SpeechflowContainer {
        makeLiveContainer()
    }

    public static func makeLiveContainer() -> SpeechflowContainer {
        let settingsStore = InMemorySettingsStore()
        let settings = settingsStore.load()

        let audioService = SystemAudioEngineService()
        let asrService = SpeechFrameworkASRService(
            audioService: audioService,
            localeIdentifier: settings.languagePair.sourceCode
        )
        let networkMonitor = StubNetworkMonitor()
        let permissionService = SystemPermissionService()
        let translateService = StubTranslateService()
        let overlayRenderer = StubOverlayRenderer()
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
            translateService: translateService,
            overlayRenderer: overlayRenderer,
            settingsStore: settingsStore,
            clock: SystemClock()
        )

        return SpeechflowContainer(
            coordinator: coordinator,
            audioService: audioService,
            asrService: asrService,
            networkMonitor: networkMonitor,
            permissionService: permissionService,
            translateService: translateService,
            overlayRenderer: overlayRenderer,
            settingsStore: settingsStore,
            transcriptBuffer: transcriptBuffer
        )
    }

    public static func makeStubContainer() -> SpeechflowContainer {
        let settingsStore = InMemorySettingsStore()
        let settings = settingsStore.load()

        let audioService = StubAudioEngineService()
        let asrService = StubASRService(
            localeIdentifier: settings.languagePair.sourceCode
        )
        let networkMonitor = StubNetworkMonitor()
        let permissionService = StubPermissionService()
        let translateService = StubTranslateService()
        let overlayRenderer = StubOverlayRenderer()
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
            translateService: translateService,
            overlayRenderer: overlayRenderer,
            settingsStore: settingsStore,
            clock: SystemClock()
        )

        return SpeechflowContainer(
            coordinator: coordinator,
            audioService: audioService,
            asrService: asrService,
            networkMonitor: networkMonitor,
            permissionService: permissionService,
            translateService: translateService,
            overlayRenderer: overlayRenderer,
            settingsStore: settingsStore,
            transcriptBuffer: transcriptBuffer
        )
    }
}
