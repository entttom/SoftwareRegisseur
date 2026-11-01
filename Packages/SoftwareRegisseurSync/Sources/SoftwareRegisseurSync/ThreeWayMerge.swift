import Foundation
import SoftwareRegisseurPersistence

/// Line-based 3-way merge of user text (spec N2: no silent last-writer-wins). Changes of both sides
/// against the common ancestor are combined when they touch different lines; if both sides changed the
/// same lines differently (or inserted at the same place), the result is a conflict for the user.
///
/// Rules (conservative on purpose): identical changes on both sides are taken once; a change directly
/// adjacent to another change is fine, but an insertion at the boundary of the other side's change
/// counts as overlapping, because the intended order is ambiguous.
public enum ThreeWayTextMerge {
    public enum Outcome: Hashable, Sendable {
        case merged(String)
        /// Both sides changed the same region differently.
        case conflict
    }

    /// Upper bound for the line-comparison table (after trimming common prefix and suffix); larger
    /// inputs are left to the user instead of spending unbounded time and memory.
    public static let maxComparisonCells = 4_000_000

    public static func merge(base: String, local: String, remote: String) -> Outcome {
        if local == remote { return .merged(local) }
        if local == base { return .merged(remote) }
        if remote == base { return .merged(local) }
        let baseLines = lines(base)
        guard let localHunks = hunks(from: baseLines, to: lines(local)),
              let remoteHunks = hunks(from: baseLines, to: lines(remote))
        else { return .conflict }

        let all = (localHunks.map { ($0, Side.local) } + remoteHunks.map { ($0, Side.remote) })
            .sorted { ($0.0.start, $0.0.end) < ($1.0.start, $1.0.end) }
        var result: [Substring] = []
        var position = 0
        var index = 0
        while index < all.count {
            var group = [all[index]]
            let groupStart = all[index].0.start
            var groupEnd = all[index].0.end
            var next = index + 1
            while next < all.count, overlaps(all[next].0, groupStart: groupStart, groupEnd: groupEnd) {
                group.append(all[next])
                groupEnd = max(groupEnd, all[next].0.end)
                next += 1
            }
            result += baseLines[position..<groupStart]
            let localVersion = apply(group.filter { $0.1 == .local }.map(\.0), to: baseLines, from: groupStart, to: groupEnd)
            let remoteVersion = apply(group.filter { $0.1 == .remote }.map(\.0), to: baseLines, from: groupStart, to: groupEnd)
            let touchedByLocal = group.contains { $0.1 == .local }
            let touchedByRemote = group.contains { $0.1 == .remote }
            if touchedByLocal, touchedByRemote, localVersion != remoteVersion { return .conflict }
            result += touchedByLocal ? localVersion : remoteVersion
            position = groupEnd
            index = next
        }
        result += baseLines[position...]
        return .merged(result.joined(separator: "\n"))
    }

    // MARK: Internals

    private enum Side { case local, remote }

    /// Replacement of base lines `start..<end` by `lines` (an insertion if `start == end`).
    struct Hunk: Equatable {
        let start: Int
        let end: Int
        let lines: [Substring]
    }

    static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func overlaps(_ hunk: Hunk, groupStart: Int, groupEnd: Int) -> Bool {
        if hunk.start < groupEnd { return true }
        // Touching: an insertion at the group's end, or anything at an insertion point.
        return hunk.start == groupEnd && (hunk.start == hunk.end || groupStart == groupEnd)
    }

    private static func apply(_ hunks: [Hunk], to base: [Substring], from start: Int, to end: Int) -> [Substring] {
        var output: [Substring] = []
        var position = start
        for hunk in hunks {
            output += base[position..<hunk.start]
            output += hunk.lines
            position = hunk.end
        }
        output += base[position..<end]
        return output
    }

    /// Differences between `a` and `b` as hunks on `a` (LCS after trimming common prefix/suffix).
    static func hunks(from a: [Substring], to b: [Substring]) -> [Hunk]? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let x = Array(a[prefix..<(a.count - suffix)])
        let y = Array(b[prefix..<(b.count - suffix)])
        let n = x.count
        let m = y.count
        if n == 0, m == 0 { return [] }
        guard (n + 1) * (m + 1) <= maxComparisonCells else { return nil }

        // lcs[i][j] = length of the longest common subsequence of x[i...] and y[j...].
        let width = m + 1
        var lcs = [Int32](repeating: 0, count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * width + j] = x[i] == y[j]
                        ? lcs[(i + 1) * width + j + 1] + 1
                        : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if x[i] == y[j] {
                matches.append((i, j))
                i += 1
                j += 1
            } else if lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        matches.append((n, m))
        var result: [Hunk] = []
        var previousA = 0
        var previousB = 0
        for (matchA, matchB) in matches {
            if matchA > previousA || matchB > previousB {
                result.append(Hunk(start: prefix + previousA, end: prefix + matchA, lines: Array(y[previousB..<matchB])))
            }
            previousA = matchA + 1
            previousB = matchB + 1
        }
        return result
    }
}

