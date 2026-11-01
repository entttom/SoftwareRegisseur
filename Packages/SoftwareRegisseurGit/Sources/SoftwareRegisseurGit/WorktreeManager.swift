import Foundation

/// One entry of `git worktree list --porcelain -z`.
public struct GitWorktree: Sendable, Hashable, Codable {
    public let url: URL
    public let headCommit: String?
    /// Full ref, e.g. `refs/heads/main`; `nil` when detached or bare.
    public let branchRef: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    /// The first entry is the main working tree (or the bare repository).
    public let isMain: Bool

    public var branchName: String? {
        branchRef.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
    }

    static func parseList(_ fields: [String]) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var current: [String: String] = [:]
        var flags = Set<String>()
        func flush() {
            guard let path = current["worktree"] else { return }
            result.append(GitWorktree(
                url: URL(filePath: path, directoryHint: .isDirectory),
                headCommit: current["HEAD"],
                branchRef: current["branch"],
                isBare: flags.contains("bare"),
                isDetached: flags.contains("detached"),
                isLocked: flags.contains("locked") || current["locked"] != nil,
                lockReason: current["locked"],
                isPrunable: flags.contains("prunable") || current["prunable"] != nil,
                isMain: result.isEmpty
            ))
            current = [:]
            flags = []
        }
        for field in fields {
            if field.isEmpty {
                flush()
                continue
            }
            let parts = field.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 { current[parts[0]] = parts[1] } else { flags.insert(parts[0]) }
        }
        flush()
        return result
    }
}

public struct CreatedWorktree: Sendable, Hashable, Codable {
    public let url: URL
    public let branchName: String
    public let baseCommit: String
}

public enum WorktreeError: Error, Sendable, Hashable {
    case invalidIdentifier(String)
    case invalidBranchName(String)
    case baseDirectoryInsideScanRoot(base: String, root: String)
    case baseDirectoryInsideRepository(String)
    case targetExists(String)
    case branchExists(String)
    case unknownBaseRef(String)
    case notAWorktree(String)
    case cannotRemoveMainWorktree(String)
    case dirty(path: String, status: GitStatus)
    /// The path is not a linked worktree that Software Regisseur created below its worktree base
    /// (SR-SEC-02); nothing was written. `reason` is a short English diagnostic.
    case notAManagedWorktree(path: String, reason: String)
}

/// Creates, lists and removes agent worktrees (spec L2, ADR-0007). Never deletes branches.
public struct WorktreeManager: Sendable {
    public static let branchPrefix = "software-regisseur"

    public let git: GitClient
    /// Canonical directory holding all agent worktrees; must be outside the scan roots.
    public let worktreesBaseDirectory: URL

    /// - Parameter scanRoots: Stammordner of the recursive scan; the base directory must not lie inside them.
    public init(git: GitClient, worktreesBaseDirectory: URL, scanRoots: [URL]) throws {
        let base = try PathGuard.canonicalize(worktreesBaseDirectory)
        for root in scanRoots {
            let canonicalRoot = try PathGuard.canonicalize(root)
            if PathGuard.isSameOrDescendant(base, of: canonicalRoot) {
                throw WorktreeError.baseDirectoryInsideScanRoot(base: base.plainPath, root: canonicalRoot.plainPath)
            }
        }
        self.git = git
        self.worktreesBaseDirectory = base
    }

    /// `software-regisseur/<task-id>/<job-short-id>` after validating both components.
    public static func branchName(taskID: String, jobShortID: String) throws(WorktreeError) -> String {
        try validateIdentifier(taskID)
        try validateIdentifier(jobShortID)
        return "\(branchPrefix)/\(taskID)/\(jobShortID)"
    }

