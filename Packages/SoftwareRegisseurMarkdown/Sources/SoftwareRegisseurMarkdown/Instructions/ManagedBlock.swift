/// Proposed change to an agent instruction file. Nothing is written here; a later layer shows `diff` and
/// writes atomically after approval (spec G rule 3, ADR-0004).
public struct InstructionFileProposal: Sendable, Hashable {
    public var path: String
    public var originalText: String?
    public var proposedText: String

    public var hasChanges: Bool {
        guard let originalText else { return true }
        return !originalText.isByteIdentical(to: proposedText)
    }

    public var diff: LineDiff { LineDiff(old: originalText ?? "", new: proposedText) }

    public func unifiedDiff(context: Int = 3) -> String {
        diff.unified(oldLabel: originalText == nil ? "/dev/null" : "a/\(path)", newLabel: "b/\(path)", context: context)
    }
}

public enum ManagedBlockError: Error, Sendable, Hashable {
    case duplicateBeginMarker(lines: [Int])
    case duplicateEndMarker(lines: [Int])
    case nestedMarkers(lines: [Int])
    case endBeforeBegin(endLine: Int)
    case missingEndMarker(beginLine: Int)
    case missingBeginMarker(endLine: Int)
    case unsupportedVersion(String, line: Int)
    case malformedMarker(String, line: Int)
}

/// Versioned, clearly delimited block of Software Regisseur rules inside `AGENTS.md` (spec G rule 2).
/// Everything outside the markers is user content and is never modified.
///
/// Version history: v1 (initial), v2 (ADR-0024: request files and ADRs are maintained by Software
/// Regisseur, agents never create/edit/move them; no commit without approval). An installed block of an
/// older supported version is recognised and replaced – including its begin marker – only through the
/// normal proposal/approval flow; nothing here writes files.
public struct ManagedBlock: Sendable, Hashable {
    public static let version = 2
    public static let beginMarker = "<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->"
    public static let endMarker = "<!-- SOFTWARE-REGISSEUR:END -->"
    /// Begin markers of older block versions that are migrated to the current version (oldest first).
    public static let legacyBeginMarkers: [Int: String] = [1: "<!-- SOFTWARE-REGISSEUR:BEGIN v1 -->"]
    static let markerToken = "SOFTWARE-REGISSEUR:"

    static func beginMarkerVersion(_ trimmedLine: String) -> Int? {
        if trimmedLine == beginMarker { return version }
        return legacyBeginMarkers.first { $0.value == trimmedLine }?.key
    }

    /// Lines between the markers (without terminators).
    public var contentLines: [String]

    public init(contentLines: [String]) {
        self.contentLines = contentLines
    }

    /// Block content from the configured layout (spec G example; paths from config, English).
    public init(layout: FolderLayout) {
        var lines = ["## Software Regisseur Workflow", "- ADRs: \(layout.adrPath.directoryString)"]
        let entries: [(String, WorkItemStatus)] = [
            ("Open requests", .open), ("In progress", .inProgress), ("Review", .review), ("Done", .done),
        ]
        for (label, status) in entries {
            if let folder = layout.folder(for: status) { lines.append("- \(label): \(folder.directoryString)") }
        }
        lines += [
            "- Read relevant accepted ADRs before architectural changes.",
            "- Request files and ADRs in the folders above are maintained by Software Regisseur.",
            "- Agents must not create, edit or move request files or ADRs; report status, changes and tests in the final message instead.",
            "- Never commit, push or merge without explicit user approval.",
            "- Do not modify secrets.",
        ]
        contentLines = lines
    }

    /// Full block including markers, with trailing line ending.
    public func rendered(lineEnding: LineEnding = .lf) -> String {
        ([Self.beginMarker] + contentLines + [Self.endMarker]).map { $0 + lineEnding.rawValue }.joined()
    }

    public enum Location: Sendable, Hashable {
        case absent
        /// 0-based line indices of the marker lines.
        case present(beginLine: Int, endLine: Int)
    }

    /// Finds the block. Markers inside fenced code blocks (documentation examples) are ignored.
    /// Blocks of older supported versions (see `legacyBeginMarkers`) are found as well.
    public static func locate(in text: String) throws(ManagedBlockError) -> Location {
        try locate(lines: TextLines.split(text))
    }

    /// Version of the installed block, `nil` when there is none. A value below `version` means the
    /// block is outdated and the next instruction proposal migrates it.
    public static func installedVersion(in text: String) throws(ManagedBlockError) -> Int? {
        let lines = TextLines.split(text)
        guard case let .present(begin, _) = try locate(lines: lines) else { return nil }
        return beginMarkerVersion(lines[begin].content.trimmingWhitespace())
    }

