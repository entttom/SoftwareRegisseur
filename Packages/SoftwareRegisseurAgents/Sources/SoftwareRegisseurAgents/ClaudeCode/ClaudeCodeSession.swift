import Foundation
import SoftwareRegisseurDomain

/// One headless Claude Code job (ADR-0021; spike claude-code §2.3): the prompt goes to stdin as a
/// stream-json user message, approvals arrive as `can_use_tool` control requests and are answered
/// only from user decisions, the run ends with the `result` message.
actor ClaudeCodeSession: AgentSession {
    nonisolated let providerId = ProviderID.claudeCode
    nonisolated let jobId: JobID
    nonisolated let events: AsyncStream<AgentSessionEvent>
    /// The CLI runs in its own process group (`POSIX_SPAWN_SETPGROUP`), so PID == PGID.
    nonisolated var processIdentifier: Int32? { get async { process.processIdentifier } }
    nonisolated var processGroupIdentifier: Int32? { get async { process.processIdentifier } }

    private let continuation: AsyncStream<AgentSessionEvent>.Continuation
    private let process: InteractiveProcess
    private let plan: AgentLaunchPlan
    private let request: AgentSessionRequest
    private let now: @Sendable () -> Date

    private var pendingApprovals: [ApprovalRequestID: (input: JSONValue, request: AgentApprovalRequest)] = [:]
    private var sessionId: String?
    private var lastAssistantText: String?
    private var lastRateLimit: QuotaSignal?
    private var finished = false
    private var cancelRequested = false
    private var stderr = BoundedLineBuffer()
    private var controlCounter = 0

    private init(process: InteractiveProcess, plan: AgentLaunchPlan, request: AgentSessionRequest, now: @escaping @Sendable () -> Date) {
        self.process = process
        self.plan = plan
        self.request = request
        self.now = now
        jobId = request.jobId
        (events, continuation) = AsyncStream.makeStream(of: AgentSessionEvent.self, bufferingPolicy: .unbounded)
    }

    static func start(plan: AgentLaunchPlan, request: AgentSessionRequest, now: @escaping @Sendable () -> Date) async throws -> ClaudeCodeSession {
        let arguments = ClaudeCodeCommand.sessionArguments(
            sessionId: request.sessionUUID, model: plan.modelArgument, effort: plan.effortArgument)
        let violations = ClaudeCodeCommand.violations(in: arguments)
        guard violations.isEmpty else {
            throw AgentSessionError.startFailed("Unzulässige Argumente: \(violations.joined(separator: ", "))")
        }
        let process = try InteractiveProcess(
            executableURL: plan.toolchain.executableURL,
            arguments: arguments,
            workingDirectory: request.workingDirectory,
            environment: plan.toolchain.environment
        )
        let session = ClaudeCodeSession(process: process, plan: plan, request: request, now: now)
        await session.begin()
        return session
    }

    private func begin() async {
        emit(.status(.starting))
        // SR-SEC-03: repository settings, hooks and MCP servers are not loaded; say so when present.
        let present = ClaudeCodeCommand.repositoryConfigurationFiles.filter { relative in
            FileManager.default.fileExists(atPath: request.workingDirectory.appending(path: relative).path(percentEncoded: false))
        }
        if !present.isEmpty {
            emit(.diagnostic("Repository-Konfiguration für Claude Code wird ignoriert (nur Benutzereinstellungen, keine MCP-Server): \(present.joined(separator: ", "))"))
        }
        Task { await self.pump() }
        do {
            try await process.writeLine(ClaudeCodeInput.userMessage(request.prompt, sessionId: request.sessionUUID).serialized())
        } catch {
            await finish(.failed(.startFailed("Prompt konnte nicht übergeben werden: \(error)")))
            process.terminate()
        }
    }

    // MARK: AgentSession

    func respond(to requestId: ApprovalRequestID, with decision: AgentApprovalDecision) async throws {
        guard !finished else { throw AgentSessionError.sessionFinished }
        guard let pending = pendingApprovals[requestId] else { throw AgentSessionError.unknownApprovalRequest(requestId) }
        guard pending.request.availableDecisions.contains(where: { CodexSession.sameKind($0, decision) }) else {
            throw AgentSessionError.decisionNotSupported(decision)
        }
        let line = try ClaudeCodeInput.permissionResponse(id: requestId.rawValue, decision: decision, originalInput: pending.input)
        pendingApprovals.removeValue(forKey: requestId)
        try await process.writeLine(line.serialized())
        emit(.approvalResolved(requestId))
        if pendingApprovals.isEmpty { emit(.status(.running)) }
        if case .cancel = decision { await cancel() }
    }

    func cancel() async {
        guard !finished, !cancelRequested else { return }
        cancelRequested = true
        controlCounter += 1
        let interrupt = ClaudeCodeInput.controlRequest(id: "sr-interrupt-\(controlCounter)", subtype: "interrupt")
        if let line = try? interrupt.serialized() { try? await process.writeLine(line) }
        process.closeStandardInput()
        Task {
            try? await Task.sleep(for: .seconds(10))
            self.forceStopIfRunning()
        }
    }

    // MARK: Stream handling

    private func pump() async {
        for await output in process.output {
            switch output {
            case let .standardOutput(line):
                if let message = ClaudeStreamParser.parse(line) { await handle(message) }
            case let .standardError(line):
                stderr.append(line)
                // `--effort` with an unknown value is silently ignored by the CLI (spike 5b) → abort.
                if line.contains("Unknown --effort value") {
                    await finish(.failed(.startParameterMismatch("Claude Code hat die Effort-Stufe ignoriert: \(truncated(line))")))
                    process.terminate()
                }
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

    private func handle(_ message: ClaudeStreamMessage) async {
        guard !finished else { return }
        switch message {
        case let .systemInit(reportedSession, model, permissionMode, _):
            sessionId = reportedSession
            if let reportedSession {
                emit(.sessionIdentified(sessionId: reportedSession, threadId: nil))
                if reportedSession.lowercased() != request.sessionUUID.uuidString.lowercased() {
                    await abort("session_id \(reportedSession) statt \(request.sessionUUID.uuidString.lowercased())")
                    return
                }
            }
            if let permissionMode, !["default", "manual"].contains(permissionMode) {
                await abort("permissionMode=\(permissionMode) statt manual")
                return
            }
            let requested = plan.modelArgument?.rawValue
            let matches = requested == nil || model == requested || model == plan.resolvedModelName
                || (plan.resolvedModelName.map { model?.hasPrefix($0) ?? false } ?? false)
            emit(.effectiveConfiguration(EffectiveConfiguration(
                model: model.flatMap(ModelID.init(rawValue:)),
                effort: nil,
                source: .claudeSystemInit,
                matchesRequest: matches,
                note: String(localized: "Effort-Stufe ist im Headless-Modus nicht bestätigbar.", bundle: .module)
            )))
            emit(.status(.running))

        case let .assistant(texts, tools):
            for text in texts {
                lastAssistantText = text
                emit(.assistantText(text, isDelta: false))
            }
            for tool in tools { emit(.toolActivity(ClaudeStreamParser.toolActivity(tool))) }

        case let .toolResults(results):
            for result in results {
                emit(.toolActivity(ToolActivity(id: result.id, kind: .other("tool_result"), summary: "",
                                                phase: result.isError ? .failed : .completed)))
            }

        case let .rateLimit(info):
            let signal = ClaudeStreamParser.quotaSignal(info)
            if signal.kind == .limitReached { lastRateLimit = signal }
            emit(.quota(signal))

        case let .apiRetry(attempt, delay, status, error):
            if error == "rate_limit" || status == 429 {
                emit(.quota(QuotaSignal(providerId: .claudeCode, kind: .retrying, code: error ?? "rate_limit",
                                        message: attempt.map { "Versuch \($0)" }, retryAfter: delay.map { .milliseconds($0) })))
            } else {
                emit(.diagnostic("Claude Code wiederholt eine API-Anfrage (\(error ?? "?"), Status \(status.map(String.init) ?? "?"))."))
            }

        case let .controlRequest(id, subtype, payload):
            if subtype == "can_use_tool" {
                let approval = ClaudeStreamParser.approvalRequest(id: id, request: payload, now: now())
                pendingApprovals[approval.id] = (payload["input"] ?? .object([:]), approval)
                emit(.status(.waitingApproval))
                emit(.approvalRequested(approval))
            } else {
                // Unknown control requests are refused, never auto-approved (spec L3).
                emit(.diagnostic("Claude-Steueranfrage \(subtype) wird nicht unterstützt und abgelehnt."))
                if let line = try? ClaudeCodeInput.controlError(id: id, message: "Not supported by Software Regisseur").serialized() {
                    try? await process.writeLine(line)
                }
            }

        case let .controlCancel(id):
            let requestId = ApprovalRequestID(id)
            if pendingApprovals.removeValue(forKey: requestId) != nil { emit(.approvalResolved(requestId)) }

        case let .controlResponse(_, success, _, error):
            if !success { emit(.diagnostic("Claude-Steuerantwort mit Fehler: \(truncated(error ?? "?"))")) }

        case let .result(result):
            if let reported = result.sessionId { sessionId = reported }
            let finalText = result.text ?? lastAssistantText
            if cancelRequested {
                await finish(.cancelled, finalMessage: finalText, denials: result.permissionDenials)
            } else if !result.isError && result.subtype == "success" {
                await finish(.completed, finalMessage: finalText, denials: result.permissionDenials)
            } else if let quota = lastRateLimit ?? (result.apiErrorStatus == 429
                ? QuotaSignal(providerId: .claudeCode, kind: .limitReached, code: "429", message: result.text) : nil) {
                await finish(.quotaExhausted(quota), finalMessage: finalText, denials: result.permissionDenials)
            } else {
                let message = ([result.text].compactMap { $0 } + result.errors).joined(separator: " ")
                await finish(.failed(.agentError(code: result.subtype, message: message.isEmpty ? "Claude Code meldet einen Fehler." : message)),
                             finalMessage: finalText, denials: result.permissionDenials)
            }
            process.closeStandardInput()

        case .system, .other:
            break

        case let .invalid(line):
            emit(.diagnostic("Unlesbare Claude-Ausgabe: \(truncated(AgentDetectionSupport.redactedTail(line)))"))
        }
    }

    private func abort(_ reason: String) async {
        await finish(.failed(.startParameterMismatch(reason)))
        process.terminate()
    }

    private func forceStopIfRunning() {
        guard !finished else { return }
        process.terminate()
    }

    private func finish(_ outcome: AgentSessionResult.Outcome, finalMessage: String? = nil, denials: [String] = []) async {
        guard !finished else { return }
        finished = true
        pendingApprovals.removeAll()
        continuation.yield(.finished(AgentSessionResult(
            outcome: outcome, finalMessage: finalMessage ?? lastAssistantText, sessionId: sessionId, permissionDenials: denials)))
        continuation.finish()
        // EOF on stdin ends the CLI; make sure no process outlives the session.
        process.closeStandardInput()
        let process = process
        Task {
            try? await Task.sleep(for: .seconds(15))
            process.terminate()
        }
    }

    private func emit(_ event: AgentSessionEvent) {
        guard !finished else { return }
        continuation.yield(event)
    }
}
