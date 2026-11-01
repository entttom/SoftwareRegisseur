import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import Synchronization

/// Schalter „Dienst pausiert“: keine neuen Agentenstarts (D1 Schnellaktion „Dienst pausieren“).
final class AdmissionGate: Sendable {
    private let open: Mutex<Bool>

    init(isOpen: Bool) {
        open = Mutex(isOpen)
    }

    var isOpen: Bool { open.withLock { $0 } }

    func set(open value: Bool) {
        open.withLock { $0 = value }
    }
}

/// Job-Repository für den `JobOrchestrator`, das bei geschlossenem ``AdmissionGate`` die Warteschlange
/// für die Zulassung leer meldet.
///
/// Der Orchestrator kennt (noch) keinen eigenen Pausenschalter. Er holt Kandidaten für die Zulassung
/// ausschließlich mit `jobs(inStates: [.scheduled, .waitingQuota], hostId: <dieser Mac>)`; genau diese
/// Abfrage wird bei Pause leer beantwortet. Alles andere – Übernahme neuer Wünsche, Heartbeats laufender
/// Jobs, Weitergabe von Freigaben, Lock-Abgleich, Steuerbefehle – läuft unverändert weiter, laufende
/// Jobs bleiben also beobachtbar und steuerbar. Ein während der Pause verstrichener Termin wird nach
/// dem Fortsetzen wie ein verpasster Termin behandelt (Nachholregel des Jobs, K3).
struct AdmissionGatedJobRepository: AgentJobRepository {
    let base: any AgentJobRepository
    let gate: AdmissionGate
    let hostId: HostID

    static let admissionStates: Set<AgentJobState> = [.scheduled, .waitingQuota]

    func create(_ job: AgentJob, actor: EventActor, at date: Date) async throws -> JobCreationResult {
        try await base.create(job, actor: actor, at: date)
    }

    func fetch(_ id: JobID) async throws -> AgentJob? { try await base.fetch(id) }

    func fetch(idempotencyKey: IdempotencyKey) async throws -> AgentJob? { try await base.fetch(idempotencyKey: idempotencyKey) }

    func jobs(forWorkItem id: WorkItemID) async throws -> [AgentJob] { try await base.jobs(forWorkItem: id) }

    func retries(of id: JobID) async throws -> [AgentJob] { try await base.retries(of: id) }

    func activeJob(forWorkItem id: WorkItemID) async throws -> AgentJob? { try await base.activeJob(forWorkItem: id) }

    func jobs(inStates states: Set<AgentJobState>, hostId: HostID?, limit: Int?) async throws -> [AgentJob] {
        if !gate.isOpen, states == Self.admissionStates, hostId == self.hostId {
            return []
        }
        return try await base.jobs(inStates: states, hostId: hostId, limit: limit)
    }

    func dueJobs(at date: Date, states: Set<AgentJobState>) async throws -> [AgentJob] {
        if !gate.isOpen { return [] }
        return try await base.dueJobs(at: date, states: states)
    }

    func transition(_ id: JobID, to state: AgentJobState, actor: EventActor, at date: Date) async throws -> JobChange {
        try await base.transition(id, to: state, actor: actor, at: date)
    }

    func update(
        _ id: JobID, expectedRevision: Int, actor: EventActor, at date: Date,
        _ mutate: @Sendable (inout AgentJob) throws -> Void
    ) async throws -> JobChange {
        try await base.update(id, expectedRevision: expectedRevision, actor: actor, at: date, mutate)
    }
}