    static func validateIdentifier(_ value: String) throws(WorktreeError) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard (1...64).contains(value.count),
              value.allSatisfy({ allowed.contains($0) }),
              let first = value.first, first.isLetter || first.isNumber,
              !value.contains(".."), !value.hasSuffix("."), !value.hasSuffix(".lock") else {
            throw .invalidIdentifier(value)
        }
    }

    /// Directory used for a job: `<base>/<repo-name>-<hash>/<task-id>-<job-short-id>`.
    public func worktreeURL(repository: URL, taskID: String, jobShortID: String) throws -> URL {
        try Self.validateIdentifier(taskID)
        try Self.validateIdentifier(jobShortID)
        let repositoryPath = try PathGuard.canonicalize(repository).plainPath
        let name = (repositoryPath as NSString).lastPathComponent
        let safeName = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(48))
        let folder = "\(safeName)-\(Self.shortHash(repositoryPath))"
        return worktreesBaseDirectory
            .appending(path: folder, directoryHint: .isDirectory)
            .appending(path: "\(taskID)-\(jobShortID)", directoryHint: .isDirectory)
    }

    /// Creates a new branch at `baseRef` checked out in a fresh worktree. Refuses if the target
    /// directory or the branch already exists.
    public func createWorktree(
        repository: URL,
        taskID: String,
        jobShortID: String,
        baseRef: String
    ) async throws -> CreatedWorktree {
        let branch = try Self.branchName(taskID: taskID, jobShortID: jobShortID)
        let check = try await git.run(["check-ref-format", "--branch", branch], in: repository, acceptedExitCodes: [0, 1, 128])
        guard check.exitCode == 0 else { throw WorktreeError.invalidBranchName(branch) }

        let repositoryRoot = try PathGuard.canonicalize(repository)
        if PathGuard.isSameOrDescendant(worktreesBaseDirectory, of: repositoryRoot) {
            throw WorktreeError.baseDirectoryInsideRepository(worktreesBaseDirectory.plainPath)
        }
        let target = try worktreeURL(repository: repository, taskID: taskID, jobShortID: jobShortID)
        if FileManager.default.fileExists(atPath: target.plainPath) || (try? FileManager.default.destinationOfSymbolicLink(atPath: target.plainPath)) != nil {
            throw WorktreeError.targetExists(target.plainPath)
        }
        let branchCheck = try await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository, acceptedExitCodes: [0, 1])
        guard branchCheck.exitCode == 1 else { throw WorktreeError.branchExists(branch) }
        let base = try await git.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(baseRef)^{commit}"], in: repository,
                                     acceptedExitCodes: [0, 1])
        guard base.exitCode == 0 else { throw WorktreeError.unknownBaseRef(baseRef) }
        let baseCommit = base.trimmedOutput

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try await git.run(["worktree", "add", "--no-track", "-b", branch, "--", target.plainPath, baseCommit], in: repository)
        return CreatedWorktree(url: target, branchName: branch, baseCommit: baseCommit)
    }

    /// SR-SEC-02: checks a host-computed job worktree before the service runs the agent or writes
    /// (`git add`/`git commit`) in it. Requires a linked worktree (never the main working tree, never a
    /// bare repository) strictly below `worktreesBaseDirectory`, registered in `repository`, with the
    /// expected `software-regisseur/…` branch checked out, whose own git directory differs from the
    /// common one. Returns the verified entry.
    @discardableResult
    public func verifyManagedWorktree(_ worktree: URL, repository: URL, expectedBranch: String) async throws -> GitWorktree {
        let canonical = try PathGuard.canonicalize(worktree)
        let path = canonical.plainPath
        func refuse(_ reason: String) -> WorktreeError { .notAManagedWorktree(path: path, reason: reason) }
        guard PathGuard.isSameOrDescendant(canonical, of: worktreesBaseDirectory), path != worktreesBaseDirectory.plainPath else {
            throw refuse("outside the worktree base directory")
        }
        guard expectedBranch.hasPrefix(Self.branchPrefix + "/") else { throw refuse("branch without \(Self.branchPrefix)/ prefix") }
        let repositoryRoot = try PathGuard.canonicalize(repository)
        guard !PathGuard.isSameOrDescendant(canonical, of: repositoryRoot) else { throw refuse("inside the repository") }
        let entries = try await list(repository: repository)
        guard let entry = entries.first(where: { ((try? PathGuard.canonicalize($0.url)) ?? $0.url).plainPath == path }) else {
            throw refuse("not registered as a worktree of the repository")
        }
        guard !entry.isMain, !entry.isBare else { throw refuse("main working tree") }
        guard entry.branchRef == "refs/heads/\(expectedBranch)" else { throw refuse("unexpected branch \(entry.branchRef ?? "detached")") }
        let gitDirectory = try await git.output(["rev-parse", "--path-format=absolute", "--git-dir"], in: canonical)
        let commonDirectory = try await git.output(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: canonical)
        let topLevel = try await git.output(["rev-parse", "--show-toplevel"], in: canonical)
        let resolvedGitDirectory = ((try? PathGuard.canonicalize(URL(filePath: gitDirectory))) ?? URL(filePath: gitDirectory)).plainPath
        let resolvedCommonDirectory = ((try? PathGuard.canonicalize(URL(filePath: commonDirectory))) ?? URL(filePath: commonDirectory)).plainPath
        guard resolvedGitDirectory != resolvedCommonDirectory else { throw refuse("not a linked worktree") }
        guard ((try? PathGuard.canonicalize(URL(filePath: topLevel, directoryHint: .isDirectory))) ?? URL(filePath: topLevel)).plainPath == path else {
            throw refuse("working directory is not the worktree root")
        }
        return entry
    }

    public func list(repository: URL) async throws -> [GitWorktree] {
        GitWorktree.parseList(try await git.run(["worktree", "list", "--porcelain", "-z"], in: repository).nulSeparatedFields)
    }

    /// Removes a linked worktree. Refuses dirty worktrees (tracked changes or untracked files) unless
    /// `force` is explicitly `true`. The branch is always kept (ADR-0015).
    public func removeWorktree(at worktree: URL, repository: URL, force: Bool = false) async throws {
        let target = try PathGuard.canonicalize(worktree).plainPath
        let worktrees = try await list(repository: repository)
        guard let entry = worktrees.first(where: { ((try? PathGuard.canonicalize($0.url)) ?? $0.url).plainPath == target }) else {
            throw WorktreeError.notAWorktree(target)
        }
        guard !entry.isMain else { throw WorktreeError.cannotRemoveMainWorktree(target) }
        if !force, FileManager.default.fileExists(atPath: target) {
            let status = try await git.status(of: entry.url)
            guard status.isClean else { throw WorktreeError.dirty(path: target, status: status) }
        }
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments += ["--", target]
        try await git.run(arguments, in: repository)
    }

    static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(String(hash, radix: 16).suffix(8))
    }
}
