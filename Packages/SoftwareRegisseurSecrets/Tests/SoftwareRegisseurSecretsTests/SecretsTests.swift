import Foundation
import Testing
@testable import SoftwareRegisseurSecrets

@Suite("SecretValue redaction")
struct SecretValueTests {
    let raw = "sk-test-SUPERSECRET-1234567890"

    @Test func descriptionsNeverRevealValue() {
        let secret = SecretValue(raw)
        #expect(!secret.description.contains(raw))
        #expect(!secret.debugDescription.contains(raw))
        #expect(!"\(secret)".contains(raw))
        #expect(!String(describing: secret).contains(raw))
        #expect(!String(reflecting: secret).contains(raw))
        #expect(!"\([secret])".contains(raw))
        #expect(!"\(Optional(secret) as Any)".contains(raw))
    }

    @Test func dumpAndMirrorNeverRevealValue() {
        let secret = SecretValue(raw)
        var output = ""
        dump(secret, to: &output)
        #expect(!output.contains(raw))
        #expect(Mirror(reflecting: secret).children.isEmpty)

        struct Holder { let key: SecretValue }
        var nested = ""
        dump(Holder(key: secret), to: &nested)
        #expect(!nested.contains(raw))
    }

    @Test func revealAndDataRoundTrip() throws {
        let secret = SecretValue(raw)
        #expect(secret.revealedValue() == raw)
        let decoded = try #require(SecretValue(utf8Data: secret.utf8Data))
        #expect(decoded == secret)
        #expect(SecretValue("  key\n").trimmed().revealedValue() == "key")
        #expect(SecretValue(utf8Data: Data([0xFF, 0xFE])) == nil)
    }
}

@Suite("InMemoryKeychainStore semantics")
struct InMemoryKeychainStoreTests {
    @Test func saveReadReplaceDelete() throws {
        let store = InMemoryKeychainStore()
        #expect(try store.read(account: "openai-default") == nil)
        #expect(try store.exists(account: "openai-default") == false)

        try store.save(SecretValue("first"), account: "openai-default")
        #expect(try store.read(account: "openai-default")?.revealedValue() == "first")
        #expect(try store.storageMode(account: "openai-default") == .deviceOnly)

        try store.save(SecretValue("second"), account: "openai-default", mode: .synchronizableRequested)
        #expect(try store.read(account: "openai-default")?.revealedValue() == "second")
        #expect(try store.storageMode(account: "openai-default") == .synchronizableRequested)

        #expect(try store.delete(account: "openai-default") == true)
        #expect(try store.delete(account: "openai-default") == false)
        #expect(try store.read(account: "openai-default") == nil)
    }

    @Test func listAccountsSorted() throws {
        let store = InMemoryKeychainStore()
        try store.save(SecretValue("a"), account: "gemini")
        try store.save(SecretValue("b"), account: "anthropic")
        try store.save(SecretValue("c"), account: "openai")
        #expect(try store.listAccounts() == ["anthropic", "gemini", "openai"])
    }

    @Test func lockedStoreThrowsInteractionNotAllowed() throws {
        let store = InMemoryKeychainStore(initial: ["openai": SecretValue("x")])
        store.setLocked(true)
        #expect(throws: KeychainError.interactionNotAllowed) { try store.read(account: "openai") }
        #expect(throws: KeychainError.interactionNotAllowed) { try store.save(SecretValue("y"), account: "openai") }
        store.setLocked(false)
        #expect(try store.read(account: "openai")?.revealedValue() == "x")
    }

    @Test func emptyAccountRejected() {
        let store = InMemoryKeychainStore()
        #expect(throws: KeychainError.invalidAccount) { try store.save(SecretValue("x"), account: "  ") }
    }

    @Test func errorMessagesAreGerman() {
        #expect(KeychainError.interactionNotAllowed.userMessage.contains("gesperrt"))
    }
}

@Suite("SystemKeychainStore")
struct SystemKeychainStoreTests {
    @Test func statusMapping() {
        #expect(SystemKeychainStore.map(errSecInteractionNotAllowed) == .interactionNotAllowed)
        #expect(SystemKeychainStore.map(errSecMissingEntitlement) == .missingEntitlement)
        #expect(SystemKeychainStore.map(errSecAuthFailed) == .authenticationFailed)
        #expect(SystemKeychainStore.map(-1) == .unhandled(status: -1))
        #expect(SystemKeychainStore.accessibility(for: .deviceOnly) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(SystemKeychainStore.accessibility(for: .synchronizableRequested) == kSecAttrAccessibleAfterFirstUnlock)
    }

    #if os(macOS)
    /// Real keychain round trip on the macOS test host. Uses a unique service and always cleans up.
    /// The data-protection keychain needs a signed host with an access group; an unsigned
    /// `swift test` host falls back to the file-based login keychain. If neither is usable
    /// (e.g. headless CI without a login keychain) the test is skipped.
    @Test func roundTripOnMacOSTestHost() throws {
        let service = "SoftwareRegisseur.tests.\(UUID().uuidString)"
        let candidates = [
            SystemKeychainStore(configuration: .init(service: service, useDataProtectionKeychain: true)),
            SystemKeychainStore(configuration: .init(service: service, useDataProtectionKeychain: false)),
        ]
        let account = "test-profile-\(UUID().uuidString)"

        var usable: SystemKeychainStore?
        for store in candidates {
            do {
                try store.save(SecretValue("probe"), account: account)
                usable = store
                break
            } catch let error as KeychainError {
                switch error {
                case .missingEntitlement, .interactionNotAllowed, .keychainUnavailable,
                     .authenticationFailed, .unhandled:
                    continue
                default:
                    throw error
                }
            }
        }
        guard let store = usable else {
            try Test.cancel("Keychain is not available in this test environment")
        }
        defer { _ = try? store.delete(account: account) }

        #expect(try store.read(account: account)?.revealedValue() == "probe")
        #expect(try store.exists(account: account))
        #expect(try store.storageMode(account: account) == .deviceOnly)

        try store.save(SecretValue("replaced"), account: account)
        #expect(try store.read(account: account)?.revealedValue() == "replaced")
        #expect(try store.listAccounts() == [account])

        #expect(try store.delete(account: account) == true)
        #expect(try store.read(account: account) == nil)
        #expect(try store.exists(account: account) == false)
        #expect(try store.listAccounts().isEmpty)
    }
    #endif
}
