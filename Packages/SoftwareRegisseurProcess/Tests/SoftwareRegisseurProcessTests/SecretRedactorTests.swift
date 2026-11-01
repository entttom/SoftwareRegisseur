import Testing
@testable import SoftwareRegisseurProcess

@Suite("SecretRedactor")
struct SecretRedactorTests {
    let redactor = SecretRedactor.standard

    @Test(arguments: [
        ("key sk-ant-api03-AbCdEf0123456789_xyz-QQ end", "key [REDACTED] end"),
        ("openai sk-proj-abcdefghijklmnopqrstuvwxyz0123 end", "openai [REDACTED] end"),
        ("google AIzaSyA1234567890abcdefghijklmnopqrstuv end", "google [REDACTED] end"),
        ("gh ghp_abcdefghijklmnopqrstuvwxyz0123456789 end", "gh [REDACTED] end"),
        ("pat github_pat_11ABCDEFG0123456789_abcdefghijklmnop end", "pat [REDACTED] end"),
        ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", "Authorization: Bearer [REDACTED]"),
        ("OPENAI_API_KEY=abc123", "OPENAI_API_KEY=[REDACTED]"),
        ("export GITHUB_TOKEN='quoted value'", "export GITHUB_TOKEN='[REDACTED]'"),
        ("DB_PASSWORD = hunter2", "DB_PASSWORD = [REDACTED]"),
        ("{\"apiKey\": \"abc\"}", "{\"apiKey\": \"[REDACTED]\"}"),
        ("client_secret: s3cr3t", "client_secret: [REDACTED]"),
        ("remote https://user:tok3n@github.com/org/repo.git", "remote https://user:[REDACTED]@github.com/org/repo.git"),
        ("AWS AKIAABCDEFGHIJKLMNOP", "AWS [REDACTED]"),
        // SR-SEC-11: additional formats.
        ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U end", "jwt [REDACTED] end"),
        ("stripe sk_live_51HxAbCdEfGhIjKlMnOpQr end", "stripe [REDACTED] end"),
        ("stripe rk_test_51HxAbCdEfGhIjKlMnOpQr end", "stripe [REDACTED] end"),
        ("npm npm_abcdefghijklmnopqrstuvwxyz0123456789 end", "npm [REDACTED] end"),
        ("google ya29.a0AfH6SMBabcdefghijklmnopqrstuvwxyz end", "google [REDACTED] end"),
        ("hook https://hooks.slack.com/services/T000/B000/XXXXXXXXXXXXXXXX end", "hook [REDACTED] end"),
        ("hf hf_abcdefghijklmnopqrstuvwxyzABCDEFGH end", "hf [REDACTED] end"),
    ])
    func redactsSecrets(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
        #expect(redactor.containsSecret(input))
    }

    @Test func redactsPEMPrivateKeyBlocks() {
        let text = """
        before
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ
        AAAAMwAAAAtzc2gtZWQyNTUxOQ
        -----END OPENSSH PRIVATE KEY-----
        after
        """
        #expect(redactor.redact(text) == "before\n[REDACTED PRIVATE KEY]\nafter")
        #expect(redactor.redact("x -----BEGIN RSA PRIVATE KEY-----\nMIIE truncated") == "x [REDACTED PRIVATE KEY]")
        // SR-SEC-11: OpenSSH/encrypted keys with header lines and PGP key blocks.
        let encrypted = "a\n-----BEGIN ENCRYPTED PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES\n\nabc\n-----END ENCRYPTED PRIVATE KEY-----\nb"
        #expect(redactor.redact(encrypted) == "a\n[REDACTED PRIVATE KEY]\nb")
        let pgp = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF\n-----END PGP PRIVATE KEY BLOCK-----"
        #expect(redactor.redact(pgp) == "[REDACTED PRIVATE KEY]")
    }

    @Test func knownCredentialFormatIgnoresOrdinaryCode() {
        #expect(!redactor.containsKnownCredentialFormat("let token = makeToken()\npassword = field.text"))
        #expect(redactor.containsSecret("let token = makeToken()"))
        #expect(redactor.containsKnownCredentialFormat("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123"))
        #expect(redactor.containsKnownCredentialFormat("-----BEGIN OPENSSH PRIVATE KEY-----\nabc"))
    }

    @Test(arguments: [
        "PWD=/Users/me/project",
        "PATH=/usr/bin:/bin",
        "git commit -m 'fix login'",
        "https://github.com/org/repo.git",
        "session 019a-4f2c resumed",
        "sk-short",
        "author: Jane Doe",
    ])
    func leavesHarmlessTextAlone(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test func redactionIsIdempotent() {
        let once = redactor.redact("API_KEY=sk-ant-abcdefghijklmnop Bearer abc.def")
        #expect(redactor.redact(once) == once)
        #expect(once == "API_KEY=[REDACTED] Bearer [REDACTED]")
    }
}
