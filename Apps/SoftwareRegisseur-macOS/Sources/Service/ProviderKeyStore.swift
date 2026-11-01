import Foundation
import Observation
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurSecrets

/// BYOK-Schlüssel für die KI-Ausarbeitung am Mac (H4, I). Gespeichert im Schlüsselbund des Macs unter
/// Dienst `SoftwareRegisseur.ProviderKeys`, Konto `<anbieter>.text`, Zugriffsgruppe wie der Agent Service
/// (IPC-README). Schlüssel erscheinen nie in Datenbank, CloudKit, Markdown oder Logs.
@MainActor
@Observable
final class ProviderKeyStore {
    static let keychainService = "SoftwareRegisseur.ProviderKeys"
    static let providers: [SoftwareRegisseurAI.AIProviderID] = KeyPurpose.text.providers

    enum CheckState: Equatable {
        case unchecked
        case checking
        case valid
        case validWithWarning(String)
        case invalid
        case failed(String)
    }

    private(set) var statuses: [String: KeyStatus] = [:]
    private(set) var checks: [String: CheckState] = [:]
    let accessGroup: String?

    @ObservationIgnored private let service: ProviderKeyService

    init(accessGroup: String?, store: (any KeychainStore)? = nil) {
        self.accessGroup = accessGroup
        service = ProviderKeyService(store: store ?? SystemKeychainStore(configuration: .init(
            service: Self.keychainService, accessGroup: accessGroup)))
    }

    func refresh() {
        for provider in Self.providers {
            statuses[provider.rawValue] = service.status(provider: provider, purpose: .text)
        }
    }

    func status(_ provider: SoftwareRegisseurAI.AIProviderID) -> KeyStatus {
        statuses[provider.rawValue] ?? .missing
    }

    func check(_ provider: SoftwareRegisseurAI.AIProviderID) -> CheckState {
        checks[provider.rawValue] ?? .unchecked
    }

    /// Speichert gerätebezogen (Standard, I); gibt eine deutsche Fehlermeldung zurück.
    func save(_ key: String, for provider: SoftwareRegisseurAI.AIProviderID) -> String? {
        defer { refresh() }
        do {
            try service.save(SecretValue(key), provider: provider, purpose: .text)
            checks[provider.rawValue] = .unchecked
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    func delete(_ provider: SoftwareRegisseurAI.AIProviderID) -> String? {
        defer { refresh() }
        do {
            try service.delete(provider: provider, purpose: .text)
            checks[provider.rawValue] = .unchecked
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Günstige Prüfung über die Modellliste des Anbieters (keine Generierungs-Tokens).
    func validate(_ provider: SoftwareRegisseurAI.AIProviderID) async {
        checks[provider.rawValue] = .checking
        do {
            let client = try service.textProvider(provider)
            switch try await client.validateAPIKey() {
            case .valid: checks[provider.rawValue] = .valid
            case let .validWithWarning(text): checks[provider.rawValue] = .validWithWarning(text)
            case .invalid: checks[provider.rawValue] = .invalid
            }
        } catch {
            checks[provider.rawValue] = .failed(Self.message(for: error))
        }
    }

    /// Modelle des Anbieters für die KI-Ausarbeitung (I: keine fest eingebauten Modell-IDs).
    func models(_ provider: SoftwareRegisseurAI.AIProviderID) async -> Result<[AIModelInfo], KeyStoreError> {
        do {
            return .success(try await service.textProvider(provider).listModels())
        } catch {
            return .failure(KeyStoreError(message: Self.message(for: error)))
        }
    }

    /// Client für „Mit KI besprechen“ mit dem gespeicherten Schlüssel (nur im Speicher, nie protokolliert).
    func textProvider(_ provider: SoftwareRegisseurAI.AIProviderID) throws -> any TextAIProvider {
        try service.textProvider(provider)
    }

    func hasKey(_ provider: SoftwareRegisseurAI.AIProviderID) -> Bool {
        if case .stored = status(provider) { return true }
        return false
    }

    struct KeyStoreError: Error, Equatable {
        let message: String
    }

    static func message(for error: any Error) -> String {
        if let keychain = error as? KeychainError { return keychain.userMessage }
        if let provider = error as? AIProviderError { return provider.userMessage() }
        return String(localized: "Der Vorgang ist fehlgeschlagen. Bitte erneut versuchen.")
    }

    static func displayName(_ provider: SoftwareRegisseurAI.AIProviderID) -> String {
        switch provider {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        default: provider.rawValue
        }
    }
}
