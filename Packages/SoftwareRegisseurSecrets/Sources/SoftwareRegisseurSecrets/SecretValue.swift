import Foundation

/// Wraps an API key or credential so it never leaks through `print`, string interpolation,
/// `dump`, `Mirror` or debugger descriptions (spec I, Q1: no secrets in logs).
///
/// Deliberately not `Codable`: secrets must only be persisted through a `KeychainStore`.
public struct SecretValue: Sendable, Equatable {
    private let storage: String

    public init(_ value: String) {
        self.storage = value
    }

    /// Returns `nil` when the data is not valid UTF-8.
    public init?(utf8Data: Data) {
        guard let value = String(data: utf8Data, encoding: .utf8) else { return nil }
        self.storage = value
    }

    /// The plain value. Only call this at the boundary where the secret is actually used
    /// (e.g. when setting an HTTP header); never log the result.
    public func revealedValue() -> String {
        storage
    }

    public var utf8Data: Data {
        Data(storage.utf8)
    }

    public var isEmpty: Bool {
        storage.isEmpty
    }

    /// Whitespace/newline-trimmed copy; pasted keys often carry a trailing newline.
    public func trimmed() -> SecretValue {
        SecretValue(storage.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let redactedPlaceholder = "SecretValue(<redacted>)"
}

extension SecretValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { Self.redactedPlaceholder }
    public var debugDescription: String { Self.redactedPlaceholder }
    public var customMirror: Mirror {
        Mirror(self, children: [(label: String?, value: Any)](), displayStyle: nil)
    }
}
