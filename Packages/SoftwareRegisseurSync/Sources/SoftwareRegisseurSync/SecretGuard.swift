import Foundation

/// Last line of defence before data leaves the device (spec N1 "nicht synchronisieren", Q1, A27):
/// rejects payloads whose JSON keys name credentials or whose string values look like API keys/tokens.
/// Key material itself lives only in the Keychain (`ProviderProfile.keychainReference` holds lookup
/// coordinates, not the key).
public enum SecretGuard {
    /// Normalized (lowercased, without `_`/`-`) key names that must never be synced.
    static let forbiddenKeyNames: Set<String> = [
        "apikey", "secret", "clientsecret", "password", "passwd", "passphrase", "token", "accesstoken",
        "refreshtoken", "authtoken", "bearertoken", "idtoken", "sessiontoken", "privatekey", "authorization",
        "credential", "credentials", "cookie",
    ]

    /// Suffixes such as `openAIApiKey`, `githubAccessToken`, `githubToken` or `signingKey` (SR-SEC-11:
    /// every name ending in `token`, `key`, `secret` or `password`), except `allowedKeyNames`.
    static let forbiddenKeySuffixes = ["apikey", "secret", "password", "passwd", "token", "key", "privatekey", "credential", "credentials"]

    /// Known harmless field names that end in a forbidden suffix (normalized). They hold identifiers,
    /// never credentials: e.g. the idempotency key of a job request or a sort key.
    static let allowedKeyNames: Set<String> = [
        "idempotencykey", "sortkey", "rangekey", "scopekey", "revisionkey", "groupkey", "codingkey", "primarykey",
        "changetoken", "servicechangetoken", "keychainreference", "settingskey",
    ]

    /// Well-known credential formats (OpenAI/Anthropic `sk-…`, Google `AIza…`, GitHub, Slack, PEM keys, bearer headers).
    // Regex is an immutable value; never mutated after initialization.
    nonisolated(unsafe) static let valuePatterns: [Regex<Substring>] = [
        /sk-[A-Za-z0-9_\-]{20,}/,
        /AIza[0-9A-Za-z_\-]{35}/,
        /gh[pousr]_[A-Za-z0-9]{36,}/,
        /github_pat_[A-Za-z0-9_]{22,}/,
        /xox[abpr]-[A-Za-z0-9\-]{10,}/,
        /-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----/,
        /[Bb]earer [A-Za-z0-9._\-]{20,}/,
        // SR-SEC-11: further well-known formats.
        /eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/,
        /(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/,
        /npm_[A-Za-z0-9]{36}/,
        /ya29\.[A-Za-z0-9_\-]{20,}/,
        /hf_[A-Za-z0-9]{30,}/,
        /glpat-[A-Za-z0-9_\-]{20,}/,
        /(?:AKIA|ASIA)[0-9A-Z]{16}/,
        /https:\/\/hooks\.slack\.com\/(?:services|workflows|triggers)\/[A-Za-z0-9_\/\-]+/,
    ]

    public static func isForbiddenKeyName(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        guard !allowedKeyNames.contains(normalized) else { return false }
        return forbiddenKeyNames.contains(normalized) || forbiddenKeySuffixes.contains { normalized.hasSuffix($0) }
    }

    public static func looksLikeSecret(_ value: String) -> Bool {
        valuePatterns.contains { value.contains($0) }
    }

    /// JSON paths of suspicious keys/values; empty means the payload may be synced.
    public static func violations(inJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return String(data: data, encoding: .utf8).map(looksLikeSecret) == true ? ["$"] : []
        }
        var found: [String] = []
        scan(object, path: "$", into: &found)
        return found
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
