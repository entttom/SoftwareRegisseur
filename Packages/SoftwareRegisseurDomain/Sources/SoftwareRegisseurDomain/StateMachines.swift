import Foundation

/// A state of an explicit, table-driven state machine (ADR-0012). Self-transitions are never allowed.
public protocol StateMachineState: Hashable, Sendable, Codable, CaseIterable where AllCases == [Self] {
    static var allowedTransitions: [Self: Set<Self>] { get }
}

public struct InvalidStateTransition<State: StateMachineState>: Error, Hashable, Sendable, CustomStringConvertible {
    public let from: State
    public let to: State

    public init(from: State, to: State) {
        self.from = from
        self.to = to
    }

    public var description: String { "Invalid \(State.self) transition \(from) → \(to)" }
}

extension StateMachineState {
    public var allowedNextStates: Set<Self> { Self.allowedTransitions[self] ?? [] }

    public func canTransition(to next: Self) -> Bool {
        next != self && allowedNextStates.contains(next)
    }

    public mutating func transition(to next: Self) throws(InvalidStateTransition<Self>) {
        guard canTransition(to: next) else { throw InvalidStateTransition(from: self, to: next) }
        self = next
    }

    /// Returns the target state if the transition is allowed.
    public func transitioned(to next: Self) throws(InvalidStateTransition<Self>) -> Self {
        var copy = self
        try copy.transition(to: next)
        return copy
    }

    public var isTerminal: Bool { allowedNextStates.isEmpty }
}

// MARK: - Project

/// Project status (spec E2, ADR-0012).
public enum ProjectStatus: String, StateMachineState {
    case pendingMacSetup
    case ready
    case unavailable
    case needsAttention
    case archived

    public static let allowedTransitions: [ProjectStatus: Set<ProjectStatus>] = [
        .pendingMacSetup: [.ready, .unavailable, .needsAttention, .archived],
        .ready: [.unavailable, .needsAttention, .archived],
        .unavailable: [.ready, .needsAttention, .archived],
        .needsAttention: [.ready, .unavailable, .archived],
        // Unarchiving re-enters through Mac reconciliation; a never-set-up project goes back to setup.
        .archived: [.pendingMacSetup, .ready, .unavailable, .needsAttention],
    ]

    public var germanDisplayName: String {
        switch self {
        case .pendingMacSetup: String(localized: "Einrichtung am Mac ausstehend", bundle: .module)
        case .ready: String(localized: "Bereit", bundle: .module)
        case .unavailable: String(localized: "Nicht erreichbar", bundle: .module)
        case .needsAttention: String(localized: "Benötigt Aufmerksamkeit", bundle: .module)
        case .archived: String(localized: "Archiviert", bundle: .module)
        }
    }
}

// MARK: - WorkItem

/// Task status, stored in Markdown frontmatter `status` (spec F5, ADR-0012).
/// Run-specific states (`pendingMac`, `needs_configuration`, `waiting_quota`) live only on `AgentJobState`.
public enum WorkItemStatus: String, StateMachineState {
    case inbox
    case open
    case queued
    case scheduled
    case inProgress = "in_progress"
    case waitingApproval = "waiting_approval"
    case implementationFinished = "implementation_finished"
    case review
    case integrated
    case done
    case blocked
    case failed
    case cancelled
    case paused

    /// Statuses a new agent job may start from; also what a cancelled job returns to (ADR-0012).
    public static let jobStartable: Set<WorkItemStatus> = [
        .inbox, .open, .blocked, .failed, .paused, .implementationFinished, .review,
    ]

    /// Statuses a job can derive when it is first seen (`requested`/`pendingMac`/`scheduled`/`admitted`/`needs_configuration`).
    private static let jobEntry: Set<WorkItemStatus> = [.queued, .scheduled, .inProgress, .blocked]

