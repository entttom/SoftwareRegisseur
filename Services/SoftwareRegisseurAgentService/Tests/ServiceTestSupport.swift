import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurIPC
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess
import SoftwareRegisseurSecrets
import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import SoftwareRegisseurWorkspace
import Synchronization
import Testing

/// 2026-10-30 18:00 UTC.
let t0 = Date(timeIntervalSince1970: 1_793_383_200)
let codexModel: ModelID = "gpt-5.5-codex"

// MARK: - Uhr und Prozesse

final class ManualClock: JobClock {
    private let current = Mutex(t0)
    func now() -> Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Kein echter Prozess: alle Fake-PIDs gelten als beendet (Wiederherstellung nach „Absturz“).
struct NoProcessInspector: ProcessInspecting {
    func observe(pid: Int32, startedAt: Date?) -> ProcessObservation { .notRunning }
    func observeProcesses(inside directory: URL) -> ProcessObservation { .notRunning }
    func startTime(of pid: Int32) -> Date? { nil }
    func terminateProcessGroup(_ pid: Int32) -> Bool { true }
    func observeProcessGroup(_ processGroup: Int32) -> ProcessObservation { .notRunning }
}

// MARK: - Fake-Agent

/// Steuerung einer Fake-Sitzung aus dem Skript.
final class FakeSessionControl: Sendable {
    let request: AgentSessionRequest
    private let continuation: AsyncStream<AgentSessionEvent>.Continuation
    private let state = Mutex<(finished: Bool, cancelled: Bool, waiters: [String: CheckedContinuation<AgentApprovalDecision, Never>],
                               decisions: [String: AgentApprovalDecision], cancelWaiters: [CheckedContinuation<Void, Never>])>(
        (false, false, [:], [:], []))

    init(request: AgentSessionRequest, continuation: AsyncStream<AgentSessionEvent>.Continuation) {
        self.request = request
        self.continuation = continuation
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func emit(_ event: AgentSessionEvent) {
        guard !state.withLock({ $0.finished }) else { return }
        continuation.yield(event)
    }

    func finish(_ outcome: AgentSessionResult.Outcome, message: String? = nil) {
        let already = state.withLock { s -> Bool in
            defer { s.finished = true }
            return s.finished
        }
        guard !already else { return }
        continuation.yield(.finished(AgentSessionResult(outcome: outcome, finalMessage: message, sessionId: "session-\(request.sessionUUID)")))
        continuation.finish()
    }

    func writeFile(_ name: String, _ content: String) {
        let url = request.workingDirectory.appending(path: name, directoryHint: .notDirectory)
        try? Data(content.utf8).write(to: url)
    }

    func requestApproval(_ id: String, command: String = "make deploy") async -> AgentApprovalDecision {
        emit(.approvalRequested(AgentApprovalRequest(
            id: ApprovalRequestID(id), kind: .commandExecution, summary: "Befehl ausführen", command: command,
            availableDecisions: [.allow, .deny(message: nil), .cancel], receivedAt: Date())))
        return await withCheckedContinuation { continuation in
            let immediate = state.withLock { s -> AgentApprovalDecision? in
                if s.cancelled { return .cancel }
                if let decision = s.decisions[id] { return decision }
                s.waiters[id] = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func respond(_ id: String, _ decision: AgentApprovalDecision) {
        let waiter = state.withLock { s -> CheckedContinuation<AgentApprovalDecision, Never>? in
            s.decisions[id] = decision
            return s.waiters.removeValue(forKey: id)
        }
        continuation.yield(.approvalResolved(ApprovalRequestID(id)))
        waiter?.resume(returning: decision)
    }

    func waitForCancel() async {
        await withCheckedContinuation { continuation in
            let cancelled = state.withLock { s -> Bool in
                if s.cancelled { return true }
                s.cancelWaiters.append(continuation)
                return false
            }
            if cancelled { continuation.resume() }
        }
    }

    func cancel() {
        let (waiters, cancelWaiters) = state.withLock { s in
            s.cancelled = true
            defer { s.waiters = [:]; s.cancelWaiters = [] }
            return (Array(s.waiters.values), s.cancelWaiters)
        }
        waiters.forEach { $0.resume(returning: .cancel) }
        cancelWaiters.forEach { $0.resume() }
    }
}

typealias FakeScript = @Sendable (FakeSessionControl) async -> Void

final class FakeSession: AgentSession {
    let providerId: ProviderID
    let jobId: JobID
    let events: AsyncStream<AgentSessionEvent>
    let control: FakeSessionControl

    init(providerId: ProviderID, request: AgentSessionRequest, script: @escaping FakeScript) {
        self.providerId = providerId
        jobId = request.jobId
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        events = stream
        control = FakeSessionControl(request: request, continuation: continuation)
        let control = control
        Task {
            await script(control)
            if control.isCancelled { control.finish(.cancelled) }
        }
    }

    var processIdentifier: Int32? { get async { 4242 } }

    func respond(to request: ApprovalRequestID, with decision: AgentApprovalDecision) async throws {
        control.respond(request.rawValue, decision)
    }

    func cancel() async {
        control.cancel()
        control.finish(.cancelled)
    }
}

enum Scripts {
    static func writeAndFinish(_ file: String = "feature.txt") -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            control.emit(.status(.running))
            control.writeFile(file, "Agentenergebnis\n")
            control.emit(.assistantText("Fertig: \(file) angelegt.", isDelta: false))
            control.finish(.completed, message: "Fertig: \(file) angelegt.")
        }
    }

    static func approval(_ id: String, command: String = "make deploy") -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            let decision = await control.requestApproval(id, command: command)
            guard decision == .allow || decision == .allowForSession else {
                control.finish(.cancelled)
                return
            }
            control.writeFile("approved.txt", "nach Freigabe\n")
            control.finish(.completed, message: "Nach Freigabe fertig.")
        }
    }

