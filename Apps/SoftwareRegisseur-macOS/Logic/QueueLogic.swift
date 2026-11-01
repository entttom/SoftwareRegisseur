import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Filter der Warteschlangenansicht (Pflichtenheft P: zeitgeplante, aktive, pausierte, fehlgeschlagene Jobs).
enum QueueFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case active
    case waiting
    case paused
    case problems
    case finished
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .active: String(localized: "Aktiv")
        case .waiting: String(localized: "Wartend & geplant")
        case .paused: String(localized: "Pausiert")
        case .problems: String(localized: "Blockiert & fehlgeschlagen")
        case .finished: String(localized: "Abgeschlossen")
        case .all: String(localized: "Alle")
        }
    }

    var states: Set<AgentJobState> {
        switch self {
        case .active: [.admitted, .starting, .running, .waitingApproval]
        case .waiting: [.requested, .pendingMac, .scheduled, .waitingQuota]
        case .paused: [.paused]
        case .problems: [.needsConfiguration, .failed]
        case .finished: [.finished, .cancelled]
        case .all: Set(AgentJobState.allCases)
        }
    }

    static func category(of state: AgentJobState) -> QueueFilter {
        allCases.first { $0 != .all && $0.states.contains(state) } ?? .all
    }

    /// Jobs des Filters in Warteschlangenreihenfolge: Priorität, geplanter Start, Anlagezeit.
    func apply(to jobs: [AgentJob], provider: ProviderID? = nil) -> [AgentJob] {
        jobs.filter { states.contains($0.state) && (provider == nil || $0.providerId == provider) }
            .sorted(by: QueueOrdering.precedes)
    }
}

enum QueueOrdering {
    static func precedes(_ lhs: AgentJob, _ rhs: AgentJob) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        let left = lhs.scheduledAt ?? .distantFuture
        let right = rhs.scheduledAt ?? .distantFuture
        if left != right { return left < right }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.jobId.uuidString < rhs.jobId.uuidString
    }
}