    /// The table contains manual transitions plus every transition produced by `derived(from:previous:)`
    /// while a job moves through `AgentJobState` (verified by tests). `integrated` is reachable only from
    /// `review` and `done` only from `integrated`, or as manual completion of an `inbox`/`open` item that
    /// never needed an agent run.
    public static let allowedTransitions: [WorkItemStatus: Set<WorkItemStatus>] = {
        let start = jobEntry
        let back = jobStartable
        let table: [WorkItemStatus: Set<WorkItemStatus>] = [
            .inbox: start.union([.open, .paused, .cancelled, .done]),
            .open: start.union([.inbox, .paused, .cancelled, .done]),
            .queued: back.union([.scheduled, .inProgress, .blocked, .paused, .failed, .cancelled]),
            .scheduled: back.union([.queued, .inProgress, .blocked, .paused, .failed, .cancelled]),
            .inProgress: back.union([
                .scheduled, .waitingApproval, .implementationFinished, .blocked, .paused, .failed, .cancelled,
            ]),
            .waitingApproval: back.union([.inProgress, .paused, .failed, .cancelled]),
            .blocked: back.union(start).union([.paused, .failed, .cancelled]),
            .paused: back.union(start).union([.failed, .cancelled]),
            .implementationFinished: start.union([.review, .open, .failed, .cancelled]),
            .review: start.union([.integrated, .open, .cancelled]),
            .integrated: [.done],
            .done: [.open],
            .failed: start.union([.open, .cancelled]),
            .cancelled: [.inbox, .open],
        ]
        return table.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.subtracting([entry.key])
        }
    }()

    public var canStartAgentJob: Bool { Self.jobStartable.contains(self) }

    /// ADR-0012 mapping while a job is active. Only the Mac host applies it.
    /// `previous` is the task status before the job started (returned for `cancelled`).
    /// `finished` maps to `implementation_finished`; `review` follows only after diff/tests are captured,
    /// and `integrated`/`done` are never derived from a job (ADR-0007, ADR-0015).
    public static func derived(from jobState: AgentJobState, previous: WorkItemStatus) -> WorkItemStatus {
        switch jobState {
        case .requested, .pendingMac: .queued
        case .scheduled, .waitingQuota: .scheduled
        case .admitted, .starting, .running: .inProgress
        case .waitingApproval: .waitingApproval
        case .needsConfiguration: .blocked
        case .paused: .paused
        case .finished: .implementationFinished
        case .failed: .failed
        case .cancelled: previous
        }
    }

    public var germanDisplayName: String {
        switch self {
        case .inbox: String(localized: "Inbox", bundle: .module)
        case .open: String(localized: "Offen", bundle: .module)
        case .queued: String(localized: "In Warteschlange", bundle: .module)
        case .scheduled: String(localized: "Geplant", bundle: .module)
        case .inProgress: String(localized: "In Arbeit", bundle: .module)
        case .waitingApproval: String(localized: "Wartet auf Freigabe", bundle: .module)
        case .implementationFinished: String(localized: "Umsetzung beendet", bundle: .module)
        case .review: String(localized: "Review", bundle: .module)
        case .integrated: String(localized: "Integriert", bundle: .module)
        case .done: String(localized: "Erledigt", bundle: .module)
        case .blocked: String(localized: "Blockiert", bundle: .module)
        case .failed: String(localized: "Fehlgeschlagen", bundle: .module)
        case .cancelled: String(localized: "Abgebrochen", bundle: .module)
        case .paused: String(localized: "Pausiert", bundle: .module)
        }
    }
}

public enum WorkItemStatusChangeError: Error, Hashable, Sendable {
    case invalidTransition(InvalidStateTransition<WorkItemStatus>)
    /// ADR-0012: manual changes on a task with an active job are rejected, not silently applied.
    case activeJobConflict(current: WorkItemStatus, requested: WorkItemStatus)
}

