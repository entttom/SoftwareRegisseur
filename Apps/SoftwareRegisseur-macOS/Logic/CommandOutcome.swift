import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Rückmeldung eines Dienstbefehls für die Oberfläche. Keine stillen Erfolge (IPC-README).
enum CommandFeedback: Hashable, Sendable {
    case success(String)
    /// Angenommen, läuft im Hintergrund weiter.
    case accepted(String)
    case failure(String)

    var message: String {
        switch self {
        case let .success(text), let .accepted(text), let .failure(text): text
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// Ergebnis eines gesendeten Befehls: das typisierte Ergebnis (falls vorhanden) und die Rückmeldung.
struct CommandOutcome: Hashable, Sendable {
    var result: ServiceResult?
    var feedback: CommandFeedback

    var succeeded: Bool { !feedback.isFailure }

    /// Bildet eine Dienstantwort auf eine deutsche Rückmeldung ab. `title` beschreibt die Aktion
    /// („Scanner aktualisieren“) und wird bei Erfolg ohne eigene Meldung verwendet.
    static func from(_ response: ServiceResponse, title: String) -> CommandOutcome {
        switch response {
        case let .result(result):
            return CommandOutcome(result: result, feedback: feedback(for: result, title: title))
        case let .failure(message):
            return CommandOutcome(result: nil, feedback: .failure(message))
        case let .notAvailable(feature):
            return CommandOutcome(result: nil, feedback: .failure(
                String(localized: "„\(title)“ ist nicht möglich: \(feature.localizedName) ist in diesem Dienst nicht verfügbar.")))
        case let .protocolMismatch(serviceVersion, clientVersion):
            return CommandOutcome(result: nil, feedback: .failure(protocolMismatchText(service: serviceVersion, client: clientVersion)))
        case let .runState(state):
            return CommandOutcome(result: nil, feedback: .success(
                state == .paused ? String(localized: "Dienst pausiert: keine neuen Agentenstarts.")
                    : String(localized: "Dienst fortgesetzt.")))
        case .stopping:
            return CommandOutcome(result: nil, feedback: .success(String(localized: "Dienst wird beendet.")))
        case .pong, .health, .statusSummary:
            return CommandOutcome(result: nil, feedback: .success(String(localized: "„\(title)“ abgeschlossen.")))
        }
    }

    static func from(_ error: ServiceClientError, title: String) -> CommandOutcome {
        CommandOutcome(result: nil, feedback: .failure(clientErrorText(error, title: title)))
    }

    static func feedback(for result: ServiceResult, title: String) -> CommandFeedback {
        let done = String(localized: "„\(title)“ abgeschlossen.")
        switch result {
        case let .done(message):
            return .success(message ?? done)
        case let .accepted(message):
            return .accepted(message ?? String(localized: "„\(title)“ wurde angenommen und läuft im Hintergrund."))
        case let .syncFinished(info):
            return syncFeedback(info)
        case let .scanFinished(info):
            var text = String(localized: "Scan abgeschlossen: \(info.indexedFolders) Ordner, \(info.createdProjects) neue und \(info.updatedProjects) aktualisierte Projekte.")
            if info.unavailableProjects > 0 {
                text += " " + String(localized: "\(info.unavailableProjects) Projekte nicht erreichbar.")
            }
            if !info.issues.isEmpty {
                text += " " + info.issues.joined(separator: " ")
            }
            return .success(text)
        case let .job(info):
            return .success(info.wasCreated
                ? String(localized: "Job angelegt: \(info.state.germanDisplayName).")
                : String(localized: "Job aktualisiert: \(info.state.germanDisplayName)."))
        case let .integration(info):
            return .success(String(localized: "Integriert per \(IntegrationStrategy.displayName(raw: info.strategy)) als \(String(info.commitSHA.prefix(10))). Es wurde nichts gepusht."))
        case let .workItem(id):
            return .success(String(localized: "Aufgabe angelegt (\(id.shortString))."))
        case let .workItemSaved(info):
            return .success(info.message)
        case let .adrCreated(info):
            return .success(String(localized: "ADR-\(String(format: "%04d", info.number)) als Entwurf angelegt: \(info.relativePath). Es wurde nichts committet."))
        case let .localDeletionPreview(preview):
            return .success(preview.summary)
        case let .localDeletionReport(report):
            return report.isComplete ? .success(DeletionConfirmation.summary(report))
                : .failure(DeletionConfirmation.summary(report) + " " + report.failed.joined(separator: " "))
        case .cloudDeletionPreview:
            return .success(String(localized: "Vorschau der iCloud-Löschung erstellt."))
        case let .gitHubProjectState(state):
            return .success(state.enabled ? String(localized: "GitHub ist für dieses Projekt aktiv.")
                            : String(localized: "GitHub ist für dieses Projekt nicht aktiv."))
        default:
            return .success(done)
        }
    }

    static func syncFeedback(_ info: SyncRunInfo) -> CommandFeedback {
        switch info.outcome {
        case .completed:
            return .success(String(localized: "Synchronisiert: \(info.applied) empfangen, \(info.sent) gesendet, \(info.conflicts) Konflikte."))
        case .coalesced:
            return .success(String(localized: "Eine Synchronisierung lief bereits; sie wurde zusammengelegt."))
        case .deferred:
            return .accepted(info.message ?? String(localized: "Synchronisierung zurückgestellt."))
        case .paused:
            return .failure(info.message ?? String(localized: "Synchronisierung pausiert – Entscheidung nötig."))
        case .failed:
            return .failure(info.message ?? String(localized: "Synchronisierung fehlgeschlagen."))
        }
    }

    static func protocolMismatchText(service: Int, client: Int) -> String {
        String(localized: "Dienst und App haben unterschiedliche Versionen (Dienst \(service), App \(client)) – Dienst neu starten.")
    }

    static func clientErrorText(_ error: ServiceClientError, title: String) -> String {
        switch error {
        case .connectionFailed:
            String(localized: "„\(title)“ fehlgeschlagen: Der Hintergrunddienst ist nicht erreichbar. Bitte in den Einstellungen den Dienst aktivieren oder starten.")
        case .timedOut:
            String(localized: "„\(title)“: Der Dienst hat nicht rechtzeitig geantwortet. Der Vorgang kann im Hintergrund weiterlaufen – bitte den Status prüfen.")
        case let .protocolMismatch(service, client):
            protocolMismatchText(service: service, client: client)
        }
    }
}
