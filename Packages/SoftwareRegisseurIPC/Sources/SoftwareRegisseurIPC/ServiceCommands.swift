import Foundation
import SoftwareRegisseurDomain

/// Hostlokale Einstellungen des Agent Service (nicht synchronisiert; liegen in `host_state`).
public struct ServiceSettings: Codable, Sendable, Hashable {
    /// Abfrageintervall der iCloud-Synchronisierung im Normalbetrieb (Sekunden, ADR-0011).
    public var syncPollInterval: TimeInterval
    /// Obergrenze des Backoffs nach Sync-Fehlern (Sekunden).
    public var syncMaxBackoff: TimeInterval
    /// Intervall des vollständigen Stammordner-Scans (Sekunden).
    public var workspaceScanInterval: TimeInterval
    /// Intervall der periodischen Markdown-Reconciliation zusätzlich zu FSEvents (Sekunden).
    public var reconcileInterval: TimeInterval
    /// Intervall der Agentenerkennung (Sekunden, J1).
    public var agentDetectionInterval: TimeInterval
    /// Intervall des GitHub-Abgleichs aktivierter Projekte (Sekunden, M3).
    public var gitHubSyncInterval: TimeInterval
    /// Längste Wartezeit der Job-Schleife ohne Anlass (Sekunden).
    public var jobsIdleInterval: TimeInterval
    /// Leerlauf-Ruhezustand verhindern, solange ein Agent arbeitet (D3, Standard aus).
    /// Bildschirm-Ruhezustand und ein manuell ausgelöster Ruhezustand bleiben unberührt.
    public var preventIdleSleepWhileAgentsRun: Bool
    /// Vom iPhone eingereihte KI-Ausarbeitungen mit Repo-Kontext automatisch ausführen (H4).
    public var processQueuedAIElaborations: Bool
    /// Wie viele Ebenen unter einem Stammordner erfasst werden (ADR-0028). 1 = nur Ordner direkt im
    /// Stammordner (Standard). Wegfallende Einträge werden auch in iCloud entfernt.
    public var folderScanDepth: Int
    /// Benutzerdefinierte Programmpfade je Agent (Rohwert der `ProviderID` → absoluter Pfad, J1). Seit
    /// Protokoll 3; geändert nur über `setAgentExecutablePath`, `updateServiceSettings` lässt sie unverändert.
    public var agentExecutablePaths: [String: String]

    public init(
        syncPollInterval: TimeInterval = 60,
        syncMaxBackoff: TimeInterval = 1_800,
        workspaceScanInterval: TimeInterval = 900,
        reconcileInterval: TimeInterval = 300,
        agentDetectionInterval: TimeInterval = 1_800,
        gitHubSyncInterval: TimeInterval = 900,
        jobsIdleInterval: TimeInterval = 60,
        preventIdleSleepWhileAgentsRun: Bool = false,
        processQueuedAIElaborations: Bool = true,
        folderScanDepth: Int = ServiceSettings.defaultFolderScanDepth,
        agentExecutablePaths: [String: String] = [:]
    ) {
        self.syncPollInterval = syncPollInterval
        self.syncMaxBackoff = syncMaxBackoff
        self.workspaceScanInterval = workspaceScanInterval
        self.reconcileInterval = reconcileInterval
        self.agentDetectionInterval = agentDetectionInterval
        self.gitHubSyncInterval = gitHubSyncInterval
        self.jobsIdleInterval = jobsIdleInterval
        self.preventIdleSleepWhileAgentsRun = preventIdleSleepWhileAgentsRun
        self.processQueuedAIElaborations = processQueuedAIElaborations
        self.folderScanDepth = folderScanDepth
        self.agentExecutablePaths = agentExecutablePaths
    }

    public static let defaultFolderScanDepth = 1
    /// Erlaubter Bereich der Ordnertiefe (der Scanner geht nie tiefer als 8 Ebenen).
    public static let folderScanDepthRange = 1...8

    private enum CodingKeys: String, CodingKey {
        case syncPollInterval, syncMaxBackoff, workspaceScanInterval, reconcileInterval, agentDetectionInterval
        case gitHubSyncInterval, jobsIdleInterval, preventIdleSleepWhileAgentsRun, processQueuedAIElaborations
        case folderScanDepth, agentExecutablePaths
    }

