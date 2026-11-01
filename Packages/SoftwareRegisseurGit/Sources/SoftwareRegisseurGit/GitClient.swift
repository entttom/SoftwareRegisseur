import Foundation
import SoftwareRegisseurProcess

/// Thin wrapper around the real `git` binary. Every call is `git -C <dir> <global options> <args>`
/// with an explicit argument array (spec L3) and a non-interactive, locale-stable environment.
public struct GitClient: Sendable {
    public let executableURL: URL
    public var environment: ProcessEnvironment
    /// Extra `-c name=value` options passed to every invocation.
    public var configOverrides: [(name: String, value: String)]
    public var timeout: Duration
    private let runner = ProcessRunner()

    public init(
        executableURL: URL,
        environment: ProcessEnvironment = GitClient.defaultEnvironment(),
        configOverrides: [(name: String, value: String)] = [],
        timeout: Duration = .seconds(300)
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.configOverrides = configOverrides
        self.timeout = timeout
    }

    /// Finds `git` via `ExecutableLocator` (LaunchAgent-safe search path, spec J1).
    public static func locate(
        locator: ExecutableLocator = ExecutableLocator(),
        configOverrides: [(name: String, value: String)] = []
    ) throws -> GitClient {
        guard let candidate = try locator.locate("git").preferred else { throw GitError.gitNotFound }
        return GitClient(
            executableURL: candidate.url,
            environment: defaultEnvironment(path: locator.pathEnvironmentValue),
            configOverrides: configOverrides
        )
    }

    /// Minimal environment plus settings that keep git non-interactive and its output parseable.
    public static func defaultEnvironment(path: String = ExecutableLocator().pathEnvironmentValue) -> ProcessEnvironment {
        ProcessEnvironment.minimal(path: path).merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0", // read-only commands must not refresh the user's index
            "GIT_EDITOR": "true",
            "GIT_MERGE_AUTOEDIT": "no",
        ])
    }

    /// Configuration that every invocation of the service carries (SR-SEC-04, SR-SEC-10): repository
    /// hooks, fsmonitor daemons, pagers, the `ext::` transport and commit signing programs from a
    /// (possibly copied, untrusted) repository configuration never run. The service never needs them;
    /// `configOverrides`/`extraConfig` come afterwards and could only re-enable them deliberately.
    public static let hardeningConfig: [(name: String, value: String)] = [
        ("core.hooksPath", "/dev/null"),
        ("core.fsmonitor", "false"),
        ("core.pager", "cat"),
        ("color.ui", "false"),
        ("core.quotePath", "false"),
        ("protocol.ext.allow", "never"),
        // Commits made by Software Regisseur (integration, job-branch leftovers) are never signed, so a
        // repository `gpg.program`/`gpg.*.program` is never executed.
        ("commit.gpgSign", "false"),
        ("tag.gpgSign", "false"),
    ]

    /// Subcommands that can run filter or merge drivers or produce diffs (checkout, index refresh,
    /// merges). For them, drivers defined in the repository's *local* or *worktree* configuration are
    /// neutralised before the call (SR-SEC-10); user-wide drivers such as Git LFS (global/system scope,
    /// trusted per threat-model assumption A1) keep working.
    static let driverSensitiveCommands: Set<String> = [
        "add", "am", "apply", "checkout", "checkout-index", "cherry-pick", "commit", "diff", "diff-files", "diff-index",
        "log", "merge", "mv", "read-tree", "rebase", "reset", "restore", "revert", "rm", "show", "stash", "status",
        "switch", "update-index", "worktree",
    ]

    /// Subcommands that print patches: external diff drivers and textconv filters are always disabled.
    static let diffCommands: Set<String> = ["diff", "log", "show"]

    /// Runs `git` in `directory`. Exit codes outside `acceptedExitCodes` throw `GitError.commandFailed`.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL?,
        input: Data? = nil,
        acceptedExitCodes: Set<Int32> = [0],
        extraConfig: [(name: String, value: String)] = []
    ) async throws -> GitCommandResult {
        var arguments = arguments
        let subcommandIndex = arguments.firstIndex { !$0.hasPrefix("-") }
        let subcommand = subcommandIndex.map { arguments[$0] }
        if let subcommandIndex, let subcommand, Self.diffCommands.contains(subcommand) {
            // `--no-ext-diff`/`--no-textconv` right after the subcommand: valid for diff, log and show.
            let missing = ["--no-ext-diff", "--no-textconv"].filter { !arguments.contains($0) }
            arguments.insert(contentsOf: missing, at: subcommandIndex + 1)
        }
        var driverConfig: [(name: String, value: String)] = []
        if let directory, let subcommand, Self.driverSensitiveCommands.contains(subcommand) {
            driverConfig = try await repositoryDriverOverrides(in: directory)
        }

        var fullArguments: [String] = []
        if let directory {
            fullArguments += ["-C", directory.path(percentEncoded: false)]
        }
        fullArguments.append("--no-pager")
        for (name, value) in Self.hardeningConfig + driverConfig + configOverrides + extraConfig {
            fullArguments += ["-c", "\(name)=\(value)"]
        }
        fullArguments += arguments

        let result = try await runner.run(ProcessRequest(
            executableURL: executableURL,
            arguments: fullArguments,
            workingDirectory: nil,
            environment: environment,
            standardInput: input,
            timeout: timeout
        ))
        switch result.terminationReason {
        case .cancellation: throw CancellationError()
        case .timeout: throw GitError.timedOut(arguments: arguments)
        case .uncaughtSignal:
            throw GitError.commandFailed(arguments: arguments, exitCode: -result.exitStatus,
                                         standardError: SecretRedactor.standard.redact(result.standardErrorString))
        case .exit:
            let output = GitCommandResult(
                exitCode: result.exitStatus,
                standardOutputData: result.standardOutput.data,
                standardError: result.standardErrorString
            )
            guard acceptedExitCodes.contains(result.exitStatus) else {
                throw GitError.commandFailed(arguments: arguments, exitCode: result.exitStatus,
                                             standardError: SecretRedactor.standard.redact(output.standardError))
            }
            return output
        }
    }

    /// Convenience: stdout with the trailing newline removed.
    func output(_ arguments: [String], in directory: URL?) async throws -> String {
        try await run(arguments, in: directory).trimmedOutput
    }

    /// `-c` overrides that disable filter (`clean`/`smudge`/`process`) and merge drivers configured in the
    /// repository's local or worktree configuration (SR-SEC-10). Reading the configuration executes
    /// nothing. A disabled filter passes content through unchanged (`required` is forced off); a
    /// disabled merge driver makes the merge report a conflict instead of running a program.
    /// Driver names that cannot be expressed safely as `-c name=value` are refused.
    public func repositoryDriverOverrides(in directory: URL) async throws -> [(name: String, value: String)] {
        var arguments = ["-C", directory.path(percentEncoded: false), "--no-pager"]
        for (name, value) in Self.hardeningConfig { arguments += ["-c", "\(name)=\(value)"] }
        arguments += ["config", "--show-scope", "--name-only", "--get-regexp", #"^(filter|merge)\..+\.(clean|smudge|process|driver)$"#]
        let result = try await runner.run(ProcessRequest(
            executableURL: executableURL, arguments: arguments, workingDirectory: nil, environment: environment,
            standardInput: nil, timeout: timeout))
        // 1 = no matching key; 128 = not inside a repository (e.g. `git init` target): nothing to neutralise.
        guard result.terminationReason == .exit, result.exitStatus == 0 else { return [] }
        return try Self.driverOverrides(fromScopedNames: result.standardOutputString)
    }

    /// Parses `git config --show-scope --name-only` lines (`<scope>\t<name>`).
    static func driverOverrides(fromScopedNames output: String) throws -> [(name: String, value: String)] {
        var overrides: [(name: String, value: String)] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "local" || parts[0] == "worktree" else { continue }
            let key = parts[1]
            guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: "."), firstDot < lastDot else { continue }
            let section = String(key[..<firstDot])
            let driver = String(key[key.index(after: firstDot)..<lastDot])
            guard !driver.isEmpty, !driver.contains("="),
                  !driver.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw GitError.unsafeRepositoryConfiguration(key)
            }
            guard seen.insert("\(section).\(driver)").inserted else { continue }
            switch section {
            case "filter":
                overrides += [("filter.\(driver).clean", ""), ("filter.\(driver).smudge", ""),
                              ("filter.\(driver).process", ""), ("filter.\(driver).required", "false")]
            case "merge":
                overrides.append(("merge.\(driver).driver", ""))
            default:
                continue
            }
        }
        return overrides
    }
}

