import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess
import Testing
@testable import SoftwareRegisseurWorkspace

/// Fake `gh` (Python, no shell) storing issues as JSON files in `$FAKE_GH_STATE`; logs every argv.
let fakeGHScript = #"""
#!/usr/bin/python3
import json, os, sys
state = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "calls.log"), "a") as log:
    log.write(json.dumps(args) + "\n")
def path(n): return os.path.join(state, "issue-%d.json" % n)
def load(n):
    with open(path(n)) as f: return json.load(f)
def save(issue):
    issue["updatedAt"] = "2026-10-30T%02d:00:00Z" % (len(os.listdir(state)) % 24)
    with open(path(issue["number"]), "w") as f: json.dump(issue, f)
def arg(name):
    return args[args.index(name) + 1] if name in args else None
if args[:1] == ["--version"]:
    print("gh version 2.99.0 (fake)"); sys.exit(0)
if args[:2] == ["auth", "status"]:
    if os.path.exists(os.path.join(state, "logged-out")):
        sys.stderr.write("You are not logged into any GitHub hosts.\n"); sys.exit(1)
    print("Logged in to github.com"); sys.exit(0)
if args[:2] == ["issue", "view"]:
    n = int(args[2])
    if not os.path.exists(path(n)):
        sys.stderr.write("issue not found\n"); sys.exit(1)
    print(json.dumps(load(n))); sys.exit(0)
if args[:2] == ["issue", "list"]:
    issues = [json.load(open(os.path.join(state, f))) for f in sorted(os.listdir(state)) if f.startswith("issue-")]
    print(json.dumps(issues)); sys.exit(0)
if args[:2] == ["issue", "create"]:
    n = len([f for f in os.listdir(state) if f.startswith("issue-")]) + 1
    body = sys.stdin.read() if arg("--body-file") == "-" else ""
    repo = arg("--repo")
    save({"number": n, "title": arg("--title"), "body": body, "state": "OPEN",
          "url": "https://github.com/%s/issues/%d" % (repo, n), "labels": []})
    print("https://github.com/%s/issues/%d" % (repo, n)); sys.exit(0)
if args[:2] == ["issue", "edit"]:
    issue = load(int(args[2]))
    if arg("--title"): issue["title"] = arg("--title")
    if arg("--body-file") == "-": issue["body"] = sys.stdin.read()
    save(issue); sys.exit(0)
if args[:2] in (["issue", "close"], ["issue", "reopen"]):
    issue = load(int(args[2])); issue["state"] = "CLOSED" if args[1] == "close" else "OPEN"
    save(issue); sys.exit(0)
