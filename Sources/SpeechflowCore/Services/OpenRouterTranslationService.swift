import Dispatch
import Foundation

private struct OpenRouterPromptContextTurn: Sendable {
    let sourceText: String
    let assistantText: String
}

private protocol OpenRouterContextPromptBuilding {
    func makePrompt(
        for sourceText: String,
        languagePair: LanguagePair,
        recentContext: [OpenRouterPromptContextTurn]
    ) -> TranslationPrompt
}

private enum OpenRouterPromptTemplateLoader {
    private static func environmentValue(
        keys: [String],
        environment: [String: String]
    ) -> String? {
        for key in keys {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        return nil
    }

    static func loadText(
        named name: String,
        overrideKeys: [String],
        environment: [String: String]
    ) -> String {
        if let overridePath = environmentValue(keys: overrideKeys, environment: environment),
           let text = try? String(contentsOfFile: overridePath, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bundle = Bundle.module
        let bundledURL =
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            ?? bundle.url(forResource: name, withExtension: "txt")
        guard
            let bundledURL,
            let text = try? String(contentsOf: bundledURL, encoding: .utf8)
        else {
            return ""
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OpenRouterAssistantPromptBuilder: TranslationPromptBuilding, OpenRouterContextPromptBuilding, Sendable {
    private let systemInstructions: String
    private let replyStyle: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.systemInstructions = OpenRouterPromptTemplateLoader.loadText(
            named: "OpenRouterAssistantSystemPrompt",
            overrideKeys: ["SPEECHFLOW_OPENROUTER_SYSTEM_PROMPT_FILE"],
            environment: environment
        )
        self.replyStyle = OpenRouterPromptTemplateLoader.loadText(
            named: "OpenRouterAssistantReplyStyle",
            overrideKeys: ["SPEECHFLOW_OPENROUTER_REPLY_STYLE_FILE"],
            environment: environment
        )
    }

    public func makePrompt(
        for sourceText: String,
        languagePair: LanguagePair
    ) -> TranslationPrompt {
        makePrompt(for: sourceText, languagePair: languagePair, recentContext: [])
    }

    fileprivate func makePrompt(
        for sourceText: String,
        languagePair: LanguagePair,
        recentContext: [OpenRouterPromptContextTurn]
    ) -> TranslationPrompt {
        let contextPayload = recentContext.map { turn in
            [
                "source_text": turn.sourceText,
                "assistant_text": turn.assistantText
            ]
        }
        let payload: [String: Any] = [
            "source_language": languagePair.sourceCode,
            "source_text": sourceText,
            "recent_context": contextPayload,
            "product_context": "",
            "reply_style": replyStyle
        ]

        let userText: String
        if
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        {
            userText = json
        } else {
            userText = sourceText
        }

        return TranslationPrompt(
            instructions: systemInstructions,
            userText: userText
        )
    }
}

public enum OpenRouterTranslationError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL(String)
    case requestEncodingFailed
    case invalidResponse
    case unexpectedStatus(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenRouter API key is not configured. Set SPEECHFLOW_OPENROUTER_API_KEY or OPENROUTER_API_KEY."
        case .invalidBaseURL(let value):
            return "OpenRouter base URL is invalid: \(value)"
        case .requestEncodingFailed:
            return "Failed to encode the OpenRouter request payload."
        case .invalidResponse:
            return "OpenRouter returned an invalid response payload."
        case .unexpectedStatus(let statusCode, let detail):
            return detail.isEmpty
                ? "OpenRouter returned HTTP \(statusCode)."
                : "OpenRouter returned HTTP \(statusCode): \(detail)"
        case .emptyResponse:
            return "OpenRouter returned an empty response."
        }
    }
}

public final class OpenRouterTranslationService: TranslateServicing, @unchecked Sendable {
    private struct ConversationTurn {
        let sequence: Int
        let sourceText: String
        var assistantText: String
    }

    private struct AssistantModelOutput {
        let text: String
        let questionSummary: String?
        let status: AssistantResponseStatus
    }

    private struct AssistantResponseEnvelope: Decodable {
        let hasQuestion: Bool?
        let questionSummary: String?
        let intent: String?
        let suggestedReplyZh: String?
        let suggestedReplyEn: String?
        let replyType: String?
        let confidence: Double?
        let needsHumanReview: Bool?

        enum CodingKeys: String, CodingKey {
            case hasQuestion = "has_question"
            case questionSummary = "question_summary"
            case intent
            case suggestedReplyZh = "suggested_reply_zh"
            case suggestedReplyEn = "suggested_reply_en"
            case replyType = "reply_type"
            case confidence
            case needsHumanReview = "needs_human_review"
        }
    }

    private struct EnqueueContext {
        let eventSink: ((SpeechflowEvent) -> Void)?
        let prompt: TranslationPrompt
        let networkQuality: NetworkQuality
    }

    private let stateQueue = DispatchQueue(label: "Speechflow.OpenRouterTranslationService")
    private let environment: [String: String]
    private let promptBuilder: TranslationPromptBuilding
    private let session: URLSession
    private let maxRecentContextTurns = 10
    private let maxStoredConversationTurns = 40

    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var languagePair = LanguagePair()
    private var policy = TranslationPolicy.defaultValue
    private var networkQuality = NetworkQuality.unknown
    private var apiKeyOverride: String?
    private var nextConversationSequence = 0
    private var completedConversationTurns: [ConversationTurn] = []
    private var pendingConversationTurns: [UUID: ConversationTurn] = [:]
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        promptBuilder: TranslationPromptBuilding? = nil
    ) {
        self.environment = environment
        self.promptBuilder = promptBuilder ?? OpenRouterAssistantPromptBuilder(environment: environment)

        let timeoutSeconds = TimeInterval(
            environment["SPEECHFLOW_OPENROUTER_TIMEOUT_SECONDS"] ?? ""
        ) ?? 30
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        cancelAll()
    }

    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        stateQueue.sync {
            self.eventSink = eventSink
        }
    }