    static func hang() -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            control.writeFile("halb.txt", "halb fertig\n")
            await control.waitForCancel()
        }
    }
}

/// Fake-Codex mit veränderbarer Fähigkeit und Skript-Warteschlange. Startet nie einen echten Prozess.
final class FakeAgentProvider: AgentProvider {
    let providerId: ProviderID = .codex
    let displayName = "Fake Codex"
    let isFullyImplemented = true
    private let state: Mutex<(capability: AgentCapability, scripts: [FakeScript], sessions: [FakeSession], detections: Int)>

    init(hostId: HostID) {
        let capability = AgentCapability(
            providerId: .codex, displayName: "Fake Codex", hostId: hostId, executablePath: "/opt/homebrew/bin/codex",
            version: "0.170.0", supportsApprovals: true, supportsModelSelection: true, supportsEffortSelection: true,
            modelCatalog: [AgentModelCapability(providerId: .codex, modelId: codexModel, displayName: "GPT Codex",
                                                supportedEffortIds: [.low, .medium, .high], source: .verifiedSpike, lastValidatedAt: t0)],
            defaultModelId: codexModel, capabilitySource: .verifiedSpike, capabilityRevision: 1, lastChecked: t0)
        state = Mutex((capability, [], [], 0))
    }

    var capability: AgentCapability { state.withLock { $0.capability } }
    var sessions: [FakeSession] { state.withLock { $0.sessions } }
    var startCount: Int { state.withLock { $0.sessions.count } }
    var detectionCount: Int { state.withLock { $0.detections } }

    func enqueue(_ script: @escaping FakeScript) { state.withLock { $0.scripts.append(script) } }

    func detect(previous: AgentCapability?) async -> AgentDetectionReport {
        state.withLock { $0.detections += 1 }
        return AgentDetectionReport(capability: capability, diagnostics: [], toolchain: nil)
    }

    func prepareLaunch(snapshot: ConfigurationSnapshot, previous: AgentCapability?) async -> LaunchPreparation {
        let capability = self.capability
        switch LaunchValidator.validate(snapshot: snapshot, capability: capability) {
        case .ok:
            return .ready(AgentLaunchPlan(
                providerId: providerId, snapshot: snapshot, capability: capability, modelArgument: snapshot.resolvedModel.modelID,
                effortArgument: snapshot.resolvedEffort.isAuto ? nil : snapshot.resolvedEffort,
                toolchain: AgentToolchain(executableURL: URL(filePath: "/usr/bin/true"), environment: .empty, version: nil)))
        case let .needsConfiguration(issues):
            return .needsConfiguration(issues, capability: capability)
        case let .notRunnable(reason):
            return .notRunnable(reason: reason, capability: capability)
        }
    }

    func startSession(plan: AgentLaunchPlan, request: AgentSessionRequest) async throws -> any AgentSession {
        let script = state.withLock { s -> FakeScript in s.scripts.isEmpty ? Scripts.writeAndFinish() : s.scripts.removeFirst() }
        let session = FakeSession(providerId: providerId, request: request, script: script)
        state.withLock { $0.sessions.append(session) }
        return session
    }
}

