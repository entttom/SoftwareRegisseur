import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess
@testable import SoftwareRegisseurWorkspace

/// Real temporary folder (canonical path) with an isolated git configuration.
final class Sandbox: @unchecked Sendable {
    let root: URL
    let git: GitClient

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appending(path: "SRWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = try PathGuard.canonicalize(raw)
        let located = try GitClient.locate()
        git = GitClient(
            executableURL: located.executableURL,
            environment: located.environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]),
            configOverrides: [
                ("user.name", "Software Regisseur Tests"), ("user.email", "tests@software-regisseur.invalid"),
                ("init.defaultBranch", "main"), ("commit.gpgsign", "false"),
            ]
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { root.appending(path: relative) }

    @discardableResult
    func mkdir(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ relative: String, _ content: String) throws {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: url(relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relative).path(percentEncoded: false))
    }

    @discardableResult
    func repository(_ relative: String, commit: Bool = true) async throws -> URL {
        let directory = try mkdir(relative)
        try await git.run(["init", "--quiet"], in: directory)
        if commit {
            try write("\(relative)/README.md", "# \(relative)\n")
            try await commitAll(directory)
        }
        return directory
    }

    func commitAll(_ repository: URL, _ message: String = "commit") async throws {
        try await git.run(["add", "-A"], in: repository)
        try await git.run(["commit", "--quiet", "-m", message], in: repository)
    }

    func gitOutput(_ arguments: [String], in directory: URL) async throws -> String {
        try await git.run(arguments, in: directory).trimmedOutput
    }
}

/// Fixed clock that can be advanced.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval = 60) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

struct Harness {
    let sandbox: Sandbox
    let database: AppDatabase
    let clock: TestClock
    let environment: WorkspaceEnvironment
    let hostId: HostID

    init(git: Bool = true) throws {
        sandbox = try Sandbox()
        database = try AppDatabase.inMemory()
        clock = TestClock()
        hostId = HostID()
        let clock = clock
        environment = WorkspaceEnvironment(
            database: database, hostId: hostId, git: git ? sandbox.git : nil,
            timeZone: TimeZone(identifier: "Europe/Vienna")!, now: { clock.now }
        )
    }

    /// Project linked to `folder` (created as git repository when `git` is true).
    func project(_ folder: String, git: Bool = true, settings: ProjectSettings? = nil) async throws -> (Project, URL) {
        let url = git ? try await sandbox.repository(folder) : try sandbox.mkdir(folder)
        let settings = settings ?? ProjectSettings(updatedAt: clock.now)
        let project = Project(name: folder, repositoryKind: git ? .gitRepository : .notARepository, hostId: hostId,
                              status: .ready, settingsId: settings.id, createdAt: clock.now)
        try await database.projects.create(project, settings: settings, at: clock.now)
        try await database.projects.saveLocation(RepositoryLocation(projectId: project.id, hostId: hostId,
                                                                    canonicalPath: url.path(percentEncoded: false).trimmingSlash), at: clock.now)
        return (project, url)
    }

    func item(_ projectId: ProjectID, title: String = "Senderliste vergrößern", type: WorkItemType = .feature,
              status: WorkItemStatus = .open, body: String = "## Ziel\n\nGrößere Liste.") async throws -> WorkItem {
        let item = WorkItem(projectId: projectId, type: type, title: title, originalNote: "Notiz", structuredBody: body,
                            status: status, createdAt: clock.now)
        try await database.workItems.insert(item, actor: .user(DeviceID()), at: clock.now)
        return item
    }
}

extension String {
    var lines: [String] { components(separatedBy: "\n") }
}

/// Lines that differ between two texts of equal line count (nil if counts differ).
func changedLines(_ old: String, _ new: String) -> [String]? {
    let a = old.lines, b = new.lines
    guard a.count == b.count else { return nil }
    return zip(a, b).filter { $0 != $1 }.map(\.1)
}

/// Polls `condition` until true or timeout.
func eventually(timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return try await condition()
}
