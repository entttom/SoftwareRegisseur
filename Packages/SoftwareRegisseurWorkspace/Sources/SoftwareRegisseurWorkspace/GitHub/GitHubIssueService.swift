import CryptoKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess

/// Why the GitHub integration is not usable (ADR-0016). Messages are German and explain the setup.
public enum GitHubUnavailableReason: Sendable, Hashable, CustomStringConvertible {
    case cliNotInstalled
    case notAuthenticated(detail: String)
    case disabledForProject
    case noGitHubRemote
    case failed(detail: String)

    public var description: String {
        switch self {
        case .cliNotInstalled:
            String(localized: "Die GitHub-CLI „gh“ ist nicht installiert. Installieren Sie sie (z. B. „brew install gh“) und melden Sie sich mit „gh auth login“ an. Lokale Funktionen bleiben unverändert nutzbar.", bundle: .module)
        case let .notAuthenticated(detail):
            String(localized: "Die GitHub-CLI ist nicht angemeldet. Bitte im Terminal „gh auth login“ ausführen. (\(detail))", bundle: .module)
        case .disabledForProject:
            String(localized: "Die GitHub-Integration ist für dieses Projekt deaktiviert.", bundle: .module)
        case .noGitHubRemote:
            String(localized: "Das Projekt hat kein GitHub-Remote. Ein Repository kann in den Projekteinstellungen angegeben werden.", bundle: .module)
        case let .failed(detail):
            String(localized: "GitHub-CLI-Aufruf fehlgeschlagen: \(detail)", bundle: .module)
        }
    }
}

