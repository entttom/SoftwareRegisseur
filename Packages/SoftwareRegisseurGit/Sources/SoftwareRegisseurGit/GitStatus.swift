import Foundation

/// Parsed `git status --porcelain=v2 --branch -z`.
public struct GitStatus: Sendable, Hashable, Codable {
    public struct Branch: Sendable, Hashable, Codable {
        /// HEAD commit, `nil` for `(initial)`.
        public var oid: String?
        /// Branch name, `nil` when detached.
        public var head: String?
        public var upstream: String?
        public var ahead: Int?
        public var behind: Int?
        public var isDetached: Bool { head == nil }

        public init(oid: String? = nil, head: String? = nil, upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil) {
            self.oid = oid
            self.head = head
            self.upstream = upstream
            self.ahead = ahead
            self.behind = behind
        }
    }

    public struct Entry: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case changed, renamedOrCopied, unmerged, untracked, ignored
        }

        public let kind: Kind
        /// Index (staged) status character, `.` when unmodified (`?`/`!` for untracked/ignored).
        public let indexStatus: Character
        /// Work tree status character.
        public let workTreeStatus: Character
        public let path: String
        /// Source path for renames/copies.
        public let originalPath: String?
        /// `N...` or `S<c><m><u>` submodule state.
        public let submoduleState: String?
        /// Rename/copy score such as `R100`.
        public let renameScore: String?

        enum CodingKeys: String, CodingKey {
            case kind, indexStatus, workTreeStatus, path, originalPath, submoduleState, renameScore
        }

        public init(kind: Kind, indexStatus: Character, workTreeStatus: Character, path: String,
                    originalPath: String? = nil, submoduleState: String? = nil, renameScore: String? = nil) {
            self.kind = kind
            self.indexStatus = indexStatus
            self.workTreeStatus = workTreeStatus
            self.path = path
            self.originalPath = originalPath
            self.submoduleState = submoduleState
            self.renameScore = renameScore
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Kind.self, forKey: .kind)
            indexStatus = try container.decode(String.self, forKey: .indexStatus).first ?? "."
            workTreeStatus = try container.decode(String.self, forKey: .workTreeStatus).first ?? "."
            path = try container.decode(String.self, forKey: .path)
            originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
            submoduleState = try container.decodeIfPresent(String.self, forKey: .submoduleState)
            renameScore = try container.decodeIfPresent(String.self, forKey: .renameScore)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(String(indexStatus), forKey: .indexStatus)
            try container.encode(String(workTreeStatus), forKey: .workTreeStatus)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(originalPath, forKey: .originalPath)
            try container.encodeIfPresent(submoduleState, forKey: .submoduleState)
            try container.encodeIfPresent(renameScore, forKey: .renameScore)
        }
    }

    public var branch: Branch
    public var entries: [Entry]

    /// No tracked changes, no conflicts and no untracked files (ignored files do not count).
    public var isClean: Bool { !entries.contains { $0.kind != .ignored } }
    public var hasTrackedChanges: Bool { entries.contains { [.changed, .renamedOrCopied, .unmerged].contains($0.kind) } }
    public var hasConflicts: Bool { entries.contains { $0.kind == .unmerged } }
    public var untrackedPaths: [String] { entries.filter { $0.kind == .untracked }.map(\.path) }

    public init(branch: Branch = Branch(), entries: [Entry] = []) {
        self.branch = branch
        self.entries = entries
    }

    /// Parses NUL-separated porcelain v2 output.
    public static func parse(_ data: Data) throws(GitError) -> GitStatus {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        var status = GitStatus()
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard let type = record.first else { continue }
            switch type {
            case "#":
                parseHeader(record, into: &status.branch)
            case "1":
                let parts = split(record, fieldCount: 9)
                guard parts.count == 9 else { throw .malformedOutput(record) }
                status.entries.append(Entry(kind: .changed, xy: parts[1], submodule: parts[2], path: parts[8]))
            case "2":
                let parts = split(record, fieldCount: 10)
                guard parts.count == 10, index < fields.count else { throw .malformedOutput(record) }
                let original = fields[index]
                index += 1
                var entry = Entry(kind: .renamedOrCopied, xy: parts[1], submodule: parts[2], path: parts[9])
                entry = Entry(kind: entry.kind, indexStatus: entry.indexStatus, workTreeStatus: entry.workTreeStatus,
                              path: entry.path, originalPath: original, submoduleState: entry.submoduleState,
                              renameScore: parts[8])
                status.entries.append(entry)
            case "u":
                let parts = split(record, fieldCount: 11)
                guard parts.count == 11 else { throw .malformedOutput(record) }
                status.entries.append(Entry(kind: .unmerged, xy: parts[1], submodule: parts[2], path: parts[10]))
            case "?":
                status.entries.append(Entry(kind: .untracked, indexStatus: "?", workTreeStatus: "?", path: String(record.dropFirst(2))))
            case "!":
                status.entries.append(Entry(kind: .ignored, indexStatus: "!", workTreeStatus: "!", path: String(record.dropFirst(2))))
            default:
                throw .malformedOutput(record)
            }
        }
        return status
    }

    private static func parseHeader(_ record: String, into branch: inout Branch) {
        let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 3 else { return }
        let value = parts[2]
        switch parts[1] {
        case "branch.oid": branch.oid = value == "(initial)" ? nil : value
        case "branch.head": branch.head = value == "(detached)" ? nil : value
        case "branch.upstream": branch.upstream = value
        case "branch.ab":
            let numbers = value.split(separator: " ")
            if numbers.count == 2 {
                branch.ahead = Int(numbers[0].dropFirst())
                branch.behind = Int(numbers[1].dropFirst())
            }
        default: break
        }
    }

    /// Splits into `fieldCount` space-separated fields; the last one (the path) may contain spaces.
    private static func split(_ record: String, fieldCount: Int) -> [String] {
        record.split(separator: " ", maxSplits: fieldCount - 1, omittingEmptySubsequences: false).map(String.init)
    }
}

extension GitStatus.Entry {
    init(kind: Kind, xy: String, submodule: String, path: String) {
        let characters = Array(xy)
        self.init(
            kind: kind,
            indexStatus: characters.first ?? ".",
            workTreeStatus: characters.count > 1 ? characters[1] : ".",
            path: path,
            submoduleState: submodule == "N..." ? nil : submodule
        )
    }
}

extension GitClient {
    /// Reads the status of the work tree at `directory` (untracked files listed individually).
    public func status(of directory: URL, includeIgnored: Bool = false) async throws -> GitStatus {
        var arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        if includeIgnored { arguments.append("--ignored") }
        return try GitStatus.parse(try await run(arguments, in: directory).standardOutputData)
    }
}
