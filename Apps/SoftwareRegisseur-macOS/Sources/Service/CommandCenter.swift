import Foundation
import Observation
import SoftwareRegisseurIPC

/// Ein laufender Dienstbefehl (Fortschrittsanzeige).
struct CommandActivity: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let startedAt: Date
}

/// Rückmeldung mit Zeitpunkt für das Hinweisband.
struct FeedbackEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let feedback: CommandFeedback
    let date: Date
}

/// Führt alle Schreibaktionen der Oberfläche als Dienstbefehle aus (ADR-0019/0020) und zeigt Fortschritt
/// und Ergebnis an. Keine stillen Erfolge.
@MainActor
@Observable
final class CommandCenter {
    private(set) var running: [CommandActivity] = []
    private(set) var latest: FeedbackEntry?
    private(set) var log: [FeedbackEntry] = []

    @ObservationIgnored private let monitor: ServiceMonitor
    /// Wird nach jedem Befehl aufgerufen (Datenbank neu lesen, Statusübersicht aktualisieren).
    @ObservationIgnored var afterCommand: (@MainActor () async -> Void)?

    init(monitor: ServiceMonitor) {
        self.monitor = monitor
    }

    var isBusy: Bool { !running.isEmpty }

    func isRunning(_ title: String) -> Bool {
        running.contains { $0.title == title }
    }

    /// Sendet `request` und liefert das Ergebnis. `title` ist die deutsche Bezeichnung der Aktion.
    @discardableResult
    func perform(_ title: String, _ request: ServiceRequest, quiet: Bool = false) async -> CommandOutcome {
        let activity = CommandActivity(title: title, startedAt: .now)
        running.append(activity)
        defer { running.removeAll { $0.id == activity.id } }

        let outcome: CommandOutcome
        switch await monitor.send(request) {
        case let .success(response):
            outcome = CommandOutcome.from(response, title: title)
        case let .failure(error):
            outcome = CommandOutcome.from(error, title: title)
        }
        if !quiet || outcome.feedback.isFailure {
            record(title: title, feedback: outcome.feedback)
        }
        if let afterCommand { await afterCommand() }
        return outcome
    }

    /// Rückmeldung einer lokalen Aktion (Datei öffnen, Export, Schlüsselbund).
    func record(title: String, feedback: CommandFeedback) {
        let entry = FeedbackEntry(title: title, feedback: feedback, date: .now)
        latest = entry
        log.insert(entry, at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    func dismissLatest() {
        latest = nil
    }
}

/// „Mit KI besprechen“ sendet über denselben Weg wie alle anderen Schreibaktionen.
extension CommandCenter: ServiceCommandPerforming {}
