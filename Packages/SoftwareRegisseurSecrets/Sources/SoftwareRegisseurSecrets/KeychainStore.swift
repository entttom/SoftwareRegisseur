import Foundation

/// Where a secret lives (spec I: device-bound by default; iCloud Keychain only opt-in).
public enum KeychainStorageMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never leaves the device. Default.
    case deviceOnly
    /// `kSecAttrSynchronizable` + `kSecAttrAccessibleAfterFirstUnlock`.
    ///
    /// Requesting synchronisation does not prove that iCloud Keychain is enabled on the device;
    /// that state cannot be detected by apps. UI must say "Synchronisierung angefordert",
    /// never "synchronisiert".
    case synchronizableRequested
}

public enum KeychainError: Error, Sendable, Equatable {
    case invalidAccount
    /// Device locked / keychain not yet unlocked after boot (`errSecInteractionNotAllowed`).
    case interactionNotAllowed
    case authenticationFailed
    case keychainUnavailable
    /// The binary lacks the keychain-access-groups entitlement (`errSecMissingEntitlement`).
    case missingEntitlement
    case duplicateItem
    /// iCloud Keychain sync was requested on a keychain that cannot hold synchronizable items.
    case synchronizationUnsupported
    case unexpectedData
    case unhandled(status: Int32)

    /// German user-facing text (spec P/Q1: errors understandable, data preserved).
    public var userMessage: String {
        switch self {
        case .invalidAccount:
            return String(localized: "Ungültiger Schlüsselbund-Eintrag.", bundle: .module)
        case .interactionNotAllowed:
            return String(localized: "Der Schlüsselbund ist gesperrt. Bitte das Gerät entsperren und erneut versuchen.", bundle: .module)
        case .authenticationFailed:
            return String(localized: "Zugriff auf den Schlüsselbund wurde verweigert.", bundle: .module)
        case .keychainUnavailable:
            return String(localized: "Der Schlüsselbund ist derzeit nicht verfügbar.", bundle: .module)
        case .missingEntitlement:
            return String(localized: "Der App fehlt die Berechtigung für den Schlüsselbund (Signierung prüfen).", bundle: .module)
        case .duplicateItem:
            return String(localized: "Der Schlüsselbund-Eintrag existiert bereits.", bundle: .module)
        case .synchronizationUnsupported:
            return String(localized: "iCloud-Schlüsselbund-Synchronisierung ist in dieser Umgebung nicht möglich. Bitte den Schlüssel gerätebezogen speichern.", bundle: .module)
        case .unexpectedData:
            return String(localized: "Der gespeicherte Schlüssel ist beschädigt.", bundle: .module)
        case .unhandled(let status):
            return String(localized: "Schlüsselbund-Fehler (\(status)).", bundle: .module)
        }
    }
}

/// Secret storage for provider API keys. `account` is the provider profile id.
public protocol KeychainStore: Sendable {
    /// Saves or replaces the secret for `account`.
    func save(_ secret: SecretValue, account: String, mode: KeychainStorageMode) throws
    /// Returns `nil` when no item exists.
    func read(account: String) throws -> SecretValue?
    /// Returns `true` when an item was removed; deleting a missing item is not an error.
    @discardableResult
    func delete(account: String) throws -> Bool
    func exists(account: String) throws -> Bool
    /// Accounts stored under this store's service, sorted.
    func listAccounts() throws -> [String]
    /// Storage mode of an existing item, `nil` if none.
    func storageMode(account: String) throws -> KeychainStorageMode?
}

extension KeychainStore {
    public func save(_ secret: SecretValue, account: String) throws {
        try save(secret, account: account, mode: .deviceOnly)
    }

    public func exists(account: String) throws -> Bool {
        try read(account: account) != nil
    }
}

enum KeychainAccountValidator {
    static func validate(_ account: String) throws {
        if account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KeychainError.invalidAccount
        }
    }
}