/// Wird beim Aufbau des Dienstes mit dem Fake-Anbieter für dessen Host-ID gefüllt.
final class ProviderBox: Sendable {
    private let value = Mutex<FakeAgentProvider?>(nil)
    private let overrides = Mutex<[[ProviderID: URL]]>([])
    var provider: FakeAgentProvider? { value.withLock { $0 } }
    /// Programmpfad-Overrides jedes Aufbaus der Anbieter (Start und jede Neukonfiguration).
    var recordedOverrides: [[ProviderID: URL]] { overrides.withLock { $0 } }

    func recordOverrides(_ value: [ProviderID: URL]) { overrides.withLock { $0.append(value) } }

    func make(hostId: HostID) -> FakeAgentProvider {
        value.withLock { current in
            if let current, current.capability.hostId == hostId { return current }
            let created = FakeAgentProvider(hostId: hostId)
            current = created
            return created
        }
    }
}

// MARK: - Fake-KI

/// Antwortet mit einem festen strukturierten Entwurf und merkt sich die Anfrage.
final class FakeTextProvider: TextAIProvider {
    let providerID: SoftwareRegisseurAI.AIProviderID = .openai
    private let requests = Mutex<[TextGenerationRequest]>([])

    var received: [TextGenerationRequest] { requests.withLock { $0 } }

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }

    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        requests.withLock { $0.append(request) }
        let json = #"{"drafts":[{"type":"feature","title":"Export als CSV","goal":"Daten exportieren","context":"","acceptanceCriteria":["CSV-Datei wird erzeugt"],"technicalNotes":[],"testCases":[],"priority":"unspecified","dependencies":[],"openQuestions":[]}]}"#
        return TextGenerationResult(provider: .openai, model: request.model, text: json, finishReason: .completed,
                                    usage: AIUsage(inputTokens: 100, outputTokens: 50))
    }
}

// MARK: - Testumgebung

/// Temporäres Verzeichnis mit echtem Git-Repository unter einem Stammordner, Datei-Datenbank,
/// Fake-Agent, Fake-KI und optional Fake-CloudKit (kein echtes CloudKit, keine echten Agenten).
final class ServiceTestHarness: @unchecked Sendable {
    let root: URL
    let developer: URL
    let repo: URL
    let storage: ServiceStorageLayout
    let git: GitClient
    let clock = ManualClock()
    let providers = ProviderBox()
    let textProvider = FakeTextProvider()
    let keychain: InMemoryKeychainStore
    let server: FakeCloudDatabase?
    let connection = FakeDeviceConnection(userRecordName: "_user-A")
    let database: AppDatabase

