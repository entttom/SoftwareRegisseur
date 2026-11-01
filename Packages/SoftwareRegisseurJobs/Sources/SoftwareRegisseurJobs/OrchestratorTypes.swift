import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit

public enum JobOrchestratorError: Error, Hashable, Sendable {
    case jobNotFound(JobID)
    case workItemNotFound(WorkItemID)
    case projectNotFound(ProjectID)
    case reviewNotFound(ReviewID)
    case workItemWithoutProject(WorkItemID)
    /// Approvals, review decisions, integration and completion need an explicit user (spec L3, M1).
    case userDecisionRequired
    case notExecutionHost(ProjectID)
    case capabilityUnknown(ProviderID)
    case configurationInvalid([ConfigurationIssue])
    case invalidState(JobID, AgentJobState)
    case noLiveSession(JobID)
    case unknownApproval(ApprovalRequestID)
    case decisionNotAvailable(AgentApprovalDecision)
    case approvalPending(JobID)
    case orphanProcessRunning(JobID)
    case noMissedRunPending(JobID)
    case reviewNotApproved(ReviewDecision)
    case alreadyIntegrated(String)
    case workItemNotInReview(WorkItemStatus)
    case notIntegrated(WorkItemStatus)
    case integrationCommitNotInDefaultBranch(String)
    /// Integration conflicts; nothing was changed in the repository (ADR-0015).
    case integrationConflict(files: [String])
    case integrationRefused(String)
    case reviewDataUnavailable(JobID)
    case repositoryUnavailable(ProjectID)
}

/// Why a due job was not started in this tick. Shown to the user (spec J2: Queue-Status).
public enum AdmissionBlock: Hashable, Sendable {
    case notExecutionHost
    case globalLimit(Int)
    case projectLimit(Int)
    case providerLimit(ProviderID, Int)
    case dependenciesOpen([WorkItemID])
    case taskLocked(LockID)
    case projectLocked(LockID)
    case repositoryUnavailable
    case defaultBranchUnknown
    case mainWorkingTreeConflicted([String])
    case providerUnavailable(ProviderID)
    case agentNotRunnable(String)
    case awaitingMissedRunDecision(Date)
    case workItemMissing
    case startFailed(String)

    public var germanDescription: String {
        switch self {
        case .notExecutionHost: String(localized: "Dieser Mac ist nicht der Ausführungshost des Projekts.", bundle: .module)
        case let .globalLimit(limit): String(localized: "Maximal \(limit) parallele Läufe erreicht.", bundle: .module)
        case let .projectLimit(limit): String(localized: "Maximal \(limit) parallele Läufe in diesem Projekt erreicht.", bundle: .module)
        case let .providerLimit(provider, limit): String(localized: "Maximal \(limit) parallele Läufe für \(provider.rawValue) erreicht.", bundle: .module)
        case let .dependenciesOpen(ids): String(localized: "Wartet auf \(ids.count) noch nicht erledigte Abhängigkeit(en).", bundle: .module)
        case .taskLocked: String(localized: "Aufgabe ist durch einen anderen Lauf gesperrt.", bundle: .module)
        case .projectLocked: String(localized: "Projektweite Sperre: im Repository läuft bereits ein Agent.", bundle: .module)
        case .repositoryUnavailable: String(localized: "Repository auf diesem Mac nicht gefunden.", bundle: .module)
        case .defaultBranchUnknown: String(localized: "Default-Branch des Repositorys unbekannt.", bundle: .module)
        case let .mainWorkingTreeConflicted(files): String(localized: "Stamm-Working-Tree hat ungelöste Konflikte (\(files.count) Datei(en)).", bundle: .module)
        case let .providerUnavailable(provider): String(localized: "Agent \(provider.rawValue) ist auf diesem Mac nicht registriert.", bundle: .module)
        case let .agentNotRunnable(reason): String(localized: "Agent nicht einsatzbereit: \(reason)", bundle: .module)
        case .awaitingMissedRunDecision: String(localized: "Geplanter Start verpasst – Entscheidung erforderlich.", bundle: .module)
        case .workItemMissing: String(localized: "Aufgabe nicht gefunden.", bundle: .module)
        case let .startFailed(reason): String(localized: "Start fehlgeschlagen: \(reason)", bundle: .module)
        }
    }
}

public struct TickReport: Sendable {
    public let now: Date
    /// Another tick was running; nothing was done.
    public var skipped = false
    public var takenOver: [JobID] = []
    /// Jobs of projects executed by another host; left untouched (spec N4, A33).
    public var foreign: [JobID] = []
    public var started: [JobID] = []
    public var blocked: [JobID: AdmissionBlock] = [:]
    public var needsConfiguration: [JobID: [ConfigurationIssue]] = [:]
    public var missed: [JobID: MissedRunAction] = [:]
    public var failed: [JobID: String] = [:]
    public var approvalTimeouts: [JobID] = []
    /// Synced user decisions relayed to agents in this tick (spec J6 V1 fallback).
    public var approvalsAnswered: [PendingApprovalID] = []
    /// Synced decisions ignored because their approval expired or the session ended.
    public var approvalsClosed: [PendingApprovalID] = []
    public var releasedLocks: [LockID] = []
    public var errors: [String] = []
    public var nextWakeDate: Date

    init(now: Date) {
        self.now = now
        nextWakeDate = now
    }
}

public enum RecoveryAction: Hashable, Sendable {
    /// Admitted but never started a process → back to the queue.
    case requeued
    /// Agent process gone → `failed`, worktree preserved.
    case failed(preservedWorktree: Bool)
    /// Agent process still alive without session → `paused`, lock kept, no second start.
    case orphanPaused(pid: Int32?)
    /// Process or worktree state unknown → `paused`, lock awaits reconciliation.
    case needsUserDecision
    case unchanged
}

public struct RecoveryReport: Sendable {
    public let recoveredAt: Date
    /// Last host heartbeat before this start (for „Mac zuletzt online“).
    public let hostLastSeenBeforeStart: Date?
    public var actions: [JobID: RecoveryAction] = [:]
    public var releasedLocks: [LockID] = []
    public var keptLocks: [LockID: LockReleaseDecision] = [:]
    public var errors: [String] = []
}

/// Planning status for UIs (spec K3: „für 22:00 geplant, Mac zuletzt online 21:30“ statt „läuft“).
/// The texts come from the Domain `ScheduleStatusText`, shared with the iPhone.
public struct JobScheduleStatus: Hashable, Sendable {
    public let jobId: JobID
    public let state: AgentJobState
    public let plannedStart: Date?
    public let timeZoneIdentifier: String?
    public let hostLastSeen: Date?
    public let missedRun: MissedRunRecord?
    public let nextQuotaAttempt: QuotaRetryState?
    public let admissionBlock: AdmissionBlock?
    public let text: String
}

extension SoftwareRegisseurGit.IntegrationStrategy {
    init(_ domain: SoftwareRegisseurDomain.IntegrationStrategy) {
        switch domain {
        case .squash: self = .squash
        case .mergeCommit: self = .mergeCommit
        case .cherryPick: self = .cherryPick
        }
    }
}

extension EventActor {
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    var payloadText: String {
        switch self {
        case let .user(device): "user:\(device.uuidString)"
        case let .host(host): "host:\(host.uuidString)"
        case let .agent(provider, job): "agent:\(provider.rawValue):\(job.uuidString)"
        case .external: "external"
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
