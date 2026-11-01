import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability
import SoftwareRegisseurSync

/// Kontrollierte Datenlöschung am Mac (Q1, A34). Der Dienst ist einziger Schreiber (ADR-0019) und löscht
/// deshalb selbst: `LocalDataEraser` mit zweistufiger Bestätigung (Vorschau + Token), geschützten
/// Repository-/Worktree-Pfaden und einem echten `LocalDatabaseShutdown` (Schleifen anhalten, Datenbank
/// schließen). Danach baut `AgentServiceCore` die Laufzeit mit einer leer neu geöffneten Datenbank auf.
/// iCloud-Daten löscht nur der Sync-Koordinator (`deleteCloudData`); lokal bleibt dabei alles erhalten.
extension ServiceRuntime {
    struct PendingLocalDeletion: Sendable {
        let eraser: LocalDataEraser
        let plan: LocalDeletionPlan
        let kind: LocalDeletionKind
    }

    struct PendingCloudDeletion: Sendable {
        let eraser: LocalDataEraser
        let plan: CloudDeletionPlan
    }

    /// Ablage des Dienstes im App-Group-Container. Worktrees und Integration enthalten Git-Arbeitskopien und
    /// werden vom Eraser grundsätzlich übersprungen.
    static func localDataLocations(_ storage: ServiceStorageLayout) -> LocalDataLocations {
        LocalDataLocations(
            appDataRoot: storage.rootURL,
            databaseFile: storage.databaseURL,
            audioDirectory: storage.rootURL.appending(path: "Audio", directoryHint: .isDirectory),
            cacheDirectories: [storage.syncAssetsURL, storage.detectionURL, storage.runtimeURL])
    }

