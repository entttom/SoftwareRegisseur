import Foundation

/// `major.minor.patch[-prerelease]` as printed by `codex --version` / `claude --version`.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (core, pre): (Substring, String?) = {
            if let dash = trimmed.firstIndex(of: "-") {
                return (trimmed[..<dash], String(trimmed[trimmed.index(after: dash)...]))
            }
            return (trimmed[...], nil)
        }()
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.init(major, minor, patch, prerelease: pre?.isEmpty == true ? nil : pre)
    }

    /// Finds the first `x.y.z[-pre]` token in tool output.
    public static func firstMatch(in text: String) -> SemanticVersion? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "(" || $0 == ")" }) {
            let candidate = token.hasPrefix("v") ? token.dropFirst() : token
            if let version = SemanticVersion(String(candidate)) { return version }
        }
        return nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (l?, r?): return l < r
        }
    }
}
