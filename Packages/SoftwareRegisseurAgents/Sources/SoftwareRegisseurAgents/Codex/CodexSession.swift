import Foundation
import SoftwareRegisseurDomain

/// One Codex job: app-server process → `initialize` → `thread/start` (explicit model, effort, cwd,
/// sandbox, approval policy) → `turn/start` → streamed notifications until `turn/completed`
/// (ADR-0021; spike codex „Jobstart“).
actor CodexSession: AgentSession {
    nonisolated let providerId = ProviderID.codex
    nonisolated let jobId: JobID
    nonisolated let events: AsyncStream<AgentSessionEvent>
    /// `codex app-server` runs in its own process group, so PID == PGID.
    nonisolated var processIdentifier: Int32? { get async { client.processIdentifier } }
    nonisolated var processGroupIdentifier: Int32? { get async { client.processIdentifier } }

    private let continuation: AsyncStream<AgentSessionEvent>.Continuation
    private let client: CodexAppServerClient
    private let plan: AgentLaunchPlan
    private let request: AgentSessionRequest
    private let clientInfo: CodexProtocol.ClientInfo
    private let requestTimeout: Duration
    private let now: @Sendable () -> Date

    private var mapper: CodexEventMapper
    private var pendingApprovals: [ApprovalRequestID: (id: JSONRPCID, method: String, params: JSONValue?, request: AgentApprovalRequest)] = [:]
    private var threadId: String?
    private var turnId: String?
    private var sessionId: String?
    private var finished = false
    private var cancelRequested = false
    private var stderr = BoundedLineBuffer()

    private init(client: CodexAppServerClient, plan: AgentLaunchPlan, request: AgentSessionRequest,
                 clientInfo: CodexProtocol.ClientInfo, requestTimeout: Duration, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.plan = plan
        self.request = request
        self.clientInfo = clientInfo
        self.requestTimeout = requestTimeout
        self.now = now
        jobId = request.jobId
        mapper = CodexEventMapper(requestedModel: plan.modelArgument?.rawValue, requestedEffort: plan.effortArgument?.rawValue)
        (events, continuation) = AsyncStream.makeStream(of: AgentSessionEvent.self, bufferingPolicy: .unbounded)
    }

    static func start(plan: AgentLaunchPlan, request: AgentSessionRequest, clientInfo: CodexProtocol.ClientInfo,
                      requestTimeout: Duration, now: @escaping @Sendable () -> Date) throws -> CodexSession {
        let client = try CodexAppServerClient.launch(toolchain: plan.toolchain, workingDirectory: request.workingDirectory)
        let session = CodexSession(client: client, plan: plan, request: request, clientInfo: clientInfo,
                                   requestTimeout: requestTimeout, now: now)
        Task { await session.pumpEvents() }
        Task { await session.runHandshakeAndTurn() }
        return session
    }

    // MARK: AgentSession

    func respond(to requestId: ApprovalRequestID, with decision: AgentApprovalDecision) async throws {
        guard !finished else { throw AgentSessionError.sessionFinished }
        guard let pending = pendingApprovals[requestId] else { throw AgentSessionError.unknownApprovalRequest(requestId) }
        guard pending.request.availableDecisions.contains(where: { Self.sameKind($0, decision) }) else {
            throw AgentSessionError.decisionNotSupported(decision)
        }
        let result = try CodexEventMapper.approvalResponse(method: pending.method, params: pending.params, decision: decision)
        pendingApprovals.removeValue(forKey: requestId)
        try await client.connection.respond(to: pending.id, result: result)
        if pendingApprovals.isEmpty { emit(.status(.running)) }
    }

    func cancel() async {
        guard !finished, !cancelRequested else { return }
        cancelRequested = true
        // Give Codex time to report `turn/completed` (interrupted), then stop the process group.
        Task {
            try? await Task.sleep(for: .seconds(15))
            self.forceStopIfRunning()
        }
        if let threadId, let turnId {
            _ = try? await client.connection.request(
                CodexProtocol.Method.turnInterrupt,
                params: ["threadId": .string(threadId), "turnId": .string(turnId)],
                timeout: .seconds(10)
            )
        }
        // Otherwise the handshake is still running: `runHandshakeAndTurn` sees `cancelRequested` after
        // its in-flight request and either finishes as cancelled or interrupts the new turn.
    }

    // MARK: Driving

    private func runHandshakeAndTurn() async {
        let model = plan.modelArgument?.rawValue
        let effort = plan.effortArgument?.rawValue
        let cwd = canonicalPath(request.workingDirectory)
        emit(.status(.starting))
        do {
            try await client.initialize(clientInfo, timeout: requestTimeout)
            let startResult = try await client.connection.request(
                CodexProtocol.Method.threadStart,
                params: CodexProtocol.threadStartParams(model: model, effort: effort, cwd: cwd),
                timeout: requestTimeout
            )
            let start = try CodexProtocol.decodeThreadStart(startResult)
            threadId = start.threadId
            mapper.threadId = start.threadId
            sessionId = start.sessionId ?? start.threadId
            emit(.sessionIdentified(sessionId: sessionId ?? start.threadId, threadId: start.threadId))

            let problems = CodexProtocol.verify(start, model: model, effort: effort, cwd: cwd)
            guard problems.isEmpty else {
                await finish(.failed(.startParameterMismatch(problems.joined(separator: "; "))))
                return
            }
            emit(.effectiveConfiguration(EffectiveConfiguration(
                model: start.model.flatMap(ModelID.init(rawValue:)),
                effort: start.reasoningEffort.flatMap(EffortLevel.init(rawValue:)),
                source: .codexThreadStartResponse,
                matchesRequest: true,
                note: String(localized: "Von Codex bestätigte Konfiguration (keine Pro-Turn-Telemetrie).", bundle: .module)
            )))
            guard !cancelRequested else {
                await finish(.cancelled)
                return
            }
            let turnResult = try await client.connection.request(
                CodexProtocol.Method.turnStart,
                params: CodexProtocol.turnStartParams(threadId: start.threadId, prompt: request.prompt, model: model,
                                                      effort: effort, clientMessageId: request.jobId.uuidString),
                timeout: requestTimeout
            )
            turnId = turnResult["turn"]?["id"]?.stringValue
            if cancelRequested, let turnId {
                _ = try? await client.connection.request(
                    CodexProtocol.Method.turnInterrupt,
                    params: ["threadId": .string(start.threadId), "turnId": .string(turnId)], timeout: .seconds(10))
            }
        } catch let error as JSONRPCError {
            if case let .remote(_, object) = error, let code = CodexProtocol.errorCode(object.data?["codexErrorInfo"]),
               CodexProtocol.quotaErrorCodes.contains(code) {
                await finishWithQuota(QuotaSignal(providerId: .codex, kind: .limitReached, code: code, message: object.message))
            } else if case .connectionClosed = error {
                // The exit handler reports the crash with the stderr tail.
            } else {
                await finish(.failed(.startFailed(error.description)))
            }
        } catch {
            await finish(.failed(.startFailed(String(describing: error))))
        }
    }

    private func pumpEvents() async {
        for await event in client.events {
            switch event {
            case let .incoming(.notification(method, params)):
                await handleNotification(method: method, params: params)
            case let .incoming(.request(id, method, params)):
                await handleServerRequest(id: id, method: method, params: params)
            case let .incoming(.invalid(line)):
                emit(.diagnostic("Unlesbare Codex-Ausgabe: \(truncated(AgentDetectionSupport.redactedTail(line)))"))
            case let .standardError(line):
                stderr.append(line)
            case let .exited(status):
                guard !finished else { continue }
                if cancelRequested {
                    await finish(.cancelled)
                } else {
                    await finish(.failed(.processEnded(exitStatus: status.exitStatus, signal: status.signal, stderrTail: stderr.text)))
                }
            }
        }
    }

    private func handleNotification(method: String, params: JSONValue?) async {
        guard !finished else { return }
        let output = mapper.map(method: method, params: params)
        for event in output.events { emit(event) }
        switch output.completion {
        case nil:
            break
        case .completed?:
            await finish(.completed)
        case .interrupted?:
            await finish(cancelRequested ? .cancelled : .failed(.agentError(code: "interrupted", message: "Turn wurde unterbrochen")))
        case let .failed(code, message)?:
            if let signal = mapper.lastQuotaSignal {
                await finishWithQuota(signal)
            } else {
                await finish(.failed(.agentError(code: code, message: message)))
            }
        }
    }

    private func handleServerRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        guard !finished else { return }
        if let approval = mapper.approvalRequest(id: id, method: method, params: params, now: now()) {
            pendingApprovals[approval.id] = (id, method, params, approval)
            emit(.status(.waitingApproval))
            emit(.approvalRequested(approval))
        } else {
            // Never auto-approve (spec L3): unsupported requests are refused explicitly.
            emit(.diagnostic("Codex-Anfrage \(method) wird von Software Regisseur nicht unterstützt und abgelehnt."))
            try? await client.connection.respondError(to: id, code: -32601, message: "Not supported by Software Regisseur")
        }
    }

    /// Enriches a quota signal with `account/rateLimits/read` (non-billable) before finishing (K2).
    private func finishWithQuota(_ signal: QuotaSignal) async {
        guard !finished else { return }
        var enriched = signal
        if let limits = try? await client.connection.request(CodexProtocol.Method.rateLimitsRead, params: nil, timeout: .seconds(10)) {
            enriched = CodexProtocol.quotaSignal(fromRateLimits: limits, kind: .limitReached, code: signal.code, message: signal.message)
            emit(.quota(enriched))
        }
        await finish(.quotaExhausted(enriched))
    }

    private func forceStopIfRunning() {
        guard !finished else { return }
        client.terminate()
    }

    private func finish(_ outcome: AgentSessionResult.Outcome) async {
        guard !finished else { return }
        finished = true
        pendingApprovals.removeAll()
        emit(.finished(AgentSessionResult(outcome: outcome, finalMessage: mapper.lastAgentMessage, sessionId: sessionId)))
        continuation.finish()
        let client = client
        Task { await client.shutdown() }
    }

    private func emit(_ event: AgentSessionEvent) {
        guard !finished || { if case .finished = event { return true }; return false }() else { return }
        continuation.yield(event)
    }

    static func sameKind(_ lhs: AgentApprovalDecision, _ rhs: AgentApprovalDecision) -> Bool {
        switch (lhs, rhs) {
        case (.allow, .allow), (.allowForSession, .allowForSession), (.deny, .deny), (.cancel, .cancel): true
        default: false
        }
    }
}
