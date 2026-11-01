import Foundation
import SoftwareRegisseurGit
import SoftwareRegisseurProcess

/// Temporary directory with helpers to build real git repositories. Isolated from the user's
/// global/system git configuration.
struct GitSandbox {
    let root: URL
    let git: GitClient

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appending(path: "SRGitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = try PathGuard.canonicalize(raw)
        let located = try GitClient.locate()
        git = GitClient(
            executableURL: located.executableURL,
            environment: located.environment.merging([
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
            ]),
            configOverrides: [
                ("user.name", "Software Regisseur Tests"),
                ("user.email", "tests@software-regisseur.invalid"),
                ("init.defaultBranch", "main"),
                ("commit.gpgsign", "false"),
                ("protocol.file.allow", "always"),
            ]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative, directoryHint: .isDirectory)
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ relative: String, _ content: String) throws {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appending(path: relative, directoryHint: .notDirectory), encoding: .utf8)
    }

    /// Creates a repository; with `commit` it gets a README and an initial commit.
    @discardableResult
    func makeRepository(_ relative: String, commit: Bool = true) async throws -> URL {
        let directory = try makeDirectory(relative)
        try await git.run(["init", "--quiet"], in: directory)
        if commit {
            try write("\(relative)/README.md", "# \(relative)\n")
            try await commitAll(directory, "Initial commit")
        }
        return directory
    }

    @discardableResult
    func commitAll(_ repository: URL, _ message: String) async throws -> String {
        try await git.run(["add", "-A"], in: repository)
        try await git.run(["commit", "--quiet", "-m", message], in: repository)
        return try await head(repository)
    }

    func head(_ repository: URL, _ ref: String = "HEAD") async throws -> String {
        try await git.run(["rev-parse", ref], in: repository).trimmedOutput
    }

    func output(_ arguments: [String], in directory: URL) async throws -> String {
        try await git.run(arguments, in: directory).trimmedOutput
    }
}
