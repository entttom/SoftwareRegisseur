import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// Maximum parallel runs (spec K1). Project settings (`allowParallel`, `maxParallelJobs`) override
/// `perProject` for their project.
public struct ConcurrencyLimits: Hashable, Sendable, Codable {
    public var global: Int
    public var perProject: Int
    public var perProvider: [ProviderID: Int]
    public var defaultPerProvider: Int?

    public init(global: Int = 2, perProject: Int = 2, perProvider: [ProviderID: Int] = [:], defaultPerProvider: Int? = nil) {
        self.global = max(1, global)
        self.perProject = max(1, perProject)
        self.perProvider = perProvider
        self.defaultPerProvider = defaultPerProvider
    }

    func providerLimit(_ provider: ProviderID) -> Int? { perProvider[provider] ?? defaultPerProvider }
}

/// What happens to an approval that nobody answered in time (spec L3). Never an automatic approval.
public enum ApprovalTimeoutAction: String, Hashable, Sendable, Codable {
    /// Job → `paused`; the session keeps waiting and the approval stays answerable.
    case pause
    /// Session is stopped, job → `failed`.
    case fail
}

public struct ApprovalTimeoutPolicy: Hashable, Sendable, Codable {
    /// nil = wait indefinitely.
    public var timeout: TimeInterval?
    public var action: ApprovalTimeoutAction

    public init(timeout: TimeInterval? = 3600, action: ApprovalTimeoutAction = .pause) {
        self.timeout = timeout
        self.action = action
    }
}

public struct JobOrchestratorConfiguration: Sendable {
    /// This Mac. Only projects whose `hostId` equals it are executed here (spec N4, A33).
    public var hostId: HostID
    /// Lock owner text (spec L1).
    public var lockOwner: String
    /// Controlled directory for agent worktrees, outside every scan root (spec L2).
    public var worktreesBaseDirectory: URL
    /// Parent for temporary integration worktrees (ADR-0015).
    public var integrationWorktreeDirectory: URL
    /// Recursive scan roots (Stammordner); the worktree base must not lie inside them.
    public var scanRoots: [URL]
    /// App-support directory for per-job runtime records and review details.
    public var runtimeDirectory: URL
    public var limits: ConcurrencyLimits
    public var lockLeaseDuration: TimeInterval
    public var heartbeatInterval: TimeInterval
    public var approvalTimeout: ApprovalTimeoutPolicy
    public var quotaRetryPlanner: QuotaRetryPlanner
    /// Upper bound for `nextWakeDate` while nothing else is due.
    public var maximumIdleInterval: TimeInterval
    /// Commits uncommitted agent output on the job branch before review capture so the result is
    /// reviewable and integrable (only the job's own branch; never the default branch).
    public var commitAgentChangesOnFinish: Bool
    /// `tick` records the host heartbeat (`AgentHost.lastSeen`, spec N4) after each pass.
    public var recordsHostHeartbeat: Bool

    public init(
        hostId: HostID,
        lockOwner: String = "SoftwareRegisseur Agent Service",
        worktreesBaseDirectory: URL,
        integrationWorktreeDirectory: URL,
        scanRoots: [URL],
        runtimeDirectory: URL,
        limits: ConcurrencyLimits = ConcurrencyLimits(),
        lockLeaseDuration: TimeInterval = 600,
        heartbeatInterval: TimeInterval = 60,
        approvalTimeout: ApprovalTimeoutPolicy = ApprovalTimeoutPolicy(),
        quotaRetryPlanner: QuotaRetryPlanner = QuotaRetryPlanner(),
        maximumIdleInterval: TimeInterval = 300,
        commitAgentChangesOnFinish: Bool = true,
        recordsHostHeartbeat: Bool = true
    ) {
        self.hostId = hostId
        self.lockOwner = lockOwner
        self.worktreesBaseDirectory = worktreesBaseDirectory
        self.integrationWorktreeDirectory = integrationWorktreeDirectory
        self.scanRoots = scanRoots
        self.runtimeDirectory = runtimeDirectory
        self.limits = limits
        self.lockLeaseDuration = lockLeaseDuration
        self.heartbeatInterval = heartbeatInterval
        self.approvalTimeout = approvalTimeout
        self.quotaRetryPlanner = quotaRetryPlanner
        self.maximumIdleInterval = maximumIdleInterval
        self.commitAgentChangesOnFinish = commitAgentChangesOnFinish
        self.recordsHostHeartbeat = recordsHostHeartbeat
    }
}

