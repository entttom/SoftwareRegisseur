import Foundation
import Observation
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability
import SoftwareRegisseurSecrets
import SoftwareRegisseurSync

/// Tabs of the iPhone app (spec P, iPhone views 1–8).
enum AppTab: String, Hashable, CaseIterable {
    case overview, tasks, inbox, dictation, projects, agents, review, settings
}

/// App-wide state: local database (ADR-0019: own app container), CloudKit sync (ADR-0011: explicit
/// triggers only), device settings and keychain access.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var database: AppDatabase?
    private(set) var syncCoordinator: SyncCoordinator?
    private(set) var syncStatus = SyncStatus()
    private(set) var syncStartError: String?
    let cloudAvailability: CloudSyncAvailability
    /// CloudKit environment from the entitlement (ADR-0027); the coordinator discards state of another one.
    let cloudEnvironment: String?
    /// Bumped after every local write and every sync run; views reload on change.
    private(set) var dataVersion = 0
    /// Section the user is on (spec P, iPhone views 1–8). Switch sections with `show(_:)`.
    var selectedTab: AppTab
    /// Latest programmatic section switch; the tab view applies it (also in the compact „Mehr“ tab).
    private(set) var tabRequest: TabRequest?
    /// Navigation path of each tab's single `NavigationStack`.
    var paths: [AppTab: [AppRoute]] = [:]
    /// Path of the compact „Mehr“ tab; starts with `.section(_)` once a section is open.
    var morePath: [AppRoute] = []
    /// Quick capture opened with ⌘N („Neue Notiz“) from any section.
    var showsQuickCapture = false
    /// Section whose search field should take focus (⌘F); the section's root list consumes it.
    var pendingSearch: AppTab?

    var settings: AppSettings {
        didSet { try? settingsStore.save(settings) }
    }

    let deviceId: DeviceID
    let settingsStore: SettingsStore
    /// Synced user-wide defaults (default agent, folder layout, workspace defaults; spec F2, J2).
    private(set) var globalSettings = GlobalSettings.defaults
    let keys: ProviderKeyService
    /// Same keychain service as `keys`; used by „Daten löschen“ (A27, A34).
    let keychain: any KeychainStore
    let directories: AppDirectories
    let permissions = SystemPermissionAuthorizer()
    /// Onboarding on the first launch; reopened from „Einstellungen“.
    let onboarding: MobileOnboarding

    private var statusTask: Task<Void, Never>?
    private var pendingSendTask: Task<Void, Never>?
    private var didRunLaunchSync = false

    var actor: EventActor { .user(deviceId) }

    init(bundle: Bundle = .main) {
        let directories = AppDirectories()
        self.directories = directories
        deviceId = DeviceIdentity.load()
        settingsStore = SettingsStore(fileURL: directories.settingsFile)
        settings = settingsStore.load()
        let keychain = SystemKeychainStore(configuration: .init(service: "SoftwareRegisseur.ProviderKeys"))
        self.keychain = keychain
        keys = ProviderKeyService(store: keychain)
        cloudAvailability = CloudSyncAvailability.detect(bundle: bundle)
        cloudEnvironment = CloudSyncAvailability.environment(bundle: bundle)
        let initial = UserDefaults.standard.string(forKey: "SRInitialTab").flatMap(AppTab.init(rawValue:))
        selectedTab = initial ?? .overview
        onboarding = MobileOnboarding(progress: Self.onboardingProgress())
    }

    /// Debug builds with `-SRScreenshotFixtures YES` (UI tests, screenshots) skip the onboarding unless
    /// `-SROnboarding YES` asks for it; then it starts fresh on every launch, at `-SROnboardingStep <step>`
    /// if given.
    private static func onboardingProgress() -> any OnboardingProgressStoring {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "SROnboarding") {
            return InMemoryOnboardingProgress(step: defaults.string(forKey: "SROnboardingStep"))
        }
        if defaults.bool(forKey: "SRScreenshotFixtures") { return InMemoryOnboardingProgress(completed: true) }
        #endif
        return UserDefaultsOnboardingProgress()
    }

    // MARK: Bootstrap

    /// - Parameter inPlace: reopen without the loading screen (after „Daten löschen“), so the screen that
    ///   shows the deletion result stays visible.
    func bootstrap(inPlace: Bool = false) async {
        guard database == nil else { return }
        if !inPlace { loadState = .loading }
        let url = directories.databaseFile
        do {
            let database = try await Task.detached(priority: .userInitiated) {
                try AppDatabase.openWriter(at: url)
            }.value
            self.database = database
            await migrateDeviceLocalData(database)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "SRScreenshotFixtures") { await insertScreenshotFixtures(database) }
            #endif
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
            return
        }
        await startSync()
        await sync(.appLaunch)
        didRunLaunchSync = true
    }

    /// One-time moves of data earlier builds kept only on this device: AI draft versions and the
    /// default agent now sync (spec H3, J2, N1). Failures keep the local data for the next launch.
    private func migrateDeviceLocalData(_ database: AppDatabase) async {
        let legacyDrafts = DraftVersionStore(repository: database.draftVersions, legacyFileURL: directories.draftVersionsFile)
        _ = try? await legacyDrafts.importLegacyVersions()
        var local = settings
        if (try? await GlobalDefaultsEditor(repository: database.globalSettings).importLegacyDefaultAgent(from: &local, at: .now)) != nil,
           local != settings {
            settings = local
        }
        await reloadGlobalSettings()
    }

    #if DEBUG
    /// Debug builds only, launch argument `-SRScreenshotFixtures YES`: a few projects and tasks for
    /// layout screenshots (ADR-0025 verification). Written through the normal repositories, only into an
    /// empty database; never part of a release build.
    private func insertScreenshotFixtures(_ database: AppDatabase) async {
        guard ((try? await database.workItems.list(WorkItemFilter())) ?? []).isEmpty else { return }
        var projectIDs: [ProjectID] = []
        for name in ["Software Regisseur", "Website Relaunch"] {
            let input = NewProjectInput(name: name, option: .draft)
            guard let plan = try? NewProjectPlanner.plan(input, choices: FolderChoices(folders: []), globalSettings: globalSettings,
                                                         device: deviceId, now: .now) else { continue }
            try? await NewProjectSubmitter(projects: database.projects, commands: database.projectSetupCommands).submit(plan, at: .now)
            if let id = plan.project?.id { projectIDs.append(id) }
        }
        let samples: [(String, WorkItemType, Priority, Int?)] = [
            ("Login-Fehler bei abgelaufener Sitzung beheben", .bug, .high, 0),
            ("Diktat: Pausieren und Fortsetzen im Hintergrund", .feature, .medium, 0),
            ("Startseite für Tablets überarbeiten", .feature, .low, 1),
            ("Idee: Wochenrückblick der Agentenläufe", .note, .medium, nil),
            ("Kontaktformular – Spam-Schutz prüfen", .bug, .medium, nil),
        ]
        for (title, type, priority, project) in samples {
            let projectID = project.flatMap { projectIDs.indices.contains($0) ? projectIDs[$0] : nil }
            let item = WorkItem(projectId: projectID, type: type, title: title, originalNote: title,
                                status: projectID == nil ? .inbox : .open, priority: priority, createdAt: .now)
            try? await database.workItems.insert(item, actor: actor, at: .now)
        }
        await insertAgentFixtures(database, staleProject: projectIDs.indices.contains(1) ? projectIDs[1] : nil)
    }

    /// A Mac host as the Agent Service would report it: Codex with model and effort choice, Claude Code
    /// with model choice only (effort „Anbieterstandard – nicht einstellbar“, spec J2a). The second project
    /// keeps a Codex preference whose effort the model no longer supports (A40), so its start sheet shows a
    /// blocked combination. UI tests (A29, A37, A40) rely on these values.
    private func insertAgentFixtures(_ database: AppDatabase, staleProject: ProjectID?) async {
        let now = Date.now
        let host = HostID()
        let codex = AgentCapability(
            providerId: .codex, displayName: "Codex", hostId: host, version: "0.50.0",
            supportsModelSelection: true, supportsEffortSelection: true,
            modelCatalog: [
                AgentModelCapability(providerId: .codex, modelId: "gpt-5-codex", displayName: "GPT-5-Codex",
                                     supportedEffortIds: [.low, .medium, .high], defaultEffortId: .medium,
                                     source: .documentedCLI, lastValidatedAt: now),
                AgentModelCapability(providerId: .codex, modelId: "gpt-4.1", displayName: "GPT-4.1",
                                     supportedEffortIds: [], availability: .deprecated,
                                     source: .documentedCLI, lastValidatedAt: now),
            ],
            defaultModelId: "gpt-5-codex", capabilitySource: .documentedCLI, capabilityRevision: 1, lastChecked: now
        )
        let claude = AgentCapability(
            providerId: .claudeCode, displayName: "Claude Code", hostId: host, version: "2.0.0",
            supportsModelSelection: true, supportsEffortSelection: false,
            modelCatalog: [
                AgentModelCapability(providerId: .claudeCode, modelId: "sonnet", displayName: "Sonnet",
                                     supportedEffortIds: [], source: .documentedCLI, lastValidatedAt: now),
                AgentModelCapability(providerId: .claudeCode, modelId: "opus", displayName: "Opus",
                                     supportedEffortIds: [], source: .documentedCLI, lastValidatedAt: now),
            ],
            capabilitySource: .documentedCLI, capabilityRevision: 1, lastChecked: now
        )
        let agentHost = AgentHost(hostId: host, name: "Studio-Mac", lastSeen: now, ready: true,
                                  agentCapabilities: [codex, claude], serviceVersion: "1.0.0")
        try? await database.capabilities.saveHost(agentHost, at: now)
        if let staleProject {
            let stale = AgentModelPreference(scope: .project(staleProject), providerId: .codex,
                                             model: .model("gpt-5-codex"), effort: .max, updatedAt: now)
            try? await database.preferences.save(stale, at: now)
        }
        await insertApprovalFixtures(database, host: host)
    }

    /// Two open approvals as the Mac relays them (spec J6 fallback): a short command with Erlauben/Ablehnen
    /// and a shortened preview, for which synced devices may only deny (SR-SEC-08). They reference a job ID
    /// that exists only here; the approval list does not need the job.
    private func insertApprovalFixtures(_ database: AppDatabase, host: HostID) async {
        guard let item = ((try? await database.workItems.list(WorkItemFilter())) ?? [])
            .first(where: { $0.title.hasPrefix("Diktat:") }) else { return }
        let now = Date.now
        let longCommand = "rsync -av --delete ./build/ deploy@example.invalid:/srv/app/ " + String(repeating: "--exclude=cache ", count: 40)
        let approvals = [
            PendingApproval(jobId: JobID(), workItemId: item.uuid, hostId: host, requestId: "fixture-short",
                            kind: .commandExecution, summary: "Befehl ausführen: swift test", preview: "swift test",
                            allowedDecisions: [.allow, .deny], requestedAt: now),
            PendingApproval(jobId: JobID(), workItemId: item.uuid, hostId: host, requestId: "fixture-truncated",
                            kind: .commandExecution, summary: "Befehl ausführen: rsync",
                            preview: String(longCommand.prefix(120)), allowedDecisions: [.deny],
                            requestedAt: now.addingTimeInterval(1), previewFullLength: longCommand.count,
                            allowRequiresHostReview: true),
        ]
        for approval in approvals { try? await database.approvals.save(approval, at: now) }
    }
    #endif

    /// Draft versions (synced Domain `DraftVersion`); nil until the database is open.
    var draftVersions: DraftVersionStore? {
        database.map { DraftVersionStore(repository: $0.draftVersions) }
    }

    /// Draft store for views that run only with an open database.
    func requireDraftVersions() throws -> DraftVersionStore {
        guard let store = draftVersions else { throw StoreError.schemaNotReady }
        return store
    }

    func reloadGlobalSettings() async {
        guard let database else { return }
        if let loaded = try? await database.globalSettings.fetch() { globalSettings = loaded }
    }

    /// Saves a change to the synced defaults; a concurrent edit elsewhere reloads instead of overwriting.
    func updateGlobalSettings(_ change: (inout GlobalSettings) -> Void) async throws {
        guard let database else { return }
        let base = globalSettings
        var updated = base
        change(&updated)
        do {
            globalSettings = try await database.globalSettings.save(updated, expectedRevision: base.revision, at: .now)
            noteLocalChange()
        } catch {
            await reloadGlobalSettings()
            throw error
        }
    }

    private func startSync() async {
        guard let database, case let .available(container) = cloudAvailability else { return }
        let configuration = SyncConfiguration(
            deviceId: deviceId, role: .mobile, assetDirectory: directories.syncAssetDirectory,
            cloudEnvironment: cloudEnvironment
        )
        let coordinator = SyncCoordinator(
            store: database.sync, configuration: configuration,
            engineFactory: CloudKitSyncEngineAdapter.factory(containerIdentifier: container)
        )
        do {
            try await coordinator.start()
            syncCoordinator = coordinator
            statusTask = Task { [weak self] in
                for await status in await coordinator.statusUpdates() {
                    self?.syncStatus = status
                }
            }
        } catch {
            syncStartError = error.localizedDescription
        }
    }

    // MARK: Sync triggers (ADR-0011: launch, foreground, pull-to-refresh, manual; no push)

    func sceneBecameActive() async {
        guard didRunLaunchSync else { return }
        await sync(.foreground)
    }

    func sync(_ reason: SyncReason) async {
        if let syncCoordinator {
            _ = await syncCoordinator.syncNow(reason: reason)
        }
        await reloadGlobalSettings()
        dataVersion += 1
    }

    /// Called after every local write: refreshes views and sends the outbox shortly after.
    func noteLocalChange() {
        dataVersion += 1
        guard let syncCoordinator else { return }
        pendingSendTask?.cancel()
        pendingSendTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            _ = await syncCoordinator.syncNow(reason: .localChange)
            self.dataVersion += 1
        }
    }

    func resolveConflict(_ id: UUID, resolution: ConflictResolution) async throws {
        if let syncCoordinator {
            try await syncCoordinator.resolveConflict(id, resolution: resolution)
        } else if let database {
            try await database.sync.resolveConflict(id, resolution: resolution)
        }
        noteLocalChange()
    }

    func acknowledgeAccountChange() async {
        try? await syncCoordinator?.acknowledgeAccountChange()
        await sync(.manual)
    }

    /// „Lokale Daten erneut hochladen“ / „Wieder mit iCloud synchronisieren“: the user's explicit decision
    /// after a zone loss or after deleting the iCloud data (full upload).
    func recreateZone() async {
        await syncCoordinator?.recreateZoneAndResume()
        await sync(.manual)
    }

    /// Retries a confirmed iCloud deletion that iCloud has not confirmed yet.
    func retryCloudDeletion() async -> String? {
        guard let syncCoordinator else { return nil }
        do {
            try await syncCoordinator.retryCloudDataDeletion()
            return nil
        } catch let error as CloudDataDeletionError {
            return error.userMessage
        } catch {
            return errorMessage(error)
        }
    }

    // MARK: Data export and deletion (spec Q1, A34)

    /// What „Daten löschen“ may touch on this iPhone (all inside the app's own container).
    var localDataLocations: LocalDataLocations { directories.localDataLocations }

    /// Deletion with preview and confirmation token. iOS needs no protected paths (the container holds
    /// no repositories), so the list is passed explicitly empty. The iCloud plan goes only through the
    /// sync coordinator.
    func makeDeletionModel() -> DataDeletionModel {
        let eraser = LocalDataEraser(
            locations: localDataLocations, keychain: keychain, database: database,
            databaseShutdown: AppDatabaseShutdown(model: self), protectedPaths: []
        )
        return DataDeletionModel(
            eraser: eraser, cloud: syncCoordinator.map(CoordinatorCloudDeletion.init),
            afterLocalDeletion: { [weak self] choice, _ in await self?.restoreAfterLocalDeletion(choice) }
        )
    }

    func makeExportModel() -> DataExportModel? {
        guard let database else { return nil }
        return .live(database: database, audioDirectory: directories.audioDirectory, destination: directories.exportDirectory)
    }

    /// `LocalDatabaseShutdown`: stops sync and every database user, then closes the database so its files
    /// can be deleted. A database still busy refuses closing; then nothing is deleted.
    func closeDatabaseForDeletion() async throws {
        pendingSendTask?.cancel()
        pendingSendTask = nil
        statusTask?.cancel()
        statusTask = nil
        syncCoordinator = nil
        didRunLaunchSync = false
        guard let database else { return }
        var lastError: (any Error)?
        for _ in 0..<20 {
            do {
                try database.close()
                self.database = nil
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? StoreError.schemaNotReady
    }

    /// Brings the app back into a consistent state after a local deletion: reopens (or recreates) the
    /// database, restarts sync, reloads device settings and refreshes all views.
    func restoreAfterLocalDeletion(_ choice: LocalDeletionChoice) async {
        directories.ensureFolders()
        if choice == .everythingLocal {
            settings = settingsStore.load()
        }
        if database == nil {
            syncStatus = SyncStatus()
            syncStartError = nil
            globalSettings = GlobalSettings.defaults
            await bootstrap(inPlace: true)
        } else if syncCoordinator == nil {
            // Closing failed (nothing was deleted from the database): resume sync with the open database.
            await startSync()
            didRunLaunchSync = true
        }
        dataVersion += 1
    }

    /// Switches to a section; in the compact layout sections without their own tab open in „Mehr“.
    func show(_ tab: AppTab) {
        selectedTab = tab
        tabRequest = TabRequest(tab: tab)
    }

    /// ⌘N: quick capture sheet over the current section.
    func requestQuickCapture() {
        showsQuickCapture = true
    }

    /// ⌘F: searches projects while „Projekte“ is open, tasks everywhere else.
    func requestSearch() {
        let target: AppTab = selectedTab == .projects ? .projects : .tasks
        // Back to the list, where the search field is (also in the compact „Mehr“ stack).
        paths[target] = []
        if !target.isCompactPrimary { morePath = [.section(target)] }
        show(target)
        pendingSearch = target
    }

    /// Removes a deleted task (and everything opened from it) from all navigation paths.
    /// - Returns: false if the task was not on any path.
    @discardableResult
    func closeRoutes(to id: WorkItemID) -> Bool {
        func truncated(_ path: [AppRoute]) -> [AppRoute]? {
            path.firstIndex(of: .task(id)).map { Array(path.prefix(upTo: $0)) }
        }
        var found = false
        for (tab, path) in paths {
            if let shorter = truncated(path) { paths[tab] = shorter; found = true }
        }
        if let shorter = truncated(morePath) { morePath = shorter; found = true }
        return found
    }

    /// Opens a task in the „Aufgaben“ tab (e.g. after dictation or duplicating), replacing that tab's path.
    func openTask(_ id: WorkItemID) {
        paths[.tasks] = [.task(id)]
        show(.tasks)
    }

    // MARK: Helpers

    var draftHeadings: DraftBodyHeadings {
        DraftBodyHeadings(
            goal: String(localized: "Ziel"),
            context: String(localized: "Kontext"),
            acceptanceCriteria: String(localized: "Akzeptanzkriterien"),
            technicalNotes: String(localized: "Technische Hinweise"),
            testCases: String(localized: "Testfälle"),
            dependencies: String(localized: "Abhängigkeiten"),
            openQuestions: String(localized: "Offene Fragen")
        )
    }

    var costEstimator: CostEstimator { CostEstimator(priceTable: settings.priceTable) }
}

/// Files in the app's own container (ADR-0019: no App Group on iOS).
struct AppDirectories: Sendable {
    let root: URL

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
            ?? URL.applicationSupportDirectory
        root = support.appendingPathComponent("SoftwareRegisseur", isDirectory: true)
        ensureFolders()
    }

    var databaseFile: URL { root.appendingPathComponent("SoftwareRegisseur.sqlite") }
    var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// Device-only draft store of earlier builds; imported once into the synced `DraftVersion` table.
    var draftVersionsFile: URL { root.appendingPathComponent("draft-versions.json") }
    var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    var syncAssetDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SoftwareRegisseurSyncAssets", isDirectory: true)
    }
    /// Data exports before they are shared or saved to Files (removed with „Exportdateien entfernen“).
    var exportDirectory: URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL.cachesDirectory
        return caches.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Everything „Daten löschen“ may remove on this iPhone (A34): sync asset staging and exports are
    /// rebuildable caches; settings and the legacy draft store are extra app files.
    var localDataLocations: LocalDataLocations {
        LocalDataLocations(
            appDataRoot: root, databaseFile: databaseFile, audioDirectory: audioDirectory,
            cacheDirectories: [syncAssetDirectory, exportDirectory],
            additionalFiles: [settingsFile, draftVersionsFile, draftVersionsFile.appendingPathExtension("imported")]
        )
    }

    /// Recreates the app folders (after „Alle lokalen Daten löschen“ removed them).
    func ensureFolders() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }
}