extension WorkItemStatus {
    /// Validates a user-initiated status change.
    public func validateManualChange(to next: WorkItemStatus, hasActiveJob: Bool) throws(WorkItemStatusChangeError) {
        if hasActiveJob { throw .activeJobConflict(current: self, requested: next) }
        guard canTransition(to: next) else {
            throw .invalidTransition(InvalidStateTransition(from: self, to: next))
        }
    }
}

// MARK: - AgentJob

/// Agent job run state (ADR-0012). Stored only in the sync index/database, never in frontmatter.
/// `finished`, `failed` and `cancelled` are terminal; a manual retry creates a new job.
public enum AgentJobState: String, StateMachineState {
    case requested
    case pendingMac
    case scheduled
    case admitted
    case starting
    case running
    case finished
    case needsConfiguration = "needs_configuration"
    case waitingApproval = "waiting_approval"
    case waitingQuota = "waiting_quota"
    case paused
    case failed
    case cancelled

    public static let allowedTransitions: [AgentJobState: Set<AgentJobState>] = [
        .requested: [.pendingMac, .scheduled, .admitted, .needsConfiguration, .failed, .cancelled],
        // pendingMac → scheduled covers both host takeover and host change (spec N4).
        .pendingMac: [.scheduled, .admitted, .needsConfiguration, .failed, .cancelled],
        .scheduled: [.pendingMac, .admitted, .needsConfiguration, .waitingQuota, .paused, .failed, .cancelled],
        // admitted → scheduled: lock busy or parallel limit reached after admission.
        .admitted: [.starting, .scheduled, .needsConfiguration, .paused, .failed, .cancelled],
        .starting: [.running, .needsConfiguration, .waitingQuota, .failed, .cancelled],
        .running: [.finished, .waitingApproval, .waitingQuota, .paused, .failed, .cancelled],
        // Unanswered approvals pause or fail the job, never auto-approve (spec L3).
        .waitingApproval: [.running, .paused, .failed, .cancelled],
        .waitingQuota: [.scheduled, .admitted, .paused, .failed, .cancelled],
        .needsConfiguration: [.pendingMac, .scheduled, .failed, .cancelled],
        .paused: [.pendingMac, .scheduled, .running, .failed, .cancelled],
        .finished: [],
        .failed: [],
        .cancelled: [],
    ]

    /// States in which the configuration snapshot may still be replaced explicitly (spec J2a).
    public static let configurationReplaceable: Set<AgentJobState> = [
        .requested, .pendingMac, .scheduled, .needsConfiguration, .waitingQuota, .paused,
    ]

    public var isActive: Bool { !isTerminal }

    public var germanDisplayName: String {
        switch self {
        case .requested: String(localized: "Angefordert", bundle: .module)
        case .pendingMac: String(localized: "Wartet auf Mac", bundle: .module)
        case .scheduled: String(localized: "Geplant", bundle: .module)
        case .admitted: String(localized: "Zugelassen", bundle: .module)
        case .starting: String(localized: "Startet", bundle: .module)
        case .running: String(localized: "Läuft", bundle: .module)
        case .finished: String(localized: "Beendet", bundle: .module)
        case .needsConfiguration: String(localized: "Konfiguration erforderlich", bundle: .module)
        case .waitingApproval: String(localized: "Wartet auf Freigabe", bundle: .module)
        case .waitingQuota: String(localized: "Wartet auf Kontingent", bundle: .module)
        case .paused: String(localized: "Pausiert", bundle: .module)
        case .failed: String(localized: "Fehlgeschlagen", bundle: .module)
        case .cancelled: String(localized: "Abgebrochen", bundle: .module)
        }
    }
}

// MARK: - ADR

/// ADR status (spec F4). Acceptance requires explicit user approval; callers enforce who may accept.
public enum ADRStatus: String, StateMachineState {
    case proposed
    case accepted
    case deprecated
    case superseded

    public static let allowedTransitions: [ADRStatus: Set<ADRStatus>] = [
        .proposed: [.accepted, .deprecated],
        .accepted: [.deprecated, .superseded],
        .deprecated: [],
        .superseded: [],
    ]
}
