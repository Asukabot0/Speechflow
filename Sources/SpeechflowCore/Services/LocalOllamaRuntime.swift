import Foundation

public protocol LocalModelRunning: AnyObject {
    func translate(
        prompt: TranslationPrompt,
        using descriptor: LocalModelDescriptor
    ) async throws -> String
    func unloadModel() async
}

enum LocalModelRuntimeError: LocalizedError {
    case invalidEndpoint(String)
    case serviceUnavailable(String)
    case invalidRequest
    case unexpectedStatus(Int, String)
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Ollama base URL is invalid: \(endpoint)"
        case .serviceUnavailable(let endpoint):
            return "Could not reach Ollama at \(endpoint). Ensure the local Ollama service is running."
        case .invalidRequest:
            return "Failed to encode the Ollama request."
        case .unexpectedStatus(let statusCode, let detail):
            if detail.isEmpty {
                return "Ollama returned HTTP \(statusCode)."
            }
            return "Ollama returned HTTP \(statusCode): \(detail)"
        case .invalidResponse:
            return "Ollama returned an invalid response payload."
        case .emptyResponse:
            return "Local model returned an empty translation."
        }
    }
}

public actor LocalOllamaRuntime: LocalModelRunning {
    private struct GenerateRequest: Encodable {
        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }

        let model: String
        let prompt: String
        let system: String
        let think: Bool
        let stream: Bool
        let options: Options
        let keepAlive: String?

        enum CodingKeys: String, CodingKey {
            case model
            case prompt
            case system
            case think
            case stream
            case options
            case keepAlive = "keep_alive"
        }
    }

    private struct GenerateResponse: Decodable {
        let response: String
    }

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let timeoutSeconds: TimeInterval
    private let keepAlive: String?
    private let maxTokens: Int
    private let thinkEnabled: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let configuration = URLSessionConfiguration.default
        let timeoutSeconds = TimeInterval(environment["SPEECHFLOW_OLLAMA_TIMEOUT_SECONDS"] ?? "")
            ?? 90
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds

        self.session = URLSession(configuration: configuration)
        self.timeoutSeconds = timeoutSeconds
        self.keepAlive = environment["SPEECHFLOW_OLLAMA_KEEP_ALIVE"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.maxTokens = Int(environment["SPEECHFLOW_OLLAMA_MAX_TOKENS"] ?? "") ?? 160
        self.thinkEnabled = Self.boolValue(
            from: environment["SPEECHFLOW_OLLAMA_THINK"],
            defaultValue: false
        )
    }

    public func translate(
        prompt: TranslationPrompt,
        using descriptor: LocalModelDescriptor
    ) async throws -> String {
        guard let endpointURL = URL(string: descriptor.endpoint) else {
            throw LocalModelRuntimeError.invalidEndpoint(descriptor.endpoint)
        }

        let requestURL = endpointURL.appendingPathComponent("api/generate")
        let payload = GenerateRequest(
            model: descriptor.modelName,
            prompt: prompt.userText,
            system: prompt.instructions,
            think: thinkEnabled,
            stream: false,
            options: .init(temperature: 0, numPredict: maxTokens),
            keepAlive: keepAlive
        )

        var request = URLRequest(url: requestURL, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            throw LocalModelRuntimeError.invalidRequest
        }

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError {
                throw error
            }
            throw LocalModelRuntimeError.serviceUnavailable(descriptor.endpoint)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalModelRuntimeError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = Self.trimmedDetail(from: responseData)
            throw LocalModelRuntimeError.unexpectedStatus(httpResponse.statusCode, detail)
        }

        let decoded: GenerateResponse
        do {
            decoded = try decoder.decode(GenerateResponse.self, from: responseData)
        } catch {
            throw LocalModelRuntimeError.invalidResponse
        }

        let normalized = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalModelRuntimeError.emptyResponse
        }
        return normalized
    }

    public func unloadModel() async {}

    private static func trimmedDetail(from data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        if
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? String
        {
            return error
        }

        let raw = String(decoding: data.prefix(240), as: UTF8.self)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boolValue(from rawValue: String?, defaultValue: Bool) -> Bool {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return defaultValue
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