    /// Fehlende Felder (gespeicherte Einstellungen oder Clients älterer Protokolle) erhalten ihren Standard.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServiceSettings()
        syncPollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .syncPollInterval) ?? defaults.syncPollInterval
        syncMaxBackoff = try container.decodeIfPresent(TimeInterval.self, forKey: .syncMaxBackoff) ?? defaults.syncMaxBackoff
        workspaceScanInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .workspaceScanInterval)
            ?? defaults.workspaceScanInterval
        reconcileInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .reconcileInterval) ?? defaults.reconcileInterval
        agentDetectionInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .agentDetectionInterval)
            ?? defaults.agentDetectionInterval
        gitHubSyncInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .gitHubSyncInterval) ?? defaults.gitHubSyncInterval
        jobsIdleInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .jobsIdleInterval) ?? defaults.jobsIdleInterval
        preventIdleSleepWhileAgentsRun = try container.decodeIfPresent(Bool.self, forKey: .preventIdleSleepWhileAgentsRun)
            ?? defaults.preventIdleSleepWhileAgentsRun
        processQueuedAIElaborations = try container.decodeIfPresent(Bool.self, forKey: .processQueuedAIElaborations)
            ?? defaults.processQueuedAIElaborations
        folderScanDepth = try container.decodeIfPresent(Int.self, forKey: .folderScanDepth) ?? defaults.folderScanDepth
        agentExecutablePaths = try container.decodeIfPresent([String: String].self, forKey: .agentExecutablePaths) ?? [:]
    }

    /// Programmpfad-Override eines Agenten.
    public func executablePath(for provider: ProviderID) -> String? {
        agentExecutablePaths[provider.rawValue]
    }

    /// Untergrenzen, damit CloudKit, Dateisystem und Agenten nicht im Sekundentakt abgefragt werden.
    public var clamped: ServiceSettings {
        var copy = self
        copy.syncPollInterval = max(15, syncPollInterval)
        copy.syncMaxBackoff = max(copy.syncPollInterval, syncMaxBackoff)
        copy.workspaceScanInterval = max(60, workspaceScanInterval)
        copy.reconcileInterval = max(30, reconcileInterval)
        copy.agentDetectionInterval = max(300, agentDetectionInterval)
        copy.gitHubSyncInterval = max(120, gitHubSyncInterval)
        copy.jobsIdleInterval = max(5, min(jobsIdleInterval, 600))
        copy.folderScanDepth = min(max(folderScanDepth, Self.folderScanDepthRange.lowerBound), Self.folderScanDepthRange.upperBound)
        return copy
    }
}

/// Entscheidung zu einem CloudKit-Sync-Konflikt (A24).
public enum SyncConflictChoice: Codable, Sendable, Hashable {
    case keepLocal
    case acceptRemote
    /// Vom Benutzer zusammengeführter Wert als JSON-Payload (Format wie der gespeicherte Konfliktwert).
    case merged(Data)
}

/// Neue Ordnerstruktur eines Projekts (alle Pfade relativ zum Repository, F2).
public struct FolderLayoutPaths: Codable, Sendable, Hashable {
    public var adrPath: String
    public var requestsRoot: String
    public var openPath: String
    public var activePath: String
    public var reviewPath: String
    public var donePath: String

    public init(adrPath: String, requestsRoot: String, openPath: String, activePath: String, reviewPath: String, donePath: String) {
        self.adrPath = adrPath
        self.requestsRoot = requestsRoot
        self.openPath = openPath
        self.activePath = activePath
        self.reviewPath = reviewPath
        self.donePath = donePath
    }
}

/// Jobwunsch aus der Mac-UI (J2a). `idempotencyKey` einmal pro geöffnetem Dialog erzeugen.
public struct JobRequestCommand: Codable, Sendable, Hashable {
    public var workItemId: WorkItemID
    public var providerId: ProviderID
    /// `nil` = Projekt-/Globalstandard übernehmen.
    public var model: ModelSelection?
    /// `nil` = Projekt-/Globalstandard übernehmen.
    public var effort: EffortLevel?
    public var schedule: JobSchedule
    public var priority: Priority
    public var idempotencyKey: IdempotencyKey

    public init(
        workItemId: WorkItemID, providerId: ProviderID, model: ModelSelection? = nil, effort: EffortLevel? = nil,
        schedule: JobSchedule = JobSchedule(kind: .immediate), priority: Priority = .medium,
        idempotencyKey: IdempotencyKey = IdempotencyKey()
    ) {
        self.workItemId = workItemId
        self.providerId = providerId
        self.model = model
        self.effort = effort
        self.schedule = schedule
        self.priority = priority
        self.idempotencyKey = idempotencyKey
    }
}

public enum GitHubIssueStateFilter: String, Codable, Sendable, Hashable, CaseIterable {
    case open
    case closed
    case all
}

/// Modus einer KI-Ausarbeitung; Rohwerte entsprechen `SoftwareRegisseurAI.DraftMode`.
public enum MacAIElaborationMode: String, Codable, Sendable, Hashable, CaseIterable {
    case kurz
    case ausfuehrlich
    case akzeptanzkriterienErgaenzen
    case technischeDetails
    case inAufgabenAufteilen
}

/// Ausarbeitung einer Aufgabe mit Repo-Kontext am Mac (H4, A11).
public struct MacAIElaborationCommand: Codable, Sendable, Hashable {
    public var workItemId: WorkItemID
    /// Rohwert der KI-Anbieter-ID, z. B. "openai", "anthropic", "gemini".
    public var providerId: String
    /// Anbieter-Modell-ID, unverändert gespeichert.
    public var modelId: String
    public var mode: MacAIElaborationMode
    /// Zusätzlich gewünschte Quelldateien (relativ zum Repository); Geheimnisse werden immer ausgeschlossen.
    public var selectedFiles: [String]

    public init(workItemId: WorkItemID, providerId: String, modelId: String, mode: MacAIElaborationMode = .ausfuehrlich,
                selectedFiles: [String] = []) {
        self.workItemId = workItemId
        self.providerId = providerId
        self.modelId = modelId
        self.mode = mode
        self.selectedFiles = selectedFiles
    }
}