    init(cloud: Bool = false, apiKey: Bool = true) async throws {
        let raw = FileManager.default.temporaryDirectory.appending(path: "SRServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = try PathGuard.canonicalize(raw)
        developer = root.appending(path: "home/Developer", directoryHint: .isDirectory)
        repo = developer.appending(path: "app", directoryHint: .isDirectory)
        storage = ServiceStorageLayout(rootURL: root.appending(path: "container/SoftwareRegisseur", directoryHint: .isDirectory))
        let located = try GitClient.locate()
        git = GitClient(
            executableURL: located.executableURL,
            environment: located.environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]),
            configOverrides: [
                ("user.name", "Software Regisseur Tests"), ("user.email", "tests@software-regisseur.invalid"),
                ("init.defaultBranch", "main"), ("commit.gpgsign", "false"),
            ])
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "--initial-branch=main"], in: repo)
        try Data("# App\n".utf8).write(to: repo.appending(path: "README.md"))
        try Data("API_KEY=sk-geheim-1234567890abcdef\n".utf8).write(to: repo.appending(path: ".env"))
        try Data(".env\n".utf8).write(to: repo.appending(path: ".gitignore"))
        try await git.run(["add", "-A"], in: repo)
        try await git.run(["commit", "--quiet", "-m", "Initial commit"], in: repo)
        database = try AppDatabase.openWriter(at: storage.databaseURL)
        server = cloud ? FakeCloudDatabase() : nil
        keychain = InMemoryKeychainStore(initial: apiKey ? ["openai.text": SecretValue("sk-test-key")] : [:])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var provider: FakeAgentProvider { providers.provider! }

    /// Kanonischer Stammordner-Pfad ohne abschließenden Schrägstrich (so speichert ihn der Dienst).
    var developerPath: String { developer.path(percentEncoded: false).trimmingTrailingSlash }

    func dependencies() -> ServiceDependencies {
        let providers = providers
        let textProvider = textProvider
        let cloudSync: CloudSyncSetup = if let server {
            .available(FakeSyncEngine.factory(server: server, connection: connection))
        } else {
            .unavailable(reason: "Testlauf ohne CloudKit")
        }
        return ServiceDependencies(
            database: database, storage: storage, version: ServiceVersion(shortVersion: "1.0.0", build: "7"), hostName: "Test-Mac",
            git: git,
            makeProviders: { hostId, _, overrides in
                providers.recordOverrides(overrides)
                return AgentProviderRegistry(providers: [providers.make(hostId: hostId)])
            },
            cloudSync: cloudSync, clock: clock, processInspector: NoProcessInspector(), keychain: keychain,
            makeTextProvider: { provider, keychain in
                // Schlüssel wie in Produktion aus dem Schlüsselbund; nur der HTTP-Client ist gefälscht.
                _ = try APIKeyLoader.load(from: keychain, account: "\(provider.rawValue).text")
                return textProvider
            },
            makeGitHub: { GitHubIssueService(environment: $0, executableURL: URL(filePath: "/nonexistent/gh")) },
            sleepAssertion: NoSleepAssertion(),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            concurrencyLimits: ConcurrencyLimits(global: 4, perProject: 4))
    }

    func makeRuntime() async throws -> ServiceRuntime {
        try await ServiceRuntime.make(dependencies())
    }

    /// Stammordner bestätigen, scannen, Agenten erkennen – wie bei der Ersteinrichtung in der UI.
    func setUp(_ runtime: ServiceRuntime) async throws -> Project {
        try expectResult(await runtime.handle(.addRootFolder(path: developer.path(percentEncoded: false))))
        try expectResult(await runtime.handle(.refreshScanner))
        try expectResult(await runtime.handle(.redetectAgents))
        let projects = try await database.projects.list()
        return try #require(projects.first { $0.name == "app" })
    }

    func addWorkItem(_ project: Project, title: String = "CSV-Export") async throws -> WorkItem {
        let item = WorkItem(projectId: project.id, type: .feature, title: title, originalNote: "Notiz: \(title)",
                            structuredBody: "## Ziel\n\(title)", status: .open, createdAt: clock.now())
        try await database.workItems.insert(item, actor: .user(DeviceID()), at: clock.now())
        return item
    }

    func requestFiles(in folder: String) -> [String] {
        let url = repo.appending(path: folder, directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".md") }
    }
}

/// Erwartet ein Befehlsergebnis (kein Fehler) und gibt es zurück.
@discardableResult
func expectResult(_ response: ServiceResponse, sourceLocation: SourceLocation = #_sourceLocation) throws -> ServiceResponse {
    if case let .failure(message) = response {
        Issue.record("Befehl fehlgeschlagen: \(message)", sourceLocation: sourceLocation)
        throw TestFailure(message)
    }
    if case let .notAvailable(feature) = response {
        Issue.record("Funktion nicht verfügbar: \(feature)", sourceLocation: sourceLocation)
        throw TestFailure("\(feature)")
    }
    return response
}

struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Pollt, bis `condition` erfüllt ist (Sitzungsereignisse laufen asynchron im Orchestrator).
func eventually(timeout: Duration = .seconds(15), sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Bedingung nicht innerhalb von \(timeout) erfüllt", sourceLocation: sourceLocation)
    throw TestFailure("timeout")
}

/// Simuliertes iPhone: eigene In-Memory-Datenbank, mobiler Sync über denselben Fake-Server.
struct SimulatedPhone {
    let deviceId = DeviceID()
    let database: AppDatabase
    let coordinator: SyncCoordinator

    init(server: FakeCloudDatabase, clock: ManualClock) async throws {
        database = try AppDatabase.inMemory()
        let deviceId = self.deviceId
        coordinator = SyncCoordinator(
            store: database.sync,
            configuration: SyncConfiguration(
                deviceId: deviceId, role: .mobile,
                assetDirectory: FileManager.default.temporaryDirectory.appending(path: "SRPhone-\(UUID().uuidString)")),
            now: { clock.now() },
            engineFactory: FakeSyncEngine.factory(server: server, connection: FakeDeviceConnection(userRecordName: "_user-A")))
        try await coordinator.start()
    }

    var actor: EventActor { .user(deviceId) }

    @discardableResult
    func sync() async throws -> SyncRunReport {
        let result = await coordinator.syncNow(reason: .manual)
        guard let report = result.report else { throw TestFailure("iPhone-Sync: \(result)") }
        return report
    }
}
