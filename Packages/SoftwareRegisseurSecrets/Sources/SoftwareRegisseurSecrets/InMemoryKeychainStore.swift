import Foundation
import Synchronization

/// Process-local store for tests and SwiftUI previews. Can simulate a locked keychain.
public final class InMemoryKeychainStore: KeychainStore {
    private struct Entry {
        var secret: SecretValue
        var mode: KeychainStorageMode
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var isLocked = false
    }

    private let state: Mutex<State>

    public init(initial: [String: SecretValue] = [:]) {
        var state = State()
        for (account, secret) in initial {
            state.entries[account] = Entry(secret: secret, mode: .deviceOnly)
        }
        self.state = Mutex(state)
    }

    /// While locked every operation throws `KeychainError.interactionNotAllowed`.
    public func setLocked(_ locked: Bool) {
        state.withLock { $0.isLocked = locked }
    }

    public func save(_ secret: SecretValue, account: String, mode: KeychainStorageMode) throws {
        try KeychainAccountValidator.validate(account)
        try state.withLock { state in
            if state.isLocked { throw KeychainError.interactionNotAllowed }
            state.entries[account] = Entry(secret: secret, mode: mode)
        }
    }

    public func read(account: String) throws -> SecretValue? {
        try KeychainAccountValidator.validate(account)
        return try state.withLock { state in
            if state.isLocked { throw KeychainError.interactionNotAllowed }
            return state.entries[account]?.secret
        }
    }

    @discardableResult
    public func delete(account: String) throws -> Bool {
        try KeychainAccountValidator.validate(account)
        return try state.withLock { state in
            if state.isLocked { throw KeychainError.interactionNotAllowed }
            return state.entries.removeValue(forKey: account) != nil
        }
    }

    public func listAccounts() throws -> [String] {
        try state.withLock { state in
            if state.isLocked { throw KeychainError.interactionNotAllowed }
            return state.entries.keys.sorted()
        }
    }

    public func storageMode(account: String) throws -> KeychainStorageMode? {
        try KeychainAccountValidator.validate(account)
        return try state.withLock { state in
            if state.isLocked { throw KeychainError.interactionNotAllowed }
            return state.entries[account]?.mode
        }
    }
}
