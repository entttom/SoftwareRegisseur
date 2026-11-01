import Foundation
import Testing
import SoftwareRegisseurSecrets
@testable import SoftwareRegisseurAI

@Suite("ContextSecretFilter")
struct ContextSecretFilterTests {
    let filter = ContextSecretFilter()

    @Test(arguments: [
        ".env", ".env.local", "Config/.env.production", "certs/server.pem", "dist/cert.p12", "keys/private.key",
        "/Users/me/.ssh/id_rsa", "id_rsa.pub", "credentials.json", "aws/credentials", "Profiles/App.mobileprovision",
        "secrets.yaml", "Secrets.JSON", "AuthKey_ABC.p8", "home/.ssh/config", "id_ed25519",
    ])
    func excludesSecretPaths(path: String) {
        #expect(filter.isExcluded(path: path), "\(path) must be excluded")
    }

    @Test(arguments: [
        "Sources/App/Environment.swift", "README.md", "docs/keys.md", "Sources/SecretValue.swift",
        "Tests/EnvTests.swift", "Package.swift", "keyboard.swift",
    ])
    func keepsRegularPaths(path: String) {
        #expect(!filter.isExcluded(path: path), "\(path) must not be excluded")
    }

    @Test func redactsKnownSecretShapes() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\nabc\n-----END RSA PRIVATE KEY-----"
        let samples: [(String, String, String)] = [
            ("key: sk-proj-abcdefghijklmnopqrstuvwxyz0123", "sk-proj-abcdefghijklmnopqrstuvwxyz0123", "openai-key"),
            ("sk-ant-api03-abcdefghijklmnopqrstuv", "sk-ant-api03-abcdefghijklmnopqrstuv", "anthropic-key"),
            ("google AIzaSyA1234567890abcdefghijklmnopqrstuv", "AIzaSyA1234567890abcdefghijklmnopqrstuv", "google-api-key"),
            ("aws AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE", "aws-access-key"),
            ("gh ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "github-token"),
            (pem, "MIIEpAIBAAKCAQEA", "private-key"),
            ("password = \"hunter2hunter2\"", "hunter2hunter2", "secret-assignment"),
            ("DB_PASSWORD: s3cr3tValue!", "s3cr3tValue!", "secret-assignment"),
            ("OPENAI_API_KEY=abc123def456", "abc123def456", "secret-assignment"),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz.123", "abcdefghijklmnopqrstuvwxyz.123", "bearer-token"),
            ("postgres://admin:pa55word@db.example.com/app", "pa55word", "url-credentials"),
        ]
        for (text, secret, kind) in samples {
            let result = filter.redact(text)
            #expect(!result.text.contains(secret), "\(kind) not redacted in: \(result.text)")
            #expect(result.redactions[kind] != nil, "expected kind \(kind), got \(result.redactions)")
        }
        // No double counting of an already-redacted value.
        let combined = filter.redact("api_key=sk-proj-abcdefghijklmnopqrstuvwxyz0123")
        #expect(combined.redactionCount == 1)
        #expect(combined.text == "api_key=[REDACTED:openai-key]")
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "Feature: Export als PDF. Der Token-Zähler soll 8 Zeichen anzeigen. Passwort-Feld validieren."
        let result = filter.redact(text)
        #expect(result.text == text)
        #expect(result.redactionCount == 0)
    }

    @Test func globMatching() {
        #expect(ContextSecretFilter.glob("*.pem", matches: "a.PEM"))
        #expect(ContextSecretFilter.glob("id_rsa*", matches: "id_rsa"))
        #expect(!ContextSecretFilter.glob("secrets.*", matches: "secrets"))
        #expect(ContextSecretFilter.glob("?.key", matches: "a.key"))
    }
}

@Suite("CostEstimator")
struct CostEstimatorTests {
    @Test func emptyDefaultTableYieldsNoEstimate() {
        #expect(PriceTable.empty.entries.isEmpty)
        #expect(CostEstimator().estimate(usage: AIUsage(inputTokens: 10, outputTokens: 10), provider: .openai, model: "x") == nil)
    }

    @Test func computesTokenAndAudioCosts() throws {
        var table = PriceTable(currencyCode: "USD")
        table.setPrice(ModelPrice(inputPerMillionTokens: 2, outputPerMillionTokens: 10, cachedInputPerMillionTokens: 0.5),
                       provider: .anthropic, model: "claude-sonnet-5-5")
        table.setPrice(ModelPrice(perAudioMinute: Decimal(string: "0.0045")), provider: .openai, model: "gpt-transcribe")
        let estimator = CostEstimator(priceTable: table)

        let text = try #require(estimator.estimate(
            usage: AIUsage(inputTokens: 1_000_000, outputTokens: 500_000, cachedInputTokens: 200_000),
            provider: .anthropic, model: "claude-sonnet-5-5"
        ))
        // 800k × 2 + 200k × 0.5 + 500k × 10 (per 1M) = 1.6 + 0.1 + 5 = 6.7
        #expect(text.amount == Decimal(string: "6.7"))
        #expect(text.isEstimate)
        #expect(text.unpricedComponents.isEmpty)
        #expect(text.formatted().contains("geschätzt"))

        let audio = try #require(estimator.estimate(usage: AIUsage(audioSeconds: 120), provider: .openai, model: "gpt-transcribe"))
        #expect(audio.amount == Decimal(string: "0.009"))

        let partial = try #require(estimator.estimate(usage: AIUsage(inputTokens: 5), provider: .openai, model: "gpt-transcribe"))
        #expect(partial.unpricedComponents == ["input"])
    }

    @Test func priceTableIsEditableJSON() throws {
        var table = PriceTable(currencyCode: "EUR", asOf: Date(timeIntervalSince1970: 1_790_000_000))
        table.setPrice(ModelPrice(inputPerMillionTokens: 1, outputPerMillionTokens: 4), provider: .gemini, model: "gemini-4-pro")
        let data = try table.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"model\" : \"gemini-4-pro\""))
        #expect(try PriceTable.decode(from: data) == table)
    }
}

@Suite("API key loading")
struct APIKeyLoaderTests {
    @Test func mapsKeychainStates() throws {
        let store = InMemoryKeychainStore()
        #expect(throws: AIProviderError.missingAPIKey) { try APIKeyLoader.load(from: store, account: "openai") }
        try store.save(SecretValue(" sk-x \n"), account: "openai")
        #expect(try APIKeyLoader.load(from: store, account: "openai").revealedValue() == "sk-x")
        store.setLocked(true)
        #expect(throws: AIProviderError.keychainLocked) { try APIKeyLoader.load(from: store, account: "openai") }
    }

    @Test func providerIDsAreOpen() {
        #expect(AIProviderID("mistral").rawValue == "mistral")
        #expect(AIProviderID.anthropic.displayName == "Anthropic")
    }
}