public enum GitHubAvailability: Sendable, Hashable {
    case available(version: String)
    case unavailable(GitHubUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public enum GitHubIssueError: Error, Sendable, Hashable, CustomStringConvertible {
    case unavailable(GitHubUnavailableReason)
    case notLinked(WorkItemID)
    case alreadyLinked(WorkItemID, issue: Int)
    case unexpectedOutput(String)
    case divergenceNotice(FileConflictID)

    public var description: String {
        switch self {
        case let .unavailable(reason): reason.description
        case let .notLinked(id): String(localized: "Aufgabe \(id) ist mit keinem GitHub-Issue verknüpft.", bundle: .module)
        case let .alreadyLinked(id, issue): String(localized: "Aufgabe \(id) ist bereits mit Issue #\(issue) verknüpft.", bundle: .module)
        case let .unexpectedOutput(detail): String(localized: "Unerwartete Ausgabe der GitHub-CLI: \(detail)", bundle: .module)
        case let .divergenceNotice(id): String(localized: "GitHub wurde seit dem letzten Abgleich geändert (Konflikthinweis \(id)).", bundle: .module)
        }
    }
}

/// Issue as returned by `gh issue view/list --json`.
public struct GitHubIssue: Sendable, Hashable, Codable {
    public struct Label: Sendable, Hashable, Codable { public let name: String }

    public let number: Int
    public let title: String
    public let body: String
    public let state: String
    public let url: String
    public let updatedAt: String
    public let labels: [Label]

    public static let jsonFields = "number,title,body,state,url,updatedAt,labels"

    public var isClosed: Bool { state.uppercased() == "CLOSED" }

    /// Content fingerprint used to detect changes on GitHub since the last sync.
    public var fingerprint: String {
        let text = [title, body, state.uppercased()].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum GitHubSyncOutcome: Sendable, Hashable {
    case unchanged
    /// Local changes were sent to GitHub (local file leads, ADR-0016).
    case pushed
    /// GitHub changed since the last sync: a conflict notice was created, nothing was overwritten.
    case divergence(FileConflict)
}

/// GitHub issue integration via the user's `gh` login (ADR-0016, spec M3): no own token, explicit argument
/// vectors without shell, local request is authoritative, GitHub changes are never discarded silently.
public actor GitHubIssueService {
    static let stateScope = "github"

    let environment: WorkspaceEnvironment
    let executableURL: URL?
    let processEnvironment: ProcessEnvironment
    let runner = ProcessRunner()
    let timeout: Duration

    /// `executableURL == nil` looks `gh` up with `ExecutableLocator` (LaunchAgent-safe paths).
    public init(
        environment: WorkspaceEnvironment, executableURL: URL? = nil, locator: ExecutableLocator = ExecutableLocator(),
        processEnvironment: ProcessEnvironment? = nil, timeout: Duration = .seconds(60)
    ) {
        self.environment = environment
        self.executableURL = executableURL ?? (try? locator.locate("gh"))?.preferred?.url
        var env = processEnvironment ?? ProcessEnvironment.minimal(path: locator.pathEnvironmentValue)
        env.merge(["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1", "GH_PAGER": "cat"])
        if let home = ProcessInfo.processInfo.environment["HOME"], env["HOME"] == nil { env.merge(["HOME": home]) }
        self.processEnvironment = env
        self.timeout = timeout
    }

    // MARK: Availability

    public func availability() async -> GitHubAvailability {
        guard let executableURL else { return .unavailable(.cliNotInstalled) }
        do {
            let version = try await run(["--version"], executable: executableURL)
            guard version.succeeded else { return .unavailable(.failed(detail: version.standardErrorString)) }
            let auth = try await run(["auth", "status"], executable: executableURL)
            guard auth.succeeded else {
                let detail = (auth.standardErrorString + auth.standardOutputString).trimmingCharacters(in: .whitespacesAndNewlines)
                return .unavailable(.notAuthenticated(detail: SecretRedactor.standard.redact(String(detail.prefix(300)))))
            }
            let line = version.standardOutputString.split(separator: "\n").first.map(String.init) ?? ""
            return .available(version: line)
        } catch {
            return .unavailable(.failed(detail: "\(error)"))
        }
    }

    public func isEnabled(projectId: ProjectID) async throws -> Bool {
        try await environment.database.hostState.value(scope: Self.stateScope, key: "enabled:\(projectId.uuidString)") == Data([1])
    }

    public func setEnabled(_ enabled: Bool, projectId: ProjectID) async throws {
        try await environment.database.hostState.setValue(Data([enabled ? 1 : 0]), scope: Self.stateScope,
                                                          key: "enabled:\(projectId.uuidString)", at: environment.now())
    }

    /// `owner/name` from the project's GitHub remote.
    public func repository(for projectId: ProjectID) async throws -> String {
        guard let project = try await environment.database.projects.fetch(projectId) else { throw WorkspaceError.projectNotFound(projectId) }
        guard let remote = project.remote, let slug = Self.repositorySlug(fromRemote: remote) else {
            throw GitHubIssueError.unavailable(.noGitHubRemote)
        }
        return slug
    }

    public static func repositorySlug(fromRemote remote: String) -> String? {
        let patterns = [#"^git@github\.com:([^/]+)/(.+?)(?:\.git)?/?$"#, #"^(?:https?|ssh)://(?:[^@/]+@)?github\.com/([^/]+)/(.+?)(?:\.git)?/?$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
                  let owner = Range(match.range(at: 1), in: remote), let name = Range(match.range(at: 2), in: remote) else { continue }
            return "\(remote[owner])/\(remote[name])"
        }
        return nil
    }

    // MARK: Issue commands

    public func viewIssue(_ number: Int, repo: String) async throws -> GitHubIssue {
        let result = try await gh(["issue", "view", String(number), "--repo", repo, "--json", GitHubIssue.jsonFields])
        return try decode(GitHubIssue.self, result)
    }

    public func listIssues(repo: String, state: String = "open", limit: Int = 100) async throws -> [GitHubIssue] {
        let result = try await gh(["issue", "list", "--repo", repo, "--state", state, "--limit", String(limit), "--json", GitHubIssue.jsonFields])
        return try decode([GitHubIssue].self, result)
    }

    // MARK: Link / import / export

    /// Links an existing issue (separate identities, ADR-0016) and records the sync baseline.
    @discardableResult
    public func link(workItemId: WorkItemID, issueNumber: Int) async throws -> GitHubIssueLink {
        let (item, repo) = try await prepare(workItemId)
        if let existing = try await environment.database.reviews.issueLink(workItemId: workItemId) {
            throw GitHubIssueError.alreadyLinked(workItemId, issue: existing.issueNumber)
        }
        let issue = try await viewIssue(issueNumber, repo: repo)
        return try await saveLink(item: item, repo: repo, issue: issue)
    }

    /// Creates a local work item from an issue; the request file follows through `RequestMaterializer`.
    public func importIssue(_ number: Int, projectId: ProjectID) async throws -> WorkItem {
        try await requireEnabled(projectId)
        let repo = try await repository(for: projectId)
        let issue = try await viewIssue(number, repo: repo)
        let labels = issue.labels.map(\.name)
        let type: WorkItemType = labels.contains { $0.lowercased() == "bug" } ? .bug : .feature
        let now = environment.now()
        let item = WorkItem(
            projectId: projectId, type: type, title: issue.title, originalNote: issue.body,
            structuredBody: issue.body, status: issue.isClosed ? .done : .open, labels: labels, createdAt: now
        )
        try await environment.database.workItems.insert(item, actor: .external, at: now)
        _ = try await saveLink(item: item, repo: repo, issue: issue)
        return item
    }

    /// Creates a GitHub issue for a local work item and links it.
    @discardableResult
    public func export(workItemId: WorkItemID) async throws -> GitHubIssueLink {
        let (item, repo) = try await prepare(workItemId)
        if let existing = try await environment.database.reviews.issueLink(workItemId: workItemId) {
            throw GitHubIssueError.alreadyLinked(workItemId, issue: existing.issueNumber)
        }
        let result = try await gh(["issue", "create", "--repo", repo, "--title", item.title, "--body-file", "-"],
                                  input: Data(Self.issueBody(item).utf8))
        let output = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let urlLine = output.split(separator: "\n").last(where: { $0.contains("/issues/") }),
              let number = Int(urlLine.split(separator: "/").last ?? "") else {
            throw GitHubIssueError.unexpectedOutput(String(output.prefix(200)))
        }
        let issue = try await viewIssue(number, repo: repo)
        return try await saveLink(item: item, repo: repo, issue: issue)
    }

    /// Bidirectional metadata/status sync with the ADR-0016 conflict rule.
    public func synchronize(workItemId: WorkItemID) async throws -> GitHubSyncOutcome {
        let (item, repo) = try await prepare(workItemId)
        guard let link = try await environment.database.reviews.issueLink(workItemId: workItemId) else {
            throw GitHubIssueError.notLinked(workItemId)
        }
        if let open = try await environment.database.fileConflicts.open(workItemId: workItemId).first(where: { $0.kind == .gitHubDivergence }) {
            return .divergence(open)
        }
        let issue = try await viewIssue(link.issueNumber, repo: repo)
        let baseline = try await environment.database.hostState.value(scope: Self.stateScope, key: Self.snapshotKey(workItemId))
            .map { String(decoding: $0, as: UTF8.self) }
        let remoteChanged = baseline != nil && baseline != issue.fingerprint
        let localChanged = item.revision != link.lastSyncedRevision

        if remoteChanged {
            // GitHub changes are never discarded: notice with both versions, user decides.
            let conflict = FileConflict(
                projectId: item.projectId!, workItemId: item.uuid, location: "\(repo)#\(link.issueNumber)", kind: .gitHubDivergence,
                databaseRevision: item.revision, databaseText: "# \(item.title)\n\n\(Self.issueBody(item))",
                externalText: "# \(issue.title)\n\n\(issue.body)\n\n[\(issue.state)]",
                detail: localChanged ? String(localized: "Lokal und auf GitHub geändert.", bundle: .module) : String(localized: "Auf GitHub geändert.", bundle: .module),
                detectedAt: environment.now()
            )
            try await environment.database.fileConflicts.insert(conflict)
            try await environment.database.events.append(TaskEvent(
                workItemId: item.uuid, kind: .conflictDetected, actor: .host(environment.hostId), timestamp: conflict.detectedAt,
                payload: ["conflictId": conflict.id.uuidString, "kind": conflict.kind.rawValue, "issue": conflict.location],
                sourceRevision: item.revision
            ))
            return .divergence(conflict)
        }
        guard localChanged || baseline == nil else { return .unchanged }
        try await push(item, issue: issue, repo: repo)
        let refreshed = try await viewIssue(link.issueNumber, repo: repo)
        _ = try await saveLink(item: item, repo: repo, issue: refreshed)
        return .pushed
    }

    /// Applies GitHub divergence resolutions requested on the iPhone (synced, spec N2/ADR-0016):
    /// `acceptedExternal` takes the GitHub version, `keptDatabase` pushes the local one, `dismissed`
    /// only closes the notice. Returns the conflicts that were handled.
    @discardableResult
    public func applyRequestedResolutions() async throws -> [FileConflictID] {
        var handled: [FileConflictID] = []
        for conflict in try await environment.database.fileConflicts.pendingRequests() where conflict.kind == .gitHubDivergence {
            switch conflict.requestedResolution {
            case .acceptedExternal?: try await resolveDivergence(conflict.id, acceptGitHub: true)
            case .keptDatabase?: try await resolveDivergence(conflict.id, acceptGitHub: false)
            case .dismissed?: _ = try await environment.database.fileConflicts.resolve(conflict.id, resolution: .dismissed, at: environment.now())
            case nil: continue
            }
            handled.append(conflict.id)
        }
        return handled
    }

    /// Resolves a GitHub divergence notice: take over the GitHub version or push the local one.
    public func resolveDivergence(_ conflictId: FileConflictID, acceptGitHub: Bool) async throws {
        guard let conflict = try await environment.database.fileConflicts.fetch(conflictId), let workItemId = conflict.workItemId else {
            throw WorkspaceError.conflictNotFound(conflictId)
        }
        let (item, repo) = try await prepare(workItemId)
        guard let link = try await environment.database.reviews.issueLink(workItemId: workItemId) else {
            throw GitHubIssueError.notLinked(workItemId)
        }
        let issue = try await viewIssue(link.issueNumber, repo: repo)
        var current = item
        if acceptGitHub {
            current = try await environment.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: .external,
                                                                      at: environment.now()) { value in
                value.title = issue.title
                value.structuredBody = issue.body
            }
        } else {
            try await push(item, issue: issue, repo: repo)
        }
        _ = try await environment.database.fileConflicts.resolve(conflictId, resolution: acceptGitHub ? .acceptedExternal : .keptDatabase,
                                                                 at: environment.now())
        let refreshed = try await viewIssue(link.issueNumber, repo: repo)
        _ = try await saveLink(item: current, repo: repo, issue: refreshed)
    }

    // MARK: Helpers

    private func push(_ item: WorkItem, issue: GitHubIssue, repo: String) async throws {
        if issue.title != item.title || issue.body != Self.issueBody(item) {
            _ = try await gh(["issue", "edit", String(issue.number), "--repo", repo, "--title", item.title, "--body-file", "-"],
                             input: Data(Self.issueBody(item).utf8))
        }
        let shouldBeClosed = [.done, .integrated, .cancelled].contains(item.status)
        if shouldBeClosed, !issue.isClosed {
            _ = try await gh(["issue", "close", String(issue.number), "--repo", repo])
        } else if !shouldBeClosed, issue.isClosed {
            _ = try await gh(["issue", "reopen", String(issue.number), "--repo", repo])
        }
    }

    private func prepare(_ workItemId: WorkItemID) async throws -> (WorkItem, String) {
        guard let item = try await environment.database.workItems.fetch(workItemId) else { throw WorkspaceError.workItemNotFound(workItemId) }
        guard let projectId = item.projectId else { throw WorkspaceError.workItemWithoutProject(workItemId) }
        try await requireEnabled(projectId)
        return (item, try await repository(for: projectId))
    }

    private func requireEnabled(_ projectId: ProjectID) async throws {
        guard try await isEnabled(projectId: projectId) else { throw GitHubIssueError.unavailable(.disabledForProject) }
        if case let .unavailable(reason) = await availability() { throw GitHubIssueError.unavailable(reason) }
    }

    private func saveLink(item: WorkItem, repo: String, issue: GitHubIssue) async throws -> GitHubIssueLink {
        let link = GitHubIssueLink(workItemId: item.uuid, repo: repo, issueNumber: issue.number, url: issue.url,
                                   lastSyncedRevision: item.revision)
        try await environment.database.reviews.saveIssueLink(link, at: environment.now())
        try await environment.database.hostState.setValue(Data(issue.fingerprint.utf8), scope: Self.stateScope,
                                                          key: Self.snapshotKey(item.uuid), at: environment.now())
        return link
    }

    static func snapshotKey(_ id: WorkItemID) -> String { "issue:\(id.uuidString)" }

    /// Issue body: the request body plus a reference to the local UUID (identities stay separate).
    static func issueBody(_ item: WorkItem) -> String {
        let body = item.structuredBody.isEmpty ? item.originalNote : item.structuredBody
        var reference = "Software Regisseur: \(item.uuid.uuidString.lowercased())"
        if let id = item.humanId { reference = "Software Regisseur: \(id.formatted) (\(item.uuid.uuidString.lowercased()))" }
        return body + "\n\n<!-- \(reference) -->"
    }

    private func gh(_ arguments: [String], input: Data? = nil) async throws -> ProcessResult {
        guard let executableURL else { throw GitHubIssueError.unavailable(.cliNotInstalled) }
        let result = try await run(arguments, executable: executableURL, input: input)
        guard result.succeeded else {
            throw GitHubIssueError.unavailable(.failed(detail: SecretRedactor.standard.redact(String(result.standardErrorString.prefix(300)))))
        }
        return result
    }

    private func run(_ arguments: [String], executable: URL, input: Data? = nil) async throws -> ProcessResult {
        try await runner.run(ProcessRequest(
            executableURL: executable, arguments: arguments, environment: processEnvironment, standardInput: input, timeout: timeout
        ))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ result: ProcessResult) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: result.standardOutput.data)
        } catch {
            throw GitHubIssueError.unexpectedOutput(String(result.standardOutputString.prefix(200)))
        }
    }
}
