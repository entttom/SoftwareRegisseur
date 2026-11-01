import Foundation

/// Scanner configuration (spec E1: configurable excludes and maximum depth).
public struct ScanOptions: Sendable, Hashable, Codable {
    public static let defaultExcludedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", "build", "dist", ".venv", "venv",
        "target", ".gradle", ".idea", ".swiftpm", "Carthage",
    ]

    /// Directory names that are never entered (matched exactly). `.git` is always skipped regardless.
    public var excludedDirectoryNames: Set<String>
    /// Absolute paths that are never entered, e.g. the Software Regisseur worktree base (spec L2).
    public var excludedPaths: [URL]
    /// Maximum depth below a scan root (the root itself has depth 0).
    public var maxDepth: Int
    /// When `false`, a hidden directory is only recorded (and entered) if it is a repository, bare
    /// repository, worktree or submodule; other hidden folders are ignored.
    public var includeHiddenDirectories: Bool

    public init(
        excludedDirectoryNames: Set<String> = ScanOptions.defaultExcludedDirectoryNames,
        excludedPaths: [URL] = [],
        maxDepth: Int = 8,
        includeHiddenDirectories: Bool = false
    ) {
        self.excludedDirectoryNames = excludedDirectoryNames
        self.excludedPaths = excludedPaths
        self.maxDepth = max(0, maxDepth)
        self.includeHiddenDirectories = includeHiddenDirectories
    }
}

/// Classification of one directory (spec E1/E2).
public enum DirectoryKind: String, Sendable, Hashable, Codable {
    /// Work tree root with a `.git` directory (or a `.git` file pointing to a separate git dir).
    case repositoryRoot
    /// `.git` file whose git dir lives in `<common>/worktrees/<name>`.
    case linkedWorktree
    /// `.git` file whose git dir lives in `<superproject>/.git/modules/<name>`.
    case submodule
    case bareRepository
    /// Folder inside a repository's work tree.
    case repositorySubfolder
    /// Folder that is not part of any repository (candidate for a new project).
    case plainFolder
}

public struct ScannedDirectory: Sendable, Hashable, Codable {
    public let url: URL
    public let kind: DirectoryKind
    /// Depth below `scanRoot`.
    public let depth: Int
    public let scanRoot: URL
    /// Subfolder → enclosing work tree; submodule → superproject; linked worktree → main repository.
    public let owningRepositoryURL: URL?
    /// Git dir for repository roots, bare repositories, worktrees and submodules.
    public let gitDirectoryURL: URL?
    /// Common git dir of a linked worktree.
    public let commonGitDirectoryURL: URL?
}

/// A main project candidate. Worktrees and submodules are attached, never listed separately (spec E1).
public struct DiscoveredRepository: Sendable, Hashable, Codable {
    public let rootURL: URL
    public let isBare: Bool
    public let gitDirectoryURL: URL
    /// Set for repositories nested in another repository's work tree (e.g. vendored repos).
    public let enclosingRepositoryURL: URL?
    public internal(set) var linkedWorktrees: [URL]
    public internal(set) var submodules: [URL]
}

public struct SymlinkedDirectory: Sendable, Hashable, Codable {
    public let url: URL
    /// Raw link destination as stored in the symlink.
    public let destination: String
}

public struct ScanIssue: Sendable, Hashable, Codable {
    public let url: URL
    public let message: String
}

public struct ScanStatistics: Sendable, Hashable, Codable {
    public internal(set) var directoriesVisited = 0
    /// Directories whose entries had to be read (cache misses).
    public internal(set) var directoriesListed = 0
    public internal(set) var cacheHits = 0
}

public struct ScanResult: Sendable, Hashable {
    public let roots: [URL]
    /// Every visited directory, sorted by path.
    public let directories: [ScannedDirectory]
    /// Main projects: repository roots (including nested ones) and bare repositories.
    public let repositories: [DiscoveredRepository]
    /// Worktrees/submodules whose main repository was not part of this scan.
    public let unattachedDirectories: [ScannedDirectory]
    /// Symlinks to directories; recorded, never followed.
    public let symlinkedDirectories: [SymlinkedDirectory]
    public let excludedDirectories: [URL]
    /// Directories not entered because of `ScanOptions.maxDepth`.
    public let depthLimitedDirectories: [URL]
    public let issues: [ScanIssue]
    public let statistics: ScanStatistics

    public func directory(at url: URL) -> ScannedDirectory? {
        directories.first { $0.url.plainPath == url.plainPath }
    }

    public func repository(at url: URL) -> DiscoveredRepository? {
        repositories.first { $0.rootURL.plainPath == url.plainPath }
    }
}

/// Per-directory listing cache keyed by path and validated by mtime/inode, so rescanning an
/// unchanged tree costs one `lstat` per directory instead of a full `readdir` (spec E1 "inkrementell").
public struct ScanCache: Sendable, Hashable, Codable {
    struct Listing: Sendable, Hashable, Codable {
        enum GitEntry: Sendable, Hashable, Codable {
            case none
            case directory
            case file(content: String, modifiedAt: FileTimestamp)
        }

        var modifiedAt: FileTimestamp
        var device: Int32
        var inode: UInt64
        var childDirectories: [String]
        var symlinkedDirectories: [String: String]
        var gitEntry: GitEntry
        var looksLikeBareRepository: Bool
    }

    var listings: [String: Listing] = [:]

    public init() {}

    public var entryCount: Int { listings.count }
}

struct FileTimestamp: Sendable, Hashable, Codable {
    var seconds: Int
    var nanoseconds: Int
}
