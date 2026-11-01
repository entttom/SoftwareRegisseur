import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

// Deutsche Anzeigenamen für Werte ohne eigene Übersetzung in den Paketen (Pflichtenheft P: einheitliche
// Terminologie, alle Texte im String Catalog). Rohwerte bleiben verlustfrei gespeichert (ADR-0006).

extension ReviewDecision {
    var displayName: String {
        switch self {
        case .pending: String(localized: "Ausstehend")
        case .approved: String(localized: "Freigegeben")
        case .changesRequested: String(localized: "Änderungen angefordert")
        case .rejected: String(localized: "Abgelehnt")
        }
    }
}

extension ApprovalRequestKind {
    var displayName: String {
        switch self {
        case .commandExecution: String(localized: "Befehl ausführen")
        case .fileChange: String(localized: "Dateiänderung")
        case .permissions: String(localized: "Berechtigungen")
        case .toolUse: String(localized: "Werkzeug verwenden")
        }
    }
}

extension TaskEventKind {
    var displayName: String {
        switch self {
        case .created: String(localized: "Angelegt")
        case .edited: String(localized: "Bearbeitet")
        case .statusChanged: String(localized: "Status geändert")
        case .humanIDAssigned: String(localized: "ID vergeben")
        case .jobRequested: String(localized: "Agentenjob angefordert")
        case .jobStateChanged: String(localized: "Jobstatus geändert")
        case .configurationReplaced: String(localized: "Konfiguration ersetzt")
        case .lockAcquired: String(localized: "Sperre gesetzt")
        case .lockReleased: String(localized: "Sperre freigegeben")
        case .reviewDecided: String(localized: "Review entschieden")
        case .integrated: String(localized: "Integriert")
        case .externalChangeDetected: String(localized: "Externe Änderung erkannt")
        case .conflictDetected: String(localized: "Konflikt erkannt")
        case .comment: String(localized: "Kommentar")
        case .approvalRequested: String(localized: "Freigabe angefragt")
        case .approvalAnswered: String(localized: "Freigabe beantwortet")
        case .approvalExpired: String(localized: "Freigabe abgelaufen")
        case .quotaWait: String(localized: "Wartet auf Kontingent")
        case .missedRun: String(localized: "Termin verpasst")
        case .jobRetried: String(localized: "Job wiederholt")
        case .typeChanged: String(localized: "Typ geändert")
        case .archived: String(localized: "Archiviert")
        case .unarchived: String(localized: "Wiederhergestellt")
        }
    }

    var symbolName: String {
        switch self {
        case .created: "plus.circle"
        case .edited: "pencil"
        case .statusChanged: "arrow.right.circle"
        case .humanIDAssigned: "number"
        case .jobRequested, .jobRetried: "play.circle"
        case .jobStateChanged: "gearshape.2"
        case .configurationReplaced: "slider.horizontal.3"
        case .lockAcquired: "lock"
        case .lockReleased: "lock.open"
        case .reviewDecided: "checkmark.seal"
        case .integrated: "arrow.triangle.merge"
        case .externalChangeDetected: "doc.badge.arrow.up"
        case .conflictDetected: "exclamationmark.triangle"
        case .comment: "text.bubble"
        case .approvalRequested, .approvalAnswered, .approvalExpired: "hand.raised"
        case .quotaWait: "hourglass"
        case .missedRun: "clock.badge.exclamationmark"
        case .typeChanged: "tag"
        case .archived, .unarchived: "archivebox"
        }
    }
}

extension ProfileSource {
    var displayName: String {
        switch self {
        case .job: String(localized: "Auftrag")
        case .project: String(localized: "Projekt")
        case .global: String(localized: "Global")
        case .providerDefault: String(localized: "Anbieterstandard")
        }
    }
}

extension ModelAvailability {
    var displayName: String {
        switch self {
        case .available: String(localized: "Verfügbar")
        case .notEntitled: String(localized: "Mit diesem Konto nicht nutzbar")
        case .deprecated: String(localized: "Veraltet")
        case .unavailable: String(localized: "Nicht verfügbar")
        }
    }
}

extension CapabilitySource {
    var displayName: String {
        switch self {
        case .documentedCLI: String(localized: "Dokumentierte CLI")
        case .appServer: String(localized: "App-Server")
        case .sdk: String(localized: "SDK")
        case .verifiedSpike: String(localized: "Geprüfter Versuch")
        case .cachedFromHost: String(localized: "Zwischengespeichert vom Mac")
        }
    }
}

extension IntegrationStrategy {
    var displayName: String {
        switch self {
        case .squash: String(localized: "Squash-Merge")
        case .mergeCommit: String(localized: "Merge-Commit")
        case .cherryPick: String(localized: "Cherry-pick")
        }
    }

    /// Rohwert aus `IntegrationInfo.strategy` (ADR-0015).
    static func displayName(raw: String) -> String {
        IntegrationStrategy(rawValue: raw)?.displayName ?? raw
    }
}

