import Foundation

/// Keeps secrets out of AI requests (spec H4: `.env`, keys, credentials, certificates strictly
/// excluded; Q1: secrets redaction for AI prompts).
public struct ContextSecretFilter: Sendable {
    public struct RedactionRule: Sendable, Hashable {
        public var kind: String
        public var pattern: String
        /// Capture group to replace; 0 replaces the whole match.
        public var group: Int

        public init(kind: String, pattern: String, group: Int = 0) {
            self.kind = kind
            self.pattern = pattern
            self.group = group
        }
    }

    public struct RedactionResult: Sendable, Hashable {
        public var text: String
        /// Number of redactions per rule kind.
        public var redactions: [String: Int]

        public var redactionCount: Int { redactions.values.reduce(0, +) }
    }

    /// Glob patterns matched case-insensitively against every path component.
    public static let defaultExcludedPathPatterns: [String] = [
        ".env*", "*.pem", "*.p12", "*.key", "id_rsa*", "credentials*", "*.mobileprovision", "secrets.*",
        // Additional key/certificate material.
        "*.p8", "*.pfx", "*.cer", "*.der", "*.jks", "*.keystore", "*.keychain", "*.keychain-db",
        "id_dsa*", "id_ecdsa*", "id_ed25519*", ".netrc", ".npmrc", ".pypirc",
        ".ssh", ".aws", ".gnupg", "*.xcconfig.local", "Local.xcconfig",
    ]

    public static let defaultRedactionRules: [RedactionRule] = [
        RedactionRule(
            kind: "private-key",
            pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        ),
        RedactionRule(kind: "anthropic-key", pattern: #"sk-ant-[A-Za-z0-9_\-]{16,}"#),
        RedactionRule(kind: "openai-key", pattern: #"sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#),
        RedactionRule(kind: "google-api-key", pattern: #"AIza[0-9A-Za-z_\-]{35}"#),
        RedactionRule(kind: "aws-access-key", pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        RedactionRule(kind: "github-token", pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"#),
        RedactionRule(kind: "slack-token", pattern: #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        RedactionRule(kind: "jwt", pattern: #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
        RedactionRule(kind: "bearer-token", pattern: #"(?i)(bearer\s+)(?!\[REDACTED)([A-Za-z0-9._~+/=\-]{20,})"#, group: 2),
        RedactionRule(kind: "url-credentials", pattern: #"(?i)\b([a-z][a-z0-9+.\-]*://[^:/\s@]+:)([^@\s/]+)(@)"#, group: 2),
        RedactionRule(
            kind: "secret-assignment",
            pattern: #"(?i)\b((?:[a-z0-9]+[_\-.])*(?:api[_\-]?key|apikey|secret(?:[_\-]?key)?|client[_\-]?secret|access[_\-]?token|auth[_\-]?token|refresh[_\-]?token|token|password|passwd|pwd|private[_\-]?key)["']?\s*[:=]\s*["']?)(?!\[REDACTED)([^\s"',;]{8,})"#,
            group: 2
        ),
    ]

    public var excludedPathPatterns: [String]
    public var redactionRules: [RedactionRule]

    public init(
        excludedPathPatterns: [String] = ContextSecretFilter.defaultExcludedPathPatterns,
        redactionRules: [RedactionRule] = ContextSecretFilter.defaultRedactionRules
    ) {
        self.excludedPathPatterns = excludedPathPatterns
        self.redactionRules = redactionRules
    }

    /// The matching pattern when the path must never be sent, otherwise `nil`.
    public func exclusionPattern(forPath path: String) -> String? {
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        for component in components {
            for pattern in excludedPathPatterns where Self.glob(pattern, matches: component) {
                return pattern
            }
        }
        return nil
    }

    public func isExcluded(path: String) -> Bool {
        exclusionPattern(forPath: path) != nil
    }

    public func redact(_ text: String) -> RedactionResult {
        var result = text
        var counts: [String: Int] = [:]
        for rule in redactionRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            guard !matches.isEmpty else { continue }
            let mutable = NSMutableString(string: result)
            for match in matches.reversed() {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound else { continue }
                mutable.replaceCharacters(in: range, with: "[REDACTED:\(rule.kind)]")
                counts[rule.kind, default: 0] += 1
            }
            result = mutable as String
        }
        return RedactionResult(text: result, redactions: counts)
    }

    /// Case-insensitive glob supporting `*` and `?`.
    static func glob(_ pattern: String, matches candidate: String) -> Bool {
        let p = Array(pattern.lowercased())
        let s = Array(candidate.lowercased())
        var pi = 0, si = 0
        var starIndex = -1, matchIndex = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == "*" {
                starIndex = pi
                matchIndex = si
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                si = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
