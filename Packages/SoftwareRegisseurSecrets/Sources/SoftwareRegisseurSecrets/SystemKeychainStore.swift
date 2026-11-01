import Foundation
import Security

/// Keychain-backed store (`kSecClassGenericPassword`), spec I and C.10.
///
/// - `service` defaults to "SoftwareRegisseur", `account` is the provider profile id.
/// - Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` unless the caller explicitly
///   opts into `.synchronizableRequested` (spec I: iCloud Keychain only opt-in with consent).
/// - Lookups use `kSecAttrSynchronizableAny` so an item is found regardless of its mode.
public struct SystemKeychainStore: KeychainStore {
    public struct Configuration: Sendable, Hashable {
        public var service: String
        /// Shared access group (e.g. "TEAMID.de.example.SoftwareRegisseur"); `nil` uses the app default.
        public var accessGroup: String?
        /// macOS only: use the data-protection keychain (iOS-style semantics). Requires a signed
        /// binary with a keychain access group; unsigned test hosts may get `missingEntitlement`.
        public var useDataProtectionKeychain: Bool

        public init(
            service: String = "SoftwareRegisseur",
            accessGroup: String? = nil,
            useDataProtectionKeychain: Bool = true
        ) {
            self.service = service
            self.accessGroup = accessGroup
            self.useDataProtectionKeychain = useDataProtectionKeychain
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: KeychainStore

    public func save(_ secret: SecretValue, account: String, mode: KeychainStorageMode) throws {
        try KeychainAccountValidator.validate(account)
        let wantsSync = mode == .synchronizableRequested
        var exact = baseQuery(account: account)

        if supportsSynchronizable {
            // Remove a variant stored in the other mode, otherwise two items would coexist.
            var otherVariant = baseQuery(account: account)
            otherVariant[kSecAttrSynchronizable as String] = !wantsSync
            let deleteStatus = SecItemDelete(otherVariant as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                throw Self.map(deleteStatus)
            }
            exact[kSecAttrSynchronizable as String] = wantsSync
        } else if wantsSync {
            throw KeychainError.synchronizationUnsupported
        }

        var addAttributes = exact
        addAttributes[kSecValueData as String] = secret.utf8Data
        addAttributes[kSecAttrAccessible as String] = Self.accessibility(for: mode)

        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: secret.utf8Data,
                kSecAttrAccessible as String: Self.accessibility(for: mode),
            ]
            let updateStatus = SecItemUpdate(exact as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw Self.map(updateStatus) }
        default:
            throw Self.map(addStatus)
        }
    }

    public func read(account: String) throws -> SecretValue? {
        try KeychainAccountValidator.validate(account)
        var query = lookupQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let data = result as? Data, let secret = SecretValue(utf8Data: data) else {
            throw KeychainError.unexpectedData
        }
        return secret
    }

    @discardableResult
    public func delete(account: String) throws -> Bool {
        try KeychainAccountValidator.validate(account)
        let status = SecItemDelete(lookupQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw Self.map(status)
        }
    }

    public func exists(account: String) throws -> Bool {
        try storageMode(account: account) != nil
    }

    public func listAccounts() throws -> [String] {
        var query = lookupQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let items = result as? [[String: Any]] else { throw KeychainError.unexpectedData }
        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        return Array(Set(accounts)).sorted()
    }

    public func storageMode(account: String) throws -> KeychainStorageMode? {
        try KeychainAccountValidator.validate(account)
        var query = lookupQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let attributes = result as? [String: Any] else { throw KeychainError.unexpectedData }
        let isSync = supportsSynchronizable && ((attributes[kSecAttrSynchronizable as String] as? Bool) ?? false)
        return isSync ? .synchronizableRequested : .deviceOnly
    }

    // MARK: Queries

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let group = configuration.accessGroup { query[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        if configuration.useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    private func lookupQuery(account: String?) -> [String: Any] {
        var query = baseQuery(account: account)
        if supportsSynchronizable {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return query
    }

    /// The file-based macOS keychain does not support `kSecAttrSynchronizable`.
    var supportsSynchronizable: Bool {
        #if os(macOS)
        return configuration.useDataProtectionKeychain
        #else
        return true
        #endif
    }

    static func accessibility(for mode: KeychainStorageMode) -> CFString {
        switch mode {
        case .deviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .synchronizableRequested: return kSecAttrAccessibleAfterFirstUnlock
        }
    }

    static func map(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled: return .authenticationFailed
        case errSecNotAvailable, errSecNoSuchKeychain: return .keychainUnavailable
        case errSecMissingEntitlement: return .missingEntitlement
        case errSecDuplicateItem: return .duplicateItem
        case errSecDecode: return .unexpectedData
        default: return .unhandled(status: status)
        }
    }
}
