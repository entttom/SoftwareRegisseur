import Foundation

/// Request types (spec F1). ADRs are a separate entity with their own number range.
public enum WorkItemType: String, Hashable, Sendable, Codable, CaseIterable {
    case feature
    case bug
    case todo
    case improvement
    case note

    /// Human-ID prefix (ADR-0018).
    public var humanIDPrefix: String {
        switch self {
        case .feature: "FR"
        case .bug: "BUG"
        case .todo: "TODO"
        case .improvement: "IMP"
        case .note: "NOTE"
        }
    }

    public init?(humanIDPrefix: String) {
        guard let match = Self.allCases.first(where: { $0.humanIDPrefix == humanIDPrefix }) else { return nil }
        self = match
    }

    public var germanDisplayName: String {
        switch self {
        case .feature: String(localized: "Feature Request", bundle: .module)
        case .bug: String(localized: "Bug Report", bundle: .module)
        case .todo: String(localized: "Todo", bundle: .module)
        case .improvement: String(localized: "Verbesserung", bundle: .module)
        case .note: String(localized: "Notiz", bundle: .module)
        }
    }
}

public enum HumanIDError: Error, Hashable, Sendable {
    case empty
    case missingSeparator(String)
    case unknownPrefix(String)
    case invalidDigits(String)
    case nonCanonicalPadding(String)
    case numberOutOfRange(Int)
}

/// Per-repository human-readable ID such as `FR-0007` (spec F3, ADR-0018).
///
/// Format: `<PREFIX>-<number>`, zero padded to at least 4 digits; larger numbers use more digits
/// (`FR-12345`). Parsing is strict and only accepts the canonical form, so `format(parse(x)) == x`.
/// Only the Mac host assigns human IDs (ADR-0018); a `WorkItem` keeps `humanId == nil` until then.
public struct HumanID: Hashable, Sendable, Comparable, Codable, LosslessStringConvertible {
    public static let minimumDigits = 4

    public let type: WorkItemType
    public let number: Int

    public init(type: WorkItemType, number: Int) throws(HumanIDError) {
        guard number >= 1 else { throw .numberOutOfRange(number) }
        self.type = type
        self.number = number
    }

    public init(parsing string: String) throws(HumanIDError) {
        guard !string.isEmpty else { throw .empty }
        guard let separator = string.firstIndex(of: "-") else { throw .missingSeparator(string) }
        let prefix = String(string[..<separator])
        let digits = String(string[string.index(after: separator)...])
        guard let type = WorkItemType(humanIDPrefix: prefix) else { throw .unknownPrefix(prefix) }
        let number = try ZeroPaddedNumber.parse(digits, minimumDigits: Self.minimumDigits)
        try self.init(type: type, number: number)
    }

    public init?(_ description: String) {
        guard let parsed = try? HumanID(parsing: description) else { return nil }
        self = parsed
    }

    public var formatted: String {
        "\(type.humanIDPrefix)-\(ZeroPaddedNumber.format(number, minimumDigits: Self.minimumDigits))"
    }

    public var description: String { formatted }

    public static func < (lhs: HumanID, rhs: HumanID) -> Bool {
        if lhs.type.humanIDPrefix != rhs.type.humanIDPrefix {
            return lhs.type.humanIDPrefix < rhs.type.humanIDPrefix
        }
        return lhs.number < rhs.number
    }

    /// Next free ID for `type`: one past the highest number ever used for that prefix (ADR-0018:
    /// separate range per prefix, never reuse). `existing` must include retired/deleted IDs.
    public static func next(for type: WorkItemType, existing: some Sequence<HumanID>) -> HumanID {
        let highest = existing.lazy.filter { $0.type == type }.map(\.number).max() ?? 0
        // highest + 1 is always >= 1, so this cannot throw.
        return try! HumanID(type: type, number: highest + 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(parsing: string)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid human ID '\(string)': \(error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatted)
    }
}

/// ADR number `NNNN` without prefix; own number range independent of human IDs (ADR-0018).
public struct ADRNumber: Hashable, Sendable, Comparable, Codable, LosslessStringConvertible {
    public static let minimumDigits = 4

    public let value: Int

    /// `0` is accepted because some imported ADR sets start at `0000` (spec E3: keep existing IDs).
    public init(_ value: Int) throws(HumanIDError) {
        guard value >= 0 else { throw .numberOutOfRange(value) }
        self.value = value
    }

    /// Accepts `0006` and `ADR-0006`.
    public init(parsing string: String) throws(HumanIDError) {
        guard !string.isEmpty else { throw .empty }
        let digits = string.hasPrefix("ADR-") ? String(string.dropFirst(4)) : string
        try self.init(ZeroPaddedNumber.parse(digits, minimumDigits: Self.minimumDigits))
    }

    public init?(_ description: String) {
        guard let parsed = try? ADRNumber(parsing: description) else { return nil }
        self = parsed
    }

    /// `0006`
    public var formatted: String { ZeroPaddedNumber.format(value, minimumDigits: Self.minimumDigits) }
    /// `ADR-0006`
    public var displayID: String { "ADR-\(formatted)" }
    public var description: String { formatted }

    public static func < (lhs: ADRNumber, rhs: ADRNumber) -> Bool { lhs.value < rhs.value }

    public static func next(after existing: some Sequence<ADRNumber>) -> ADRNumber {
        let highest = existing.lazy.map(\.value).max() ?? 0
        return try! ADRNumber(highest + 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            do { try self.init(int) } catch {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ADR number \(int)")
            }
            return
        }
        let string = try container.decode(String.self)
        do { try self.init(parsing: string) } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ADR number '\(string)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatted)
    }
}

enum ZeroPaddedNumber {
    static func parse(_ digits: String, minimumDigits: Int) throws(HumanIDError) -> Int {
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
            throw .invalidDigits(digits)
        }
        guard let number = Int(digits) else { throw .invalidDigits(digits) }
        guard digits == format(number, minimumDigits: minimumDigits) else {
            throw .nonCanonicalPadding(digits)
        }
        return number
    }

    static func format(_ number: Int, minimumDigits: Int) -> String {
        let raw = String(number)
        guard raw.count < minimumDigits else { return raw }
        return String(repeating: "0", count: minimumDigits - raw.count) + raw
    }
}
