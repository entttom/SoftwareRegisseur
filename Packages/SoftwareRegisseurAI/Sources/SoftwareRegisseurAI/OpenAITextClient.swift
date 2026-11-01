import Foundation
import SoftwareRegisseurSecrets

/// Endpoint + auth for the OpenAI API (research §1, §2.1): `Authorization: Bearer`,
/// optional `OpenAI-Organization` / `OpenAI-Project`.
public struct OpenAIConnection: Sendable {
    public var apiKey: SecretValue
    public var baseURL: URL
    public var organizationID: String?
    public var projectID: String?

    public init(
        apiKey: SecretValue,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        organizationID: String? = nil,
        projectID: String? = nil
    ) {
        self.apiKey = apiKey.trimmed()
        self.baseURL = baseURL
        self.organizationID = organizationID
        self.projectID = projectID
    }

    var headers: [String: String] {
        var headers = ["Authorization": "Bearer \(apiKey.revealedValue())"]
        if let organizationID { headers["OpenAI-Organization"] = organizationID }
        if let projectID { headers["OpenAI-Project"] = projectID }
        return headers
    }

    func perform(_ request: URLRequest, http: any HTTPClient, now: Date) async throws -> HTTPResponse {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        let response = try await http.send(request)
        guard response.isSuccess else { throw ProviderErrorMapper.openAI(response, now: now) }
        return response
    }

    func listModels(http: any HTTPClient, configuration: AIClientConfiguration) async throws -> [AIModelInfo] {
        let url = try HTTPRequestBuilder.url(baseURL, path: "/models")
        let request = try HTTPRequestBuilder.jsonRequest(
            url: url, method: "GET", headers: headers, body: nil, timeout: configuration.timeout
        )
        let response = try await configuration.retryPolicy.run {
            try await perform(request, http: http, now: Date())
        }
        let list = try ResponseDecoding.decode(OpenAIModelList.self, from: response.body)
        // The models endpoint carries no capability fields (research §2.2); use the local table.
        return list.data.map { model in
            let info = AIModelInfo(
                id: model.id,
                provider: .openai,
                capabilities: .unknown,
                lifecycle: model.shutdownDate == nil ? .active : .deprecated,
                shutdownDate: model.shutdownDate,
                createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
            return configuration.capabilityTable.apply(to: info)
        }
    }
}

struct OpenAIModelList: Decodable {
    struct Model: Decodable {
        var id: String
        var created: Int?
        var shutdownDate: Date?

        enum CodingKeys: String, CodingKey {
            case id, created
            case shutdownDate = "shutdown_date"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            created = try container.decodeIfPresent(Int.self, forKey: .created)
            // Format of `shutdown_date` is not specified in the research (unix seconds or date
            // string); accept both, ignore anything else.
            switch try container.decodeIfPresent(JSONValue.self, forKey: .shutdownDate) {
            case .integer(let seconds): shutdownDate = Date(timeIntervalSince1970: TimeInterval(seconds))
            case .number(let seconds): shutdownDate = Date(timeIntervalSince1970: seconds)
            case .string(let string): shutdownDate = ResponseDecoding.iso8601(string)
            default: shutdownDate = nil
            }
        }
    }

    var data: [Model]
}

/// OpenAI text elaboration via the Responses API (`POST /v1/responses`, research §2.1/§2.3).
public struct OpenAITextClient: TextAIProvider {
    public let providerID: AIProviderID = .openai
    public var connection: OpenAIConnection
    public var configuration: AIClientConfiguration
    /// Responses are not stored server-side (data minimisation, spec H3 "zweckgebunden").
    public var storeResponses: Bool
    private let http: any HTTPClient

    public init(
        connection: OpenAIConnection,
        http: any HTTPClient = URLSessionHTTPClient(),
        configuration: AIClientConfiguration = AIClientConfiguration(),
        storeResponses: Bool = false
    ) {
        self.connection = connection
        self.http = http
        self.configuration = configuration
        self.storeResponses = storeResponses
    }

    public func listModels() async throws -> [AIModelInfo] {
        try await connection.listModels(http: http, configuration: configuration)
    }

    public func validateAPIKey() async throws -> KeyValidationResult {
        do {
            _ = try await connection.listModels(http: http, configuration: configuration)
            return .valid
        } catch AIProviderError.invalidAPIKey {
            return .invalid
        }
    }

    public func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        let url = try HTTPRequestBuilder.url(connection.baseURL, path: "/responses")
        let urlRequest = try HTTPRequestBuilder.jsonRequest(
            url: url, method: "POST", headers: connection.headers, body: Self.body(for: request, store: storeResponses),
            timeout: configuration.timeout
        )
        let response = try await configuration.retryPolicy.run { [connection, http] in
            try await connection.perform(urlRequest, http: http, now: Date())
        }
        return try Self.parse(response, model: request.model)
    }

    static func body(for request: TextGenerationRequest, store: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(request.messages.map { message in
                ["role": .string(message.role.rawValue), "content": .string(message.content)]
            }),
            "max_output_tokens": .integer(request.maxOutputTokens),
            "store": .bool(store),
        ]
        if let system = request.systemPrompt {
            body["instructions"] = .string(system)
        }
        if let format = request.structuredOutput {
            body["text"] = [
                "format": [
                    "type": "json_schema",
                    "name": .string(format.name),
                    "schema": format.schema,
                    "strict": true,
                ],
            ]
        }
        return .object(body)
    }

    static func parse(_ response: HTTPResponse, model: String) throws -> TextGenerationResult {
        let json: JSONValue
        do { json = try JSONValue.parse(response.body) } catch {
            throw AIProviderError.invalidResponse(String(localized: "Antwort konnte nicht gelesen werden", bundle: .module))
        }
        var text = ""
        var refusal: String?
        for item in json["output"]?.arrayValue ?? [] where item["type"]?.stringValue == "message" {
            for part in item["content"]?.arrayValue ?? [] {
                switch part["type"]?.stringValue {
                case "output_text": text += part["text"]?.stringValue ?? ""
                case "refusal": refusal = part["refusal"]?.stringValue ?? ""
                default: break
                }
            }
        }

        let finish: FinishReason
        if let refusal {
            finish = .refusal(refusal.isEmpty ? nil : refusal)
        } else {
            switch json["status"]?.stringValue {
            case "completed", nil: finish = .completed
            case "incomplete":
                let reason = json["incomplete_details"]?["reason"]?.stringValue
                finish = reason == "max_output_tokens" ? .maxTokens : .other(reason ?? "incomplete")
            case let other?: finish = .other(other)
            }
        }

        let usage = json["usage"]
        return TextGenerationResult(
            provider: .openai,
            model: json["model"]?.stringValue ?? model,
            text: text,
            finishReason: finish,
            usage: AIUsage(
                inputTokens: usage?["input_tokens"]?.intValue ?? 0,
                outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                cachedInputTokens: usage?["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
                cacheWriteInputTokens: usage?["input_tokens_details"]?["cache_write_tokens"]?.intValue ?? 0,
                reasoningTokens: usage?["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
            ),
            requestID: response.header("x-request-id")
        )
    }
}
