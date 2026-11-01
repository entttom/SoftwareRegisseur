import Foundation
import SoftwareRegisseurSecrets

/// Loads a provider key from the keychain and maps keychain failures to provider errors,
/// so a missing or locked key becomes an explainable state instead of a crash (spec I).
public enum APIKeyLoader {
    public static func load(from store: any KeychainStore, account: String) throws -> SecretValue {
        do {
            guard let secret = try store.read(account: account)?.trimmed(), !secret.isEmpty else {
                throw AIProviderError.missingAPIKey
            }
            return secret
        } catch let error as KeychainError {
            switch error {
            case .interactionNotAllowed: throw AIProviderError.keychainLocked
            case .invalidAccount: throw AIProviderError.missingAPIKey
            default: throw AIProviderError.invalidRequest(error.userMessage)
            }
        }
    }
}
