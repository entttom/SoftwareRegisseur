import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurIPC
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess
import SoftwareRegisseurSecrets
import SoftwareRegisseurSync
import SoftwareRegisseurWorkspace

/// CloudKit-Verfügbarkeit dieses Dienstprozesses.
enum CloudSyncSetup: Sendable {
    /// Unsignierter Build, Platzhalter-Team oder fehlender Container: kein `CKContainer` (würde abstürzen).
    case unavailable(reason: String)
    /// `environment`: CloudKit environment of the entitlement (ADR-0027), checked by the coordinator.
    case available(SyncEngineFactory, environment: String? = nil)
}

/// Austauschbare Abhängigkeiten des Dienstes (Produktion: `AgentServiceMain`, Tests: Fakes).
struct ServiceDependencies: Sendable {
    var database: AppDatabase
    var storage: ServiceStorageLayout
    var version: ServiceVersion
    var hostName: String
    /// `nil`: Git nicht gefunden → keine Agentenjobs, Rest läuft weiter.
    var git: GitClient?
    /// Agentenanbieter für diesen Host; das Erkennungsverzeichnis liegt in der Dienstablage.
    /// `executableOverrides`: vom Benutzer festgelegte Programmpfade (J1); bei Änderung baut der Dienst die
    /// Anbieter ohne Neustart neu (``ReconfigurableAgentProvider``).
    var makeProviders: @Sendable (_ hostId: HostID, _ detectionDirectory: URL, _ executableOverrides: [ProviderID: URL])
        -> AgentProviderRegistry
    /// Öffnet die Datenbank als einziger Schreiber; nach einer Löschung (A34) wird sie damit leer neu geöffnet.
    var openDatabase: @Sendable (URL) throws -> AppDatabase = { try AppDatabase.openWriter(at: $0) }
    var cloudSync: CloudSyncSetup
    var clock: any JobClock
    var processInspector: any ProcessInspecting
    var keychain: any KeychainStore
    /// Text-KI-Client mit dem Schlüssel aus dem Mac-Schlüsselbund (H4, I).
    var makeTextProvider: @Sendable (SoftwareRegisseurAI.AIProviderID, any KeychainStore) throws -> any TextAIProvider
    var makeGitHub: @Sendable (WorkspaceEnvironment) -> GitHubIssueService
    var sleepAssertion: any SleepAssertionControlling
    /// Basis für den Stammordner-Vorschlag `~/Developer`.
    var homeDirectory: URL
    var concurrencyLimits: ConcurrencyLimits

    /// Produktionsverhalten für Textanbieter: Schlüssel aus dem Schlüsselbund, Konto `<anbieter>.text`.
    static let keychainTextProvider: @Sendable (SoftwareRegisseurAI.AIProviderID, any KeychainStore) throws -> any TextAIProvider = {
        provider, keychain in
        try ProviderKeyService(store: keychain).textProvider(provider)
    }
}

