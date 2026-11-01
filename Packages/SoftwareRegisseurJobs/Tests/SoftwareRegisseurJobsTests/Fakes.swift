import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurJobs
import SoftwareRegisseurGit
import SoftwareRegisseurProcess
import Synchronization
@testable import SoftwareRegisseurAgents

// MARK: - Clock

final class ManualClock: JobClock {
    private let current: Mutex<Date>

    init(_ date: Date) { current = Mutex(date) }

    func now() -> Date { current.withLock { $0 } }
    func set(_ date: Date) { current.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

// MARK: - Process inspector

final class FakeProcessInspector: ProcessInspecting {
    private let state = Mutex<(alive: Set<Int32>, busyDirectories: Set<String>, terminated: [Int32])>(([], [], []))
    /// Process-group states; groups without an entry are `unknown` (cwd-scan fallback).
    private let groups = Mutex<[Int32: ProcessObservation]>([:])

    func setGroup(_ group: Int32, _ observation: ProcessObservation?) {
        groups.withLock { $0[group] = observation }
    }

    func observeProcessGroup(_ processGroup: Int32) -> ProcessObservation {
        groups.withLock { $0[processGroup] ?? .unknown }
    }

    func setAlive(_ pid: Int32, _ alive: Bool) {
        state.withLock { if alive { $0.alive.insert(pid) } else { $0.alive.remove(pid) } }
    }

    func setBusy(_ directory: String, _ busy: Bool) {
        state.withLock { if busy { $0.busyDirectories.insert(directory) } else { $0.busyDirectories.remove(directory) } }
    }

    var terminated: [Int32] { state.withLock { $0.terminated } }

    func observe(pid: Int32, startedAt: Date?) -> ProcessObservation {
        state.withLock { $0.alive.contains(pid) ? .running : .notRunning }
    }

    func observeProcesses(inside directory: URL) -> ProcessObservation {
        let path = directory.path(percentEncoded: false)
        return state.withLock { s in s.busyDirectories.contains { path.hasPrefix($0) || $0.hasPrefix(path) } ? .running : .notRunning }
    }

    func startTime(of pid: Int32) -> Date? { nil }

    func terminateProcessGroup(_ pid: Int32) -> Bool {
        state.withLock {
            $0.terminated.append(pid)
            $0.alive.remove(pid)
        }
        return true
    }
}

// MARK: - Session

/// Control handle passed to a scripted fake session.
final class FakeSessionControl: Sendable {
    let request: AgentSessionRequest
    private let continuation: AsyncStream<AgentSessionEvent>.Continuation
    private let state = Mutex<(finished: Bool, cancelled: Bool, decisions: [String: AgentApprovalDecision],
                               waiters: [String: CheckedContinuation<AgentApprovalDecision, Never>],
                               cancelWaiters: [CheckedContinuation<Void, Never>])>((false, false, [:], [:], []))

    init(request: AgentSessionRequest, continuation: AsyncStream<AgentSessionEvent>.Continuation) {
        self.request = request
        self.continuation = continuation
    }

    var workingDirectory: URL { request.workingDirectory }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var decisions: [String: AgentApprovalDecision] { state.withLock { $0.decisions } }

    func emit(_ event: AgentSessionEvent) {
        guard !state.withLock({ $0.finished }) else { return }
        continuation.yield(event)
    }

    func finish(_ outcome: AgentSessionResult.Outcome, message: String? = nil) {
        let alreadyFinished = state.withLock { s -> Bool in
            defer { s.finished = true }
            return s.finished
        }
        guard !alreadyFinished else { return }
        continuation.yield(.finished(AgentSessionResult(outcome: outcome, finalMessage: message, sessionId: "session-\(request.sessionUUID)")))
        continuation.finish()
    }

    func requestApproval(_ id: String, summary: String = "Befehl ausführen", now: Date = Date()) async -> AgentApprovalDecision {
        emit(.approvalRequested(AgentApprovalRequest(
            id: ApprovalRequestID(id), kind: .commandExecution, summary: summary, command: "make deploy",
            availableDecisions: [.allow, .deny(message: nil), .cancel], receivedAt: now)))
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

    /// Blocks until `cancel()` (used to simulate a long or hanging run).
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

    func respond(_ id: String, _ decision: AgentApprovalDecision) throws {
        let waiter = try state.withLock { s -> CheckedContinuation<AgentApprovalDecision, Never>? in
            guard !s.finished else { throw AgentSessionError.sessionFinished }
            s.decisions[id] = decision
            return s.waiters.removeValue(forKey: id)
        }
        continuation.yield(.approvalResolved(ApprovalRequestID(id)))
        waiter?.resume(returning: decision)
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

final class FakeSession: AgentSession, AgentProcessIdentifying {
    let providerId: ProviderID
    let jobId: JobID
    let events: AsyncStream<AgentSessionEvent>
    let control: FakeSessionControl
    let pid: Int32?

    init(providerId: ProviderID, request: AgentSessionRequest, pid: Int32?, script: @escaping FakeScript) {
        self.providerId = providerId
        jobId = request.jobId
        self.pid = pid
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        events = stream
        control = FakeSessionControl(request: request, continuation: continuation)
        let control = control
        Task {
            await script(control)
            if control.isCancelled { control.finish(.cancelled) }
        }
    }

    var processIdentifier: Int32? { get async { pid } }

    func respond(to request: ApprovalRequestID, with decision: AgentApprovalDecision) async throws {
        try control.respond(request.rawValue, decision)
    }

    func cancel() async {
        control.cancel()
        control.finish(.cancelled)
    }
}

// MARK: - Provider

/// In-test `AgentProvider` with a mutable capability and a queue of scripted sessions.
final class FakeProvider: AgentProvider {
    let providerId: ProviderID
    let displayName: String
    let isFullyImplemented = true
    private let state: Mutex<(capability: AgentCapability, scripts: [FakeScript], sessions: [FakeSession],
                              requests: [AgentSessionRequest], plans: [AgentLaunchPlan], nextPid: Int32, failNextStart: Bool)>
    let defaultScript: FakeScript

    init(providerId: ProviderID, capability: AgentCapability, defaultScript: @escaping FakeScript = Scripts.writeAndCommit()) {
        self.providerId = providerId
        displayName = providerId.rawValue
        self.defaultScript = defaultScript
        state = Mutex((capability, [], [], [], [], 4000, false))
    }

    var capability: AgentCapability { state.withLock { $0.capability } }
    var startCount: Int { state.withLock { $0.sessions.count } }
    var sessions: [FakeSession] { state.withLock { $0.sessions } }
    var requests: [AgentSessionRequest] { state.withLock { $0.requests } }
    var plans: [AgentLaunchPlan] { state.withLock { $0.plans } }

    func setCapability(_ capability: AgentCapability) { state.withLock { $0.capability = capability } }
    func enqueue(_ script: @escaping FakeScript) { state.withLock { $0.scripts.append(script) } }
    func failNextStart() { state.withLock { $0.failNextStart = true } }

    func detect(previous: AgentCapability?) async -> AgentDetectionReport {
        AgentDetectionReport(capability: capability, diagnostics: [], toolchain: nil)
    }

    func prepareLaunch(snapshot: ConfigurationSnapshot, previous: AgentCapability?) async -> LaunchPreparation {
        let capability = self.capability
        switch LaunchValidator.validate(snapshot: snapshot, capability: capability) {
        case .ok:
            return .ready(AgentLaunchPlan(
                providerId: providerId, snapshot: snapshot, capability: capability,
                modelArgument: snapshot.resolvedModel.modelID,
                effortArgument: snapshot.resolvedEffort.isAuto ? nil : snapshot.resolvedEffort,
                toolchain: AgentToolchain(executableURL: URL(filePath: "/usr/bin/true"), environment: .empty, version: nil)))
        case let .needsConfiguration(issues):
            return .needsConfiguration(issues, capability: capability)
        case let .notRunnable(reason):
            return .notRunnable(reason: reason, capability: capability)
        }
    }

    func startSession(plan: AgentLaunchPlan, request: AgentSessionRequest) async throws -> any AgentSession {
        let fail = state.withLock { s in
            defer { s.failNextStart = false }
            return s.failNextStart
        }
        if fail { throw AgentSessionError.startFailed("Prozess nicht startbar") }
        let (script, pid) = state.withLock { s -> (FakeScript, Int32) in
            s.nextPid += 1
            s.requests.append(request)
            s.plans.append(plan)
            return (s.scripts.isEmpty ? defaultScript : s.scripts.removeFirst(), s.nextPid)
        }
        let session = FakeSession(providerId: providerId, request: request, pid: pid, script: script)
        state.withLock { $0.sessions.append(session) }
        return session
    }
}

// MARK: - Scripts

enum Scripts {
    static func writeFile(_ control: FakeSessionControl, _ name: String, _ content: String) {
        let url = control.workingDirectory.appending(path: name, directoryHint: .notDirectory)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url)
    }

    static func gitCommit(_ control: FakeSessionControl, git: GitClient, message: String) async {
        _ = try? await git.run(["add", "-A"], in: control.workingDirectory)
        _ = try? await git.run(["commit", "--quiet", "-m", message], in: control.workingDirectory)
    }

    /// Writes a file, reports a passing test run and completes; optionally commits itself.
    static func writeAndCommit(
        file: String = "feature.txt", content: String = "Agentenergebnis\n", commitWith git: GitClient? = nil,
        model: ModelID? = nil, effort: EffortLevel? = nil
    ) -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: "thread-1"))
            control.emit(.status(.running))
            if model != nil || effort != nil {
                control.emit(.effectiveConfiguration(EffectiveConfiguration(
                    model: model, effort: effort, source: .codexThreadStartResponse, matchesRequest: true)))
            }
            writeFile(control, file, content)
            if let git { await gitCommit(control, git: git, message: "Agent: \(file)") }
            control.emit(.toolActivity(ToolActivity(id: "t1", kind: .command, summary: "swift test", phase: .started)))
            control.emit(.toolActivity(ToolActivity(id: "t1", kind: .command, summary: "swift test", phase: .completed)))
            control.emit(.assistantText("Fertig: \(file) angelegt, Tests grün.", isDelta: false))
            control.finish(.completed, message: "Fertig: \(file) angelegt, Tests grün.")
        }
    }

    /// Runs until cancelled (simulates a long agent run or a service crash mid-run).
    static func hang(writing file: String? = nil) -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            if let file { writeFile(control, file, "halb fertig\n") }
            await control.waitForCancel()
        }
    }

    static func quota(provider: ProviderID = .codex, resetsAt: Date?, retryAfter: Duration? = nil) -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            control.emit(.quota(QuotaSignal(providerId: provider,
                                            kind: .limitReached, code: "usageLimitExceeded",
                                            message: "Limit erreicht", resetsAt: resetsAt, retryAfter: retryAfter)))
            await control.waitForCancel()
        }
    }

    static func approval(_ id: String, then file: String = "approved.txt") -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            let decision = await control.requestApproval(id)
            guard decision == .allow || decision == .allowForSession else {
                control.finish(.cancelled)
                return
            }
            writeFile(control, file, "nach Freigabe\n")
            control.finish(.completed, message: "Nach Freigabe fertig.")
        }
    }
}
