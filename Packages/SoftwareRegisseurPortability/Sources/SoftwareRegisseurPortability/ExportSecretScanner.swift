import Foundation

/// Secret detection for export files (spec Q1, N1, A27/A34).
///
/// The rules mirror `SoftwareRegisseurSync.SecretGuard` (forbidden JSON key names and credential value
/// formats) plus the value formats of `SoftwareRegisseurProcess.SecretRedactor`. They are reimplemented
/// here so this package does not depend on Sync/Process (CloudKit, process spawning). Keep the lists in
/// step with those two types; `ExportSecretScanner.rulesVersion` is written into every manifest.
public enum ExportSecretScanner {
    /// Bumped whenever the rule set below changes.
    public static let rulesVersion = 1

    /// Normalized (lowercased, without `_`/`-`) key names that name credentials (SecretGuard).
    static let forbiddenKeyNames: Set<String> = [
        "apikey", "secret", "clientsecret", "password", "passwd", "passphrase", "token", "accesstoken",
        "refreshtoken", "authtoken", "bearertoken", "idtoken", "sessiontoken", "privatekey", "authorization",
        "credential", "credentials", "cookie",
    ]

    /// Suffixes such as `openAIApiKey` or `githubAccessToken` (SecretGuard).
    static let forbiddenKeySuffixes = [
        "apikey", "secret", "password", "accesstoken", "refreshtoken", "authtoken", "privatekey",
    ]

    /// Credential value formats: union of SecretGuard and SecretRedactor patterns.
    static let valuePatterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#,
        #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
        #"sk-[A-Za-z0-9_\-]{16,}"#,
        #"AIza[0-9A-Za-z_\-]{35}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"glpat-[A-Za-z0-9_\-]{20,}"#,
        #"xox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"(?i)\bbearer\s+[A-Za-z0-9\-._~+/]{20,}=*"#,
        // Credentials embedded in URLs: scheme://user:password@host
        #"[A-Za-z][A-Za-z0-9+.\-]*://[^/\s:@]+:[^@\s/]+@"#,
    ].map { try! NSRegularExpression(pattern: $0) } // Compile-time constants.

    public static func isForbiddenKeyName(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return forbiddenKeyNames.contains(normalized) || forbiddenKeySuffixes.contains { normalized.hasSuffix($0) }
    }

    public static func looksLikeSecret(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return valuePatterns.contains { $0.firstMatch(in: value, range: range) != nil }
    }

    /// JSON paths (`$.a[0].b`) of credential-named keys and credential-looking string values.
    public static func findings(inJSON data: Data, rootPath: String = "$") -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return looksLikeSecret(String(decoding: data, as: UTF8.self)) ? [rootPath] : []
        }
        var found: [String] = []
        scan(object, path: rootPath, into: &found)
        return found
    }

    /// Findings in plain text (Markdown): one entry per matching line number (1-based).
    public static func findings(inText text: String) -> [Int] {
        var lines: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where looksLikeSecret(String(line)) {
            lines.append(index + 1)
        }
        return lines
    }

    private static func scan(_ value: Any, path: String, into found: inout [String]) {
        switch value {
        case let dictionary as [String: Any]:
            for key in dictionary.keys.sorted() {
                let child = "\(path).\(key)"
                if isForbiddenKeyName(key) { found.append(child) }
                scan(dictionary[key]!, path: child, into: &found)
            }
        case let array as [Any]:
            for (index, element) in array.enumerated() { scan(element, path: "\(path)[\(index)]", into: &found) }
        case let string as String:
            if looksLikeSecret(string), found.last != path { found.append(path) }
        default:
            break
        }
    }
}