/// Kompositionswurzel und Schleifen des Agent Service (Pflichtenheft C, D3, E, G, H4, J, K, L, M, N).
///
/// Schleifen (nur nach ``startLoops()``; Tests rufen die Durchläufe direkt auf):
/// - **Jobs**: `JobOrchestrator.tick`, danach Schlaf bis `min(nextWakeDate, Leerlaufintervall)`, bei
///   laufenden Agenten höchstens 10 s; geweckt durch Sync-Ergebnisse, IPC-Befehle und Aufwachen.
/// - **Sync**: `PollingScheduler` → ``performSync(reason:)`` (Standard 60 s, Backoff bei Fehlern).
/// - **Haushalt**: Projekteinrichtung, angeforderte Konfliktlösungen, Markdown-Abgleich geänderter
///   Aufgaben, KI-Ausarbeitungen; nach jedem Sync, jeder Job-Änderung und spätestens alle 2 min.
/// - **Scanner**: Stammordner-Scan beim Start, auf Anforderung und periodisch; FSEvents-Watcher mit
///   periodischer Reconciliation über `RepositorySyncService`.
/// - **Agentenerkennung**: beim Start, periodisch (Standard 30 min), auf Anforderung; vor jedem Start
///   frischt der Orchestrator die Fähigkeiten zusätzlich selbst auf.
/// - **GitHub**: Abgleich aktivierter Projekte (Standard 15 min).
actor ServiceRuntime {
    let deps: ServiceDependencies
    let database: AppDatabase
    let clock: any JobClock
    let stateStore: ServiceStateStore
    let hostId: HostID
    /// Geräte-ID des Mac-Benutzers: Akteur aller Entscheidungen aus der Mac-UI und Sync-Geräte-ID.
    let deviceId: DeviceID
    let startedAt: Date
    let gate: AdmissionGate
    let environment: WorkspaceEnvironment
    let catalog: ProjectCatalog
    let setupService: ProjectSetupService
    let repositorySync: RepositorySyncService
    let instructions: InstructionsManager
    let migrator: FolderLayoutMigrator
    let gitHub: GitHubIssueService
    let providers: AgentProviderRegistry
    /// Dieselben Anbieter wie in `providers`, austauschbar für neue Programmpfade.
    let reconfigurableProviders: [ReconfigurableAgentProvider]
    let orchestrator: JobOrchestrator?
    let coordinator: SyncCoordinator?
    let syncUnavailableReason: String?

    var runState: ServiceRunState
    var settings: ServiceSettings
    var rootFolders: [ServiceStateStore.RootFolder]
    var isBootstrapped = false
    var recoveryReport: RecoveryReport?

    // Schleifen und Signale
    let jobsSignal = WakeSignal()
    let housekeepingSignal = WakeSignal()
    let scanSignal = WakeSignal()
    let detectionSignal = WakeSignal()
    let gitHubSignal = WakeSignal()
    var loops: [Task<Void, Never>] = []
    var poller: PollingScheduler?
    var syncStatusTask: Task<Void, Never>?
    var sendSoonTask: Task<Void, Never>?
    var powerObserver: SystemPowerObserver?

    // Zustand für Status und Abgleich
    var syncStatus: SyncStatus?
    var lastSyncResult: SyncRunResult?
    var lastTick: TickReport?
    var lastLiveJobs: Set<JobID> = []
    var lastHeartbeat: Date?
    var lastHeartbeatReady: Bool?
    var scanTask: Task<ScanInfo, any Error>?
    var lastScan: ScanInfo?
    var lastScanError: String?
    var detectionTask: Task<[AgentDetectionReport], Never>?
    var lastDetection: Date?
    var watchedProjects: Set<ProjectID> = []
    var proposals: [ProjectID: InstructionProposal] = [:]
    var migrationPlans: [UUID: ProjectID] = [:]
    var gitHubAvailability: GitHubAvailability?
    var gitHubAvailabilityCheckedAt: Date?
    var eventCursor: Date?
    var processedEvents: [EventID: Date] = [:]
    var needsFullReconcile = true
    var aiQueueDirty = true
    var lastAIQueueScan: Date?
    var aiInFlight: Set<AIRequestID> = []
    var pendingAIElaborations = 0

    // Datenlöschung (A34)
    var localDeletionPlans: [UUID: PendingLocalDeletion] = [:]
    var cloudDeletionPlans: [UUID: PendingCloudDeletion] = [:]
    var loopsRanBeforeDeletion = false
    /// Datenbank für eine Löschung geschlossen: diese Laufzeit nimmt keine Befehle mehr an; der
    /// `AgentServiceCore` ersetzt sie durch eine neu aufgebaute.
    var isShutDownForDeletion = false

    var userActor: EventActor { .user(deviceId) }
    var hostActor: EventActor { .host(hostId) }

    // MARK: Aufbau

    /// Liest bzw. erzeugt Kennungen und Einstellungen, baut alle Bausteine und führt die
    /// Wiederherstellung laufender Jobs aus (D3). Kontaktiert weder CloudKit noch Agenten.
    static func make(_ deps: ServiceDependencies) async throws -> ServiceRuntime {
        let database = deps.database
        let clock = deps.clock
        let stateStore = ServiceStateStore(store: database.hostState, now: { clock.now() })
        let hostId = HostID(try await stateStore.stableIdentifier(key: "hostId"))
        let deviceId = DeviceID(try await stateStore.stableIdentifier(key: "deviceId"))
        let runState = await stateStore.runState()
        let settings = await stateStore.settings()
        let roots = await stateStore.rootFolders()

        for directory in [deps.storage.worktreesURL, deps.storage.integrationURL, deps.storage.runtimeURL,
                          deps.storage.syncAssetsURL, deps.storage.detectionURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        let environment = WorkspaceEnvironment(database: database, hostId: hostId, git: deps.git, now: { clock.now() })
        let catalog = ProjectCatalog(environment: environment, configuration: Self.catalogConfiguration(roots: roots, storage: deps.storage))
        let setupService = ProjectSetupService(environment: environment, catalog: catalog)
        let repositorySync = RepositorySyncService(environment: environment)
        let reconfigurable = deps.makeProviders(hostId, deps.storage.detectionURL, Self.executableOverrides(settings)).providers
            .map(ReconfigurableAgentProvider.init)
        let providers = AgentProviderRegistry(providers: reconfigurable)
        let gate = AdmissionGate(isOpen: runState == .running)

        var orchestrator: JobOrchestrator?
        if let git = deps.git {
            let configuration = JobOrchestratorConfiguration(
                hostId: hostId,
                worktreesBaseDirectory: deps.storage.worktreesURL,
                integrationWorktreeDirectory: deps.storage.integrationURL,
                scanRoots: roots.map { URL(filePath: $0.path, directoryHint: .isDirectory) },
                runtimeDirectory: deps.storage.runtimeURL,
                limits: deps.concurrencyLimits,
                // Der Dienst schreibt den Heartbeat selbst (gedrosselt, mit „pausiert“ als nicht bereit).
                recordsHostHeartbeat: false
            )
            let documentFiles = database.documentFiles
            let dependencies = JobOrchestratorDependencies(
                jobs: AdmissionGatedJobRepository(base: database.jobs, gate: gate, hostId: hostId),
                locks: database.locks, workItems: database.workItems, projects: database.projects,
                capabilities: database.capabilities, preferences: database.preferences, reviews: database.reviews,
                events: database.events, approvals: database.approvals, providers: providers, git: git,
                processInspector: deps.processInspector, clock: clock,
                requestFilePath: { item in try? await documentFiles.fetch(entityId: item.uuid.rawValue)?.relativePath },
                // ADR-0024: effective folder layout → exempt from the integration dirty check, named in the prompt.
                // An invalid layout yields no exemption (stricter, never wider).
                documentPaths: { projectId in (try? await environment.documentPaths(projectId)) ?? [] },
                // ADR-0026: live bestätigte Stammordner – ein später entfernter Stammordner gilt sofort nicht mehr.
                allowedRepositoryRoots: {
                    await stateStore.rootFolders().map { URL(filePath: $0.path, directoryHint: .isDirectory) }
                }
            )
            orchestrator = try JobOrchestrator(configuration: configuration, dependencies: dependencies)
        }

        var coordinator: SyncCoordinator?
        var unavailableReason: String?
        switch deps.cloudSync {
        case let .unavailable(reason):
            unavailableReason = reason
        case let .available(factory, cloudEnvironment):
            coordinator = SyncCoordinator(
                store: database.sync,
                configuration: SyncConfiguration(deviceId: deviceId, role: .executionHost(hostId), assetDirectory: deps.storage.syncAssetsURL,
                                                 cloudEnvironment: cloudEnvironment),
                now: { clock.now() },
                engineFactory: factory
            )
        }

        let runtime = ServiceRuntime(
            deps: deps, stateStore: stateStore, hostId: hostId, deviceId: deviceId, gate: gate, environment: environment,
            catalog: catalog, setupService: setupService, repositorySync: repositorySync, providers: providers,
            reconfigurableProviders: reconfigurable, orchestrator: orchestrator, coordinator: coordinator, syncUnavailableReason: unavailableReason,
            runState: runState, settings: settings, rootFolders: roots
        )
        try await runtime.bootstrap()
        return runtime
    }

    private init(
        deps: ServiceDependencies, stateStore: ServiceStateStore, hostId: HostID, deviceId: DeviceID, gate: AdmissionGate,
        environment: WorkspaceEnvironment, catalog: ProjectCatalog, setupService: ProjectSetupService,
        repositorySync: RepositorySyncService, providers: AgentProviderRegistry,
        reconfigurableProviders: [ReconfigurableAgentProvider], orchestrator: JobOrchestrator?,
        coordinator: SyncCoordinator?, syncUnavailableReason: String?, runState: ServiceRunState, settings: ServiceSettings,
        rootFolders: [ServiceStateStore.RootFolder]
    ) {
        self.deps = deps
        database = deps.database
        clock = deps.clock
        self.stateStore = stateStore
        self.hostId = hostId
        self.deviceId = deviceId
        startedAt = deps.clock.now()
        self.gate = gate
        self.environment = environment
        self.catalog = catalog
        self.setupService = setupService
        self.repositorySync = repositorySync
        instructions = InstructionsManager(environment: environment)
        migrator = FolderLayoutMigrator(environment: environment)
        gitHub = deps.makeGitHub(environment)
        self.providers = providers
        self.reconfigurableProviders = reconfigurableProviders
        self.orchestrator = orchestrator
        self.coordinator = coordinator
        self.syncUnavailableReason = syncUnavailableReason
        self.runState = runState
        self.settings = settings
        self.rootFolders = rootFolders
    }

    /// Gültige Programmpfad-Overrides aus den Diensteinstellungen.
    static func executableOverrides(_ settings: ServiceSettings) -> [ProviderID: URL] {
        var result: [ProviderID: URL] = [:]
        for (raw, path) in settings.agentExecutablePaths where path.hasPrefix("/") {
            guard let provider = ProviderID(rawValue: raw) else { continue }
            result[provider] = URL(filePath: path, directoryHint: .notDirectory)
        }
        return result
    }

    static func catalogConfiguration(roots: [ServiceStateStore.RootFolder], storage: ServiceStorageLayout) -> CatalogConfiguration {
        CatalogConfiguration(
            roots: roots.map { URL(filePath: $0.path, directoryHint: .isDirectory) },
            options: ScanOptions(excludedPaths: [storage.rootURL])
        )
    }

    private func bootstrap() async throws {
        let now = clock.now()
        let existing = try await database.capabilities.host(hostId)
        try await database.capabilities.saveHost(AgentHost(
            hostId: hostId, name: deps.hostName, lastSeen: now, ready: false,
            agentCapabilities: existing?.agentCapabilities ?? [], serviceVersion: deps.version.shortVersion
        ), at: now)

        if let orchestrator {
            let report = await orchestrator.recover(at: now)
            recoveryReport = report
            ServiceLog.jobs.notice("Wiederherstellung: \(report.actions.count, privacy: .public) Jobs geprüft, \(report.releasedLocks.count, privacy: .public) Sperren freigegeben, \(report.keptLocks.count, privacy: .public) behalten, \(report.errors.count, privacy: .public) Fehler")
            for error in report.errors {
                ServiceLog.jobs.error("Wiederherstellung: \(ServiceLog.redact(error), privacy: .private)")
            }
        } else {
            ServiceLog.jobs.fault("Git nicht gefunden – Agentenjobs sind deaktiviert")
        }

        if let coordinator {
            do {
                try await coordinator.start()
                syncStatus = await coordinator.status
            } catch {
                ServiceLog.sync.error("Sync-Koordinator nicht startbar: \(ServiceLog.redact(error), privacy: .private)")
            }
        } else if let syncUnavailableReason {
            ServiceLog.sync.notice("iCloud-Synchronisierung nicht verfügbar: \(ServiceLog.redact(syncUnavailableReason), privacy: .private)")
        }

        watchedProjects = Set(((try? await repositorySync.watchedProjects()) ?? []).map(\.0))
        isBootstrapped = true
        ServiceLog.lifecycle.notice("Dienst bereit: Zustand \(self.runState.rawValue, privacy: .public), \(self.rootFolders.count, privacy: .public) Stammordner, Sync \(self.coordinator == nil ? "aus" : "an", privacy: .public)")
    }

    // MARK: Schleifen

    /// Startet alle Hintergrundschleifen (Produktion). Idempotent.
    func startLoops() async {
        guard loops.isEmpty else { return }
        if let coordinator {
            let updates = await coordinator.statusUpdates()
            syncStatusTask = Task { [weak self] in
                for await status in updates {
                    await self?.syncStatusChanged(status)
                }
            }
            startPoller()
        }
        do {
            try await repositorySync.start(reconcileInterval: .seconds(settings.reconcileInterval))
        } catch {
            ServiceLog.workspace.error("Dateisystem-Beobachtung nicht startbar: \(ServiceLog.redact(error), privacy: .private)")
        }
        loops.append(Task { [weak self] in await self?.jobsLoop() })
        loops.append(Task { [weak self] in await self?.housekeepingLoop() })
        loops.append(Task { [weak self] in await self?.scanLoop() })
        loops.append(Task { [weak self] in await self?.detectionLoop() })
        loops.append(Task { [weak self] in await self?.gitHubLoop() })
        let observer = SystemPowerObserver { [weak self] event in
            Task { await self?.handlePower(event) }
        }
        if observer.start() { powerObserver = observer }
    }

    /// Hält alle Schleifen an (Dienststopp). Laufende Agenten werden nicht abgebrochen; nach einem
    /// Neustart übernimmt die Wiederherstellung (D3).
    func stopLoops() async {
        loops.forEach { $0.cancel() }
        loops = []
        await poller?.stop()
        poller = nil
        syncStatusTask?.cancel()
        sendSoonTask?.cancel()
        await repositorySync.stop()
        powerObserver?.stop()
        powerObserver = nil
        deps.sleepAssertion.setPreventIdleSleep(false, reason: "")
    }

    func startPoller() {
        guard coordinator != nil else { return }
        let trigger = SyncTrigger(runtime: self)
        let poller = PollingScheduler(
            target: trigger,
            configuration: PollingConfiguration(interval: settings.syncPollInterval, maxInterval: settings.syncMaxBackoff)
        )
        self.poller = poller
        Task { await poller.start() }
    }

    private func jobsLoop() async {
        while !Task.isCancelled {
            let nextWake = await jobsPass()
            let live = !(lastLiveJobs.isEmpty)
            let cap = live ? 10 : settings.jobsIdleInterval
            let seconds = min(cap, max(1, nextWake.timeIntervalSince(clock.now())))
            await jobsSignal.wait(timeout: .seconds(seconds))
        }
    }

    private func housekeepingLoop() async {
        while !Task.isCancelled {
            await housekeepingPass()
            await housekeepingSignal.wait(timeout: .seconds(120))
        }
    }

    private func scanLoop() async {
        while !Task.isCancelled {
            if !rootFolders.isEmpty {
                _ = try? await scan()
            }
            await scanSignal.wait(timeout: .seconds(settings.workspaceScanInterval))
        }
    }

    private func detectionLoop() async {
        while !Task.isCancelled {
            _ = await detectAgents()
            await detectionSignal.wait(timeout: .seconds(settings.agentDetectionInterval))
        }
    }

    private func gitHubLoop() async {
        // Erst nach dem ersten Scan, damit Projekte und Remotes bekannt sind.
        await gitHubSignal.wait(timeout: .seconds(60))
        while !Task.isCancelled {
            await gitHubPass(projectId: nil)
            await gitHubSignal.wait(timeout: .seconds(settings.gitHubSyncInterval))
        }
    }

    // MARK: Ruhezustand

    func handlePower(_ event: SystemPowerObserver.Event) async {
        switch event {
        case .willSleep:
            // Nichts verhindern (D3); laufende Agenten werden vom System mit angehalten.
            ServiceLog.power.notice("Mac geht in den Ruhezustand")
        case .didWake:
            ServiceLog.power.notice("Mac aufgewacht – Sync, Jobs und Repositories werden neu geprüft")
            needsFullReconcile = true
            jobsSignal.signal()
            housekeepingSignal.signal()
            await poller?.resume()
            Task { [weak self] in _ = await self?.performSync(reason: .poll) }
        }
    }

    // MARK: Sync

    /// Ein Sync-Lauf (Abruf, dann Senden). Weckt danach Jobs und Haushalt, wenn Daten angekommen sind.
    @discardableResult
    func performSync(reason: SyncReason) async -> SyncRunResult {
        guard let coordinator else { return .paused(.notStarted) }
        let result = await coordinator.syncNow(reason: reason)
        lastSyncResult = result
        syncStatus = await coordinator.status
        switch result {
        case let .completed(report):
            if report.applied + report.deleted + report.conflicts > 0 {
                needsFullReconcile = true
                aiQueueDirty = true
                housekeepingSignal.signal()
                jobsSignal.signal()
            }
            if report.applied + report.sent > 0 {
                ServiceLog.sync.info("Sync (\(reason.rawValue, privacy: .public)): \(report.applied, privacy: .public) übernommen, \(report.sent, privacy: .public) gesendet, \(report.conflicts, privacy: .public) Konflikte")
            }
        case let .failed(failure):
            ServiceLog.sync.error("Sync fehlgeschlagen: \(ServiceLog.redact(failure.message), privacy: .private)")
        case let .paused(pause):
            ServiceLog.sync.notice("Sync pausiert: \(pause.rawValue, privacy: .public)")
        case .deferred, .coalesced:
            break
        }
        return result
    }

    /// Lokale Änderungen bald senden (entprellt), statt bis zum nächsten Poll zu warten.
    func sendSoon() {
        guard coordinator != nil, sendSoonTask == nil else { return }
        sendSoonTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.flushSendSoon()
        }
    }

    private func flushSendSoon() async {
        sendSoonTask = nil
        await performSync(reason: .localChange)
    }

    private func syncStatusChanged(_ status: SyncStatus) {
        if status.accountState != syncStatus?.accountState {
            ServiceLog.sync.notice("iCloud-Account-Zustand: \(status.accountState.rawValue, privacy: .public)")
        }
        if Set(status.attention) != Set(syncStatus?.attention ?? []) {
            for attention in status.attention {
                ServiceLog.sync.notice("Sync braucht Aufmerksamkeit: \(ServiceLog.redact(attention.message), privacy: .private)")
            }
        }
        syncStatus = status
    }
}

/// Verbindet den `PollingScheduler` mit dem Dienst, damit jeder Poll auch Jobs und Abgleich weckt.
private struct SyncTrigger: SyncTriggering {
    weak var runtime: ServiceRuntime?

    func syncNow(reason: SyncReason) async -> SyncRunResult {
        guard let runtime else { return .paused(.notStarted) }
        return await runtime.performSync(reason: reason)
    }
}
