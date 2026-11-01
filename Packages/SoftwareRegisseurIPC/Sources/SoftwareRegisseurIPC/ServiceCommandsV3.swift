import Foundation
import SoftwareRegisseurDomain

// Befehlsdaten seit Protokoll 3: Schreibwege der Mac-UI für Aufgaben, KI-Entwürfe, ADRs, Einstellungen,
// Datenlöschung (A34) und Sync-Konflikte. Der Dienst bleibt einziger Schreiber (ADR-0019); jede Änderung
// läuft über die Repositories und wird dadurch synchronisiert.

// MARK: - Aufgaben

/// Neue Notiz (Inbox) oder Aufgabe in einem Projekt.
///
/// `workItemId` erzeugt die UI einmal pro Dialog: eine Wiederholung nach Zeitüberschreitung legt keine
/// zweite Aufgabe an, sondern liefert die bestehende (Idempotenz).
public struct CreateWorkItemCommand: Codable, Sendable, Hashable {
    public var workItemId: WorkItemID
    /// `nil` = Inbox (Status `inbox`), sonst Status `open`.
    public var projectId: ProjectID?
    public var type: WorkItemType
    public var title: String
    /// Freitext; wird Originalnotiz und Markdown-Inhalt der neuen Aufgabe.
    public var text: String
    public var priority: Priority
    public var labels: [String]

    public init(workItemId: WorkItemID = WorkItemID(), projectId: ProjectID? = nil, type: WorkItemType = .note, title: String,
                text: String = "", priority: Priority = .medium, labels: [String] = []) {
        self.workItemId = workItemId
        self.projectId = projectId
        self.type = type
        self.title = title
        self.text = text
        self.priority = priority
        self.labels = labels
    }
}

/// Bearbeitung der Benutzerfelder einer Aufgabe mit optimistischer Revision (Pflichtenheft O).
/// Weicht `expectedRevision` vom gespeicherten Stand ab, lehnt der Dienst mit deutscher Meldung ab
/// („inzwischen geändert – bitte neu laden“).
public struct WorkItemEditCommand: Codable, Sendable, Hashable {
    public var workItemId: WorkItemID
    public var expectedRevision: Int
    public var title: String
    public var structuredBody: String
    public var priority: Priority
    public var labels: [String]
    /// Verweise immer über UUIDs (ADR-0018).
    public var dependencies: [WorkItemID]

    public init(workItemId: WorkItemID, expectedRevision: Int, title: String, structuredBody: String, priority: Priority,
                labels: [String], dependencies: [WorkItemID]) {
        self.workItemId = workItemId
        self.expectedRevision = expectedRevision
        self.title = title
        self.structuredBody = structuredBody
        self.priority = priority
        self.labels = labels
        self.dependencies = dependencies
    }
}

/// Gemeinsame Regeln für Aufgabenbefehle, die UI und Dienst gleich auswerten.
public enum WorkItemCommandRules {
    /// Status, die nur der Dienst aus Jobs bzw. nach Integration setzt (ADR-0012, M1). Manuelle Wechsel
    /// dorthin werden abgelehnt.
    public static let hostOnlyStatuses: Set<WorkItemStatus> = [
        .integrated, .queued, .scheduled, .inProgress, .waitingApproval, .implementationFinished,
    ]

    /// Manuell wählbare Zielstatus ohne aktiven Job (Zustandsmaschine minus Dienst-Status).
    public static func manualTargets(from status: WorkItemStatus) -> [WorkItemStatus] {
        WorkItemStatus.allCases.filter { status.canTransition(to: $0) && !hostOnlyStatuses.contains($0) }
    }

    /// Normalisierte Labels: getrimmt, ohne leere und doppelte Einträge, Reihenfolge bleibt.
    public static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - ADRs

/// Neuer ADR-Entwurf: Nummer vergibt der Mac (ADR-0018), Text aus der `TEMPLATE.md` des Repositorys,
/// Status `proposed`, atomar in den ADR-Ordner geschrieben und nie committet (ADR-0024).
public struct CreateADRCommand: Codable, Sendable, Hashable {
    public var projectId: ProjectID
    public var title: String
    /// Optionale Abschnittsinhalte; leer = Vorlagentext bleibt.
    public var context: String
    public var decision: String
    public var alternatives: String
    public var consequences: String
    /// Nummern der ADRs, die dieser Entwurf ersetzen soll (nur Frontmatter `supersedes`; der Status der
    /// alten ADRs ändert sich erst mit `changeADRStatus(… .superseded …)`).
    public var supersedes: [Int]

    public init(projectId: ProjectID, title: String, context: String = "", decision: String = "", alternatives: String = "",
                consequences: String = "", supersedes: [Int] = []) {
        self.projectId = projectId
        self.title = title
        self.context = context
        self.decision = decision
        self.alternatives = alternatives
        self.consequences = consequences
        self.supersedes = supersedes
    }
}

// MARK: - Einstellungen

/// Modell/Stufe eines Agenten. `nil` = Ebene erbt (Projekt → global → Anbieterstandard, ADR-0006).
public struct AgentModelChoice: Codable, Sendable, Hashable {
    public var providerId: ProviderID
    public var model: ModelSelection?
    public var effort: EffortLevel?

    public init(providerId: ProviderID, model: ModelSelection? = nil, effort: EffortLevel? = nil) {
        self.providerId = providerId
        self.model = model
        self.effort = effort
    }