/// Field-wise 3-way merge of two sync payloads against their common ancestor (`SyncConflict`).
/// A field changed on one side only is taken from that side; text changed on both sides is merged
/// line by line; any other field changed differently on both sides is a conflict.
/// Bookkeeping fields at the top level are combined instead of conflicting: `updatedAt` takes the
/// later value and `revision` the higher one (plus one if the merge produced new content).
public enum SyncPayloadMerge {
    public enum Outcome: Hashable, Sendable {
        /// Generic JSON; pass it through `SyncPayloadCodec.canonicalize` before storing.
        case merged(Data, mergedFields: [String])
        case conflict(fields: [String])
    }

    public static let revisionKey = "revision"
    public static let timestampKeys: Set<String> = ["updatedAt"]

    public static func merge(ancestor: Data, local: Data, remote: Data) throws -> Outcome {
        let decoder = SyncPayloadCodec.makeDecoder()
        let base = try decoder.decode(JSONValue.self, from: ancestor)
        let mine = try decoder.decode(JSONValue.self, from: local)
        let theirs = try decoder.decode(JSONValue.self, from: remote)
        guard case var .object(baseFields) = base, case var .object(localFields) = mine, case var .object(remoteFields) = theirs else {
            return .conflict(fields: ["$"])
        }
        // Bookkeeping fields are handled after the content merge.
        var bookkeeping: [String: (JSONValue?, JSONValue?)] = [:]
        for key in timestampKeys.union([revisionKey]) {
            bookkeeping[key] = (localFields.removeValue(forKey: key), remoteFields.removeValue(forKey: key))
            baseFields[key] = nil
        }

        var state = MergeState()
        var merged = state.mergeObject(baseFields, localFields, remoteFields, path: "")
        guard state.conflicts.isEmpty else { return .conflict(fields: state.conflicts.sorted()) }

        let isNewContent = merged != localFields && merged != remoteFields
        for (key, values) in bookkeeping {
            switch values {
            case let (local?, remote?):
                if key == revisionKey, let l = local.integer, let r = remote.integer {
                    merged[key] = .integer(max(l, r) + (isNewContent ? 1 : 0))
                } else if let l = local.number, let r = remote.number {
                    merged[key] = l >= r ? local : remote
                } else if local == remote {
                    merged[key] = local
                } else {
                    return .conflict(fields: [key])
                }
            case let (value?, nil), let (nil, value?):
                merged[key] = value
            case (nil, nil):
                break
            }
        }
        let data = try SyncPayloadCodec.encode(JSONValue.object(merged))
        return .merged(data, mergedFields: state.bothChanged.sorted())
    }

    private struct MergeState {
        var conflicts: [String] = []
        /// Fields changed on both sides and combined.
        var bothChanged: [String] = []

        mutating func mergeObject(
            _ base: [String: JSONValue], _ local: [String: JSONValue], _ remote: [String: JSONValue], path: String
        ) -> [String: JSONValue] {
            var result: [String: JSONValue] = [:]
            for key in Set(base.keys).union(local.keys).union(remote.keys) {
                let fieldPath = path.isEmpty ? key : "\(path).\(key)"
                if let value = mergeValue(base[key], local[key], remote[key], path: fieldPath) {
                    result[key] = value
                }
            }
            return result
        }

        mutating func mergeValue(_ base: JSONValue?, _ local: JSONValue?, _ remote: JSONValue?, path: String) -> JSONValue? {
            if local == remote { return local }
            if local == base { return remote }
            if remote == base { return local }
            bothChanged.append(path)
            switch (base, local, remote) {
            case let (.object(b)?, .object(l)?, .object(r)?):
                return .object(mergeObject(b, l, r, path: path))
            case let (_, .string(l)?, .string(r)?):
                let ancestor: String
                switch base {
                case let .string(text)?: ancestor = text
                case nil, .null?: ancestor = ""
                default:
                    conflicts.append(path)
                    return local
                }
                switch ThreeWayTextMerge.merge(base: ancestor, local: l, remote: r) {
                case let .merged(text): return .string(text)
                case .conflict:
                    conflicts.append(path)
                    return local
                }
            default:
                conflicts.append(path)
                return local
            }
        }
    }
}

/// Generic JSON value for field-wise merging.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var integer: Int64? {
        if case let .integer(value) = self { value } else { nil }
    }

    var number: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
