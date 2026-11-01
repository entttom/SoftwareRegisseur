import Darwin
import Foundation

/// Stable repository identity (spec E1 "Repository-ID stabil aus Git-Metadaten, nicht nur aus Namen").
public struct RepositoryIdentity: Sendable, Hashable, Codable {
    /// `git-roots:<sha>[,<sha>…]` or, without commits, `provisional:<dev>-<inode>-<birth>` of the git dir.
    public let value: String
    /// Sorted root commit SHAs (empty for provisional identities).
    public let rootCommits: [String]
    /// `true` while the repository has no commits; the value then changes after the first commit.
    public let isProvisional: Bool
}

public struct GitRemote: Sendable, Hashable, Codable {
    public let name: String
    /// Fetch URL with any embedded password removed (never sync credentials, spec Q1).
    public let fetchURL: String?
    public let pushURL: String?
}

public struct RepositoryInfo: Sendable, Hashable, Codable {
    public enum DefaultBranchSource: String, Sendable, Hashable, Codable {
        /// `refs/remotes/origin/HEAD`.
        case originHead
        /// Existing local branch named like `init.defaultBranch`.
        case initDefaultBranch
        /// Existing local `main` or `master`.
        case conventionalName
        /// The currently checked-out branch.
        case currentBranch
        /// Unborn branch of a repository without commits.
        case unbornHead
    }

    public let rootURL: URL
    public let gitDirectoryURL: URL
    public let isBare: Bool
    public let currentBranch: String?
    public let isDetachedHead: Bool
    public let headCommit: String?
    public let defaultBranch: String?
    public let defaultBranchSource: DefaultBranchSource?
    public let remotes: [GitRemote]
    public let identity: RepositoryIdentity
}

/// Reads repository metadata with read-only git commands; never writes into the repository or its config.
public struct RepositoryInspector: Sendable {
    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public func inspect(_ url: URL) async throws -> RepositoryInfo {
        let directory = url
        let bareCheck = try await git.run(["rev-parse", "--is-bare-repository"], in: directory, acceptedExitCodes: [0, 128])
        guard bareCheck.exitCode == 0 else { throw GitError.notARepository(url.path(percentEncoded: false)) }
        let isBare = bareCheck.trimmedOutput == "true"
        let gitDirectory = URL(filePath: try await git.output(["rev-parse", "--path-format=absolute", "--git-dir"], in: directory),
                               directoryHint: .isDirectory)
        let rootURL: URL
        if isBare {
            rootURL = gitDirectory
        } else {
            rootURL = URL(filePath: try await git.output(["rev-parse", "--show-toplevel"], in: directory), directoryHint: .isDirectory)
        }

        let symbolic = try await git.run(["symbolic-ref", "--quiet", "HEAD"], in: directory, acceptedExitCodes: [0, 1])
        let headRef = symbolic.exitCode == 0 ? symbolic.trimmedOutput : nil
        let currentBranch = headRef.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
        let head = try await git.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: directory, acceptedExitCodes: [0, 1])
        let headCommit = head.exitCode == 0 ? head.trimmedOutput : nil

        let (defaultBranch, source) = try await determineDefaultBranch(
            in: directory, currentBranch: currentBranch, hasCommits: headCommit != nil)
        let remotes = try await readRemotes(in: directory)
        let identity = try await identity(of: directory, gitDirectory: gitDirectory, hasCommits: headCommit != nil)

        return RepositoryInfo(
            rootURL: rootURL,
            gitDirectoryURL: gitDirectory,
            isBare: isBare,
            currentBranch: currentBranch,
            isDetachedHead: headRef == nil,
            headCommit: headCommit,
            defaultBranch: defaultBranch,
            defaultBranchSource: source,
            remotes: remotes,
            identity: identity
        )
    }

    /// Root commits reachable from HEAD; provisional filesystem identity for repositories without commits.
    public func identity(of directory: URL) async throws -> RepositoryIdentity {
        let gitDirectory = URL(filePath: try await git.output(["rev-parse", "--path-format=absolute", "--git-dir"], in: directory))
        let head = try await git.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: directory, acceptedExitCodes: [0, 1])
        return try await identity(of: directory, gitDirectory: gitDirectory, hasCommits: head.exitCode == 0)
    }

    private func identity(of directory: URL, gitDirectory: URL, hasCommits: Bool) async throws -> RepositoryIdentity {
        if hasCommits {
            let roots = try await git.run(["rev-list", "--max-parents=0", "HEAD"], in: directory).lines.sorted()
            if !roots.isEmpty {
                return RepositoryIdentity(value: "git-roots:" + roots.joined(separator: ","), rootCommits: roots, isProvisional: false)
            }
        }
        var info = stat()
        guard stat(gitDirectory.path(percentEncoded: false), &info) == 0 else {
            throw GitError.notARepository(directory.path(percentEncoded: false))
        }
        return RepositoryIdentity(
            value: "provisional:\(info.st_dev)-\(info.st_ino)-\(info.st_birthtimespec.tv_sec)",
            rootCommits: [],
            isProvisional: true
        )
    }

    private func determineDefaultBranch(
        in directory: URL,
        currentBranch: String?,
        hasCommits: Bool
    ) async throws -> (String?, RepositoryInfo.DefaultBranchSource?) {
        let originHead = try await git.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: directory,
                                           acceptedExitCodes: [0, 1, 128])
        if originHead.exitCode == 0, originHead.trimmedOutput.hasPrefix("refs/remotes/origin/") {
            return (String(originHead.trimmedOutput.dropFirst("refs/remotes/origin/".count)), .originHead)
        }
        let configured = try await git.run(["config", "--get", "init.defaultBranch"], in: directory, acceptedExitCodes: [0, 1])
        if configured.exitCode == 0, !configured.trimmedOutput.isEmpty,
           try await branchExists(configured.trimmedOutput, in: directory) {
            return (configured.trimmedOutput, .initDefaultBranch)
        }
        for name in ["main", "master"] where try await branchExists(name, in: directory) {
            return (name, .conventionalName)
        }
        if let currentBranch {
            return (currentBranch, hasCommits ? .currentBranch : .unbornHead)
        }
        return (nil, nil)
    }

    func branchExists(_ name: String, in directory: URL) async throws -> Bool {
        try await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: directory,
                          acceptedExitCodes: [0, 1]).exitCode == 0
    }

    private func readRemotes(in directory: URL) async throws -> [GitRemote] {
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        var order: [String] = []
        for line in try await git.run(["remote", "-v"], in: directory).lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0]
            if !order.contains(name) { order.append(name) }
            if parts[1].hasSuffix(" (fetch)") {
                fetch[name] = Self.removingPassword(String(parts[1].dropLast(" (fetch)".count)))
            } else if parts[1].hasSuffix(" (push)") {
                push[name] = Self.removingPassword(String(parts[1].dropLast(" (push)".count)))
            }
        }
        return order.map { GitRemote(name: $0, fetchURL: fetch[$0], pushURL: push[$0]) }
    }

    static func removingPassword(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.password != nil else { return url }
        components.password = nil
        return components.string ?? url
    }
}
