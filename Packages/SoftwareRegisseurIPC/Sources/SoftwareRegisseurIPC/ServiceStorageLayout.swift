import Foundation

/// Gemeinsame Dateiablage von UI und Agent Service im App-Group-Container (ADR-0019).
///
/// Der Dienst öffnet ``databaseURL`` als einziger Schreiber (`AppDatabase.openWriter`), die UI
/// dieselbe Datei nur lesend (`AppDatabase.openReadOnly`). Beide leiten den Pfad ausschließlich
/// hier ab, damit sie garantiert dieselbe Datei verwenden.
public struct ServiceStorageLayout: Sendable, Hashable {
    /// Wurzel der Ablage (App-Group-Container oder in Tests ein temporäres Verzeichnis).
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Ablage im App-Group-Container. `nil`, wenn das System keinen Container liefert.
    public init?(endpoint: ServiceEndpoint, fileManager: FileManager = .default) {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: endpoint.appGroupIdentifier) else {
            return nil
        }
        self.init(rootURL: container.appending(path: "SoftwareRegisseur", directoryHint: .isDirectory))
    }

    /// SQLite-Datenbank (WAL; `-wal`/`-shm` liegen daneben).
    public var databaseURL: URL { rootURL.appending(path: "Database/SoftwareRegisseur.sqlite", directoryHint: .notDirectory) }
    /// Agenten-Worktrees, außerhalb jedes Stammordners (L2).
    public var worktreesURL: URL { rootURL.appending(path: "Worktrees", directoryHint: .isDirectory) }
    /// Worktree für die Integration in den Default-Branch (ADR-0015).
    public var integrationURL: URL { rootURL.appending(path: "Integration", directoryHint: .isDirectory) }
    /// Hostlokale Laufzeitdaten der Jobs (Prozess-IDs, Worktree-Pfade, Review-Pfade).
    public var runtimeURL: URL { rootURL.appending(path: "Runtime", directoryHint: .isDirectory) }
    /// Temporäre CloudKit-Assets der Synchronisierung.
    public var syncAssetsURL: URL { rootURL.appending(path: "SyncAssets", directoryHint: .isDirectory) }
    /// Neutrales Arbeitsverzeichnis für die Agentenerkennung (keine Projektkonfiguration).
    public var detectionURL: URL { rootURL.appending(path: "Detection", directoryHint: .isDirectory) }
}