extension ReviewPolicy {
    var displayName: String {
        switch self {
        case .manualReview: String(localized: "Manuelles Review")
        case .testsAndManualReview: String(localized: "Tests und manuelles Review")
        }
    }
}

extension AgentInstructionsPolicy {
    var displayName: String {
        switch self {
        case .managedBlock: String(localized: "Verwalteter Block in AGENTS.md")
        case .proposeOnly: String(localized: "Nur Vorschläge")
        case .disabled: String(localized: "Deaktiviert")
        }
    }
}

extension RepositoryKind {
    var displayName: String {
        switch self {
        case .gitRepository: String(localized: "Git-Repository")
        case .notARepository: String(localized: "Noch kein Repository")
        case .subfolderOfRepository: String(localized: "Unterordner eines Repositories")
        }
    }
}

extension RepositoryScanState {
    var displayName: String {
        switch self {
        case .notScanned: String(localized: "Noch nicht gescannt")
        case .scanning: String(localized: "Wird gescannt")
        case .scanned: String(localized: "Gescannt")
        case .unreachable: String(localized: "Nicht erreichbar")
        case .failed: String(localized: "Scan fehlgeschlagen")
        }
    }
}

extension SyncSummary.State {
    var displayName: String {
        switch self {
        case .unavailable: String(localized: "Nicht verfügbar")
        case .idle: String(localized: "Bereit")
        case .syncing: String(localized: "Synchronisiert gerade")
        case .paused: String(localized: "Pausiert – Entscheidung nötig")
        case .failed: String(localized: "Fehlgeschlagen")
        }
    }
}

extension SyncSummary.AccountState {
    var displayName: String {
        switch self {
        case .unknown: String(localized: "Unbekannt")
        case .available: String(localized: "Angemeldet")
        case .signedOut: String(localized: "Nicht angemeldet")
        case .switched: String(localized: "Account gewechselt")
        case .temporarilyUnavailable: String(localized: "Vorübergehend nicht verfügbar")
        }
    }
}

extension FileConflictKind {
    var displayName: String {
        switch self {
        case .concurrentEdit: String(localized: "Gleichzeitige Änderung")
        case .statusChangeDuringActiveJob: String(localized: "Statusänderung während eines aktiven Jobs")
        case .fileDeleted: String(localized: "Datei gelöscht")
        case .invalidFile: String(localized: "Datei nicht lesbar")
        case .gitHubDivergence: String(localized: "Abweichung auf GitHub")
        }
    }
}

extension FileConflictResolution {
    var displayName: String {
        switch self {
        case .keptDatabase: String(localized: "App-Stand behalten")
        case .acceptedExternal: String(localized: "Externen Stand übernehmen")
        case .dismissed: String(localized: "Verworfen")
        }
    }
}

extension ProjectSetupState {
    var displayName: String {
        switch self {
        case .pending: String(localized: "Ausstehend")
        case .completed: String(localized: "Abgeschlossen")
        case .failed: String(localized: "Fehlgeschlagen")
        }
    }
}

extension ProjectSetupKind {
    var displayName: String {
        switch self {
        case .createProject: String(localized: "Projekt anlegen")
        case .linkProject: String(localized: "Projekt verknüpfen")
        }
    }
}

extension TestOutcome {
    var displayName: String {
        switch self {
        case .passed: String(localized: "Bestanden")
        case .failed: String(localized: "Fehlgeschlagen")
        case .skipped: String(localized: "Übersprungen")
        case .notRun: String(localized: "Nicht ausgeführt")
        }
    }
}

extension ADRStatus {
    var displayName: String {
        switch self {
        case .proposed: String(localized: "Vorgeschlagen")
        case .accepted: String(localized: "Angenommen")
        case .deprecated: String(localized: "Veraltet")
        case .superseded: String(localized: "Ersetzt")
        }
    }
}

extension LockScope {
    var displayName: String {
        switch self {
        case .task: String(localized: "Aufgabensperre")
        case .project: String(localized: "Projektweite Sperre")
        }
    }
}

extension LockRecoveryState {
    var displayName: String {
        switch self {
        case .active: String(localized: "Aktiv")
        case .awaitingReconciliation: String(localized: "Wird mit Prozess und Worktree abgeglichen")
        case .released: String(localized: "Freigegeben")
        }
    }
}

extension MissedRunPolicy {
    var displayName: String {
        switch self {
        case .runImmediatelyWhenAvailable: String(localized: "Sofort nachholen")
        case .ask: String(localized: "Nachfragen")
        case .skipExpired: String(localized: "Verpassten Termin überspringen")
        }
    }
}

extension MacAIElaborationMode {
    var displayName: String {
        switch self {
        case .kurz: String(localized: "Kurz")
        case .ausfuehrlich: String(localized: "Ausführlich")
        case .akzeptanzkriterienErgaenzen: String(localized: "Akzeptanzkriterien ergänzen")
        case .technischeDetails: String(localized: "Technische Details")
        case .inAufgabenAufteilen: String(localized: "In Aufgaben aufteilen")
        }
    }
}

