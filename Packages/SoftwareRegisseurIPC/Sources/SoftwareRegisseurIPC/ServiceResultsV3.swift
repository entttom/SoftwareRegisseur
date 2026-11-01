import Foundation
import SoftwareRegisseurDomain

// Ergebnisarten seit Protokoll 3.

/// Stand einer Aufgabe nach einem Schreibbefehl. Die UI liest den vollständigen Datensatz danach aus der
/// Nur-Lese-Datenbank; `revision` erlaubt die nächste Bearbeitung ohne Neuladen.
public struct WorkItemSavedInfo: Codable, Sendable, Hashable {
    public var workItemId: WorkItemID
    public var revision: Int
    public var status: WorkItemStatus
    public var type: WorkItemType
    public var projectId: ProjectID?
    public var isArchived: Bool
    /// `false`, wenn ein Anlegebefehl mit derselben ID schon ausgeführt war (Idempotenz).
    public var wasCreated: Bool
    /// Deutsche Rückmeldung für die UI.
    public var message: String

    public init(workItemId: WorkItemID, revision: Int, status: WorkItemStatus, type: WorkItemType, projectId: ProjectID?,
                isArchived: Bool, wasCreated: Bool = false, message: String) {
        self.workItemId = workItemId
        self.revision = revision
        self.status = status
        self.type = type
        self.projectId = projectId
        self.isArchived = isArchived
        self.wasCreated = wasCreated
        self.message = message
    }
}

/// Neu angelegter ADR-Entwurf (nicht committet, ADR-0024).
public struct ADRCreatedInfo: Codable, Sendable, Hashable {
    public var projectId: ProjectID
    /// Vom Mac vergebene Nummer (eigener Nummernkreis, ADR-0018).
    public var number: Int
    /// Pfad relativ zum Repository.
    public var relativePath: String
    /// Datenbank-ID nach dem Einlesen; `nil`, falls der Abgleich noch aussteht.
    public var adrId: ADRID?

    public init(projectId: ProjectID, number: Int, relativePath: String, adrId: ADRID?) {
        self.projectId = projectId
        self.number = number
        self.relativePath = relativePath
        self.adrId = adrId
    }
}

/// GitHub-Zustand eines Projekts (M3, ADR-0016).
public struct GitHubProjectStateInfo: Codable, Sendable, Hashable {
    public var projectId: ProjectID
    public var enabled: Bool
    /// `owner/name` aus dem Remote, falls ermittelbar.
    public var repository: String?
    /// Deutsche Erklärung, warum kein Repository ermittelt werden konnte.
    public var detail: String?

    public init(projectId: ProjectID, enabled: Bool, repository: String?, detail: String?) {
        self.projectId = projectId
        self.enabled = enabled
        self.repository = repository
        self.detail = detail
    }
}

/// Vorschau einer lokalen Löschung. Gelöscht wird nur mit `planId` und `confirmationToken` aus genau
/// dieser Vorschau und nur die gelisteten Einträge (A34).
public struct LocalDeletionPreviewInfo: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        /// Deutsche Bezeichnung.
        public var label: String
        public var byteCount: Int64?
        /// Verschwindet auch auf anderen Geräten (iCloud-Schlüsselbund).
        public var affectsOtherDevices: Bool

        public init(label: String, byteCount: Int64?, affectsOtherDevices: Bool) {
            self.label = label
            self.byteCount = byteCount
            self.affectsOtherDevices = affectsOtherDevices
        }
    }

    public var planId: UUID
    public var kind: LocalDeletionKind
    public var confirmationToken: String
    public var title: String
    public var summary: String
    public var items: [Item]
    /// Was bewusst erhalten bleibt (iCloud, Git-Repositories, Worktrees …).
    public var retained: [String]
    /// Folgen für diesen Mac (z. B. Stammordner und Diensteinstellungen werden zurückgesetzt).
    public var consequences: [String]
    public var totalBytes: Int64
    public var expiresAt: Date

    public init(planId: UUID, kind: LocalDeletionKind, confirmationToken: String, title: String, summary: String, items: [Item],
                retained: [String], consequences: [String], totalBytes: Int64, expiresAt: Date) {
        self.planId = planId
        self.kind = kind
        self.confirmationToken = confirmationToken
        self.title = title
        self.summary = summary
        self.items = items
        self.retained = retained
        self.consequences = consequences
        self.totalBytes = totalBytes
        self.expiresAt = expiresAt
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// Ergebnis einer ausgeführten lokalen Löschung.
public struct LocalDeletionReportInfo: Codable, Sendable, Hashable {
    public var deleted: [String]
    public var alreadyMissing: [String]
    /// Bezeichnung und deutsche Fehlermeldung.
    public var failed: [String]
    /// Der Dienst hat die Datenbank geschlossen und leer neu geöffnet; die UI muss ihre Nur-Lese-Verbindung
    /// neu aufbauen.
    public var databaseReopened: Bool

    public init(deleted: [String], alreadyMissing: [String], failed: [String], databaseReopened: Bool) {
        self.deleted = deleted
        self.alreadyMissing = alreadyMissing
        self.failed = failed
        self.databaseReopened = databaseReopened
    }

    public var isComplete: Bool { failed.isEmpty }
}

/// Vorschau der Löschung aller iCloud-Daten. Löscht selbst nichts.
public struct CloudDeletionPreviewInfo: Codable, Sendable, Hashable {
    public var planId: UUID
    public var confirmationToken: String
    public var title: String
    public var consequences: [String]
    public var expiresAt: Date

    public init(planId: UUID, confirmationToken: String, title: String, consequences: [String], expiresAt: Date) {
        self.planId = planId
        self.confirmationToken = confirmationToken
        self.title = title
        self.consequences = consequences
        self.expiresAt = expiresAt
    }
}
