import Foundation

/// Redacts likely secrets before text reaches logs, diagnostics or AI prompts (spec Q1).
/// Heuristic by nature: it prefers over-redaction of credential-looking values.
public struct SecretRedactor: Sendable {
    public let replacement: String

    public init(replacement: String = "[REDACTED]") {
        self.replacement = replacement
    }

    public static let standard = SecretRedactor()

    public func redact(_ text: String) -> String {
        var result = text
        for rule in Self.rules {
            result = rule.apply(to: result, replacement: replacement)
        }
        return result
    }

    public func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }

    /// Whether `text` contains a credential in a well-known token format (private keys, provider API
    /// keys, JWTs, webhook URLs …). Unlike `containsSecret` it ignores the generic `NAME=value` rule, so
    /// ordinary source code such as `let token = makeToken()` does not match. Used to keep likely
    /// secret files out of commits made by Software Regisseur (SR-SEC-09).
    public func containsKnownCredentialFormat(_ text: String) -> Bool {
        Self.rules.contains { rule in
            if case .assignment = rule.kind { return false }
            return rule.regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }

    // MARK: - Rules

    private struct Rule: @unchecked Sendable { // NSRegularExpression is immutable and thread-safe.
        enum Kind {
            /// Replace the whole match.
            case whole(String?)
            /// Keep capture group 1, replace the rest.
            case keepPrefix
            /// Generic `NAME=value` / `NAME: value`; only redacted when NAME looks sensitive.
            case assignment
        }
        let regex: NSRegularExpression
        let kind: Kind

        init(_ pattern: String, _ kind: Kind, options: NSRegularExpression.Options = []) {
            // Patterns are compile-time constants; a failure is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.kind = kind
        }

        func apply(to text: String, replacement: String) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            let output = NSMutableString(string: text)
            for match in matches.reversed() {
                switch kind {
                case .whole(let custom):
                    output.replaceCharacters(in: match.range, with: custom ?? replacement)
                case .keepPrefix:
                    let prefix = ns.substring(with: match.range(at: 1))
                    output.replaceCharacters(in: match.range, with: prefix + replacement)
                case .assignment:
                    let name = ns.substring(with: match.range(at: 1))
                    let value = ns.substring(with: match.range(at: 3))
                    guard Self.isSensitiveName(name), value != replacement, value != "\"\"", value != "''",
                          !["bearer", "basic"].contains(value.lowercased()) else { continue }
                    let quote = value.first.flatMap { $0 == "\"" || $0 == "'" ? String($0) : nil } ?? ""
                    output.replaceCharacters(in: match.range(at: 3), with: quote + replacement + quote)
                }
            }
            return output as String
        }

        static let sensitiveWords: Set<String> = [
            "key", "apikey", "token", "secret", "password", "passwd", "passphrase", "pass",
            "credential", "credentials", "auth", "authorization", "cookie", "pat", "privatekey",
        ]

        static func isSensitiveName(_ name: String) -> Bool {
            let lower = name.lowercased()
            let words = lower.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            if words.contains(where: { sensitiveWords.contains(String($0)) }) { return true }
            // camelCase such as apiKey, accessToken, clientSecret.
            return ["key", "token", "secret", "password", "passwd"].contains { lower.hasSuffix($0) }
        }
    }

    private static let rules: [Rule] = [
        // PEM private keys of any flavour (RSA, EC, OPENSSH, ENCRYPTED, PGP … incl. headers such as
        // `Proc-Type`); also lower-case/space variants written by some tools.
        Rule(#"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END \1PRIVATE KEY(?: BLOCK)?-----"#,
             .whole("[REDACTED PRIVATE KEY]"), options: .caseInsensitive),
        Rule(#"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY(?: BLOCK)?-----[\s\S]*"#, .whole("[REDACTED PRIVATE KEY]"), options: .caseInsensitive),
        Rule(#"\bsk-ant-[A-Za-z0-9_\-]{8,}"#, .whole(nil)),
        Rule(#"\bsk-[A-Za-z0-9_\-]{16,}"#, .whole(nil)),
        Rule(#"\bAIza[0-9A-Za-z_\-]{35}"#, .whole(nil)),
        Rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, .whole(nil)),
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, .whole(nil)),
        Rule(#"\bglpat-[A-Za-z0-9_\-]{20,}"#, .whole(nil)),
        Rule(#"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#, .whole(nil)),
        Rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, .whole(nil)),
        // SR-SEC-11: further well-known token formats.
        // JSON Web Tokens (header.payload.signature, both JSON parts base64url of `{"`).
        Rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, .whole(nil)),
        // Stripe secret and restricted keys (live and test).
        Rule(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#, .whole(nil)),
        // npm access tokens.
        Rule(#"\bnpm_[A-Za-z0-9]{36}\b"#, .whole(nil)),
        // Google OAuth access tokens.
        Rule(#"\bya29\.[A-Za-z0-9_\-]{20,}"#, .whole(nil)),
        // Hugging Face tokens.
        Rule(#"\bhf_[A-Za-z0-9]{30,}"#, .whole(nil)),
        // Slack incoming webhooks and Discord webhooks (the URL itself is the credential).
        Rule(#"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9_/\-]+"#, .whole(nil)),
        Rule(#"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]+"#, .whole(nil)),
        Rule(#"\b(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"#, .keepPrefix, options: .caseInsensitive),
        Rule(#"\b(Basic\s+)[A-Za-z0-9+/]{8,}=*"#, .keepPrefix, options: .caseInsensitive),
        // Credentials embedded in URLs: scheme://user:password@host
        Rule(#"([A-Za-z][A-Za-z0-9+.\-]*://[^/\s:@]+:)[^@\s/]+(?=@)"#, .keepPrefix),
        // NAME=value, NAME: value, "name": "value", export NAME='value'
        Rule(#"\b([A-Za-z_][A-Za-z0-9_.\-]*)["']?(\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s"',;]+)"#, .assignment),
    ]
}
