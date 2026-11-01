import Foundation

/// Open, lossless string identifier. Values come from installed agents/providers at runtime, so these
/// are not closed enums (ADR-0006: store provider-native IDs losslessly, translate only for display).
/// The raw value is stored verbatim; only empty or whitespace-only strings are rejected.
public protocol OpenStringIdentifier: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible, CodingKeyRepresentable
where RawValue == String, StringLiteralType == String {
    init?(rawValue: String)
}

extension OpenStringIdentifier {
    public init(stringLiteral value: String) {
        guard let identifier = Self(rawValue: value) else {
            preconditionFailure("Empty identifier literal for \(Self.self)")
        }
        self = identifier
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var codingKey: any CodingKey { OpenIdentifierCodingKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    static func isValidRawValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct OpenIdentifierCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Coding agent provider (Codex, Claude Code, later Cursor, Gemini CLI, ...).
public struct ProviderID: OpenStringIdentifier {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.isValidRawValue(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let codex: ProviderID = "codex"
    public static let claudeCode: ProviderID = "claude-code"
}

/// Provider-native coding-agent model ID, stored verbatim.
public struct ModelID: OpenStringIdentifier {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.isValidRawValue(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// Reasoning/effort level as an execution resource, not a task-difficulty estimate (ADR-0006, J2a).
/// Unknown provider values are kept losslessly and displayed with their raw ID.
public struct EffortLevel: OpenStringIdentifier {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.isValidRawValue(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Provider/model default: no effort parameter is passed to the agent.
    public static let auto: EffortLevel = "auto"
    public static let low: EffortLevel = "low"
    public static let medium: EffortLevel = "medium"
    public static let high: EffortLevel = "high"
    public static let xhigh: EffortLevel = "xhigh"
    public static let max: EffortLevel = "max"

    public static let knownLevels: [EffortLevel] = [.auto, .low, .medium, .high, .xhigh, .max]

    public var isKnown: Bool { Self.knownLevels.contains(self) }
    public var isAuto: Bool { self == .auto }

    public var germanDisplayName: String {
        switch self {
        case .auto: String(localized: "Automatisch", bundle: .module)
        case .low: String(localized: "Niedrig", bundle: .module)
        case .medium: String(localized: "Mittel", bundle: .module)
        case .high: String(localized: "Hoch", bundle: .module)
        case .xhigh: String(localized: "Extra hoch", bundle: .module)
        case .max: String(localized: "Maximum", bundle: .module)
        default: rawValue
        }
    }
}

/// Model choice at one configuration level. `providerDefault` lets the agent pick its own default model
/// (nothing is passed). Kept separate from `ModelID` so a provider model literally named "auto" or
/// "default" is never confused with the provider default.
public enum ModelSelection: Hashable, Sendable, Codable {
    case providerDefault
    case model(ModelID)

    public var modelID: ModelID? {
        if case let .model(id) = self { return id }
        return nil
    }

    public var germanDisplayName: String {
        switch self {
        case .providerDefault: String(localized: "Anbieterstandard", bundle: .module)
        case let .model(id): id.rawValue
        }
    }
}

/// Text-AI / transcription provider (spec H3, I). Independent from coding agents (ADR-0006).
public struct AIProviderID: OpenStringIdentifier {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.isValidRawValue(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let openAI: AIProviderID = "openai"
    public static let anthropic: AIProviderID = "anthropic"
    public static let gemini: AIProviderID = "gemini"
    public static let appleOnDevice: AIProviderID = "apple"
}

/// Model ID for text AI / transcription, separate from coding-agent `ModelID` (ADR-0006).
public struct AIModelID: OpenStringIdentifier {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.isValidRawValue(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// Stable repository identity derived by the Mac from Git/local metadata, not from name or path (spec E1).
public struct RepositoryIdentity: OpenStringIdentifier {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.isValidRawValue(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}