    public func updateLanguagePair(_ pair: LanguagePair) {
        stateQueue.sync {
            languagePair = pair
        }
    }

    public func updatePolicy(_ policy: TranslationPolicy) {
        stateQueue.sync {
            self.policy = policy
        }
    }

    public func updateNetworkQuality(_ quality: NetworkQuality) {
        stateQueue.sync {
            networkQuality = quality
        }
    }

    public func updateOpenRouterAPIKey(_ apiKey: String) {
        stateQueue.sync {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKeyOverride = trimmed.isEmpty ? nil : trimmed
        }
    }

    public func enqueue(_ segment: TranscriptSegment) {
        let context = stateQueue.sync { () -> EnqueueContext in
            if let existingTask = inFlightTasks.removeValue(forKey: segment.id) {
                existingTask.cancel()
                pendingConversationTurns.removeValue(forKey: segment.id)
            }

            let recentContext = recentContextTurns(limit: maxRecentContextTurns)
            nextConversationSequence += 1
            pendingConversationTurns[segment.id] = ConversationTurn(
                sequence: nextConversationSequence,
                sourceText: segment.sourceText,
                assistantText: ""
            )

            let prompt: TranslationPrompt
            if let contextPromptBuilder = promptBuilder as? OpenRouterContextPromptBuilding {
                prompt = contextPromptBuilder.makePrompt(
                    for: segment.sourceText,
                    languagePair: languagePair,
                    recentContext: recentContext
                )
            } else {
                prompt = promptBuilder.makePrompt(
                    for: segment.sourceText,
                    languagePair: languagePair
                )
            }

            return EnqueueContext(
                eventSink: eventSink,
                prompt: prompt,
                networkQuality: networkQuality
            )
        }

        guard let eventSink = context.eventSink else {
            discardPendingConversationTurn(for: segment.id)
            debugLog("[Translation][OpenRouter] enqueue ignored because eventSink is not set")
            return
        }

        if context.networkQuality == .offline {
            completeConversationTurn(
                for: segment.id,
                assistantText: nil
            )
            eventSink(
                .translationFinished(
                    TranslationResult(
                        segmentID: segment.id,
                        text: nil,
                        assistantText: nil,
                        assistantStatus: .unavailable,
                        backend: .remote,
                        isDegraded: true,
                        appliedPolish: false
                    )
                )
            )
            return
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let assistantOutput = try await self.translate(prompt: context.prompt)
                guard !Task.isCancelled else {
                    return
                }

                self.completeConversationTurn(
                    for: segment.id,
                    assistantText: assistantOutput.text
                )

                let result = TranslationResult(
                    segmentID: segment.id,
                    text: nil,
                    assistantText: assistantOutput.text,
                    assistantQuestionSummary: assistantOutput.questionSummary,
                    assistantStatus: assistantOutput.status,
                    backend: .remote,
                    isDegraded: context.networkQuality == .constrained,
                    appliedPolish: false
                )

                let sink = self.finishTask(for: segment.id)
                sink?(.translationFinished(result))
            } catch is CancellationError {
                self.discardPendingConversationTurn(for: segment.id)
                _ = self.finishTask(for: segment.id)
            } catch {
                guard !Task.isCancelled else {
                    self.discardPendingConversationTurn(for: segment.id)
                    _ = self.finishTask(for: segment.id)
                    return
                }

                self.completeConversationTurn(
                    for: segment.id,
                    assistantText: nil
                )

                let sink = self.finishTask(for: segment.id)
                sink?(
                    .translationFinished(
                        TranslationResult(
                            segmentID: segment.id,
                            text: nil,
                            assistantText: nil,
                            assistantStatus: .unavailable,
                            backend: .remote,
                            isDegraded: true,
                            appliedPolish: false
                        )
                    )
                )
            }
        }