    /// Keine eigene Wahl: die Voreinstellung wird entfernt.
    public var inherits: Bool { model == nil && effort == nil }
}

/// Projekteinstellungen außer der Ordnerstruktur (die läuft über `previewFolderMigration`).
public struct ProjectSettingsCommand: Codable, Sendable, Hashable {
    public var projectId: ProjectID
    /// Revision der gelesenen `ProjectSettings`.
    public var expectedRevision: Int
    /// `nil` = globaler Standardagent.
    public var defaultAgentId: ProviderID?
    /// Vollständige Liste der Projekt-Voreinstellungen; Anbieter ohne Eintrag erben.
    public var modelPreferences: [AgentModelChoice]
    public var integrationStrategy: IntegrationStrategy
    public var allowParallel: Bool
    /// `nil` = keine eigene Grenze.
    public var maxParallelJobs: Int?
    public var projectWideLock: Bool
    public var reviewPolicy: ReviewPolicy
    public var agentInstructionsPolicy: AgentInstructionsPolicy

    public init(projectId: ProjectID, expectedRevision: Int, defaultAgentId: ProviderID?, modelPreferences: [AgentModelChoice],
                integrationStrategy: IntegrationStrategy, allowParallel: Bool, maxParallelJobs: Int?, projectWideLock: Bool,
                reviewPolicy: ReviewPolicy, agentInstructionsPolicy: AgentInstructionsPolicy) {
        self.projectId = projectId
        self.expectedRevision = expectedRevision
        self.defaultAgentId = defaultAgentId
        self.modelPreferences = modelPreferences
        self.integrationStrategy = integrationStrategy
        self.allowParallel = allowParallel
        self.maxParallelJobs = maxParallelJobs
        self.projectWideLock = projectWideLock
        self.reviewPolicy = reviewPolicy
        self.agentInstructionsPolicy = agentInstructionsPolicy
    }

    /// Größte zulässige Parallelität je Projekt.
    public static let parallelJobsRange = 1...16
}

/// Synchronisierte Benutzer-Standards (`GlobalSettings`, F2/J2).
public struct GlobalSettingsCommand: Codable, Sendable, Hashable {
    /// Revision der gelesenen `GlobalSettings` (0 = noch nie gespeichert).
    public var expectedRevision: Int
    public var defaultAgentId: ProviderID?
    public var folderLayout: FolderLayoutPaths
    public var allowParallel: Bool
    public var projectWideLock: Bool
    public var maxParallelJobs: Int?
    public var reviewPolicy: ReviewPolicy
    public var integrationStrategy: IntegrationStrategy
    public var agentInstructionsPolicy: AgentInstructionsPolicy
    public var proposeGitInitForNewFolders: Bool

    public init(expectedRevision: Int, defaultAgentId: ProviderID?, folderLayout: FolderLayoutPaths, allowParallel: Bool,
                projectWideLock: Bool, maxParallelJobs: Int?, reviewPolicy: ReviewPolicy, integrationStrategy: IntegrationStrategy,
                agentInstructionsPolicy: AgentInstructionsPolicy, proposeGitInitForNewFolders: Bool) {
        self.expectedRevision = expectedRevision
        self.defaultAgentId = defaultAgentId
        self.folderLayout = folderLayout
        self.allowParallel = allowParallel
        self.projectWideLock = projectWideLock
        self.maxParallelJobs = maxParallelJobs
        self.reviewPolicy = reviewPolicy
        self.integrationStrategy = integrationStrategy
        self.agentInstructionsPolicy = agentInstructionsPolicy
        self.proposeGitInitForNewFolders = proposeGitInitForNewFolders
    }
}

// MARK: - Datenlöschung (Q1, A34)

/// Umfang einer lokalen Löschung auf diesem Mac (Ablage des Dienstes im App-Group-Container).
public enum LocalDeletionKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Datenbank (danach leer neu angelegt) und wiederherstellbare Zwischenspeicher.
    case localDatabase
    /// API-Schlüssel der KI-Anbieter im gemeinsamen Schlüsselbund dieses Macs.
    case apiKeys
    /// Alles Lokale: Datenbank, Zwischenspeicher, gerätebezogene Schlüssel, übrige Dienstdateien.
    case everythingLocal
}

// MARK: - KI-Entwürfe

/// Verlaufseintrag (`TaskEventKind.comment`), mit dem der Dienst eine Entscheidung über einen KI-Entwurf
/// festhält: verworfen (`rejectDraftVersion`) oder – seit Protokoll 4 – aus „Mit KI besprechen“ übernommen
/// (`appendConversationDraft` mit `accept`). Die UI erkennt verworfene Versionen über diese Schlüssel im Verlauf der
/// Aufgabe (synchronisiert).
public enum DraftDecisionEvent {
    public static let decisionKey = "draftDecision"
    public static let rejected = "rejected"
    /// Seit Protokoll 4: übernommener Gesprächsvorschlag.
    public static let accepted = "accepted"
    public static let draftIdKey = "draftVersionId"
    public static let versionKey = "draftVersion"
    /// Seit Protokoll 4: Kanal der Entwurfsversion (`DraftGenerationChannel`, z. B. `conversation`).
    public static let channelKey = "draftChannel"
    /// Seit Protokoll 4: ID des Gesprächs, aus dem der Entwurf stammt.
    public static let conversationIdKey = "conversationId"

    /// IDs der verworfenen Entwürfe aus den Verlaufsdaten einer Aufgabe.
    public static func rejectedDraftIds(in payloads: [[String: String]]) -> Set<UUID> {
        Set(payloads.compactMap { payload in
            guard payload[decisionKey] == rejected, let raw = payload[draftIdKey] else { return nil }
            return UUID(uuidString: raw)
        })
    }
}
