import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess
import Testing

/// 2026-10-30 18:00 UTC = 19:00 Europe/Vienna (CET).
let t0 = Date(timeIntervalSince1970: 1_793_383_200)

func iso(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

let codexModel: ModelID = "gpt-5.5-codex"
let codexMini: ModelID = "gpt-5.5-mini"
let claudeModel: ModelID = "opus"

func capability(_ provider: ProviderID, hostId: HostID, models: [(ModelID, [EffortLevel])], revision: Int = 1,
                effortSelectable: Bool = true) -> AgentCapability {
    AgentCapability(
        providerId: provider, displayName: provider.rawValue, hostId: hostId, executablePath: "/opt/homebrew/bin/\(provider)",
        version: "1.0.0", supportsApprovals: true, supportsModelSelection: true, supportsEffortSelection: effortSelectable,
        modelCatalog: models.map {
            AgentModelCapability(providerId: provider, modelId: $0.0, displayName: $0.0.rawValue, supportedEffortIds: $0.1,
                                 source: .verifiedSpike, lastValidatedAt: t0)
        },
        defaultModelId: models.first?.0, capabilitySource: .verifiedSpike, capabilityRevision: revision, lastChecked: t0)
}

/// Real temporary git repository, file database and fake agents for one test.
final class TestEnvironment: @unchecked Sendable {
    let root: URL
    let repo: URL
    let git: GitClient
    let database: AppDatabase
    let hostId = HostID()
    let project: Project
    let clock = ManualClock(t0)
    let inspector = FakeProcessInspector()
    let codex: FakeProvider
    let claude: FakeProvider
    let user = EventActor.user(DeviceID())

    init(projectWideLock: Bool = false, allowParallel: Bool = true, maxParallelJobs: Int? = nil,
         integrationStrategy: SoftwareRegisseurDomain.IntegrationStrategy = .squash) async throws {
        let raw = FileManager.default.temporaryDirectory.appending(path: "SRJobsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = try PathGuard.canonicalize(raw)
        let located = try GitClient.locate()
        git = GitClient(
            executableURL: located.executableURL,
            environment: located.environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]),
            configOverrides: [
                ("user.name", "Software Regisseur Tests"), ("user.email", "tests@software-regisseur.invalid"),
                ("init.defaultBranch", "main"), ("commit.gpgsign", "false"),
            ])
        repo = root.appending(path: "repos/app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "--initial-branch=main"], in: repo)
        try Data("# App\n".utf8).write(to: repo.appending(path: "README.md"))
        try Data("Basis\n".utf8).write(to: repo.appending(path: "feature.txt"))
        try await git.run(["add", "-A"], in: repo)
        try await git.run(["commit", "--quiet", "-m", "Initial commit"], in: repo)

        database = try AppDatabase.openWriter(at: root.appending(path: "state/db.sqlite"))
        let settings = ProjectSettings(allowParallel: allowParallel, projectWideLock: projectWideLock,
                                       maxParallelJobs: maxParallelJobs, integrationStrategy: integrationStrategy, updatedAt: t0)
        project = Project(name: "App", repositoryIdentity: RepositoryIdentity(rawValue: "git:\(UUID().uuidString)"),
                          repositoryKind: .gitRepository, hostId: hostId, settingsId: settings.id, createdAt: t0)
        try await database.projects.create(project, settings: settings, at: t0)
        try await database.projects.saveLocation(
            RepositoryLocation(projectId: project.id, hostId: hostId, canonicalPath: repo.path(percentEncoded: false)), at: t0)

        let codexCapability = capability(.codex, hostId: hostId, models: [(codexModel, [.low, .medium, .high]), (codexMini, [.low])])
        let claudeCapability = capability(.claudeCode, hostId: hostId, models: [(claudeModel, [.low, .high, .max])])
        try await database.capabilities.saveHost(AgentHost(
            hostId: hostId, name: "Mac Studio", lastSeen: t0, ready: true,
            agentCapabilities: [codexCapability, claudeCapability], serviceVersion: "1.0"), at: t0)
        codex = FakeProvider(providerId: .codex, capability: codexCapability)
        claude = FakeProvider(providerId: .claudeCode, capability: claudeCapability)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var registry: AgentProviderRegistry { AgentProviderRegistry(providers: [codex, claude]) }

    func orchestrator(
        hostId: HostID? = nil,
        limits: ConcurrencyLimits = ConcurrencyLimits(global: 4, perProject: 4),
        approvalTimeout: ApprovalTimeoutPolicy = ApprovalTimeoutPolicy(timeout: 600, action: .pause),
        planner: QuotaRetryPlanner = QuotaRetryPlanner(),
        lease: TimeInterval = 600,
        requestFilePath: (@Sendable (WorkItem) async -> String?)? = nil,
        documentPaths: (@Sendable (ProjectID) async -> [String])? = nil,
        allowedRepositoryRoots: (@Sendable () async -> [URL])? = nil
    ) throws -> JobOrchestrator {
        let configuration = JobOrchestratorConfiguration(
            hostId: hostId ?? self.hostId,
            worktreesBaseDirectory: root.appending(path: "worktrees", directoryHint: .isDirectory),
            integrationWorktreeDirectory: root.appending(path: "integration", directoryHint: .isDirectory),
            scanRoots: [root.appending(path: "repos", directoryHint: .isDirectory)],
            runtimeDirectory: root.appending(path: "runtime", directoryHint: .isDirectory),
            limits: limits, lockLeaseDuration: lease, heartbeatInterval: 60, approvalTimeout: approvalTimeout,
            quotaRetryPlanner: planner)
        let dependencies = JobOrchestratorDependencies(
            database: database, providers: registry, git: git, processInspector: inspector, clock: clock, randomSeed: 42,
            requestFilePath: requestFilePath, documentPaths: documentPaths, allowedRepositoryRoots: allowedRepositoryRoots)
        return try JobOrchestrator(configuration: configuration, dependencies: dependencies)
    }

    @discardableResult
    func addWorkItem(_ title: String, dependencies: [WorkItemID] = []) async throws -> WorkItem {
        let item = WorkItem(projectId: project.id, type: .feature, title: title, originalNote: "Notiz: \(title)",
                            structuredBody: "## Ziel\n\(title)", status: .open, dependencies: dependencies, createdAt: clock.now())
        try await database.workItems.insert(item, actor: user, at: clock.now())
        return item
    }

    func request(
        _ orchestrator: JobOrchestrator, _ item: WorkItem, provider: ProviderID = .codex,
        override: JobConfigurationOverride? = nil, schedule: JobSchedule = JobSchedule(kind: .immediate),
        priority: Priority = .medium, key: IdempotencyKey = IdempotencyKey()
    ) async throws -> AgentJob {
        try await orchestrator.requestJob(workItemId: item.uuid, providerId: provider, override: override, schedule: schedule,
                                          priority: priority, idempotencyKey: key, by: user).job
    }

    func job(_ id: JobID) async throws -> AgentJob { try #require(try await database.jobs.fetch(id)) }
    func item(_ id: WorkItemID) async throws -> WorkItem { try #require(try await database.workItems.fetch(id)) }

    func output(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        try await git.run(arguments, in: directory ?? repo).trimmedOutput
    }

    func fileExists(_ path: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: path).path(percentEncoded: false))
    }
}

/// Polls `condition` until true (async session events are processed on the orchestrator actor).
func eventually(timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within \(timeout)")
}
