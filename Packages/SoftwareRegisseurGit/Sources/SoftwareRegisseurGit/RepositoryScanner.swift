import Darwin
import Foundation

/// Recursive, symlink-safe, cycle-free and incremental scan of the configured root folders (spec E1).
///
/// The scanner only reads directory entries plus `.git` files / `commondir` files; it never runs
/// git, never enters `.git` directories or bare repositories and never follows symlinked directories.
public actor RepositoryScanner {
    public var options: ScanOptions
    public private(set) var cache: ScanCache

    public init(options: ScanOptions = ScanOptions(), cache: ScanCache = ScanCache()) {
        self.options = options
        self.cache = cache
    }

    public func setOptions(_ options: ScanOptions) {
        self.options = options
    }

    /// Scans `roots`. Throws `CancellationError` when the calling task is cancelled.
    public func scan(roots: [URL]) throws -> ScanResult {
        var walker = ScanWalker(options: options, previousCache: cache)
        let result = try walker.run(roots: roots)
        cache = walker.newCache
        return result
    }
}

// MARK: - Walker

struct ScanWalker {
    private struct Frame {
        let path: String
        let depth: Int
        let scanRoot: String
        /// Work tree that owns this directory (nil outside repositories).
        let enclosingRepository: String?
        /// Hidden directory that is only inspected for being a repository.
        let probeOnly: Bool
    }

    private struct Identity: Hashable {
        let device: Int32
        let inode: UInt64
    }

    let options: ScanOptions
    let previousCache: ScanCache
    private(set) var newCache = ScanCache()

    private var visited = Set<Identity>()
    private var directories: [ScannedDirectory] = []
    private var symlinks: [SymlinkedDirectory] = []
    private var excluded: [URL] = []
    private var depthLimited: [URL] = []
    private var issues: [ScanIssue] = []
    private var statistics = ScanStatistics()
    private let excludedPaths: Set<String>

    init(options: ScanOptions, previousCache: ScanCache) {
        self.options = options
        self.previousCache = previousCache
        excludedPaths = Set(options.excludedPaths.map { ((try? PathGuard.canonicalize($0)) ?? $0).plainPath })
    }

    mutating func run(roots: [URL]) throws -> ScanResult {
        var canonicalRoots: [String] = []
        for root in roots {
            do {
                let canonical = try PathGuard.canonicalize(root).plainPath
                guard PathGuard.isDirectory(URL(filePath: canonical)) else {
                    issues.append(ScanIssue(url: root, message: "Scan root is not a directory"))
                    continue
                }
                if !canonicalRoots.contains(canonical) { canonicalRoots.append(canonical) }
            } catch {
                issues.append(ScanIssue(url: root, message: "Scan root cannot be resolved: \(error)"))
            }
        }

        for root in canonicalRoots {
            var stack = [Frame(path: root, depth: 0, scanRoot: root,
                               enclosingRepository: Self.enclosingRepository(ofRoot: root), probeOnly: false)]
            while let frame = stack.popLast() {
                if Task.isCancelled { throw CancellationError() }
                stack.append(contentsOf: visit(frame).reversed())
            }
        }
        return makeResult(roots: canonicalRoots)
    }

    /// Visits one directory and returns the child frames to descend into.
    private mutating func visit(_ frame: Frame) -> [Frame] {
        var info = stat()
        guard lstat(frame.path, &info) == 0 else {
            issues.append(ScanIssue(url: Self.directoryURL(frame.path), message: "lstat failed: \(String(cString: strerror(errno)))"))
            return []
        }
        let identity = Identity(device: info.st_dev, inode: info.st_ino)
        guard visited.insert(identity).inserted else { return [] } // cycle or overlapping roots
        statistics.directoriesVisited += 1

        guard let listing = listing(for: frame.path, info: info) else {
            issues.append(ScanIssue(url: Self.directoryURL(frame.path), message: "Directory not readable: \(String(cString: strerror(errno)))"))
            return []
        }

        let classification = classify(path: frame.path, listing: listing, enclosingRepository: frame.enclosingRepository)
        if frame.probeOnly && ![.repositoryRoot, .bareRepository, .linkedWorktree, .submodule].contains(classification.kind) {
            return []
        }
        directories.append(ScannedDirectory(
            url: Self.directoryURL(frame.path),
            kind: classification.kind,
            depth: frame.depth,
            scanRoot: Self.directoryURL(frame.scanRoot),
            owningRepositoryURL: classification.owner.map(Self.directoryURL),
            gitDirectoryURL: classification.gitDirectory.map(Self.directoryURL),
            commonGitDirectoryURL: classification.commonGitDirectory.map(Self.directoryURL)
        ))

        for (name, destination) in listing.symlinkedDirectories.sorted(by: { $0.key < $1.key }) {
            symlinks.append(SymlinkedDirectory(url: Self.directoryURL(Self.join(frame.path, name)), destination: destination))
        }

        let childContext: String?
        switch classification.kind {
        case .bareRepository, .linkedWorktree:
            return [] // never enter repository internals or duplicate a worktree's content
        case .repositoryRoot, .submodule:
            childContext = frame.path
        case .repositorySubfolder, .plainFolder:
            childContext = frame.enclosingRepository
        }

        var children: [Frame] = []
        for name in listing.childDirectories.sorted() {
            let childPath = Self.join(frame.path, name)
            if name == ".git" || options.excludedDirectoryNames.contains(name) || excludedPaths.contains(childPath) {
                excluded.append(Self.directoryURL(childPath))
                continue
            }
            guard frame.depth + 1 <= options.maxDepth else {
                depthLimited.append(Self.directoryURL(childPath))
                continue
            }
            let hidden = name.hasPrefix(".") && !options.includeHiddenDirectories
            children.append(Frame(path: childPath, depth: frame.depth + 1, scanRoot: frame.scanRoot,
                                  enclosingRepository: childContext, probeOnly: hidden))
        }
        return children
    }

