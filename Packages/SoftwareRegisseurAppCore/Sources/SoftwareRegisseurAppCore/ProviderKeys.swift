import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurSecrets

/// Separate key settings for transcription and text drafting (spec I: „Unabhängige Einstellungen“).
public enum KeyPurpose: String, Hashable, Sendable, Codable, CaseIterable {
    case transcription
    case text

    /// Providers v1 supports for the purpose (H2 B: OpenAI; H3: OpenAI, Anthropic, Gemini).
    public var providers: [SoftwareRegisseurAI.AIProviderID] {
        switch self {
        case .transcription: [.openai]
        case .text: [.openai, .anthropic, .gemini]
        }
    }
}

public enum KeyStatus: Hashable, Sendable {
    case missing
    case stored(KeychainStorageMode)
    case unreadable(String)
}

/// Keychain access for BYOK keys. One item per provider and purpose; nothing is written to the database,
/// CloudKit, Markdown or logs (spec I, Q1).
public struct ProviderKeyService: Sendable {
    public let store: any KeychainStore

    public init(store: any KeychainStore) {
        self.store = store
    }

    public static func account(provider: SoftwareRegisseurAI.AIProviderID, purpose: KeyPurpose) -> String {
        "\(provider.rawValue).\(purpose.rawValue)"
    }

    public func status(provider: SoftwareRegisseurAI.AIProviderID, purpose: KeyPurpose) -> KeyStatus {
        let account = Self.account(provider: provider, purpose: purpose)
        do {
            guard let mode = try store.storageMode(account: account) else { return .missing }
            return .stored(mode)
        } catch let error as KeychainError {
            return .unreadable(error.userMessage)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func save(_ key: SecretValue, provider: SoftwareRegisseurAI.AIProviderID, purpose: KeyPurpose,
                     mode: KeychainStorageMode = .deviceOnly) throws {
        let trimmed = key.trimmed()
        guard !trimmed.isEmpty else { throw AIProviderError.missingAPIKey }
        try store.save(trimmed, account: Self.account(provider: provider, purpose: purpose), mode: mode)
    }

    public func delete(provider: SoftwareRegisseurAI.AIProviderID, purpose: KeyPurpose) throws {
        try store.delete(account: Self.account(provider: provider, purpose: purpose))
    }

    public func load(provider: SoftwareRegisseurAI.AIProviderID, purpose: KeyPurpose) throws -> SecretValue {
        try APIKeyLoader.load(from: store, account: Self.account(provider: provider, purpose: purpose))
    }

    /// Text provider client for the stored key.
    public func textProvider(_ provider: SoftwareRegisseurAI.AIProviderID) throws -> any TextAIProvider {
        let key = try load(provider: provider, purpose: .text)
        switch provider {
        case .openai: return OpenAITextClient(connection: OpenAIConnection(apiKey: key))
        case .anthropic: return AnthropicTextClient(apiKey: key)
        case .gemini: return GeminiTextClient(apiKey: key)
        default: throw AIProviderError.capabilityUnsupported(provider.rawValue)
        }
    }

    public func transcriptionProvider() throws -> any TranscriptionProvider {
        OpenAITranscriptionClient(connection: OpenAIConnection(apiKey: try load(provider: .openai, purpose: .transcription)))
    }
}
