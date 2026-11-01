import Foundation

/// OpenAI Speech-to-Text via `POST /v1/audio/transcriptions` (research §1, spec H2 B).
public struct OpenAITranscriptionClient: TranscriptionProvider {
    /// Recommended, non-deprecated model (research §1). Still validated against `GET /v1/models`.
    public static let defaultModel = "gpt-transcribe"
    /// "Files can be up to 25 MB." Decimal megabytes are used as the conservative reading.
    public static let uploadLimitBytes = 25_000_000

    public let providerID: AIProviderID = .openai
    public let maxUploadBytes: Int = OpenAITranscriptionClient.uploadLimitBytes
    public let supportedFormats: Set<AudioFormat> = Set(AudioFormat.allCases)

    public var connection: OpenAIConnection
    public var configuration: AIClientConfiguration
    private let http: any HTTPClient
    private let boundary: @Sendable () -> String

    public init(
        connection: OpenAIConnection,
        http: any HTTPClient = URLSessionHTTPClient(),
        configuration: AIClientConfiguration = AIClientConfiguration(timeout: 300),
        boundary: @escaping @Sendable () -> String = { "SoftwareRegisseur-\(UUID().uuidString)" }
    ) {
        self.connection = connection
        self.http = http
        self.configuration = configuration
        self.boundary = boundary
    }

    public func listModels() async throws -> [AIModelInfo] {
        try await connection.listModels(http: http, configuration: configuration)
    }

    /// Valid key alone is not enough: warn if the default model is not listed for this key
    /// (research §2.6: project-scoped keys may lack access).
    public func validateAPIKey() async throws -> KeyValidationResult {
        do {
            let models = try await listModels()
            if !models.contains(where: { $0.id == Self.defaultModel }) {
                return .validWithWarning(String(localized: "Das Modell „\(Self.defaultModel)“ ist für diesen Schlüssel nicht gelistet.", bundle: .module))
            }
            return .valid
        } catch AIProviderError.invalidAPIKey {
            return .invalid
        }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let urlRequest = try makeURLRequest(for: request)
        let response = try await configuration.retryPolicy.run { [connection, http] in
            try await connection.perform(urlRequest, http: http, now: Date())
        }
        return try Self.parse(response, model: request.model)
    }

    /// Validates limits locally and builds the multipart request. Exposed for tests.
    func makeURLRequest(for request: TranscriptionRequest) throws -> URLRequest {
        guard supportedFormats.contains(request.audio.format) else {
            throw AIProviderError.unsupportedAudioFormat(request.audio.format.rawValue)
        }
        let size = try request.audio.byteCount()
        guard size <= maxUploadBytes else {
            throw AIProviderError.fileTooLarge(bytes: size, limit: maxUploadBytes)
        }
        let keywords = try Self.validatedKeywords(request.keywords)

        var form = MultipartFormData(boundary: boundary())
        form.addField(name: "model", value: request.model)
        form.addField(name: "response_format", value: "json")
        if let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            form.addField(name: "prompt", value: prompt)
        }
        for keyword in keywords {
            form.addField(name: "keywords[]", value: keyword)
        }
        // `languages` replaces `language`; never send both (research §1).
        for language in request.languages where !language.isEmpty {
            form.addField(name: "languages[]", value: language)
        }
        form.addFile(
            name: "file", fileName: request.audio.fileName, mimeType: request.audio.format.mimeType,
            data: try request.audio.loadData()
        )

        let url = try HTTPRequestBuilder.url(connection.baseURL, path: "/audio/transcriptions")
        var urlRequest = URLRequest(url: url, timeoutInterval: configuration.timeout)
        urlRequest.httpMethod = "POST"
        for (name, value) in connection.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.finalized()
        return urlRequest
    }

    /// Keywords containing `<`, `>`, CR or LF make OpenAI reject the whole request (research §1),
    /// so they are refused locally with a precise error instead of silently dropped.
    static func validatedKeywords(_ keywords: [String]) throws -> [String] {
        try keywords.compactMap { raw in
            let keyword = raw.trimmingCharacters(in: .whitespaces)
            if keyword.isEmpty { return nil }
            if keyword.contains(where: { $0 == "<" || $0 == ">" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) {
                throw AIProviderError.invalidTranscriptionHint(keyword)
            }
            return keyword
        }
    }

    static func parse(_ response: HTTPResponse, model: String) throws -> TranscriptionResult {
        let json: JSONValue
        do { json = try JSONValue.parse(response.body) } catch {
            throw AIProviderError.invalidResponse(String(localized: "Antwort konnte nicht gelesen werden", bundle: .module))
        }
        guard let text = json["text"]?.stringValue else {
            throw AIProviderError.invalidResponse("Kein Transkript in der Antwort")
        }
        var usage = AIUsage()
        if let raw = json["usage"] {
            switch raw["type"]?.stringValue {
            case "duration":
                usage.audioSeconds = raw["seconds"]?.doubleValue
            default:
                usage.inputTokens = raw["input_tokens"]?.intValue ?? 0
                usage.outputTokens = raw["output_tokens"]?.intValue ?? 0
            }
        }
        let languages = (json["languages"]?.arrayValue ?? []).compactMap { entry in
            entry.stringValue ?? entry["language"]?.stringValue ?? entry["code"]?.stringValue
        }
        return TranscriptionResult(
            provider: .openai, model: model, text: text, detectedLanguages: languages, usage: usage
        )
    }
}

struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(fileName))\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
