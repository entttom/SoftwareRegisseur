import Foundation

/// `ProjectSettings.integrationStrategy` (ADR-0015).
public enum IntegrationStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    case squash
    case mergeCommit
    case cherryPick
}

public struct IntegrationRequest: Sendable, Hashable {
    /// Main working tree (or any worktree) of the repository.
    public var repository: URL
    public var defaultBranch: String
    public var jobBranch: String
    public var strategy: IntegrationStrategy
    /// Message for the squash or merge commit (ignored for cherry-pick, which keeps the original messages).
    public var commitMessage: String
    /// Directory for the temporary integration worktree; must be outside the scan roots.
    public var temporaryWorktreeParent: URL
    /// Kept for source compatibility only: repository hooks never run for commands of the service
    /// (`GitClient.hardeningConfig`, SR-SEC-04), whatever this value is.
    public var runHooks: Bool
    /// Repository-relative folders (e.g. ADR folder, requests root) whose uncommitted changes in the
    /// default-branch worktree do not block the integration (ADR-0024). Untracked and modified files
    /// below these prefixes are tolerated; conflicts and anything else still block. If the integration
    /// would create, modify or delete such an uncommitted file, it aborts with
    /// `IntegrationError.uncommittedDocumentsWouldBeOverwritten` before the default branch moves.
    /// Empty, absolute, `.` or traversing entries are ignored (they never widen the exemption).
    public var ignoredUncommittedPaths: [String]
    /// Commit the job branch had when it was reviewed (SR-SEC-06). When set, the integration refuses
    /// with `IntegrationError.jobBranchMoved` if the branch tip differs, so commits added after the
    /// review are never integrated unreviewed.
    public var expectedJobTip: String?

    public init(
        repository: URL,
        defaultBranch: String,
        jobBranch: String,
        strategy: IntegrationStrategy = .squash,
        commitMessage: String,
        temporaryWorktreeParent: URL,
        runHooks: Bool = false,
        ignoredUncommittedPaths: [String] = [],
        expectedJobTip: String? = nil
    ) {
        self.repository = repository
        self.defaultBranch = defaultBranch
        self.jobBranch = jobBranch
        self.strategy = strategy
        self.commitMessage = commitMessage
        self.temporaryWorktreeParent = temporaryWorktreeParent
        self.runHooks = runHooks
        self.ignoredUncommittedPaths = ignoredUncommittedPaths
        self.expectedJobTip = expectedJobTip
    }
}

public struct IntegrationResult: Sendable, Hashable, Codable {
    public let strategy: IntegrationStrategy
    /// New tip of the default branch – stored in the review as proof of integration (ADR-0015).
    public let commitSHA: String
    public let previousDefaultBranchCommit: String
    /// Job branch commits that were integrated (oldest first).
    public let integratedCommits: [String]
    /// Worktree where the default branch is checked out and was fast-forwarded, if any.
    public let updatedWorktree: URL?
}

public enum IntegrationError: Error, Sendable, Hashable {
    case branchNotFound(String)
    case nothingToIntegrate
    case emptyCommitMessage
    /// The worktree that has the default branch checked out has local changes; nothing was touched.
    case defaultBranchWorktreeDirty(path: String, status: GitStatus)
    /// The job branch is checked out in a worktree with uncommitted changes that would be left out.
    case jobWorktreeDirty(path: String, status: GitStatus)
    /// Integration conflicts; the temporary worktree was cleaned up and nothing changed.
    case conflicts(files: [String])
    case cherryPickOfMergeCommitsUnsupported([String])
    /// The default branch moved while integrating; nothing changed.
    case defaultBranchMoved(expected: String, actual: String)
    case repositoryAlreadyExists(String)
    /// The integration would create, modify or delete files below the ignored document paths that are
    /// uncommitted (untracked or modified) in the default-branch worktree at `path` (ADR-0024). Nothing
    /// was changed; `files` are repository-relative and sorted.
    case uncommittedDocumentsWouldBeOverwritten(path: String, files: [String])
    /// The job branch no longer points at the reviewed commit (SR-SEC-06); nothing was changed.
    case jobBranchMoved(expected: String, actual: String)
}

