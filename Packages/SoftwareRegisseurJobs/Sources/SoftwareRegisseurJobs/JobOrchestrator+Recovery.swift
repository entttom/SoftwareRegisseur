import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// Crash recovery on service start (spec D3, J3, L1; A21). Sessions do not survive a restart, so
/// every job that had a process is reconciled from process and worktree facts. Nothing is started
/// again automatically except jobs that never had a process (`admitted`).
extension JobOrchestrator {
    public func recover(at requested: Date) async -> RecoveryReport {
        let now = advance(to: requested)
        let lastSeen = try? await deps.capabilities.host(hostId)?.lastSeen
        hostLastSeenBeforeStart = lastSeen
        var report = RecoveryReport(recoveredAt: now, hostLastSeenBeforeStart: lastSeen)

        let jobs: [AgentJob]
        do {
            jobs = try await deps.jobs.jobs(inStates: [.admitted, .starting, .running, .waitingApproval, .paused],
                                            hostId: hostId, limit: nil)
        } catch {
            report.errors.append("recover: \(error)")
            return report
        }
        for job in jobs where runs[job.jobId] == nil {
            do {
                report.actions[job.jobId] = try await recover(job, now: now)
            } catch {
                report.errors.append("recover \(job.jobId): \(error)")
            }
        }

        if let locks = try? await deps.locks.activeLocks(hostId: hostId) {
            for lock in locks where runs[lock.jobId] == nil {
                let job = try? await deps.jobs.fetch(lock.jobId)
                switch await attemptLockRelease(lock, job: job, now: now) {
                case .released: report.releasedLocks.append(lock.lockId)
                case let .kept(decision): report.keptLocks[lock.lockId] = decision
                case .failed: report.errors.append("lock \(lock.lockId): Freigabe fehlgeschlagen")
                }
            }
        }
        return report
    }

    func recover(_ job: AgentJob, now: Date) async throws -> RecoveryAction {
        let record = runtime.record(job.jobId)
        let hadProcess = record?.processIdentifier != nil || record?.sessionUUID != nil || job.state != .admitted
        let openApprovals = ((try? await deps.approvals.approvals(jobId: job.jobId)) ?? []).filter(\.isOpen)
        if job.state == .paused, record?.orphanedProcess != true, openApprovals.isEmpty {
            return .unchanged // regular pause without process
        }
        let process: ProcessObservation = hadProcess ? observeProcess(record: record, job: job) : .notRunning
        let worktree = await observeWorktree(record?.worktreePath)
        // The session that could transport the answers is gone; later decisions are ignored.
        for approval in openApprovals {
            await closeApproval(approval, expired: true, reason: "serviceRestarted", at: now)
        }

        switch process {
        case .running:
            let pid = record?.processIdentifier
            _ = try? updateRecord(job.jobId) { $0.orphanedProcess = true }
            if job.state != .paused {
                try await move(job.jobId, to: .paused, at: now) {
                    let process = pid.map { " (PID \($0))" } ?? ""
                    $0.lastError = String(localized: "Dienst neu gestartet: Agentenprozess\(process) läuft ohne Verbindung weiter. Kein zweiter Start; Sperre bleibt bis zum Prozessende.", bundle: .module)
                }
            }
            return .orphanPaused(pid: pid)
        case .unknown:
            if job.state != .paused {
                try await move(job.jobId, to: .paused, at: now) {
                    $0.lastError = String(localized: "Dienst neu gestartet: Prozesszustand unbekannt – bitte prüfen.", bundle: .module)
                }
            }
            return .needsUserDecision
        case .notRunning:
            if !hadProcess {
                try await move(job.jobId, to: .scheduled, at: now)
                return .requeued
            }
            if job.state == .paused {
                _ = try? updateRecord(job.jobId) { $0.orphanedProcess = false }
                return .unchanged
            }
            try await move(job.jobId, to: .failed, at: now) {
                $0.lastError = String(localized: "Dienst wurde während des Laufs beendet; Agentenprozess nicht mehr aktiv. Ergebnis nicht erfasst – Worktree bleibt erhalten.", bundle: .module)
            }
            return .failed(preservedWorktree: worktree == .hasChanges || worktree == .clean)
        }
    }
}