        stateQueue.sync {
            inFlightTasks[segment.id] = task
        }
    }

    public func cancelAll() {
        let tasks = stateQueue.sync { () -> [Task<Void, Never>] in
            let currentTasks = Array(inFlightTasks.values)
            inFlightTasks.removeAll()
            pendingConversationTurns.removeAll()
            return currentTasks
        }

        tasks.forEach { $0.cancel() }
    }

    private func finishTask(for segmentID: UUID) -> ((SpeechflowEvent) -> Void)? {
        stateQueue.sync {
            inFlightTasks.removeValue(forKey: segmentID)
            return eventSink
        }
    }

    private func recentContextTurns(limit: Int) -> [OpenRouterPromptContextTurn] {
        let pendingTurns = Array(pendingConversationTurns.values)
        let orderedTurns = (completedConversationTurns + pendingTurns)
            .sorted { lhs, rhs in
                lhs.sequence < rhs.sequence
            }
            .suffix(limit)

        return orderedTurns.map { turn in
            OpenRouterPromptContextTurn(
                sourceText: turn.sourceText,
                assistantText: turn.assistantText
            )
        }
    }

    private func completeConversationTurn(
        for segmentID: UUID,
        assistantText: String?
    ) {
        stateQueue.sync {
            guard var turn = pendingConversationTurns.removeValue(forKey: segmentID) else {
                return
            }

            turn.assistantText = assistantText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completedConversationTurns.append(turn)
            if completedConversationTurns.count > maxStoredConversationTurns {
                completedConversationTurns.removeFirst(
                    completedConversationTurns.count - maxStoredConversationTurns
                )
            }
        }
    }

    private func discardPendingConversationTurn(for segmentID: UUID) {
        _ = stateQueue.sync {
            pendingConversationTurns.removeValue(forKey: segmentID)
        }
    }

    private func translate(prompt: TranslationPrompt) async throws -> AssistantModelOutput {
        let request = try makeRequest(for: prompt)
        let (payload, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterTranslationError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw OpenRouterTranslationError.unexpectedStatus(
                httpResponse.statusCode,
                errorDetail(from: payload)
            )
        }

        let text = try extractContent(from: payload)
        if let response = decodeAssistantResponse(from: text) {
            return formatAssistantResponse(response)
        }

        let normalized = TranslationOutputNormalizer.normalizeModelOutput(text)
        guard !normalized.isEmpty else {
            throw OpenRouterTranslationError.emptyResponse
        }

        return AssistantModelOutput(
            text: normalized,
            questionSummary: nil,
            status: .answered
        )
    }

    private func makeRequest(for prompt: TranslationPrompt) throws -> URLRequest {
        let baseURLString = environmentValue(
            keys: ["SPEECHFLOW_OPENROUTER_BASE_URL", "OPENROUTER_BASE_URL"],
            fallback: "https://openrouter.ai/api/v1"
        ) ?? "https://openrouter.ai/api/v1"

        guard let baseURL = URL(string: baseURLString) else {
            throw OpenRouterTranslationError.invalidBaseURL(baseURLString)
        }

        guard let apiKey = currentAPIKey() else {
            throw OpenRouterTranslationError.missingAPIKey
        }

        let requestURL = baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        let payload: [String: Any] = [
            "model": environmentValue(
                keys: ["SPEECHFLOW_OPENROUTER_MODEL", "OPENROUTER_MODEL"],
                fallback: "openai/gpt-oss-120b:nitro"
            ) ?? "openai/gpt-oss-120b:nitro",
            "messages": [
                [
                    "role": "system",
                    "content": prompt.instructions
                ],
                [
                    "role": "user",
                    "content": prompt.userText
                ]
            ],
            "stream": false,
            "reasoning": [
                "effort": environmentValue(
                    keys: [
                        "SPEECHFLOW_OPENROUTER_REASONING_EFFORT",
                        "OPENROUTER_REASONING_EFFORT"
                    ],
                    fallback: "medium"
                ) ?? "medium"
            ]
        ]

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw OpenRouterTranslationError.requestEncodingFailed
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw OpenRouterTranslationError.requestEncodingFailed
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let appName = environmentValue(
            keys: ["SPEECHFLOW_OPENROUTER_APP_NAME", "OPENROUTER_APP_NAME"],
            fallback: "Speechflow"
        ) {
            request.setValue(appName, forHTTPHeaderField: "X-Title")
        }

        if let referer = environmentValue(
            keys: ["SPEECHFLOW_OPENROUTER_HTTP_REFERER", "OPENROUTER_SITE_URL"]
        ) {
            request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }

        return request
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

    private func currentAPIKey() -> String? {
        let override = stateQueue.sync {
            apiKeyOverride
        }
        if let override, !override.isEmpty {
            return override
        }

        return environmentValue(
            keys: ["SPEECHFLOW_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"]
        )
    }

    private func errorDetail(from payload: Data) -> String {
        guard
            let raw = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return String(decoding: payload, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if
            let error = raw["error"] as? [String: Any],
            let message = error["message"] as? String {
            return message
        }

        if let message = raw["message"] as? String {
            return message
        }

        return String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractContent(from payload: Data) throws -> String {
        guard
            let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let choices = raw["choices"] as? [[String: Any]],
            let firstChoice = choices.first
        else {
            throw OpenRouterTranslationError.invalidResponse
        }

        if let message = firstChoice["message"] as? [String: Any] {
            return extractContentValue(message["content"])
        }

        if let text = firstChoice["text"] as? String {
            return text
        }

        throw OpenRouterTranslationError.invalidResponse
    }

    private func extractContentValue(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }

        guard let parts = value as? [[String: Any]] else {
            return ""
        }

        let extractedParts = parts.compactMap { part -> String? in
            if let text = part["text"] as? String {
                return text
            }
            if let value = part["content"] as? String {
                return value
            }
            return nil
        }

        return extractedParts.joined(separator: "\n")
    }

    private func formatAssistantResponse(_ response: AssistantResponseEnvelope) -> AssistantModelOutput {
        let suggestedReplyZh = TranslationOutputNormalizer.normalizeModelOutput(response.suggestedReplyZh ?? "")
        let suggestedReplyEn = TranslationOutputNormalizer.normalizeModelOutput(response.suggestedReplyEn ?? "")
        let questionSummary = TranslationOutputNormalizer.normalizeModelOutput(response.questionSummary ?? "")
        let replyType = response.replyType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let hasQuestion = response.hasQuestion ?? (!suggestedReplyZh.isEmpty || !suggestedReplyEn.isEmpty)

        guard hasQuestion, replyType != "none" else {
            return AssistantModelOutput(
                text: "",
                questionSummary: nil,
                status: .noQuestion
            )
        }

        var replyLines: [String] = []
        if !suggestedReplyZh.isEmpty {
            replyLines.append("答复: \(suggestedReplyZh)")
        }
        if !suggestedReplyEn.isEmpty {
            replyLines.append("EN: \(suggestedReplyEn)")
        }

        return AssistantModelOutput(
            text: replyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            questionSummary: questionSummary.isEmpty ? nil : questionSummary,
            status: .answered
        )
    }

    private func decodeAssistantResponse(from text: String) -> AssistantResponseEnvelope? {
        let candidates = jsonCandidates(from: text)
        let decoder = JSONDecoder()

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else {
                continue
            }

            if let decoded = try? decoder.decode(AssistantResponseEnvelope.self, from: data) {
                return decoded
            }
        }

        return nil
    }

    private func jsonCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var candidates: [String] = [trimmed]
        if trimmed.hasPrefix("```"), let fenceStart = trimmed.firstIndex(of: "\n") {
            let afterFence = trimmed.index(after: fenceStart)
            let inner = String(trimmed[afterFence...])
            if let closingRange = inner.range(of: "```", options: .backwards) {
                let fenced = String(inner[..<closingRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !fenced.isEmpty {
                    candidates.append(fenced)
                }
            }
        }

        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            let objectSlice = String(trimmed[firstBrace...lastBrace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !objectSlice.isEmpty {
                candidates.append(objectSlice)
            }
        }

        return Array(Set(candidates))
    }

}