    // MARK: Listing & cache

    private mutating func listing(for path: String, info: stat) -> ScanCache.Listing? {
        let modifiedAt = FileTimestamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        if var cached = previousCache.listings[path], cached.modifiedAt == modifiedAt,
           cached.device == info.st_dev, cached.inode == info.st_ino {
            // `.git` file contents can change without touching the directory mtime.
            if case .file(_, let gitModifiedAt) = cached.gitEntry {
                let current = Self.readGitFile(in: path)
                if current?.modifiedAt != gitModifiedAt {
                    cached.gitEntry = current.map { .file(content: $0.content, modifiedAt: $0.modifiedAt) } ?? .none
                }
            }
            statistics.cacheHits += 1
            newCache.listings[path] = cached
            return cached
        }
        guard let listing = Self.readListing(path: path, modifiedAt: modifiedAt, info: info) else { return nil }
        statistics.directoriesListed += 1
        newCache.listings[path] = listing
        return listing
    }

    static func readListing(path: String, modifiedAt: FileTimestamp, info: stat) -> ScanCache.Listing? {
        guard let handle = opendir(path) else { return nil }
        defer { closedir(handle) }
        var childDirectories: [String] = []
        var symlinked: [String: String] = [:]
        var gitEntry = ScanCache.Listing.GitEntry.none
        var hasHEADFile = false, hasObjects = false, hasRefs = false

        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let childPath = join(path, name)
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                var childInfo = stat()
                guard lstat(childPath, &childInfo) == 0 else { continue }
                switch childInfo.st_mode & S_IFMT {
                case S_IFDIR: type = DT_DIR
                case S_IFLNK: type = DT_LNK
                case S_IFREG: type = DT_REG
                default: continue
                }
            }
            switch type {
            case DT_DIR:
                if name == ".git" {
                    gitEntry = .directory
                } else {
                    childDirectories.append(name)
                    if name == "objects" { hasObjects = true }
                    if name == "refs" { hasRefs = true }
                }
            case DT_REG:
                if name == ".git" {
                    if let file = readGitFile(in: path) { gitEntry = .file(content: file.content, modifiedAt: file.modifiedAt) }
                } else if name == "HEAD" {
                    hasHEADFile = true
                }
            case DT_LNK:
                var target = stat()
                guard stat(childPath, &target) == 0, (target.st_mode & S_IFMT) == S_IFDIR else { continue }
                if name == ".git" {
                    gitEntry = .directory
                } else {
                    symlinked[name] = readLink(childPath) ?? ""
                }
            default:
                continue
            }
        }
        return ScanCache.Listing(
            modifiedAt: modifiedAt,
            device: info.st_dev,
            inode: info.st_ino,
            childDirectories: childDirectories,
            symlinkedDirectories: symlinked,
            gitEntry: gitEntry,
            looksLikeBareRepository: gitEntry == .none && hasHEADFile && hasObjects && hasRefs
        )
    }

    // MARK: Classification

    private struct Classification {
        var kind: DirectoryKind
        var owner: String?
        var gitDirectory: String?
        var commonGitDirectory: String?
    }

    private mutating func classify(path: String, listing: ScanCache.Listing, enclosingRepository: String?) -> Classification {
        switch listing.gitEntry {
        case .directory:
            let gitDirectory = Self.join(path, ".git")
            if access(Self.join(gitDirectory, "HEAD"), F_OK) == 0 {
                return Classification(kind: .repositoryRoot, owner: enclosingRepository,
                                      gitDirectory: Self.realPath(gitDirectory) ?? gitDirectory)
            }
            issues.append(ScanIssue(url: Self.directoryURL(path), message: ".git directory without HEAD"))
        case .file(let content, _):
            if let link = classifyGitFile(path: path, content: content, enclosingRepository: enclosingRepository) {
                return link
            }
            issues.append(ScanIssue(url: Self.directoryURL(path), message: "Unrecognized .git file"))
        case .none:
            if listing.looksLikeBareRepository {
                return Classification(kind: .bareRepository, owner: enclosingRepository, gitDirectory: path)
            }
        }
        return Classification(kind: enclosingRepository == nil ? .plainFolder : .repositorySubfolder, owner: enclosingRepository)
    }

    private mutating func classifyGitFile(path: String, content: String, enclosingRepository: String?) -> Classification? {
        let line = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        var target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if !target.hasPrefix("/") { target = Self.join(path, target) }
        let gitDirectory = Self.realPath(target) ?? (target as NSString).standardizingPath

        // Linked worktrees have a `commondir` file in their private git dir.
        if let common = try? String(contentsOfFile: Self.join(gitDirectory, "commondir"), encoding: .utf8) {
            var commonPath = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !commonPath.hasPrefix("/") { commonPath = Self.join(gitDirectory, commonPath) }
            let commonDirectory = Self.realPath(commonPath) ?? (commonPath as NSString).standardizingPath
            return Classification(kind: .linkedWorktree, owner: Self.workTree(ofCommonGitDirectory: commonDirectory),
                                  gitDirectory: gitDirectory, commonGitDirectory: commonDirectory)
        }
        if let range = gitDirectory.range(of: "/.git/modules/") {
            let superproject = String(gitDirectory[..<range.lowerBound])
            return Classification(kind: .submodule, owner: enclosingRepository ?? superproject, gitDirectory: gitDirectory)
        }
        if let range = gitDirectory.range(of: "/worktrees/", options: .backwards) {
            // Broken/prunable worktree: derive the common dir from the path.
            let commonDirectory = String(gitDirectory[..<range.lowerBound])
            issues.append(ScanIssue(url: Self.directoryURL(path), message: "Worktree git dir is missing (prunable)"))
            return Classification(kind: .linkedWorktree, owner: Self.workTree(ofCommonGitDirectory: commonDirectory),
                                  gitDirectory: gitDirectory, commonGitDirectory: commonDirectory)
        }
        // `git init --separate-git-dir`: a normal repository with an external git dir.
        return Classification(kind: .repositoryRoot, owner: enclosingRepository, gitDirectory: gitDirectory)
    }

    // MARK: Result

    private func makeResult(roots: [String]) -> ScanResult {
        let sortedDirectories = directories.sorted { $0.url.plainPath < $1.url.plainPath }
        var repositories: [DiscoveredRepository] = []
        var indexByGitDirectory: [String: Int] = [:]
        var indexByRoot: [String: Int] = [:]
        for entry in sortedDirectories where entry.kind == .repositoryRoot || entry.kind == .bareRepository {
            let gitDirectory = entry.gitDirectoryURL ?? entry.url
            indexByGitDirectory[gitDirectory.plainPath] = repositories.count
            indexByRoot[entry.url.plainPath] = repositories.count
            repositories.append(DiscoveredRepository(
                rootURL: entry.url,
                isBare: entry.kind == .bareRepository,
                gitDirectoryURL: gitDirectory,
                enclosingRepositoryURL: entry.owningRepositoryURL,
                linkedWorktrees: [],
                submodules: []
            ))
        }
        var unattached: [ScannedDirectory] = []
        for entry in sortedDirectories {
            switch entry.kind {
            case .linkedWorktree:
                if let common = entry.commonGitDirectoryURL, let index = indexByGitDirectory[common.plainPath] {
                    repositories[index].linkedWorktrees.append(entry.url)
                } else {
                    unattached.append(entry)
                }
            case .submodule:
                if let owner = entry.owningRepositoryURL, let index = indexByRoot[owner.plainPath] {
                    repositories[index].submodules.append(entry.url)
                } else {
                    unattached.append(entry)
                }
            default:
                break
            }
        }
        return ScanResult(
            roots: roots.map(Self.directoryURL),
            directories: sortedDirectories,
            repositories: repositories,
            unattachedDirectories: unattached,
            symlinkedDirectories: symlinks.sorted { $0.url.plainPath < $1.url.plainPath },
            excludedDirectories: excluded.sorted { $0.plainPath < $1.plainPath },
            depthLimitedDirectories: depthLimited.sorted { $0.plainPath < $1.plainPath },
            issues: issues,
            statistics: statistics
        )
    }

    // MARK: Helpers

    /// When a scan root lies inside a repository work tree, its folders are subfolders of that repo.
    static func enclosingRepository(ofRoot root: String) -> String? {
        var current = (root as NSString).deletingLastPathComponent
        while current != "/" && !current.isEmpty {
            var info = stat()
            if lstat(join(current, ".git"), &info) == 0 { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func workTree(ofCommonGitDirectory common: String) -> String {
        (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
    }

    static func readGitFile(in directory: String) -> (content: String, modifiedAt: FileTimestamp)? {
        let path = join(directory, ".git")
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 4096,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return (String(decoding: data, as: UTF8.self),
                FileTimestamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec))
    }

    static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length >= 0 else { return nil }
        return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func directoryURL(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }
}
