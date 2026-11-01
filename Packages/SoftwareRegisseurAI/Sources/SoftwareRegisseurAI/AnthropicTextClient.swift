import Foundation
import SoftwareRegisseurSecrets

/// Anthropic Messages API client (research §2.1–§2.5).
///
/// - Always sends `anthropic-version` (reference calls it optional, overview mandatory → always send).
/// - Never sends `temperature`, `top_p` or `top_k`: version 2026-10-21 rejects them with 400.
public struct AnthropicTextClient: TextAIProvider {
    public enum AuthScheme: Sendable {
        /// `Authorization: Bearer <key>` (research §2.1, current form).
        case bearer
        /// `x-api-key: <key>` (legacy, still supported).
        case xAPIKey
    }

    public static let defaultAPIVersion = "2026-10-21"

    public let providerID: AIProviderID = .anthropic
    public var apiKey: SecretValue
    public var baseURL: URL
    public var apiVersion: String
    public var authScheme: AuthScheme
    public var configuration: AIClientConfiguration
    private let http: any HTTPClient

    public init(
        apiKey: SecretValue,
        http: any HTTPClient = URLSessionHTTPClient(),
        configuration: AIClientConfiguration = AIClientConfiguration(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = AnthropicTextClient.defaultAPIVersion,
        authScheme: AuthScheme = .bearer
    ) {
        self.apiKey = apiKey.trimmed()
        self.http = http
        self.configuration = configuration
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.authScheme = authScheme
    }

    var headers: [String: String] {
        var headers = ["anthropic-version": apiVersion]
        switch authScheme {
        case .bearer: headers["Authorization"] = "Bearer \(apiKey.revealedValue())"
        case .xAPIKey: headers["x-api-key"] = apiKey.revealedValue()
        }
        return headers
    }

    private func perform(_ request: URLRequest) async throws -> HTTPResponse {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return try await configuration.retryPolicy.run { [http] in
            let response = try await http.send(request)
            guard response.isSuccess else { throw ProviderErrorMapper.anthropic(response, now: Date()) }
            return response
        }
    }

    // MARK: Models

    public func listModels() async throws -> [AIModelInfo] {
        var models: [AIModelInfo] = []
        var afterID: String?
        var pages = 0
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            let page = try await fetchModelPage(query: query)
            models += page.data.map { configuration.capabilityTable.apply(to: Self.modelInfo(from: $0)) }
            afterID = page.hasMore == true ? page.lastID : nil
            pages += 1
        } while afterID != nil && pages < 50
        return models
    }

    public func validateAPIKey() async throws -> KeyValidationResult {
        do {
            _ = try await fetchModelPage(query: [URLQueryItem(name: "limit", value: "1")])
            return .valid
        } catch AIProviderError.invalidAPIKey {
            return .invalid
        }
    }

    private func fetchModelPage(query: [URLQueryItem]) async throws -> AnthropicModelPage {
        let url = try HTTPRequestBuilder.url(baseURL, path: "/v1/models", query: query)
        let request = try HTTPRequestBuilder.jsonRequest(
            url: url, method: "GET", headers: headers, body: nil, timeout: configuration.timeout
        )
        return try ResponseDecoding.decode(AnthropicModelPage.self, from: try await perform(request).body)
    }

    static func modelInfo(from model: AnthropicModelPage.Model) -> AIModelInfo {
        let capabilities = model.capabilities
        let lifecycle: AIModelLifecycle
        switch model.lifecycle {
        case "active": lifecycle = .active
        case "deprecated": lifecycle = .deprecated
        case "retired": lifecycle = .retired
        default: lifecycle = model.deprecatedAt == nil ? .unknown : .deprecated
        }
        return AIModelInfo(
            id: model.id,
            provider: .anthropic,
            displayName: model.displayName,
            capabilities: AIModelCapabilities(
                // Every listed Messages model generates text.
                textGeneration: .supported,
                structuredOutput: capabilitySupport(capabilities?["structured_outputs"]),
                audioTranscription: .unsupported,
                thinking: thinkingSupport(capabilities?["thinking"]),
                imageInput: capabilitySupport(capabilities?["image_input"]),
                effortLevels: effortLevels(capabilities?["effort"])
            ),
            lifecycle: lifecycle,
            shutdownDate: ResponseDecoding.iso8601(model.retiresAt),
            inputTokenLimit: model.maxInputTokens,
            outputTokenLimit: model.maxTokens,
            createdAt: ResponseDecoding.iso8601(model.createdAt)
        )
    }

