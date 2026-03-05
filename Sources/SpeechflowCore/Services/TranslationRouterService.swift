import Dispatch
import Foundation

public protocol ModelAssetManaging: AnyObject {
    func preferredLocalModelDescriptor() -> LocalModelDescriptor
    func installState(for descriptor: LocalModelDescriptor) -> LocalModelInstallState
}

public struct TranslationPrompt: Equatable, Sendable {
    public let instructions: String
    public let userText: String

    public init(instructions: String, userText: String) {
        self.instructions = instructions
        self.userText = userText
    }
}

public protocol TranslationPromptBuilding {
    func makePrompt(for sourceText: String, languagePair: LanguagePair) -> TranslationPrompt
}

public struct TranslationPromptBuilder: TranslationPromptBuilding, Sendable {
    public init() {}

    public func makePrompt(
        for sourceText: String,
        languagePair: LanguagePair
    ) -> TranslationPrompt {
        TranslationPrompt(
            instructions: """
            You are a translation engine for live subtitles.
            Translate from \(languagePair.sourceCode) to \(languagePair.targetCode).
            Keep the translation natural, spoken, and easy to read out loud.
            Prefer everyday phrasing over stiff or overly literal wording.
            Keep the line concise while preserving the original tone and intent.
            Return only the translation text.
            Do not explain, do not add notes, and do not include thinking or markup.
            """,
            userText: sourceText
        )
    }
}

public final class LocalModelAssetStore: ModelAssetManaging {
    private final class TagQueryState: @unchecked Sendable {
        var payload: Data?
        var responseError: Error?
        var responseStatusCode: Int?
    }

