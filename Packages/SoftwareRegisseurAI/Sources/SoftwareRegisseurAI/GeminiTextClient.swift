import Foundation
import SoftwareRegisseurSecrets

/// Google Gemini client on `generateContent` (research §2.3 proposal: stable fields for v1;
/// the Interactions API is still to be evaluated). The key travels only in the
/// `x-goog-api-key` header, never in the URL (research §2.1).
public struct GeminiTextClient: TextAIProvider {
    public let providerID: AIProviderID = .gemini
    public var apiKey: SecretValue
    public var baseURL: URL
    public var configuration: AIClientConfiguration
    private let http: any HTTPClient

    public init(
        apiKey: SecretValue,
        http: any HTTPClient = URLSessionHTTPClient(),
        configuration: AIClientConfiguration = AIClientConfiguration(),
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    ) {
        self.apiKey = apiKey.trimmed()
        self.http = http
        self.configuration = configuration
        self.baseURL = baseURL
    }

    var headers: [String: String] {
        ["x-goog-api-key": apiKey.revealedValue()]
    }

    private func perform(_ request: URLRequest) async throws -> HTTPResponse {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return try await configuration.retryPolicy.run { [http] in
            let response = try await http.send(request)
            guard response.isSuccess else { throw ProviderErrorMapper.gemini(response, now: Date()) }
            return response
        }
    }

    // MARK: Models

    /// All models; use `AIModelInfo.capabilities.textGeneration == .supported` to filter
    /// models offering `generateContent`.
    public func listModels() async throws -> [AIModelInfo] {
        var models: [AIModelInfo] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await fetchModelPage(query: query)
            models += (page.models ?? []).map { configuration.capabilityTable.apply(to: Self.modelInfo(from: $0)) }
            pageToken = (page.nextPageToken?.isEmpty == false) ? page.nextPageToken : nil
            pages += 1
        } while pageToken != nil && pages < 50
        return models
    }

    public func validateAPIKey() async throws -> KeyValidationResult {
        do {
            _ = try await fetchModelPage(query: [URLQueryItem(name: "pageSize", value: "1")])
            return .valid
        } catch AIProviderError.invalidAPIKey {
            return .invalid
        }
    }

    private func fetchModelPage(query: [URLQueryItem]) async throws -> GeminiModelPage {
        let url = try HTTPRequestBuilder.url(baseURL, path: "/models", query: query)
        let request = try HTTPRequestBuilder.jsonRequest(
            url: url, method: "GET", headers: headers, body: nil, timeout: configuration.timeout
        )
        return try ResponseDecoding.decode(GeminiModelPage.self, from: try await perform(request).body)
    }

    static func modelID(fromName name: String) -> String {
        name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
    }

    static func modelInfo(from model: GeminiModelPage.Model) -> AIModelInfo {
        let methods = model.supportedGenerationMethods
        return AIModelInfo(
            id: modelID(fromName: model.name),
            provider: .gemini,
            displayName: model.displayName,
            capabilities: AIModelCapabilities(
                textGeneration: methods.map { CapabilitySupport($0.contains("generateContent")) } ?? .unknown,
                // The model resource carries no structured-output flag.
                structuredOutput: .unknown,
                audioTranscription: .unknown,
                thinking: CapabilitySupport(model.thinking),
                imageInput: .unknown
            ),
            lifecycle: .unknown,
            inputTokenLimit: model.inputTokenLimit,
            outputTokenLimit: model.outputTokenLimit
        )
    }

    // MARK: Generation

    public func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        let modelID = Self.modelID(fromName: request.model)
        let path = "/models/\(HTTPRequestBuilder.pathSegment(modelID)):generateContent"
        let url = try HTTPRequestBuilder.url(baseURL, path: path)
        let urlRequest = try HTTPRequestBuilder.jsonRequest(
            url: url, method: "POST", headers: headers, body: Self.body(for: request), timeout: configuration.timeout
        )
        return try Self.parse(try await perform(urlRequest), model: modelID)
    }

    static func body(for request: TextGenerationRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "contents": .array(request.messages.map { message in
                [
                    "role": .string(message.role == .user ? "user" : "model"),
                    "parts": [["text": .string(message.content)]],
                ]
            }),
        ]
        if let system = request.systemPrompt {
            body["systemInstruction"] = ["parts": [["text": .string(system)]]]
        }
        var generationConfig: [String: JSONValue] = ["maxOutputTokens": .integer(request.maxOutputTokens)]
        if let format = request.structuredOutput {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseJsonSchema"] = format.schema
        }
        body["generationConfig"] = .object(generationConfig)
        return .object(body)
    }

    static func parse(_ response: HTTPResponse, model: String) throws -> TextGenerationResult {
        let json: JSONValue
        do { json = try JSONValue.parse(response.body) } catch {
            throw AIProviderError.invalidResponse(String(localized: "Antwort konnte nicht gelesen werden", bundle: .module))
        }
        let candidate = json["candidates"]?[0]
        let text = (candidate?["content"]?["parts"]?.arrayValue ?? [])
            .filter { $0["thought"]?.boolValue != true }
            .compactMap { $0["text"]?.stringValue }
            .joined()

        let finish: FinishReason
        if let block = json["promptFeedback"]?["blockReason"]?.stringValue {
            finish = .refusal(block)
        } else {
            switch candidate?["finishReason"]?.stringValue {
            case "STOP", nil: finish = .completed
            case "MAX_TOKENS": finish = .maxTokens
            case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
                finish = .refusal(candidate?["finishReason"]?.stringValue)
            case let other?: finish = .other(other)
            }
        }

        let usage = json["usageMetadata"]
        let candidates = usage?["candidatesTokenCount"]?.intValue ?? 0
        let thoughts = usage?["thoughtsTokenCount"]?.intValue ?? 0
        return TextGenerationResult(
            provider: .gemini,
            model: json["modelVersion"]?.stringValue ?? model,
            text: text,
            finishReason: finish,
            usage: AIUsage(
                inputTokens: (usage?["promptTokenCount"]?.intValue ?? 0) + (usage?["toolUsePromptTokenCount"]?.intValue ?? 0),
                // Thinking tokens are reported separately from candidates but billed as output.
                outputTokens: candidates + thoughts,
                cachedInputTokens: usage?["cachedContentTokenCount"]?.intValue ?? 0,
                reasoningTokens: thoughts
            ),
            requestID: json["responseId"]?.stringValue
        )
    }
}

struct GeminiModelPage: Decodable {
    struct Model: Decodable {
        var name: String
        var displayName: String?
        var inputTokenLimit: Int?
        var outputTokenLimit: Int?
        var supportedGenerationMethods: [String]?
        var thinking: Bool?
    }

    var models: [Model]?
    var nextPageToken: String?
}