/// `LocalDatabaseShutdown` for `LocalDataEraser`: the app model stops sync and closes the database.
struct AppDatabaseShutdown: LocalDatabaseShutdown {
    weak var model: AppModel?

    func closeDatabaseForDeletion() async throws {
        guard let model else { throw DeletionError.databaseShutdownUnavailable }
        try await model.closeDatabaseForDeletion()
    }
}

/// The iCloud plan of „Daten löschen“ is carried out only by the sync coordinator (zone deletion,
/// then paused until the user resumes).
struct CoordinatorCloudDeletion: CloudDataDeleting {
    let coordinator: SyncCoordinator

    func deleteCloudData(_ request: CloudDataDeletionRequest) async throws {
        do {
            try await coordinator.deleteCloudData(request)
        } catch let error as CloudDataDeletionError {
            throw CloudDataDeletionFailure(message: error.userMessage)
        }
    }
}

/// Stable per-installation device ID for `EventActor.user` and sync bookkeeping.
enum DeviceIdentity {
    static func load(defaults: UserDefaults = .standard) -> DeviceID {
        let key = "SRDeviceIdentifier"
        if let raw = defaults.string(forKey: key), let id = DeviceID(uuidString: raw) { return id }
        let id = DeviceID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }
}

/// Whether this build can use CloudKit. Unsigned or placeholder-signed builds have no iCloud entitlement;
/// touching `CKContainer` there would crash, so sync stays off and the app works locally (A26 shown honestly).
enum CloudSyncAvailability: Equatable, Sendable {
    case available(container: String)
    case unavailable(CloudSyncUnavailableReason)

    static func detect(bundle: Bundle) -> CloudSyncAvailability {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let signingAllowed = value("SRCodeSigningAllowed").uppercased()
        if signingAllowed == "NO" { return .unavailable(.unsignedBuild) }
        let team = value("SRDevelopmentTeam")
        if team.isEmpty || team == value("SRTemplateTeamPlaceholder") { return .unavailable(.placeholderSigning) }
        let container = value("SRCloudKitContainerIdentifier")
        guard container.hasPrefix("iCloud."), !container.contains("$(") else { return .unavailable(.missingContainer) }
        return .available(container: container)
    }

    /// `SRCloudKitEnvironment` (Config/Base.xcconfig, same value as the entitlement); nil if not substituted.
    static func environment(bundle: Bundle) -> String? {
        let value = (bundle.object(forInfoDictionaryKey: "SRCloudKitEnvironment") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.contains("$(") ? nil : value
    }
}

enum CloudSyncUnavailableReason: Equatable, Sendable {
    case unsignedBuild
    case placeholderSigning
    case missingContainer
}