    /// Alle bekannten Repository-, Stammordner- und Worktree-Pfade dieses Macs, die existieren. Nichts darin
    /// darf gelöscht werden, und kein gelöschter Ordner darf einen davon enthalten.
    func protectedDeletionPaths() async -> [URL] {
        var paths = rootFolders.map(\.path)
        paths += ((try? await database.projects.locations(hostId: hostId)) ?? []).map(\.canonicalPath)
        let jobs = (try? await database.jobs.jobs(inStates: Set(AgentJobState.allCases), hostId: nil, limit: nil)) ?? []
        paths += jobs.compactMap(\.worktreePath)
        for directory in [deps.storage.worktreesURL, deps.storage.integrationURL] {
            let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            paths += children.filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path(percentEncoded: false)) }
                .map { $0.path(percentEncoded: false) }
        }
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    func makeEraser() async -> LocalDataEraser {
        let clock = clock
        return LocalDataEraser(
            locations: Self.localDataLocations(deps.storage), keychain: deps.keychain, database: database,
            databaseShutdown: RuntimeDatabaseShutdown(runtime: self), protectedPaths: await protectedDeletionPaths(),
            clock: { clock.now() })
    }

    // MARK: Lokal

    func prepareLocalDeletion(_ kind: LocalDeletionKind) async throws -> LocalDeletionPreviewInfo {
        let scope: LocalDeletionScope = switch kind {
        case .localDatabase: .localDatabase
        case .apiKeys: .apiKeys(.all)
        case .everythingLocal: .everythingLocal
        }
        let eraser = await makeEraser()
        let plan = try await eraser.preparePlan(scope)
        // Nur die jeweils neueste Vorschau gilt.
        localDeletionPlans = [plan.id: PendingLocalDeletion(eraser: eraser, plan: plan, kind: kind)]
        var consequences: [String] = []
        if kind != .apiKeys {
            consequences.append("Projekte, Aufgaben, ADRs, Aufträge und Verlauf verschwinden von diesem Mac. Ist iCloud aktiv, kommen synchronisierte Daten beim nächsten Abruf zurück.")
            consequences.append("Bestätigte Stammordner, Diensteinstellungen und die Kennung dieses Macs werden zurückgesetzt; danach Stammordner neu bestätigen.")
            consequences.append("Die Datenbank wird sofort leer neu angelegt; der Dienst läuft ohne Neustart weiter.")
        } else {
            consequences.append("KI-Ausarbeitungen am Mac brauchen danach einen neuen API-Schlüssel.")
        }
        return LocalDeletionPreviewInfo(
            planId: plan.id, kind: kind, confirmationToken: plan.confirmationToken.value, title: plan.title, summary: plan.summary,
            items: plan.items.map { .init(label: $0.label, byteCount: $0.byteCount, affectsOtherDevices: $0.affectsOtherDevices) },
            retained: plan.retained + ["Agenten-Worktrees und Integrations-Arbeitskopien bleiben erhalten."],
            consequences: consequences, totalBytes: plan.totalBytes, expiresAt: plan.expiresAt)
    }

    func executeLocalDeletion(planId: UUID, token: String) async throws -> LocalDeletionReportInfo {
        guard let pending = localDeletionPlans[planId] else { throw ServiceError.deletionPlanNotFound }
        if pending.kind != .apiKeys, let orchestrator {
            let live = await orchestrator.liveJobIds
            guard live.isEmpty else { throw ServiceError.agentsRunning(live.count) }
        }
        localDeletionPlans[planId] = nil
        let report = try await pending.eraser.execute(pending.plan, confirmation: DeletionConfirmationToken(value: token))
        ServiceLog.lifecycle.notice("Lokale Löschung (\(pending.kind.rawValue, privacy: .public)): \(report.deleted.count, privacy: .public) gelöscht, \(report.failed.count, privacy: .public) fehlgeschlagen")
        return LocalDeletionReportInfo(
            deleted: report.deleted.map(\.label), alreadyMissing: report.alreadyMissing.map(\.label),
            failed: report.failed.map { "\($0.item.label): \($0.message)" }, databaseReopened: isShutDownForDeletion)
    }

    /// `LocalDatabaseShutdown` des Dienstes: Schleifen, Poller, Beobachter anhalten, laufende Scans und
    /// Erkennungen abwarten, dann die Datenbank schließen. Danach nimmt diese Laufzeit keine Befehle mehr an.
    func shutDownForDeletion() async throws {
        guard !isShutDownForDeletion else { return }
        loopsRanBeforeDeletion = !loops.isEmpty
        await stopLoops()
        if let detectionTask { _ = await detectionTask.value }
        if let scanTask { _ = try? await scanTask.value }
        var attempts = 0
        while true {
            do {
                try database.close()
                isShutDownForDeletion = true
                ServiceLog.lifecycle.notice("Datenbank für die Löschung geschlossen")
                return
            } catch {
                attempts += 1
                guard attempts < 30 else {
                    // Datenbank bleibt offen: Dienst arbeitet unverändert weiter, nichts wurde gelöscht.
                    if loopsRanBeforeDeletion { await startLoops() }
                    throw error
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: iCloud

    func prepareCloudDeletion() async -> CloudDeletionPreviewInfo {
        let eraser = await makeEraser()
        let plan = await eraser.prepareCloudDeletion()
        cloudDeletionPlans = [plan.id: PendingCloudDeletion(eraser: eraser, plan: plan)]
        return CloudDeletionPreviewInfo(planId: plan.id, confirmationToken: plan.confirmationToken.value, title: plan.title,
                                        consequences: plan.consequences, expiresAt: plan.expiresAt)
    }

    func confirmCloudDeletion(planId: UUID, token: String, coordinator: SyncCoordinator) async throws {
        guard let pending = cloudDeletionPlans[planId] else { throw ServiceError.deletionPlanNotFound }
        cloudDeletionPlans[planId] = nil
        let request = try await pending.eraser.confirmCloudDeletion(pending.plan, confirmation: DeletionConfirmationToken(value: token))
        defer { Task { await self.refreshSyncStatus() } }
        try await coordinator.deleteCloudData(request)
        syncStatus = await coordinator.status
        ServiceLog.sync.notice("iCloud-Daten auf Wunsch des Benutzers gelöscht; Sync pausiert")
    }

    func retryCloudDeletion(coordinator: SyncCoordinator) async throws {
        defer { Task { await self.refreshSyncStatus() } }
        try await coordinator.retryCloudDataDeletion()
        syncStatus = await coordinator.status
    }

    func refreshSyncStatus() async {
        guard let coordinator, !isShutDownForDeletion else { return }
        syncStatus = await coordinator.status
    }
}

/// Schließt die Datenbank des Dienstes für eine Löschung (A34).
struct RuntimeDatabaseShutdown: LocalDatabaseShutdown {
    weak var runtime: ServiceRuntime?

    func closeDatabaseForDeletion() async throws {
        guard let runtime else { throw DeletionError.databaseShutdownUnavailable }
        try await runtime.shutDownForDeletion()
    }
}
