import Foundation

/// Open provider identifier for transcription and text providers (spec C.9, I).
/// Not related to coding-agent providers (ADR-0005/0006).
public struct AIProviderID: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let openai: AIProviderID = "openai"
    public static let anthropic: AIProviderID = "anthropic"
    public static let gemini: AIProviderID = "gemini"

    public var description: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        default: return rawValue
        }
    }
}

/// Tri-state capability: providers that publish no capability data yield `.unknown`
/// (research §2.2: OpenAI lists no capabilities). Never treat `.unknown` as supported silently.
public enum CapabilitySupport: String, Sendable, Hashable, Codable {
    case supported
    case unsupported
    case unknown

    init(_ flag: Bool?) {
        switch flag {
        case .some(true): self = .supported
        case .some(false): self = .unsupported
        case .none: self = .unknown
        }
    }
}

public struct AIModelCapabilities: Sendable, Hashable, Codable {
    public var textGeneration: CapabilitySupport
    public var structuredOutput: CapabilitySupport
    public var audioTranscription: CapabilitySupport
    public var thinking: CapabilitySupport
    public var imageInput: CapabilitySupport
    /// Effort levels when the provider lists them (Anthropic); empty = not reported.
    public var effortLevels: [String]

    public init(
        textGeneration: CapabilitySupport = .unknown,
        structuredOutput: CapabilitySupport = .unknown,
        audioTranscription: CapabilitySupport = .unknown,
        thinking: CapabilitySupport = .unknown,
        imageInput: CapabilitySupport = .unknown,
        effortLevels: [String] = []
    ) {
        self.textGeneration = textGeneration
        self.structuredOutput = structuredOutput
        self.audioTranscription = audioTranscription
        self.thinking = thinking
        self.imageInput = imageInput
        self.effortLevels = effortLevels
    }

    public static let unknown = AIModelCapabilities()

    /// Fills `.unknown` fields from `other` (used for the local capability table).
    public func merging(knownFrom other: AIModelCapabilities) -> AIModelCapabilities {
        func pick(_ own: CapabilitySupport, _ fallback: CapabilitySupport) -> CapabilitySupport {
            own == .unknown ? fallback : own
        }
        return AIModelCapabilities(
            textGeneration: pick(textGeneration, other.textGeneration),
            structuredOutput: pick(structuredOutput, other.structuredOutput),
            audioTranscription: pick(audioTranscription, other.audioTranscription),
            thinking: pick(thinking, other.thinking),
            imageInput: pick(imageInput, other.imageInput),
            effortLevels: effortLevels.isEmpty ? other.effortLevels : effortLevels
        )
    }
}

public enum AIModelLifecycle: String, Sendable, Hashable, Codable {
    case active
    case deprecated
    case retired
    case unknown
}

/// A model as returned by a provider's model-list endpoint (loaded dynamically, spec H3/I).
public struct AIModelInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var provider: AIProviderID
    public var displayName: String
    public var capabilities: AIModelCapabilities
    public var lifecycle: AIModelLifecycle
    /// Announced shutdown / retirement date if the provider reports one.
    public var shutdownDate: Date?
    public var inputTokenLimit: Int?
    public var outputTokenLimit: Int?
    public var createdAt: Date?

    public init(
        id: String,
        provider: AIProviderID,
        displayName: String? = nil,
        capabilities: AIModelCapabilities = .unknown,
        lifecycle: AIModelLifecycle = .unknown,
        shutdownDate: Date? = nil,
        inputTokenLimit: Int? = nil,
        outputTokenLimit: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName ?? id
        self.capabilities = capabilities
        self.lifecycle = lifecycle
        self.shutdownDate = shutdownDate
        self.inputTokenLimit = inputTokenLimit
        self.outputTokenLimit = outputTokenLimit
        self.createdAt = createdAt
    }
}

/// User-maintained capabilities for providers that do not publish them (research §2.2, OpenAI).
/// Empty by default; entries only fill `.unknown` fields and never override provider data.
public struct LocalCapabilityTable: Sendable, Hashable, Codable {
    public var entries: [String: AIModelCapabilities]

    public init(entries: [String: AIModelCapabilities] = [:]) {
        self.entries = entries
    }

    public func apply(to model: AIModelInfo) -> AIModelInfo {
        guard let local = entries[model.id] else { return model }
        var copy = model
        copy.capabilities = model.capabilities.merging(knownFrom: local)
        return copy
    }
}

public enum KeyValidationResult: Sendable, Equatable {
    case valid
    /// Key works, but something the feature needs is missing (e.g. `gpt-transcribe` not listed).
    case validWithWarning(String)
    case invalid
}