public struct ChangedFile: Sendable, Hashable, Codable {
    /// Single-letter status from `--name-status` (A, M, D, R, C, T, U).
    public let status: String
    public let path: String
    public let originalPath: String?
    /// `nil` for binary files.
    public let additions: Int?
    public let deletions: Int?
    public var isBinary: Bool { additions == nil && deletions == nil }
}

public struct DiffSummary: Sendable, Hashable, Codable {
    public let base: String
    public let head: String
    public let files: [ChangedFile]
    public var totalAdditions: Int { files.compactMap(\.additions).reduce(0, +) }
    public var totalDeletions: Int { files.compactMap(\.deletions).reduce(0, +) }
}

/// Integrates reviewed job branches into the default branch (spec M1 step 5, ADR-0015).
///
/// All merging happens in a dedicated temporary worktree detached at the default branch tip. The
/// default branch is then advanced with a compare-and-swap (`update-ref <new> <old>`) or, when it is
/// checked out in a *clean* worktree, with `merge --ff-only` there. Never pushes, never forces,
/// never resets user worktrees.
public struct IntegrationService: Sendable {
    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public func integrate(_ request: IntegrationRequest) async throws -> IntegrationResult {
        let repository = request.repository
        guard request.strategy == .cherryPick || !request.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationError.emptyCommitMessage
        }
        let oldTip = try await resolveBranch(request.defaultBranch, in: repository)
        let jobTip = try await resolveBranch(request.jobBranch, in: repository)
        if let expected = request.expectedJobTip, expected != jobTip {
            throw IntegrationError.jobBranchMoved(expected: expected, actual: jobTip)
        }
        let pending = try await git.run(["rev-list", "--reverse", "\(oldTip)..\(jobTip)"], in: repository).lines
        guard !pending.isEmpty else { throw IntegrationError.nothingToIntegrate }

        // Safety checks before anything is created.
        let documentPrefixes = Self.normalizedPathPrefixes(request.ignoredUncommittedPaths)
        let worktrees = try await WorktreeManager.listWorktrees(git: git, repository: repository)
        let defaultCheckout = worktrees.first { $0.branchRef == "refs/heads/\(request.defaultBranch)" && !$0.isBare }
        if let defaultCheckout {
            let status = try await git.status(of: defaultCheckout.url)
            guard Self.blockingEntries(of: status, ignoring: documentPrefixes).isEmpty else {
                throw IntegrationError.defaultBranchWorktreeDirty(path: defaultCheckout.url.plainPath, status: status)
            }
        }
        if let jobCheckout = worktrees.first(where: { $0.branchRef == "refs/heads/\(request.jobBranch)" }) {
            let status = try await git.status(of: jobCheckout.url)
            guard !status.hasTrackedChanges, status.untrackedPaths.isEmpty else {
                throw IntegrationError.jobWorktreeDirty(path: jobCheckout.url.plainPath, status: status)
            }
        }
        if request.strategy == .cherryPick {
            let merges = try await git.run(["rev-list", "--merges", "\(oldTip)..\(jobTip)"], in: repository).lines
            guard merges.isEmpty else { throw IntegrationError.cherryPickOfMergeCommitsUnsupported(merges) }
        }