public struct GitCommandResult: Sendable, Hashable {
    public let exitCode: Int32
    public let standardOutputData: Data
    public let standardError: String

    public var standardOutput: String { String(decoding: standardOutputData, as: UTF8.self) }
    public var trimmedOutput: String {
        var text = standardOutput
        while text.last == "\n" || text.last == "\r" { text.removeLast() }
        return text
    }
    public var lines: [String] {
        trimmedOutput.isEmpty ? [] : trimmedOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    /// NUL-separated records (for `-z` output), without the trailing empty element.
    public var nulSeparatedFields: [String] {
        var fields = standardOutputData.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        return fields
    }
}

public enum GitError: Error, Sendable, Hashable, CustomStringConvertible {
    case gitNotFound
    case commandFailed(arguments: [String], exitCode: Int32, standardError: String)
    case timedOut(arguments: [String])
    case notARepository(String)
    case malformedOutput(String)
    /// The repository configuration defines a filter/merge driver whose name cannot be neutralised
    /// safely (SR-SEC-10); the command was not run.
    case unsafeRepositoryConfiguration(String)

    public var description: String {
        switch self {
        case .gitNotFound: "git executable not found"
        case .commandFailed(let arguments, let code, let stderr):
            "git \(arguments.first ?? "") failed (\(code)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut(let arguments): "git \(arguments.first ?? "") timed out"
        case .notARepository(let path): "Not a git repository: \(path)"
        case .malformedOutput(let detail): "Unexpected git output: \(detail)"
        case .unsafeRepositoryConfiguration(let key): "Unsafe repository configuration refused: \(key)"
        }
    }
}