    static func locate(lines: [TextLine]) throws(ManagedBlockError) -> Location {
        var begins: [Int] = []
        var ends: [Int] = []
        var order: [(isBegin: Bool, line: Int)] = []
        var fence = FenceTracker()
        for (index, line) in lines.enumerated() {
            if fence.consume(line.content) { continue }
            let trimmed = line.content.trimmingWhitespace()
            guard trimmed.hasPrefix("<!--"), trimmed.contains(markerToken) else { continue }
            if beginMarkerVersion(trimmed) != nil {
                begins.append(index)
                order.append((true, index))
            } else if trimmed == endMarker {
                ends.append(index)
                order.append((false, index))
            } else if let match = trimmed.wholeMatch(of: /<!--\s*SOFTWARE-REGISSEUR:BEGIN\s+v([0-9]+)\s*-->/) {
                throw .unsupportedVersion("v" + match.1, line: index + 1)
            } else {
                throw .malformedMarker(trimmed, line: index + 1)
            }
        }
        if begins.isEmpty, ends.isEmpty { return .absent }
        if begins.count > 1 || ends.count > 1 {
            // B B E E (or deeper) is nesting; any other repetition is duplication.
            if begins.count == ends.count, order.prefix(begins.count).allSatisfy(\.isBegin) {
                throw .nestedMarkers(lines: order.map { $0.line + 1 })
            }
            if begins.count > 1 { throw .duplicateBeginMarker(lines: begins.map { $0 + 1 }) }
            throw .duplicateEndMarker(lines: ends.map { $0 + 1 })
        }
        guard let begin = begins.first else { throw .missingBeginMarker(endLine: ends[0] + 1) }
        guard let end = ends.first else { throw .missingEndMarker(beginLine: begin + 1) }
        guard begin < end else { throw .endBeforeBegin(endLine: end + 1) }
        return .present(beginLine: begin, endLine: end)
    }

    /// New file text: appends the block (one blank line separation) or replaces only the lines between the
    /// markers. All other bytes stay identical. Throws instead of guessing on broken markers.
    public func apply(to existing: String?) throws(ManagedBlockError) -> String {
        guard let existing, !existing.isEmpty else { return rendered() }
        let lineEnding = LineEnding.detect(in: existing)
        var lines = TextLines.split(existing)
        switch try Self.locate(lines: lines) {
        case .absent:
            let separator = TextLines.blankLineSeparator(after: existing, lineEnding: lineEnding)
            return existing + separator + rendered(lineEnding: lineEnding)
        case let .present(begin, end):
            let terminator = lines[begin].terminator.isEmpty ? lineEnding.rawValue : lines[begin].terminator
            let replacement = contentLines.map { TextLine(content: $0, terminator: terminator) }
            lines.replaceSubrange((begin + 1)..<end, with: replacement)
            // Version migration: only the marker text changes; indentation/trailing whitespace stay.
            let marker = lines[begin].content.trimmingWhitespace()
            if marker != Self.beginMarker {
                lines[begin] = TextLine(content: lines[begin].content.replacingOccurrences(of: marker, with: Self.beginMarker),
                                        terminator: lines[begin].terminator)
            }
            return TextLines.join(lines)
        }
    }

    public func proposal(for existing: String?, path: String = "AGENTS.md") throws(ManagedBlockError)
        -> InstructionFileProposal {
        InstructionFileProposal(path: path, originalText: existing, proposedText: try apply(to: existing))
    }
}

/// CLAUDE.md integration (spec G rule 5): only ever appends `@AGENTS.md`, never rewrites existing content.
/// Whether the installed Claude Code supports imports is checked by the caller (capability detection).
public enum ClaudeMemoryImport {
    public static let agentsImportLine = "@AGENTS.md"

    /// True if a line (outside code fences) equals `@AGENTS.md`, ignoring surrounding whitespace.
    public static func containsAgentsImport(_ text: String) -> Bool {
        var fence = FenceTracker()
        for line in TextLines.split(text) {
            if fence.consume(line.content) { continue }
            var content = line.content
            if content.unicodeScalars.first == "\u{FEFF}" { content = String(Substring(content.unicodeScalars.dropFirst())) }
            if content.trimmingWhitespace() == agentsImportLine { return true }
        }
        return false
    }

    /// Proposal that appends the import line; `hasChanges` is false when the import already exists.
    public static func proposal(for existing: String?, path: String = "CLAUDE.md") -> InstructionFileProposal {
        guard let existing, !existing.isEmpty else {
            return InstructionFileProposal(path: path, originalText: existing, proposedText: agentsImportLine + "\n")
        }
        if containsAgentsImport(existing) {
            return InstructionFileProposal(path: path, originalText: existing, proposedText: existing)
        }
        let lineEnding = LineEnding.detect(in: existing)
        let le = lineEnding.rawValue
        let separator = TextLines.blankLineSeparator(after: existing, lineEnding: lineEnding)
        return InstructionFileProposal(path: path, originalText: existing, proposedText: existing + separator + agentsImportLine + le)
    }
}