/// Injected collaborators. Everything with side effects outside the database is replaceable in tests.
public struct JobOrchestratorDependencies: Sendable {
    public var jobs: any AgentJobRepository
    public var locks: any TaskLockRepository
    public var workItems: any WorkItemRepository
    public var projects: any ProjectRepository
    public var capabilities: any CapabilityRepository
    public var preferences: any PreferenceRepository
    public var reviews: any ReviewRepository
    public var events: any EventLog
    /// Synced approval requests and user decisions (spec J6 V1 fallback).
    public var approvals: any ApprovalRepository
    public var providers: AgentProviderRegistry
    public var git: GitClient
    public var processInspector: any ProcessInspecting
    public var clock: any JobClock
    public var promptBuilder: AgentPromptBuilder
    /// Seed for quota backoff jitter; nil = random.
    public var randomSeed: UInt64?
    /// Repository-relative request file of a work item (Markdown layer), named in the agent prompt.
    public var requestFilePath: (@Sendable (WorkItem) async -> String?)?
    /// Repository-relative document folders (ADR folder, requests root) of the project's effective
    /// folder layout (ADR-0024). Uncommitted changes there do not block the integration, and agents are
    /// told not to touch them. nil = derived from the stored `ProjectSettings` (or their defaults).
    public var documentPaths: (@Sendable (ProjectID) async -> [String])?
    /// Currently confirmed root folders (Stammordner) of this Mac (SR-SEC-01, ADR-0026). A repository
    /// location is only used when its canonical path lies inside one of them. nil = the roots of
    /// `JobOrchestratorConfiguration.scanRoots` (fixed at service start). The service should pass a
    /// live source so roots confirmed later are honoured.
    public var allowedRepositoryRoots: (@Sendable () async -> [URL])?

    public init(
        jobs: any AgentJobRepository,
        locks: any TaskLockRepository,
        workItems: any WorkItemRepository,
        projects: any ProjectRepository,
        capabilities: any CapabilityRepository,
        preferences: any PreferenceRepository,
        reviews: any ReviewRepository,
        events: any EventLog,
        approvals: any ApprovalRepository,
        providers: AgentProviderRegistry,
        git: GitClient,
        processInspector: any ProcessInspecting = DarwinProcessInspector(),
        clock: any JobClock = SystemJobClock(),
        promptBuilder: AgentPromptBuilder = AgentPromptBuilder(),
        randomSeed: UInt64? = nil,
        requestFilePath: (@Sendable (WorkItem) async -> String?)? = nil,
        documentPaths: (@Sendable (ProjectID) async -> [String])? = nil,
        allowedRepositoryRoots: (@Sendable () async -> [URL])? = nil
    ) {
        self.requestFilePath = requestFilePath
        self.documentPaths = documentPaths
        self.allowedRepositoryRoots = allowedRepositoryRoots
        self.jobs = jobs
        self.locks = locks
        self.workItems = workItems
        self.projects = projects
        self.capabilities = capabilities
        self.preferences = preferences
        self.reviews = reviews
        self.events = events
        self.approvals = approvals
        self.providers = providers
        self.git = git
        self.processInspector = processInspector
        self.clock = clock
        self.promptBuilder = promptBuilder
        self.randomSeed = randomSeed
    }

    /// All repositories from one database (the Agent Service is the single writer, ADR-0019).
    public init(
        database: AppDatabase,
        providers: AgentProviderRegistry,
        git: GitClient,
        processInspector: any ProcessInspecting = DarwinProcessInspector(),
        clock: any JobClock = SystemJobClock(),
        promptBuilder: AgentPromptBuilder = AgentPromptBuilder(),
        randomSeed: UInt64? = nil,
        requestFilePath: (@Sendable (WorkItem) async -> String?)? = nil,
        documentPaths: (@Sendable (ProjectID) async -> [String])? = nil,
        allowedRepositoryRoots: (@Sendable () async -> [URL])? = nil
    ) {
        self.init(
            jobs: database.jobs, locks: database.locks, workItems: database.workItems, projects: database.projects,
            capabilities: database.capabilities, preferences: database.preferences, reviews: database.reviews,
            events: database.events, approvals: database.approvals, providers: providers, git: git, processInspector: processInspector,
            clock: clock, promptBuilder: promptBuilder, randomSeed: randomSeed, requestFilePath: requestFilePath,
            documentPaths: documentPaths, allowedRepositoryRoots: allowedRepositoryRoots
        )
    }
}

// MARK: - Clock

/// Time source for event timestamps. The service loop passes explicit `now` values to `tick(now:)`.
public protocol JobClock: Sendable {
    func now() -> Date
}

public struct SystemJobClock: JobClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Deterministic jitter source (SplitMix64).
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