    private let environment: [String: String]
    private let session: URLSession
    private let cacheQueue = DispatchQueue(label: "Speechflow.LocalModelAssetStore")
    private var cachedInstalledModels: Set<String>?
    private var cacheTimestamp: Date?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: configuration)
    }

    public func preferredLocalModelDescriptor() -> LocalModelDescriptor {
        let modelName = resolvedModelName()
        let endpoint = resolvedBaseURL()
        let runtimePreference = resolvedRuntimePreference()

        if modelName == "qwen3.5:2b" {
            return LocalModelDescriptor.qwen3_5_2B(
                endpoint: endpoint,
                runtimePreference: runtimePreference
            )
        }

        if modelName == "qwen3.5:0.8b" {
            return LocalModelDescriptor.qwen3_5_0_8B(
                endpoint: endpoint,
                runtimePreference: runtimePreference
            )
        }

        let displayName = environmentValue(
            keys: ["SPEECHFLOW_LOCAL_MODEL_NAME"],
            fallback: modelName
        ) ?? modelName

        return LocalModelDescriptor(
            id: modelName,
            displayName: displayName,
            version: "custom",
            quantization: "ollama",
            modelName: modelName,
            endpoint: endpoint,
            estimatedSizeInBytes: 0,
            runtimePreference: runtimePreference
        )
    }

    public func installState(for descriptor: LocalModelDescriptor) -> LocalModelInstallState {
        guard let installedModels = installedModels() else {
            return .failed
        }
        return installedModels.contains(descriptor.modelName) ? .ready : .notInstalled
    }

    private func resolvedModelName() -> String {
        environmentValue(
            keys: ["SPEECHFLOW_OLLAMA_MODEL", "SPEECHFLOW_LOCAL_MODEL_ID"],
            fallback: "qwen3.5:0.8b"
        ) ?? "qwen3.5:0.8b"
    }

    private func resolvedRuntimePreference() -> LocalModelRuntimePreference {
        .ollama
    }

    private func resolvedBaseURL() -> String {
        environmentValue(
            keys: ["SPEECHFLOW_OLLAMA_BASE_URL"],
            fallback: "http://127.0.0.1:11434"
        ) ?? "http://127.0.0.1:11434"
    }

    private func environmentValue(keys: [String], fallback: String? = nil) -> String? {
        for key in keys {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    private func installedModels() -> Set<String>? {
        cacheQueue.sync {
            let now = Date()
            if let cachedInstalledModels,
               let cacheTimestamp,
               now.timeIntervalSince(cacheTimestamp) < 10 {
                return cachedInstalledModels
            }

            guard let fetchedModels = fetchInstalledModels() else {
                return nil
            }

            cachedInstalledModels = fetchedModels
            self.cacheTimestamp = now
            return fetchedModels
        }
    }

    private func fetchInstalledModels() -> Set<String>? {
        guard let tagsURL = URL(string: resolvedBaseURL())?
            .appendingPathComponent("api/tags") else {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let state = TagQueryState()

        let task = session.dataTask(with: tagsURL) { data, response, error in
            state.payload = data
            state.responseError = error
            state.responseStatusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }

        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + 2)
        if waitResult == .timedOut {
            task.cancel()
            return nil
        }

        if state.responseError != nil {
            return nil
        }

        guard state.responseStatusCode == 200, let payload = state.payload else {
            return nil
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else {
            return nil
        }

        return Set(models.compactMap { $0["name"] as? String })
    }
}

public final class LocalOllamaTranslationService: TranslateServicing, @unchecked Sendable {
    private struct Request: Sendable {
        let segment: TranscriptSegment
        let prompt: TranslationPrompt
        let descriptor: LocalModelDescriptor
        let generation: Int
    }

    private let stateQueue = DispatchQueue(label: "Speechflow.LocalOllamaTranslationService")

    private let modelAssetStore: ModelAssetManaging
    private let promptBuilder: TranslationPromptBuilding
    private let runtime: LocalModelRunning

    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var languagePair = LanguagePair()
    private var requestStream: AsyncStream<Request>
    private var requestContinuation: AsyncStream<Request>.Continuation
    private var workerTask: Task<Void, Never>?
    private var queueGeneration = 0

    public init(
        modelAssetStore: ModelAssetManaging = LocalModelAssetStore(),
        promptBuilder: TranslationPromptBuilding = TranslationPromptBuilder(),
        runtime: LocalModelRunning = LocalOllamaRuntime()
    ) {
        self.modelAssetStore = modelAssetStore
        self.promptBuilder = promptBuilder
        self.runtime = runtime

        let (stream, continuation) = AsyncStream.makeStream(of: Request.self)
        self.requestStream = stream
        self.requestContinuation = continuation
    }

    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        stateQueue.sync {
            self.eventSink = eventSink
            ensureWorkerLocked()
        }
    }

    public func updateLanguagePair(_ pair: LanguagePair) {
        stateQueue.sync {
            languagePair = pair
        }
    }

    public func updatePolicy(_ policy: TranslationPolicy) {
        _ = policy
    }

    public func updateNetworkQuality(_ quality: NetworkQuality) {
        _ = quality
    }

    public func enqueue(_ segment: TranscriptSegment) {
        let preflight = stateQueue.sync { () -> (PreflightAction, AsyncStream<Request>.Continuation) in
            (preflightRequest(for: segment), requestContinuation)
        }

        switch preflight.0 {
        case .enqueue(let request):
            preflight.1.yield(request)
        case .emitFailure(let eventSink, let message):
            eventSink(.translationFailed(segmentID: segment.id, message: message))
        case .drop:
            return
        }
    }

    public func cancelAll() {
        let workerToCancel = stateQueue.sync { () -> Task<Void, Never>? in
            let currentWorker = workerTask
            workerTask = nil
            queueGeneration += 1

            let (stream, continuation) = AsyncStream.makeStream(of: Request.self)
            requestStream = stream
            requestContinuation = continuation

            if eventSink != nil {
                ensureWorkerLocked()
            }

            return currentWorker
        }

        workerToCancel?.cancel()
    }

    private enum PreflightAction {
        case enqueue(Request)
        case emitFailure((SpeechflowEvent) -> Void, String)
        case drop
    }

    private func preflightRequest(for segment: TranscriptSegment) -> PreflightAction {
        guard let eventSink else {
            debugLog("[Translation][LocalOllama] enqueue ignored because eventSink is not set")
            return .drop
        }

        let descriptor = modelAssetStore.preferredLocalModelDescriptor()
        let installState = modelAssetStore.installState(for: descriptor)

        switch installState {
        case .notInstalled:
            return .emitFailure(
                eventSink,
                "Ollama model \(descriptor.modelName) is not installed. Run 'ollama pull \(descriptor.modelName)'."
            )
        case .failed:
            return .emitFailure(
                eventSink,
                "Ollama is unavailable at \(descriptor.endpoint) or model discovery failed."
            )
        case .ready:
            let prompt = promptBuilder.makePrompt(
                for: segment.sourceText,
                languagePair: languagePair
            )
            guard !prompt.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .emitFailure(eventSink, "Local Ollama prompt generation failed.")
            }

            debugLog(
                "[Translation][LocalOllama] queued model=\(descriptor.modelName) endpoint=\(descriptor.endpoint) segment=\(segment.id)"
            )
            return .enqueue(
                Request(
                    segment: segment,
                    prompt: prompt,
                    descriptor: descriptor,
                    generation: queueGeneration
                )
            )
        }
    }

    private func ensureWorkerLocked() {
        guard workerTask == nil else {
            return
        }

        let stream = requestStream
        workerTask = Task { [weak self] in
            await self?.processRequests(from: stream)
        }
    }

    private func processRequests(from stream: AsyncStream<Request>) async {
        for await request in stream {
            if Task.isCancelled {
                break
            }

            do {
                let rawText = try await runtime.translate(
                    prompt: request.prompt,
                    using: request.descriptor
                )
                let translatedText = TranslationOutputNormalizer.normalizeModelOutput(rawText)
                guard !translatedText.isEmpty else {
                    throw LocalModelRuntimeError.emptyResponse
                }

                let eventSink = stateQueue.sync { () -> ((SpeechflowEvent) -> Void)? in
                    guard request.generation == self.queueGeneration else {
                        return nil
                    }
                    return self.eventSink
                }
                eventSink?(
                    .translationFinished(
                        TranslationResult(
                            segmentID: request.segment.id,
                            text: translatedText,
                            backend: .localOllama,
                            isDegraded: false,
                            appliedPolish: false,
                            metadata: TranslationExecutionMetadata(
                                requestedBackendPreference: .localOllama,
                                resolvedBackend: .localOllama,
                                didFallback: false,
                                localModelID: request.descriptor.id
                            )
                        )
                    )
                )
            } catch is CancellationError {
                if Task.isCancelled {
                    break
                }
            } catch {
                let eventSink = stateQueue.sync { () -> ((SpeechflowEvent) -> Void)? in
                    guard request.generation == self.queueGeneration else {
                        return nil
                    }
                    return self.eventSink
                }
                eventSink?(
                    .translationFailed(
                        segmentID: request.segment.id,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

}

public final class TranslationRouterService: TranslateServicing {
    private enum ProviderRoute: Equatable {
        case systemProvider
        case localProvider
    }

    private struct PendingExecution {
        let requestedBackendPreference: TranslationBackendPreference
        var activeRoute: ProviderRoute
        var didFallback: Bool
        var fallbackReason: String?
        let startedAt: Date
    }

    private let stateQueue = DispatchQueue(label: "Speechflow.TranslationRouterService")
    private let systemProvider: TranslateServicing
    private let localProvider: TranslateServicing

    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var backendPreference: TranslationBackendPreference
    private var pendingSegments: [UUID: TranscriptSegment] = [:]
    private var pendingExecutions: [UUID: PendingExecution] = [:]

    public init(
        preferredBackend: TranslationBackendPreference = .localOllama,
        systemProvider: TranslateServicing,
        localProvider: TranslateServicing = LocalOllamaTranslationService()
    ) {
        self.backendPreference = preferredBackend
        self.systemProvider = systemProvider
        self.localProvider = localProvider
    }

    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        stateQueue.sync {
            self.eventSink = eventSink
        }

        systemProvider.start { [weak self] event in
            self?.handleProviderEvent(event, from: .systemProvider)
        }
        localProvider.start { [weak self] event in
            self?.handleProviderEvent(event, from: .localProvider)
        }
    }

    public func updateLanguagePair(_ pair: LanguagePair) {
        systemProvider.updateLanguagePair(pair)
        localProvider.updateLanguagePair(pair)
    }

    public func updatePolicy(_ policy: TranslationPolicy) {
        systemProvider.updatePolicy(policy)
        localProvider.updatePolicy(policy)
    }

    public func updateNetworkQuality(_ quality: NetworkQuality) {
        systemProvider.updateNetworkQuality(quality)
        localProvider.updateNetworkQuality(quality)
    }

    public func updateBackendPreference(_ backendPreference: TranslationBackendPreference) {
        stateQueue.sync {
            self.backendPreference = backendPreference
        }
    }

    public func enqueue(_ segment: TranscriptSegment) {
        let selectedService = stateQueue.sync { () -> TranslateServicing in
            let selectedRoute = selectedExecutionRoute(for: backendPreference)
            pendingSegments[segment.id] = segment
            pendingExecutions[segment.id] = PendingExecution(
                requestedBackendPreference: backendPreference,
                activeRoute: selectedRoute,
                didFallback: false,
                fallbackReason: nil,
                startedAt: Date()
            )
            return service(for: selectedRoute)
        }

        selectedService.enqueue(segment)
    }

    public func cancelAll() {
        stateQueue.sync {
            pendingSegments.removeAll()
            pendingExecutions.removeAll()
        }

        localProvider.cancelAll()
        systemProvider.cancelAll()
    }

    private func handleProviderEvent(_ event: SpeechflowEvent, from route: ProviderRoute) {
        switch event {
        case .translationFinished(let result):
            let completion = stateQueue.sync {
                finish(result: result, from: route)
            }

            guard let completion else {
                return
            }

            completion.eventSink(.translationFinished(completion.result))
        case .translationFailed(let segmentID, let message):
            let failureAction = stateQueue.sync {
                handleFailure(segmentID: segmentID, message: message, from: route)
            }

            switch failureAction {
            case .none:
                return
            case .forward(let eventSink, let segmentID, let message):
                eventSink(.translationFailed(segmentID: segmentID, message: message))
            case .fallback(let provider, let segment):
                provider.enqueue(segment)
            }
        default:
            let eventSink = stateQueue.sync {
                self.eventSink
            }
            eventSink?(event)
        }
    }

    private func selectedExecutionRoute(for preference: TranslationBackendPreference) -> ProviderRoute {
        switch preference {
        case .system:
            return .systemProvider
        case .localOllama:
            return .localProvider
        }
    }

    private func service(for route: ProviderRoute) -> TranslateServicing {
        switch route {
        case .localProvider:
            return localProvider
        case .systemProvider:
            return systemProvider
        }
    }

    private func finish(
        result: TranslationResult,
        from route: ProviderRoute
    ) -> (eventSink: (SpeechflowEvent) -> Void, result: TranslationResult)? {
        guard
            let pendingExecution = pendingExecutions[result.segmentID],
            pendingExecution.activeRoute == route,
            let eventSink
        else {
            return nil
        }

        pendingSegments.removeValue(forKey: result.segmentID)
        pendingExecutions.removeValue(forKey: result.segmentID)

        let latencyMilliseconds = max(
            0,
            Int(Date().timeIntervalSince(pendingExecution.startedAt) * 1000)
        )
        let metadata = TranslationExecutionMetadata(
            requestedBackendPreference: pendingExecution.requestedBackendPreference,
            resolvedBackend: result.backend,
            didFallback: pendingExecution.didFallback,
            fallbackReason: pendingExecution.fallbackReason,
            localModelID: result.metadata?.localModelID,
            latencyMilliseconds: latencyMilliseconds
        )
        let normalizedResult = TranslationResult(
            segmentID: result.segmentID,
            text: result.text,
            assistantText: result.assistantText,
            assistantQuestionSummary: result.assistantQuestionSummary,
            assistantStatus: result.assistantStatus,
            backend: result.backend,
            isDegraded: result.isDegraded || pendingExecution.didFallback,
            appliedPolish: result.backend == .remote ? result.appliedPolish : false,
            metadata: metadata
        )
        return (eventSink, normalizedResult)
    }

    private enum FailureAction {
        case none
        case forward((SpeechflowEvent) -> Void, UUID, String)
        case fallback(TranslateServicing, TranscriptSegment)
    }

    private func handleFailure(
        segmentID: UUID,
        message: String,
        from route: ProviderRoute
    ) -> FailureAction {
        guard
            var pendingExecution = pendingExecutions[segmentID],
            pendingExecution.activeRoute == route
        else {
            return .none
        }

        if route == .localProvider, !pendingExecution.didFallback, let segment = pendingSegments[segmentID] {
            pendingExecution.didFallback = true
            pendingExecution.fallbackReason = message
            pendingExecution.activeRoute = .systemProvider
            pendingExecutions[segmentID] = pendingExecution
            return .fallback(systemProvider, segment)
        }

        pendingSegments.removeValue(forKey: segmentID)
        pendingExecutions.removeValue(forKey: segmentID)

        guard let eventSink else {
            return .none
        }

        return .forward(eventSink, segmentID, message)
    }
}
