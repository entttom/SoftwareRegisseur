import Foundation
import Observation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Lesezugriff der Oberfläche auf die Datenbank des Dienstes (ADR-0019: nur lesend, der Dienst ist der
/// einzige Schreiber). Änderungen werden über Größe/Zeitstempel der Datenbank- und WAL-Datei erkannt und
/// lösen ein Neuladen aus; zusätzlich wird alle 30 s neu gelesen.
@MainActor
@Observable
final class LibraryStore {
    enum Phase: Equatable {
        /// Keine gültige App Group: die Datenbank ist nicht auffindbar.
        case unconfigured
        /// Datenbank existiert noch nicht oder ist noch nicht migriert (Dienst startet noch).
        case waiting(String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .waiting(String(localized: "Datenbank wird geöffnet …"))
    private(set) var snapshot: LibrarySnapshot = .empty
    private(set) var isLoading = false

    @ObservationIgnored private let databaseURL: URL?
    @ObservationIgnored private(set) var database: AppDatabase?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSignature: [FileSignature] = []
    @ObservationIgnored private var lastFullReload = Date.distantPast

    init(databaseURL: URL?) {
        self.databaseURL = databaseURL
        if databaseURL == nil { phase = .unconfigured }
    }

    /// Vorschauen/Bildschirmfotos: fester Datenbestand.
    init(database: AppDatabase) {
        databaseURL = nil
        self.database = database
    }

    func start() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Sofort neu laden (nach eigenen Befehlen).
    func reload() async {
        if database == nil { openIfPossible() }
        guard let database else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await LibraryLoader.load(from: database)
            snapshot = loaded
            phase = .ready
            lastFullReload = .now
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Vor einer Löschung durch den Dienst (A34): eigene Nur-Lese-Verbindung schließen, damit die
    /// Datenbankdateien nicht offen gehalten werden. Bis `reopenAfterDeletion()` wird nicht neu geöffnet.
    func closeForDeletion() {
        watchTask?.cancel()
        watchTask = nil
        try? database?.close()
        database = nil
        snapshot = .empty
        phase = .waiting(String(localized: "Daten werden gelöscht …"))
    }

    /// Nach der Löschung: die vom Dienst neu angelegte Datenbank lesend öffnen und die Beobachtung fortsetzen.
    func reopenAfterDeletion() async {
        lastSignature = []
        openIfPossible()
        await reload()
        start()
    }

    private func tick() async {
        if database == nil {
            openIfPossible()
            if database != nil { await reload() }
            return
        }
        let signature = currentSignature()
        if signature != lastSignature || Date.now.timeIntervalSince(lastFullReload) > 30 {
            lastSignature = signature
            await reload()
        }
    }

    private func openIfPossible() {
        guard let databaseURL else { return }
        do {
            database = try AppDatabase.openReadOnly(at: databaseURL)
            lastSignature = currentSignature()
        } catch {
            phase = Self.phase(for: error)
        }
    }

    private struct FileSignature: Equatable {
        var size: Int
        var modified: Date
    }

    private func currentSignature() -> [FileSignature] {
        guard let databaseURL else { return [] }
        let paths = [databaseURL.path, databaseURL.path + "-wal"]
        return paths.map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return FileSignature(size: (attributes?[.size] as? NSNumber)?.intValue ?? -1,
                                 modified: attributes?[.modificationDate] as? Date ?? .distantPast)
        }
    }

    static func phase(for error: any Error) -> Phase {
        if let store = error as? StoreError {
            switch store {
            case .schemaNotReady:
                return .waiting(String(localized: "Die Datenbank des Hintergrunddienstes ist noch nicht bereit. Sobald der Dienst läuft, erscheinen hier die Daten."))
            case .schemaTooNew:
                return .failed(String(localized: "Die Datenbank stammt von einer neueren Version des Dienstes. Bitte die App aktualisieren."))
            default:
                break
            }
        }
        return .failed(message(for: error))
    }

    static func message(for error: any Error) -> String {
        if let store = error as? StoreError, case .schemaTooNew = store {
            return String(localized: "Die Datenbank stammt von einer neueren Version des Dienstes. Bitte die App aktualisieren.")
        }
        return String(localized: "Die Daten konnten nicht gelesen werden. Der Hintergrunddienst schreibt möglicherweise gerade; es wird automatisch erneut versucht.")
    }

    // MARK: Detaildaten (bei Bedarf)

    func events(for workItem: WorkItemID) async -> [TaskEvent] {
        guard let database else { return [] }
        return (try? await database.events.events(forWorkItem: workItem)) ?? []
    }

    func drafts(for workItem: WorkItemID) async -> [DraftVersion] {
        guard let database else { return [] }
        return (try? await database.draftVersions.versions(workItemId: workItem)) ?? []
    }

    /// Repository-relativer Pfad der Markdown-Datei einer Aufgabe oder eines ADRs.
    func documentPath(entityId: UUID) async -> String? {
        guard let database else { return nil }
        return try? await database.documentFiles.fetch(entityId: entityId)?.relativePath
    }

    func indexedFolders(hostId: HostID) async -> [IndexedFolder] {
        guard let database else { return [] }
        return (try? await database.indexedFolders.list(hostId: hostId)) ?? []
    }

    func approvals(for job: JobID) async -> [PendingApproval] {
        guard let database else { return [] }
        return (try? await database.approvals.approvals(jobId: job)) ?? []
    }
}