extension MacAIElaborationInfo.State {
    var displayName: String {
        switch self {
        case .pending: String(localized: "Wartet")
        case .running: String(localized: "Läuft")
        case .completed: String(localized: "Fertig")
        case .failed: String(localized: "Fehlgeschlagen")
        }
    }
}

extension ServiceFeature {
    var localizedName: String {
        switch self {
        case .cloudSync: String(localized: "iCloud-Synchronisierung")
        case .repositoryScanner: String(localized: "Git-Scanner")
        }
    }
}

extension ServiceStatusSummary.MacState {
    var displayName: String {
        switch self {
        case .ready: String(localized: "Mac bereit")
        case .paused: String(localized: "Mac pausiert")
        case .degraded: String(localized: "Mac eingeschränkt")
        case .starting: String(localized: "Mac startet")
        }
    }
}

extension EventActor {
    /// Wer eine Änderung ausgelöst hat (M2: beteiligtes Gerät/Agent, soweit bekannt).
    var displayName: String {
        switch self {
        case let .user(device):
            String(localized: "Benutzer (Gerät \(device.shortString))")
        case .host:
            String(localized: "Mac-Dienst")
        case let .agent(provider, _):
            ProviderNames.displayName(provider)
        case .external:
            String(localized: "Extern (Editor, Git)")
        }
    }
}

/// Anzeigename eines Coding-Agenten; unbekannte Anbieter erscheinen mit ihrer ID.
enum ProviderNames {
    static func displayName(_ provider: ProviderID) -> String {
        switch provider {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        default: provider.rawValue
        }
    }

    static func displayName(_ provider: ProviderID, capabilities: [AgentCapability]) -> String {
        if let name = capabilities.first(where: { $0.providerId == provider })?.displayName, !name.isEmpty {
            return name
        }
        return displayName(provider)
    }
}

extension WorkItem {
    /// „FR-0001 · Titel“ bzw. nur der Titel, solange der Mac noch keine ID vergeben hat (ADR-0018).
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? String(localized: "Ohne Titel") : trimmed
        guard let humanId else { return name }
        return "\(humanId.formatted) · \(name)"
    }

    var displayID: String {
        humanId?.formatted ?? String(localized: "noch ohne ID")
    }
}

/// Deutsche Kurzfassung der Ereignisdaten in der Historie (Pflichtenheft P). Bekannte Schlüssel erhalten deutsche
/// Bezeichnungen, Zustände ihre Anzeigenamen, IDs werden gekürzt; unbekannte Schlüssel bleiben unverändert sichtbar.
enum EventPayloadText {
    static func summary(kind: TaskEventKind, payload: [String: String]) -> String {
        var remaining = Dictionary(payload.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var parts: [String] = []
        if let from = remaining.removeValue(forKey: "from"), let to = remaining.removeValue(forKey: "to") {
            let label = kind == .typeChanged ? String(localized: "Typ") : String(localized: "Status")
            parts.append("\(label): \(value(from, kind: kind)) → \(value(to, kind: kind))")
        }
        for (key, label) in labels {
            guard let raw = remaining.removeValue(forKey: key) else { continue }
            parts.append("\(label): \(display(key: key, raw))")
        }
        parts += remaining.keys.sorted().map { "\($0): \(remaining[$0] ?? "")" }
        return parts.joined(separator: " · ")
    }

    private static let labels: [(String, String)] = [
        ("status", String(localized: "Status")),
        ("workitemstatus", String(localized: "Aufgabe")),
        ("providerid", String(localized: "Agent")),
        ("provider", String(localized: "Agent")),
        ("resolvedmodel", String(localized: "Modell")),
        ("model", String(localized: "Modell")),
        ("resolvedeffort", String(localized: "Stufe")),
        ("effort", String(localized: "Stufe")),
        ("decision", String(localized: "Entscheidung")),
        ("reason", String(localized: "Grund")),
        ("humanid", String(localized: "Nummer")),
        ("priority", String(localized: "Priorität")),
        ("path", String(localized: "Datei")),
        ("fields", String(localized: "Felder")),
        ("branch", String(localized: "Branch")),
        ("jobid", String(localized: "Job")),
    ]

    private static func value(_ raw: String, kind: TaskEventKind) -> String {
        switch kind {
        case .jobStateChanged: AgentJobState(rawValue: raw)?.germanDisplayName ?? raw
        case .typeChanged: WorkItemType(rawValue: raw)?.germanDisplayName ?? raw
        default: WorkItemStatus(rawValue: raw)?.germanDisplayName ?? raw
        }
    }

    private static func display(key: String, _ raw: String) -> String {
        switch key {
        case "status", "workitemstatus": WorkItemStatus(rawValue: raw)?.germanDisplayName ?? raw
        case "providerid", "provider": ProviderID(rawValue: raw).map(ProviderNames.displayName) ?? raw
        case "resolvedmodel", "model": raw == "providerDefault" ? String(localized: "Anbieterstandard") : raw
        case "resolvedeffort", "effort": EffortLevel(rawValue: raw)?.germanDisplayName ?? raw
        case "jobid": String(raw.prefix(8))
        default: raw
        }
    }
}