    /// Capability entries are objects with `supported` (research §2.2); accept bare bools too.
    static func capabilitySupport(_ value: JSONValue?) -> CapabilitySupport {
        guard let value else { return .unknown }
        if let flag = value.boolValue { return CapabilitySupport(flag) }
        return CapabilitySupport(value["supported"]?.boolValue)
    }

    static func thinkingSupport(_ value: JSONValue?) -> CapabilitySupport {
        guard let value else { return .unknown }
        if let explicit = value["supported"]?.boolValue ?? value.boolValue { return CapabilitySupport(explicit) }
        if let types = value["types"]?.arrayValue { return types.isEmpty ? .unsupported : .supported }
        return .unknown
    }

    /// The exact shape of `capabilities.effort` is not fully documented; collect any level names found.
    static func effortLevels(_ value: JSONValue?) -> [String] {
        let known = ["low", "medium", "high", "xhigh", "max"]
        func collect(_ value: JSONValue) -> [String] {
            switch value {
            case .string(let level): return known.contains(level) ? [level] : []
            case .array(let items): return items.flatMap(collect)
            case .object(let object):
                let flagged = object.compactMap { key, value -> String? in
                    known.contains(key) && (value.boolValue == true || value["supported"]?.boolValue == true) ? key : nil
                }
                return flagged + object.filter { !known.contains($0.key) }.values.flatMap(collect)
            default: return []
            }
        }
        guard let value else { return [] }
        let found = Set(collect(value))
        return known.filter(found.contains)
    }

    // MARK: Generation

    public func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        let url = try HTTPRequestBuilder.url(baseURL, path: "/v1/messages")
        let urlRequest = try HTTPRequestBuilder.jsonRequest(
            url: url, method: "POST", headers: headers, body: Self.body(for: request), timeout: configuration.timeout
        )
        return try Self.parse(try await perform(urlRequest), model: request.model)
    }

    static func body(for request: TextGenerationRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .integer(request.maxOutputTokens),
            "messages": .array(request.messages.map { message in
                ["role": .string(message.role.rawValue), "content": .string(message.content)]
            }),
        ]
        if let system = request.systemPrompt {
            body["system"] = .string(system)
        }
        if let format = request.structuredOutput {
            body["output_config"] = ["format": ["type": "json_schema", "schema": format.schema]]
        }
        return .object(body)
    }

    static func parse(_ response: HTTPResponse, model: String) throws -> TextGenerationResult {
        let json: JSONValue
        do { json = try JSONValue.parse(response.body) } catch {
            throw AIProviderError.invalidResponse(String(localized: "Antwort konnte nicht gelesen werden", bundle: .module))
        }
        let text = (json["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()

        let finish: FinishReason
        switch json["stop_reason"]?.stringValue {
        case "end_turn", "stop_sequence", nil: finish = .completed
        case "max_tokens", "model_context_window_exceeded": finish = .maxTokens
        case "refusal": finish = .refusal(nil)
        case let other?: finish = .other(other)
        }

        let usage = json["usage"]
        let uncachedInput = usage?["input_tokens"]?.intValue ?? 0
        let cacheRead = usage?["cache_read_input_tokens"]?.intValue ?? 0
        let cacheWrite = usage?["cache_creation_input_tokens"]?.intValue ?? 0
        return TextGenerationResult(
            provider: .anthropic,
            model: json["model"]?.stringValue ?? model,
            text: text,
            finishReason: finish,
            usage: AIUsage(
                // Anthropic reports cache reads/writes separately from `input_tokens`.
                inputTokens: uncachedInput + cacheRead + cacheWrite,
                outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                cachedInputTokens: cacheRead,
                cacheWriteInputTokens: cacheWrite,
                reasoningTokens: usage?["output_tokens_details"]?["thinking_tokens"]?.intValue
                    ?? usage?["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
            ),
            requestID: response.header("request-id") ?? json["id"]?.stringValue
        )
    }
}

struct AnthropicModelPage: Decodable {
    struct Model: Decodable {
        var id: String
        var displayName: String?
        var createdAt: String?
        var lifecycle: String?
        var deprecatedAt: String?
        var retiresAt: String?
        var maxInputTokens: Int?
        var maxTokens: Int?
        var capabilities: JSONValue?

        enum CodingKeys: String, CodingKey {
            case id, lifecycle, capabilities
            case displayName = "display_name"
            case createdAt = "created_at"
            case deprecatedAt = "deprecated_at"
            case retiresAt = "retires_at"
            case maxInputTokens = "max_input_tokens"
            case maxTokens = "max_tokens"
        }
    }

    var data: [Model]
    var hasMore: Bool?
    var lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}
