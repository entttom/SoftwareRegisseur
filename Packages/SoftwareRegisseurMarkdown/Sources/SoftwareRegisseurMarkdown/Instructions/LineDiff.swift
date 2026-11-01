/// Line-based diff for change previews (spec G rule 3: "diff anzeigen").
public struct LineDiff: Sendable, Hashable {
    public enum Operation: Sendable, Hashable {
        case equal
        case insert
        case delete
    }

    public struct Line: Sendable, Hashable {
        public var operation: Operation
        /// Line content without terminator.
        public var text: String
        /// 1-based line numbers.
        public var oldLineNumber: Int?
        public var newLineNumber: Int?
    }

    public let lines: [Line]
    private let oldHasTrailingNewline: Bool
    private let newHasTrailingNewline: Bool

    /// Lines are compared including their terminators, so line-ending changes show up as edits.
    public init(old: String, new: String) {
        let oldLines = TextLines.split(old)
        let newLines = TextLines.split(new)
        oldHasTrailingNewline = oldLines.last.map { !$0.terminator.isEmpty } ?? true
        newHasTrailingNewline = newLines.last.map { !$0.terminator.isEmpty } ?? true
        lines = Self.compute(oldLines.map(\.raw), newLines.map(\.raw), oldLines.map(\.content), newLines.map(\.content))
    }

    public var insertedLines: [Line] { lines.filter { $0.operation == .insert } }
    public var deletedLines: [Line] { lines.filter { $0.operation == .delete } }
    public var hasChanges: Bool { lines.contains { $0.operation != .equal } }

    private static func compute(_ old: [String], _ new: [String], _ oldText: [String], _ newText: [String]) -> [Line] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        var result: [Line] = []
        for index in 0..<prefix {
            result.append(Line(operation: .equal, text: oldText[index], oldLineNumber: index + 1, newLineNumber: index + 1))
        }
        let oldMiddle = Array(prefix..<(old.count - suffix))
        let newMiddle = Array(prefix..<(new.count - suffix))
        let n = oldMiddle.count
        let m = newMiddle.count
        if n * m <= 4_000_000 {
            // LCS table over the differing middle part.
            var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            if n > 0, m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i][j] = old[oldMiddle[i]] == new[newMiddle[j]]
                            ? table[i + 1][j + 1] + 1
                            : max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
            var i = 0
            var j = 0
            while i < n || j < m {
                if i < n, j < m, old[oldMiddle[i]] == new[newMiddle[j]] {
                    result.append(Line(operation: .equal, text: oldText[oldMiddle[i]],
                                       oldLineNumber: oldMiddle[i] + 1, newLineNumber: newMiddle[j] + 1))
                    i += 1
                    j += 1
                } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                    result.append(Line(operation: .delete, text: oldText[oldMiddle[i]],
                                       oldLineNumber: oldMiddle[i] + 1, newLineNumber: nil))
                    i += 1
                } else {
                    result.append(Line(operation: .insert, text: newText[newMiddle[j]],
                                       oldLineNumber: nil, newLineNumber: newMiddle[j] + 1))
                    j += 1
                }
            }
        } else {
            for index in oldMiddle {
                result.append(Line(operation: .delete, text: oldText[index], oldLineNumber: index + 1, newLineNumber: nil))
            }
            for index in newMiddle {
                result.append(Line(operation: .insert, text: newText[index], oldLineNumber: nil, newLineNumber: index + 1))
            }
        }
        for offset in 0..<suffix {
            let oldIndex = old.count - suffix + offset
            let newIndex = new.count - suffix + offset
            result.append(Line(operation: .equal, text: oldText[oldIndex],
                               oldLineNumber: oldIndex + 1, newLineNumber: newIndex + 1))
        }
        return result
    }

    /// Unified diff text (`--- a/…`, `+++ b/…`, `@@ -l,s +l,s @@`). Empty when there are no changes.
    public func unified(oldLabel: String = "a", newLabel: String = "b", context: Int = 3) -> String {
        guard hasChanges else { return "" }
        let changeIndices = lines.indices.filter { lines[$0].operation != .equal }
        var hunks: [ClosedRange<Int>] = []
        for index in changeIndices {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = hunks.last, range.lowerBound <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                hunks.append(range)
            }
        }
        var output = "--- \(oldLabel)\n+++ \(newLabel)\n"
        let lastOldIndex = lines.lastIndex { $0.oldLineNumber != nil }
        let lastNewIndex = lines.lastIndex { $0.newLineNumber != nil }
        for hunk in hunks {
            let slice = lines[hunk]
            let oldCount = slice.filter { $0.operation != .insert }.count
            let newCount = slice.filter { $0.operation != .delete }.count
            let oldStart = slice.first { $0.oldLineNumber != nil }?.oldLineNumber
                ?? (lines[..<hunk.lowerBound].last { $0.oldLineNumber != nil }?.oldLineNumber ?? 0)
            let newStart = slice.first { $0.newLineNumber != nil }?.newLineNumber
                ?? (lines[..<hunk.lowerBound].last { $0.newLineNumber != nil }?.newLineNumber ?? 0)
            output += "@@ -\(Self.range(oldStart, oldCount)) +\(Self.range(newStart, newCount)) @@\n"
            for index in hunk {
                let line = lines[index]
                let marker = switch line.operation {
                case .equal: " "
                case .insert: "+"
                case .delete: "-"
                }
                output += marker + line.text + "\n"
                let isLastOld = index == lastOldIndex && line.operation != .insert && !oldHasTrailingNewline
                let isLastNew = index == lastNewIndex && line.operation != .delete && !newHasTrailingNewline
                if isLastOld || isLastNew { output += "\\ No newline at end of file\n" }
            }
        }
        return output
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }
}
