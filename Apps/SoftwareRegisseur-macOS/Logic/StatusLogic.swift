import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Ampel ohne „grün ohne Prüfung“ (D1): `ok` nur nach echter Antwort des Dienstes.
enum StatusLevel: Hashable, Sendable {
    case ok
    case info
    case warning
    case error
    case unknown
}

/// „Mac bereit / pausiert / offline“ aus Verbindung und Statusübersicht des Dienstes.
struct MacStatePresentation: Hashable, Sendable {
    var title: String
    var detail: String?
    var level: StatusLevel
    var symbolName: String

    /// `reachable == false` heißt: Dienst nicht erreichbar → „Mac offline“ (nur die UI stellt das fest).
    static func make(reachable: Bool?, summary: ServiceStatusSummary?) -> MacStatePresentation {
        guard let reachable else {
            return MacStatePresentation(title: String(localized: "Status wird geprüft …"), detail: nil, level: .unknown,
                                        symbolName: "circle.dotted")
        }
        guard reachable else {
            return MacStatePresentation(
                title: String(localized: "Mac offline"),
                detail: String(localized: "Der Hintergrunddienst antwortet nicht. Agenten starten erst wieder, wenn er läuft."),
                level: .error, symbolName: "bolt.horizontal.circle")
        }
        guard let summary else {
            return MacStatePresentation(title: String(localized: "Dienst erreichbar"),
                                        detail: String(localized: "Statusübersicht wird geladen …"), level: .unknown,
                                        symbolName: "circle.dotted")
        }
        switch summary.macState {
        case .ready:
            return MacStatePresentation(title: summary.macState.displayName, detail: nil, level: .ok, symbolName: "checkmark.circle")
        case .paused:
            return MacStatePresentation(title: summary.macState.displayName,
                                        detail: String(localized: "Keine neuen Agentenstarts. Laufende Jobs, Sync und Scanner laufen weiter."),
                                        level: .warning, symbolName: "pause.circle")
        case .degraded:
            return MacStatePresentation(title: summary.macState.displayName, detail: summary.problems.first,
                                        level: .warning, symbolName: "exclamationmark.triangle")
        case .starting:
            return MacStatePresentation(title: summary.macState.displayName, detail: nil, level: .info, symbolName: "hourglass")
        }
    }
}

/// iCloud-Zeile der Menüleiste (D1: Status und letzte Synchronisierung).
struct SyncPresentation: Hashable, Sendable {
    var title: String
    var detail: String?
    var level: StatusLevel

    static func make(_ sync: SyncSummary, now: Date) -> SyncPresentation {
        let last = sync.lastSync.map { String(localized: "Zuletzt synchronisiert \($0.formatted(.relative(presentation: .named, unitsStyle: .wide)))") }
            ?? String(localized: "Noch nie erfolgreich synchronisiert")
        switch sync.state {
        case .unavailable:
            return SyncPresentation(title: String(localized: "iCloud nicht verfügbar"),
                                    detail: sync.unavailableReason ?? last, level: .warning)
        case .idle:
            var detail = last
            if sync.pendingChanges > 0 { detail += " · " + String(localized: "\(sync.pendingChanges) Änderungen ausstehend") }
            if sync.openConflicts > 0 {
                return SyncPresentation(title: String(localized: "iCloud: \(sync.openConflicts) Konflikte"), detail: detail, level: .warning)
            }
            return SyncPresentation(title: String(localized: "iCloud bereit"), detail: detail, level: .ok)
        case .syncing:
            return SyncPresentation(title: String(localized: "iCloud synchronisiert …"), detail: last, level: .info)
        case .paused:
            return SyncPresentation(title: String(localized: "iCloud pausiert – Entscheidung nötig"),
                                    detail: sync.attention.first ?? last, level: .warning)
        case .failed:
            var detail = sync.lastError ?? last
            if let retry = sync.retryNotBefore, retry > now {
                detail += " · " + String(localized: "Nächster Versuch \(retry.formatted(date: .omitted, time: .shortened))")
            }
            return SyncPresentation(title: String(localized: "iCloud-Fehler"), detail: detail, level: .error)
        }
    }
}

/// Zahlen der Menüleiste (D1), direkt aus der Statusübersicht.
struct QueuePresentation: Hashable, Sendable {
    var waitingText: String
    var nextStartText: String?
    var problemsText: String?
    var reviewsText: String?
    var approvalsText: String?

    static func make(_ queue: QueueSummary, now: Date) -> QueuePresentation {
        let waiting = String(localized: "\(queue.waiting) wartend · \(queue.scheduled) geplant")
        let next = queue.nextPlannedStart.map {
            String(localized: "Nächster Start: \(ScheduleStatusText.format($0, now: now, timeZone: .current))")
        }
        var problems: String?
        if queue.blocked + queue.failed > 0 {
            problems = String(localized: "\(queue.blocked) blockiert · \(queue.failed) fehlgeschlagen")
        }
        let reviews = queue.reviewsPending > 0 ? String(localized: "\(queue.reviewsPending) zur Review") : nil
        let approvals = queue.openApprovals > 0 ? String(localized: "\(queue.openApprovals) offene Freigaben") : nil
        return QueuePresentation(waitingText: waiting, nextStartText: next, problemsText: problems, reviewsText: reviews,
                                 approvalsText: approvals)
    }
}

/// Agentenzeile der Menüleiste: einsatzbereit nur, wenn die Erkennung es belegt (J1).
struct AgentPresentation: Hashable, Sendable, Identifiable {
    var providerId: ProviderID
    var name: String
    var activeJobs: Int
    var stateText: String
    var level: StatusLevel

    var id: ProviderID { providerId }

    static func make(_ agent: AgentProviderSummary) -> AgentPresentation {
        let state: String
        let level: StatusLevel
        if !agent.installed {
            state = String(localized: "nicht installiert")
            level = .warning
        } else if !agent.authenticated {
            state = String(localized: "nicht angemeldet")
            level = .warning
        } else if !agent.ready {
            state = agent.diagnostic ?? String(localized: "nicht einsatzbereit")
            level = .warning
        } else if agent.activeJobs > 0 {
            state = String(localized: "\(agent.activeJobs) aktiv")
            level = .info
        } else {
            state = String(localized: "bereit, keine aktiven Läufe")
            level = .ok
        }
        let name = agent.displayName.isEmpty ? ProviderNames.displayName(agent.providerId) : agent.displayName
        return AgentPresentation(providerId: agent.providerId, name: name, activeJobs: agent.activeJobs, stateText: state, level: level)
    }
}
