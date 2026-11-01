import Foundation

/// Text elaboration provider (spec C.9, H3). Strictly separate from coding agents:
/// nothing in this module can start, resume or instruct an agent.
public protocol TextAIProvider: Sendable {
    var providerID: AIProviderID { get }
    /// Loads models dynamically from the provider (spec I: no hard-wired model ids).
    func listModels() async throws -> [AIModelInfo]
    /// Cheap key check via the model-list endpoint (research §2.6); no generation tokens.
    func validateAPIKey() async throws -> KeyValidationResult
    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult
}

public struct AIMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: String) -> AIMessage { AIMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> AIMessage { AIMessage(role: .assistant, content: content) }
}

/// JSON-schema structured output request. The schema must follow the common subset
/// (research §2.3): all fields required, nullable via type unions, `additionalProperties: false`,
/// no length/number constraints.
public struct StructuredOutputFormat: Sendable, Hashable {
    public var name: String
    public var schema: JSONValue

    public init(name: String, schema: JSONValue) {
        self.name = name
        self.schema = schema
    }
}

public struct TextGenerationRequest: Sendable, Hashable {
    public var model: String
    public var systemPrompt: String?
    public var messages: [AIMessage]
    public var structuredOutput: StructuredOutputFormat?
    public var maxOutputTokens: Int

    public init(
        model: String,
        systemPrompt: String? = nil,
        messages: [AIMessage],
        structuredOutput: StructuredOutputFormat? = nil,
        maxOutputTokens: Int = 4096
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.structuredOutput = structuredOutput
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Normalised token usage. `inputTokens` includes cached input; `outputTokens` includes
/// reasoning/thinking tokens (both are billed as output); detail fields are informative.
public struct AIUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var reasoningTokens: Int
    /// Audio seconds for duration-billed transcription.
    public var audioSeconds: Double?

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        reasoningTokens: Int = 0,
        audioSeconds: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningTokens = reasoningTokens
        self.audioSeconds = audioSeconds
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public static let zero = AIUsage()

    public static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        let seconds: Double? = (lhs.audioSeconds == nil && rhs.audioSeconds == nil)
            ? nil : (lhs.audioSeconds ?? 0) + (rhs.audioSeconds ?? 0)
        return AIUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteInputTokens: lhs.cacheWriteInputTokens + rhs.cacheWriteInputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            audioSeconds: seconds
        )
    }
}

public enum FinishReason: Sendable, Hashable {
    case completed
    case maxTokens
    case refusal(String?)
    case other(String)
}

public struct TextGenerationResult: Sendable, Hashable {
    public var provider: AIProviderID
    public var model: String
    public var text: String
    public var finishReason: FinishReason
    public var usage: AIUsage
    /// Provider request id for diagnostics (never contains the key).
    public var requestID: String?

    public init(
        provider: AIProviderID,
        model: String,
        text: String,
        finishReason: FinishReason,
        usage: AIUsage,
        requestID: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.text = text
        self.finishReason = finishReason
        self.usage = usage
        self.requestID = requestID
    }

    /// Decodes structured output. Refusals and truncated output become dedicated errors
    /// (research §2.3: show refusal/abort as separate state; always validate locally).
    public func decodeStructured<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        switch finishReason {
        case .refusal(let detail):
            throw AIProviderError.refusal(detail)
        case .maxTokens:
            throw AIProviderError.incompleteOutput(nil)
        case .completed, .other:
            break
        }
        let cleaned = Self.stripCodeFence(text)
        guard let data = cleaned.data(using: .utf8), !cleaned.isEmpty else {
            throw AIProviderError.invalidResponse("Leere Antwort")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse("Strukturierte Antwort entspricht nicht dem Schema")
        }
    }

    static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if trimmed.hasSuffix("```") { trimmed = String(trimmed.dropLast(3)) }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Common connection settings shared by all provider clients.
public struct AIClientConfiguration: Sendable {
    public var timeout: TimeInterval
    public var retryPolicy: RetryPolicy
    public var capabilityTable: LocalCapabilityTable

    public init(
        timeout: TimeInterval = 60,
        retryPolicy: RetryPolicy = RetryPolicy(),
        capabilityTable: LocalCapabilityTable = LocalCapabilityTable()
    ) {
        self.timeout = timeout
        self.retryPolicy = retryPolicy
        self.capabilityTable = capabilityTable
    }
}

enum ResponseDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse(String(localized: "Antwort konnte nicht gelesen werden", bundle: .module))
        }
    }

    static func iso8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = RetryAfterParser.parseRFC3339(value) { return date }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: value)
    }
}