sys.stderr.write("unsupported: %r\n" % args); sys.exit(2)
"""#

@Suite("GitHub issues via gh (M3, ADR-0016)")
struct GitHubIssueServiceTests {
    @Test func missingGhDisablesFeatureWithGermanExplanation() async throws {
        let h = try Harness()
        let empty = try h.sandbox.mkdir("leer")
        let service = GitHubIssueService(environment: h.environment,
                                         locator: ExecutableLocator(userDirectories: [empty], includeDefaultDirectories: false))
        let availability = await service.availability()
        #expect(availability == .unavailable(.cliNotInstalled))
        #expect(GitHubUnavailableReason.cliNotInstalled.description.contains("nicht installiert"))
        let (project, _) = try await h.project("app")
        try await service.setEnabled(true, projectId: project.id)
        let item = try await h.item(project.id)
        await #expect(throws: GitHubIssueError.self) { _ = try await service.export(workItemId: item.uuid) }
        // Local functions are unaffected.
        try await RequestMaterializer(environment: h.environment).materialize(item.uuid)
    }

    @Test func fakeGhHappyPathExportPushDivergenceAndImport() async throws {
        let h = try Harness()
        let tools = try h.sandbox.mkdir("tools")
        let state = try h.sandbox.mkdir("gh-state")
        let gh = tools.appending(path: "gh")
        try Data(fakeGHScript.utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path(percentEncoded: false))
        let service = GitHubIssueService(
            environment: h.environment,
            locator: ExecutableLocator(userDirectories: [tools], includeDefaultDirectories: false),
            processEnvironment: ProcessEnvironment.minimal().merging(["FAKE_GH_STATE": state.path(percentEncoded: false)])
        )
        guard case .available = await service.availability() else {
            Issue.record("fake gh not available")
            return
        }
        try Data().write(to: state.appending(path: "logged-out"))
        guard case .unavailable(.notAuthenticated) = await service.availability() else {
            Issue.record("logged-out state not detected")
            return
        }
        try FileManager.default.removeItem(at: state.appending(path: "logged-out"))

        var (project, _) = try await h.project("app")
        project.remote = "git@github.com:example/regie.git"
        project = try await h.database.projects.update(project, expectedRevision: project.revision, at: h.clock.now)
        let item = try await h.item(project.id)
        // Disabled per project by default.
        await #expect(throws: GitHubIssueError.unavailable(.disabledForProject)) { _ = try await service.export(workItemId: item.uuid) }
        try await service.setEnabled(true, projectId: project.id)

        let link = try await service.export(workItemId: item.uuid)
        #expect(link.issueNumber == 1 && link.repo == "example/regie")
        #expect(try await service.viewIssue(1, repo: "example/regie").body.contains(item.uuid.uuidString.lowercased()))
        #expect(try await service.synchronize(workItemId: item.uuid) == .unchanged)

        // Local change → pushed (local file leads).
        var current = try #require(try await h.database.workItems.fetch(item.uuid))
        current = try await h.database.workItems.update(item.uuid, expectedRevision: current.revision, actor: .user(DeviceID()), at: h.clock.now) {
            $0.title = "Neuer Titel"
        }
        #expect(try await service.synchronize(workItemId: item.uuid) == .pushed)
        #expect(try await service.viewIssue(1, repo: "example/regie").title == "Neuer Titel")

        // GitHub change → conflict notice, nothing overwritten, nothing pushed.
        let issuePath = state.appending(path: "issue-1.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: issuePath)) as? [String: Any])
        json["title"] = "Auf GitHub geändert"
        try JSONSerialization.data(withJSONObject: json).write(to: issuePath)
        guard case let .divergence(conflict) = try await service.synchronize(workItemId: item.uuid) else {
            Issue.record("expected divergence")
            return
        }
        #expect(conflict.kind == .gitHubDivergence && conflict.externalText?.contains("Auf GitHub geändert") == true)
        #expect(try await h.database.workItems.fetch(item.uuid)?.title == "Neuer Titel")
        #expect(try await service.viewIssue(1, repo: "example/regie").title == "Auf GitHub geändert")
        guard case .divergence = try await service.synchronize(workItemId: item.uuid) else {
            Issue.record("divergence must stay until resolved")
            return
        }
        #expect(try await h.database.fileConflicts.open(workItemId: item.uuid).count == 1)

        try await service.resolveDivergence(conflict.id, acceptGitHub: true)
        #expect(try await h.database.workItems.fetch(item.uuid)?.title == "Auf GitHub geändert")
        #expect(try await service.synchronize(workItemId: item.uuid) == .unchanged)

        // Import of an existing issue creates a separate local identity.
        _ = try await h.database.workItems.fetch(item.uuid)
        let imported = try await service.importIssue(1, projectId: project.id)
        #expect(imported.uuid != item.uuid && imported.title == "Auf GitHub geändert")
        #expect(try await h.database.reviews.issueLink(workItemId: imported.uuid)?.issueNumber == 1)

        // Every call was an argv without shell; no token handling.
        let log = try String(contentsOf: state.appending(path: "calls.log"), encoding: .utf8)
        #expect(log.contains("[\"issue\", \"create\", \"--repo\", \"example/regie\", \"--title\""))
        #expect(!log.lowercased().contains("token"))
    }

    @Test func repositorySlugParsing() {
        #expect(GitHubIssueService.repositorySlug(fromRemote: "git@github.com:owner/name.git") == "owner/name")
        #expect(GitHubIssueService.repositorySlug(fromRemote: "https://github.com/owner/name") == "owner/name")
        #expect(GitHubIssueService.repositorySlug(fromRemote: "ssh://git@github.com/owner/name.git") == "owner/name")
        #expect(GitHubIssueService.repositorySlug(fromRemote: "git@gitlab.com:owner/name.git") == nil)
    }
}

@Suite("Repository context for AI elaboration (H4, A11)")
struct RepoContextBuilderTests {
    @Test func excludesSecretsRedactsAndRespectsBudget() async throws {
        let h = try Harness()
        let (_, repo) = try await h.project("app", git: false)
        try h.sandbox.write("app/.env", "SECRET=supersecretvalue123\n")
        try h.sandbox.write("app/config/server.key", "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n")
        try h.sandbox.write("app/config/credentials.json", "{\"password\": \"hunter2hunter2\"}\n")
        try h.sandbox.write("app/Sources/App.swift", "let api_key = \"sk-proj-abcdefghijklmnopqrstuvwxyz0123456789\"\nprint(\"hi\")\n")
        try h.sandbox.write("app/Sources/Big.swift", String(repeating: "let x = 1\n", count: 3000))
        try h.sandbox.write("app/docs/adr/0001-angenommen.md", "---\nadr: 0001\ntitle: Angenommen\nstatus: accepted\n---\nInhalt A\n")
        try h.sandbox.write("app/docs/adr/0002-vorschlag.md", "---\nadr: 0002\ntitle: Vorschlag\nstatus: proposed\n---\nInhalt B\n")
        try h.sandbox.write("app/docs/requests/open/BUG-0001-absturz.md", requestFile(id: "BUG-0001", title: "Absturz"))
        try h.sandbox.write("outside.txt", "geheim außerhalb\n")
        try FileManager.default.createSymbolicLink(at: h.sandbox.url("app/Sources/link.swift"), withDestinationURL: h.sandbox.url("outside.txt"))

        let builder = RepoContextBuilder(options: .init(maxCharacters: 8_000))
        let context = builder.build(root: repo, layout: .default, selectedFiles: [
            ".env", "config/server.key", "config/credentials.json", "Sources/App.swift", "../outside.txt",
            "Sources/link.swift", "Sources/Big.swift", "Sources/fehlt.swift",
        ])
        let manifest = context.manifest
        let excluded = Dictionary(manifest.excluded.compactMap { entry in entry.path.map { ($0, entry.reason) } }, uniquingKeysWith: { a, _ in a })
        #expect(excluded[".env"] == .secretPath(pattern: ".env*"))
        #expect(excluded["config/server.key"] == .secretPath(pattern: "*.key"))
        #expect(excluded["config/credentials.json"] == .secretPath(pattern: "credentials*"))
        #expect(excluded["../outside.txt"] == .outsideRepository)
        #expect(excluded["Sources/link.swift"] == .symlink)
        #expect(excluded["Sources/Big.swift"] == .overBudget)
        #expect(excluded["Sources/fehlt.swift"] == .notFound)

        let all = context.items.map(\.content).joined(separator: "\n")
        #expect(!all.contains("supersecretvalue123") && !all.contains("hunter2") && !all.contains("BEGIN PRIVATE KEY"))
        #expect(!all.contains("sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!all.contains("geheim außerhalb"))
        let app = try #require(manifest.included.first { $0.path == "Sources/App.swift" })
        #expect(app.redactionCount >= 1)
        #expect(manifest.included.contains { $0.title.hasPrefix("ADR-0001") })
        #expect(!manifest.included.contains { $0.title.hasPrefix("ADR-0002") })
        #expect(manifest.included.contains { $0.kind == .existingRequest })
        let tree = try #require(context.items.first { $0.kind == .repositoryStructure }?.content)
        #expect(tree.contains("Sources/") && !tree.contains("server.key") && !tree.contains("credentials.json"))
        #expect(manifest.totalCharacters <= 8_000)
        // Manifest lists exactly what the items contain.
        #expect(manifest.included.count == context.items.count)
        #expect(zip(manifest.included, context.items).allSatisfy { $0.characterCount == $1.content.count })
    }
}

@Suite("FSEvents watcher and sync service (E3, U4)")
struct WatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func externalEditIsPickedUpViaFSEvents() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let service = RepositorySyncService(environment: h.environment)
        await service.reconcile(projectId: project.id)
        let path = "app/docs/requests/open/FR-0001-senderliste-vergroessern.md"
        #expect(h.sandbox.exists(path))

        try await service.start(reconcileInterval: .seconds(3600), debounce: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(500)) // let the stream settle
        try h.sandbox.write(path, try h.sandbox.read(path).replacingOccurrences(of: "Größere Liste.", with: "Per Editor geändert."))
        let picked = await eventually(timeout: .seconds(30)) {
            (try? await h.database.workItems.fetch(item.uuid))??.structuredBody.contains("Per Editor geändert.") == true
        }
        await service.stop()
        #expect(picked)
    }

    @Test(.timeLimit(.minutes(1)))
    func watcherDeliversChangesForRealPaths() async throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.mkdir("watch")
        let watcher = RepositoryWatcher(paths: [folder], latency: 0.05)
        try watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try sandbox.write("watch/a.md", "x")
        let received = Task {
            for await batch in watcher.changes where batch.contains(where: { $0.path.hasSuffix("/watch/a.md") }) {
                return true
            }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            watcher.stop()
        }
        let result = await received.value
        timeout.cancel()
        watcher.stop()
        #expect(result)
    }
}