/// Steueraktionen eines Jobs. Angeboten wird nur, was im aktuellen Zustand tatsächlich wirkt (P: keine toten Buttons).
enum JobAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case resolveMissedRunNow
    case resolveMissedRunSkip
    case pause
    case resume
    case cancel
    case retry
    case replaceConfiguration
    case setExpectedQuotaReset
    case terminateOrphanedProcess
    case removeWorktree

    var id: Self { self }

    var title: String {
        switch self {
        case .resolveMissedRunNow: String(localized: "Verpassten Termin jetzt nachholen")
        case .resolveMissedRunSkip: String(localized: "Verpassten Termin überspringen")
        case .pause: String(localized: "Pausieren")
        case .resume: String(localized: "Fortsetzen")
        case .cancel: String(localized: "Abbrechen")
        case .retry: String(localized: "Wiederholen")
        case .replaceConfiguration: String(localized: "Modell/Stufe ersetzen …")
        case .setExpectedQuotaReset: String(localized: "Erwarteten Kontingent-Reset setzen …")
        case .terminateOrphanedProcess: String(localized: "Verwaisten Prozess beenden")
        case .removeWorktree: String(localized: "Worktree entfernen")
        }
    }

    var symbolName: String {
        switch self {
        case .resolveMissedRunNow: "play.fill"
        case .resolveMissedRunSkip: "forward.end"
        case .pause: "pause"
        case .resume: "play"
        case .cancel: "xmark.circle"
        case .retry: "arrow.clockwise"
        case .replaceConfiguration: "slider.horizontal.3"
        case .setExpectedQuotaReset: "hourglass"
        case .terminateOrphanedProcess: "bolt.slash"
        case .removeWorktree: "trash"
        }
    }

    /// Aktionen, die eine Rückfrage brauchen, weil sie nicht rückgängig zu machen sind.
    var isDestructive: Bool {
        switch self {
        case .cancel, .terminateOrphanedProcess, .removeWorktree: true
        default: false
        }
    }

    /// Verfügbare Aktionen aus Jobzustand und (optional) hostlokalen Details des Dienstes.
    static func available(for job: AgentJob, status: JobStatusInfo?) -> [JobAction] {
        var actions: [JobAction] = []
        if status?.awaitingMissedRunDecision == true {
            actions += [.resolveMissedRunNow, .resolveMissedRunSkip]
        }
        if job.state.canTransition(to: .paused) { actions.append(.pause) }
        if job.state == .paused { actions.append(.resume) }
        if job.state.isActive { actions.append(.cancel) }
        if job.state.isTerminal { actions.append(.retry) }
        if job.startedAt == nil, AgentJobState.configurationReplaceable.contains(job.state) {
            actions.append(.replaceConfiguration)
        }
        if job.state == .waitingQuota || isQuotaSchedule(job.schedule.kind) && job.state.isActive && job.startedAt == nil {
            actions.append(.setExpectedQuotaReset)
        }
        if status?.orphanedProcess == true { actions.append(.terminateOrphanedProcess) }
        if job.state.isTerminal, (status?.worktreePath ?? job.worktreePath) != nil {
            actions.append(.removeWorktree)
        }
        return actions
    }

    private static func isQuotaSchedule(_ kind: ScheduleKind) -> Bool {
        if case .retryAfterQuota = kind { return true }
        return false
    }

    /// Dienstbefehl der Aktion. Aktionen mit eigener Eingabe (Konfiguration, Reset-Zeit) liefern `nil`.
    func request(for jobId: JobID, idempotencyKey: IdempotencyKey = IdempotencyKey()) -> ServiceRequest? {
        switch self {
        case .resolveMissedRunNow: .resolveMissedRun(jobId: jobId, runNow: true)
        case .resolveMissedRunSkip: .resolveMissedRun(jobId: jobId, runNow: false)
        case .pause: .pauseJob(jobId: jobId)
        case .resume: .resumeJob(jobId: jobId)
        case .cancel: .cancelJob(jobId: jobId)
        case .retry: .retryJob(jobId: jobId, idempotencyKey: idempotencyKey)
        case .terminateOrphanedProcess: .terminateOrphanedProcess(jobId: jobId)
        case .removeWorktree: .removeWorktree(jobId: jobId)
        case .replaceConfiguration, .setExpectedQuotaReset: nil
        }
    }
}

/// Darstellung der Modell-/Effort-Konfiguration eines Jobs (J2a: angefragt, aufgelöst, effektiv).
struct JobConfigurationText: Hashable, Sendable {
    var requested: String
    var resolved: String
    var effective: String
    var sources: String

    init(job: AgentJob) {
        let notSet = String(localized: "Standard übernommen")
        let requestedModel = job.configSnapshot.requestedModel?.germanDisplayName ?? notSet
        let requestedEffort = job.requestedEffort?.germanDisplayName ?? notSet
        requested = "\(requestedModel) · \(requestedEffort)"
        resolved = "\(job.resolvedModel.germanDisplayName) · \(job.resolvedEffort.germanDisplayName)"
        effective = job.effectiveModelId == nil && job.effectiveEffort == nil
            ? AgentJob.unconfirmedText
            : "\(job.effectiveModelDisplayText) · \(job.effectiveEffortDisplayText)"
        sources = String(localized: "Modell aus: \(job.profileSource.model.displayName), Stufe aus: \(job.profileSource.effort.displayName)")
    }
}

/// Planungszeile eines Jobs aus synchronisierten Daten (K3), ergänzt um den Zustand.
enum JobScheduleText {
    static func text(for job: AgentJob, hostLastSeen: Date?, now: Date) -> String {
        if let text = ScheduleStatusText.status(for: job, hostLastSeen: hostLastSeen, now: now) {
            return text
        }
        switch job.schedule.kind {
        case .manualPause where !job.state.isTerminal && job.startedAt == nil:
            return String(localized: "gespeichert – wartet auf manuelle Freigabe")
        default:
            return job.state.germanDisplayName
        }
    }
}