        // Redundant with `GitClient.hardeningConfig`; kept explicit for this security-relevant path.
        let hookConfig: [(name: String, value: String)] = [("core.hooksPath", "/dev/null"), ("commit.gpgSign", "false")]
        try FileManager.default.createDirectory(at: request.temporaryWorktreeParent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = try PathGuard.canonicalize(request.temporaryWorktreeParent)
            .appending(path: "integration-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try await git.run(["worktree", "add", "--detach", "--", temporary.plainPath, oldTip], in: repository, extraConfig: hookConfig)

        let newCommit: String
        do {
            newCommit = try await performStrategy(request, in: temporary, oldTip: oldTip, jobTip: jobTip, pending: pending, hookConfig: hookConfig)
        } catch {
            await discardTemporaryWorktree(temporary, repository: repository)
            throw error
        }
        await discardTemporaryWorktree(temporary, repository: repository)

        // The job branch must still be the reviewed one when the default branch moves (SR-SEC-06).
        if request.expectedJobTip != nil {
            let currentJobTip = try await resolveBranch(request.jobBranch, in: repository)
            guard currentJobTip == jobTip else { throw IntegrationError.jobBranchMoved(expected: jobTip, actual: currentJobTip) }
        }

        // Advance the default branch without touching dirty trees.
        if let defaultCheckout {
            let status = try await git.status(of: defaultCheckout.url)
            guard Self.blockingEntries(of: status, ignoring: documentPrefixes).isEmpty else {
                throw IntegrationError.defaultBranchWorktreeDirty(path: defaultCheckout.url.plainPath, status: status)
            }
            let currentTip = try await resolveBranch(request.defaultBranch, in: repository)
            guard currentTip == oldTip else { throw IntegrationError.defaultBranchMoved(expected: oldTip, actual: currentTip) }
            // ADR-0024: never overwrite uncommitted request/ADR files; abort before anything moves.
            let uncommittedDocuments = Self.uncommittedPaths(of: status, under: documentPrefixes)
            if !uncommittedDocuments.isEmpty {
                let changed = try await git.run(["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", oldTip, newCommit, "--"],
                                                in: repository).nulSeparatedFields
                let collisions = uncommittedDocuments.filter { dirty in changed.contains { Self.pathsOverlap(dirty, $0) } }
                if !collisions.isEmpty {
                    throw IntegrationError.uncommittedDocumentsWouldBeOverwritten(
                        path: defaultCheckout.url.plainPath, files: collisions.sorted())
                }
            }
            try await git.run(["merge", "--ff-only", "--no-edit", newCommit], in: defaultCheckout.url, extraConfig: hookConfig)
        } else {
            let update = try await git.run(
                ["update-ref", "-m", "software-regisseur: integrate \(request.jobBranch) (\(request.strategy.rawValue))",
                 "refs/heads/\(request.defaultBranch)", newCommit, oldTip],
                in: repository, acceptedExitCodes: [0, 1, 128])
            if update.exitCode != 0 {
                let actual = (try? await resolveBranch(request.defaultBranch, in: repository)) ?? "?"
                throw IntegrationError.defaultBranchMoved(expected: oldTip, actual: actual)
            }
        }
        return IntegrationResult(
            strategy: request.strategy,
            commitSHA: newCommit,
            previousDefaultBranchCommit: oldTip,
            integratedCommits: pending,
            updatedWorktree: defaultCheckout?.url
        )
    }

    private func performStrategy(
        _ request: IntegrationRequest,
        in worktree: URL,
        oldTip: String,
        jobTip: String,
        pending: [String],
        hookConfig: [(name: String, value: String)]
    ) async throws -> String {
        switch request.strategy {
        case .squash:
            let merge = try await git.run(["merge", "--squash", "--no-commit", jobTip], in: worktree,
                                          acceptedExitCodes: [0, 1], extraConfig: hookConfig)
            if merge.exitCode != 0 { throw IntegrationError.conflicts(files: try await conflictedFiles(in: worktree)) }
            let staged = try await git.run(["diff", "--cached", "--quiet"], in: worktree, acceptedExitCodes: [0, 1])
            guard staged.exitCode == 1 else { throw IntegrationError.nothingToIntegrate }
            try await git.run(["commit", "--quiet", "-m", request.commitMessage], in: worktree, extraConfig: hookConfig)
        case .mergeCommit:
            let merge = try await git.run(["merge", "--no-ff", "--no-edit", "-m", request.commitMessage, jobTip],
                                          in: worktree, acceptedExitCodes: [0, 1], extraConfig: hookConfig)
            if merge.exitCode != 0 { throw IntegrationError.conflicts(files: try await conflictedFiles(in: worktree)) }
        case .cherryPick:
            let pick = try await git.run(["cherry-pick", "--empty=drop"] + pending, in: worktree,
                                         acceptedExitCodes: [0, 1], extraConfig: hookConfig)
            if pick.exitCode != 0 { throw IntegrationError.conflicts(files: try await conflictedFiles(in: worktree)) }
        }
        // A result that changes no content (e.g. job already squashed earlier) is not an integration.
        let newTree = try await git.output(["rev-parse", "--verify", "HEAD^{tree}"], in: worktree)
        let oldTree = try await git.output(["rev-parse", "--verify", "\(oldTip)^{tree}"], in: worktree)
        guard newTree != oldTree else { throw IntegrationError.nothingToIntegrate }
        return try await git.output(["rev-parse", "--verify", "HEAD^{commit}"], in: worktree)
    }

    // MARK: - Uncommitted document paths (ADR-0024)

    /// Normalised repository-relative prefixes; drops entries that could widen the exemption to the
    /// whole repository or outside of it.
    static func normalizedPathPrefixes(_ raw: [String]) -> [String] {
        var result: [String] = []
        for entry in raw {
            var path = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path != ".", !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { continue }
            if !result.contains(path) { result.append(path) }
        }
        return result
    }

    static func isPath(_ path: String, under prefixes: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Entries that block the integration: everything except untracked/modified files whose path (and
    /// rename source) lie below a document prefix. Conflicts always block; ignored files never do.
    static func blockingEntries(of status: GitStatus, ignoring prefixes: [String]) -> [GitStatus.Entry] {
        status.entries.filter { entry in
            switch entry.kind {
            case .ignored: return false
            case .unmerged: return true
            case .untracked, .changed, .renamedOrCopied:
                guard !prefixes.isEmpty, entry.submoduleState == nil else { return true }
                return !(isPath(entry.path, under: prefixes) && (entry.originalPath.map { isPath($0, under: prefixes) } ?? true))
            }
        }
    }

    /// Uncommitted paths (incl. rename sources) below the document prefixes.
    static func uncommittedPaths(of status: GitStatus, under prefixes: [String]) -> [String] {
        guard !prefixes.isEmpty else { return [] }
        var paths: Set<String> = []
        for entry in status.entries where [.untracked, .changed, .renamedOrCopied].contains(entry.kind) {
            for path in [entry.path, entry.originalPath].compactMap({ $0 }) where isPath(path, under: prefixes) {
                paths.insert(path)
            }
        }
        return Array(paths)
    }

    /// Same path or one is a directory of the other. Case-insensitive, because the default APFS volume
    /// is, so a case-only difference would still overwrite the file.
    static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased(), b = rhs.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private func conflictedFiles(in worktree: URL) async throws -> [String] {
        try await git.status(of: worktree).entries.filter { $0.kind == .unmerged }.map(\.path)
    }

    /// Removes the temporary integration worktree. It is owned by Software Regisseur, so aborting
    /// in-progress operations and resetting *this* worktree is safe.
    private func discardTemporaryWorktree(_ worktree: URL, repository: URL) async {
        for abort in [["merge", "--abort"], ["cherry-pick", "--abort"], ["reset", "--hard", "--quiet"], ["clean", "-fdq"]] {
            _ = try? await git.run(abort, in: worktree, acceptedExitCodes: [0, 1, 128])
        }
        _ = try? await git.run(["worktree", "remove", "--", worktree.plainPath], in: repository, acceptedExitCodes: [0])
        // Only ever forced for our own temporary worktree, never for user worktrees.
        if FileManager.default.fileExists(atPath: worktree.plainPath) {
            _ = try? await git.run(["worktree", "remove", "--force", "--", worktree.plainPath], in: repository)
        }
        _ = try? await git.run(["worktree", "prune"], in: repository)
    }

    private func resolveBranch(_ name: String, in repository: URL) async throws -> String {
        let result = try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)^{commit}"], in: repository,
                                       acceptedExitCodes: [0, 1])
        guard result.exitCode == 0 else { throw IntegrationError.branchNotFound(name) }
        return result.trimmedOutput
    }

    // MARK: - Diff

    /// Files changed on `head` since its merge base with `base` (`base...head`).
    public func diffSummary(repository: URL, base: String, head: String) async throws -> DiffSummary {
        let range = "\(base)...\(head)"
        let nameStatus = try await git.run(["diff", "--name-status", "-z", "-M", "--no-ext-diff", range, "--"], in: repository)
            .nulSeparatedFields
        let numstat = try await git.run(["diff", "--numstat", "-z", "-M", "--no-ext-diff", range, "--"], in: repository)
            .nulSeparatedFields

        var counts: [String: (Int?, Int?)] = [:]
        var index = 0
        while index < numstat.count {
            let parts = numstat[index].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            index += 1
            guard parts.count >= 3 else { continue }
            var path = parts[2]
            if path.isEmpty, index + 1 < numstat.count { // rename: "a\td\t" NUL old NUL new
                path = numstat[index + 1]
                index += 2
            }
            counts[path] = (Int(parts[0]), Int(parts[1]))
        }

        var files: [ChangedFile] = []
        index = 0
        while index < nameStatus.count {
            let code = nameStatus[index]
            index += 1
            guard let letter = code.first else { continue }
            var originalPath: String?
            if letter == "R" || letter == "C" {
                guard index + 1 < nameStatus.count else { break }
                originalPath = nameStatus[index]
                index += 1
            }
            guard index < nameStatus.count else { break }
            let path = nameStatus[index]
            index += 1
            let count = counts[path]
            files.append(ChangedFile(status: String(letter), path: path, originalPath: originalPath,
                                     additions: count?.0, deletions: count?.1))
        }
        return DiffSummary(base: base, head: head, files: files)
    }

    public func changedFiles(repository: URL, base: String, head: String) async throws -> [String] {
        try await diffSummary(repository: repository, base: base, head: head).files.map(\.path)
    }
}

/// Explicit repository creation (spec E2: `git init` only after the user agreed).
public struct RepositoryInitializer: Sendable {
    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    /// Runs `git init` in an existing directory; refuses if a `.git` entry already exists there.
    public func initRepository(at directory: URL, initialBranch: String = "main") async throws {
        let path = try PathGuard.canonicalize(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.plainPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathGuardError.parentNotFound(path.plainPath)
        }
        let gitEntry = path.appending(path: ".git").plainPath
        if FileManager.default.fileExists(atPath: gitEntry) || (try? FileManager.default.destinationOfSymbolicLink(atPath: gitEntry)) != nil {
            throw IntegrationError.repositoryAlreadyExists(path.plainPath)
        }
        let check = try await git.run(["check-ref-format", "--branch", initialBranch], in: nil, acceptedExitCodes: [0, 1, 128])
        guard check.exitCode == 0 else { throw WorktreeError.invalidBranchName(initialBranch) }
        try await git.run(["init", "--quiet", "--initial-branch=\(initialBranch)", "--", path.plainPath], in: nil)
    }
}

extension WorktreeManager {
    static func listWorktrees(git: GitClient, repository: URL) async throws -> [GitWorktree] {
        GitWorktree.parseList(try await git.run(["worktree", "list", "--porcelain", "-z"], in: repository).nulSeparatedFields)
    }
}
