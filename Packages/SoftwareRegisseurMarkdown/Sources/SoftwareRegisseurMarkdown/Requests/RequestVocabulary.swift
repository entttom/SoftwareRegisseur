import Foundation

/// WorkItem status as written to the request frontmatter (ADR-0012, spec F5). Job-only states such as
/// `pendingMac` or `waiting_quota` are deliberately absent.
public enum WorkItemStatus: String, Sendable, Hashable, Codable, CaseIterable, CodingKeyRepresentable {
    case inbox
    case open
    case queued
    case scheduled
    case inProgress = "in_progress"
    case waitingApproval = "waiting_approval"
    case implementationFinished = "implementation_finished"
    case review
    case integrated
    case done
    case blocked
    case failed
    case cancelled
    case paused
}

/// Request kinds (spec F1). ADRs are handled separately (spec F4: "ADRs nicht automatisch als Feature Requests
/// interpretieren").
public enum RequestType: String, Sendable, Hashable, Codable, CaseIterable {
    case feature
    case bug
    case todo
    case improvement
    case note

    /// Human ID prefix (ADR-0018).
    public var idPrefix: HumanIDPrefix {
        switch self {
        case .feature: .fr
        case .bug: .bug
        case .todo: .todo
        case .improvement: .imp
        case .note: .note
        }
    }
}

public enum HumanIDPrefix: String, Sendable, Hashable, Codable, CaseIterable {
    case fr = "FR"
    case bug = "BUG"
    case todo = "TODO"
    case imp = "IMP"
    case note = "NOTE"

    public var requestType: RequestType {
        switch self {
        case .fr: .feature
        case .bug: .bug
        case .todo: .todo
        case .imp: .improvement
        case .note: .note
        }
    }
}

public enum RequestPriority: String, Sendable, Hashable, Codable, CaseIterable {
    case low
    case medium
    case high
    case urgent
}

/// Human readable request ID such as `FR-0001` (ADR-0018: four digits with leading zeros, more when needed,
/// one number range per prefix and repository).
public struct HumanID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let prefix: HumanIDPrefix
    public let number: Int

    public init(prefix: HumanIDPrefix, number: Int) {
        precondition(number >= 0, "HumanID numbers are non-negative")
        self.prefix = prefix
        self.number = number
    }

    /// Parses `FR-0001`. Shorter digit runs from imported repositories (`FR-7`) are accepted (spec E3: keep
    /// existing IDs); `description` always renders the canonical form.
    public init?(_ string: String) {
        guard let match = string.wholeMatch(of: /([A-Z]+)-([0-9]{1,9})/),
              let prefix = HumanIDPrefix(rawValue: String(match.1)),
              let number = Int(match.2) else { return nil }
        self.init(prefix: prefix, number: number)
    }

    public var description: String {
        prefix.rawValue + "-" + Self.pad(number)
    }

    public static func < (lhs: HumanID, rhs: HumanID) -> Bool {
        (lhs.prefix.rawValue, lhs.number) < (rhs.prefix.rawValue, rhs.number)
    }

    /// Next free ID for `prefix`, given existing IDs or request file names and an optional high-water mark from
    /// the host's local index (ADR-0018: numbers are never reused, even after deletion).
    public static func next(prefix: HumanIDPrefix, existing: some Sequence<String>, highWaterMark: Int = 0) -> HumanID {
        var highest = highWaterMark
        for candidate in existing {
            let id = HumanID(candidate) ?? RequestFileName.parse(candidate)?.id
            if let id, id.prefix == prefix { highest = max(highest, id.number) }
        }
        return HumanID(prefix: prefix, number: highest + 1)
    }

    static func pad(_ number: Int) -> String {
        let digits = String(number)
        return digits.count >= 4 ? digits : String(repeating: "0", count: 4 - digits.count) + digits
    }
}

/// ISO 8601 timestamps with offset as used in request frontmatter (spec F3: `2026-10-29T20:00:00+01:00`).
public enum RequestTimestamp {
    public static func format(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
    }

    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingWhitespace()
        if let date = try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon).parse(trimmed) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(trimmed) { return date }
        return nil
    }
}
