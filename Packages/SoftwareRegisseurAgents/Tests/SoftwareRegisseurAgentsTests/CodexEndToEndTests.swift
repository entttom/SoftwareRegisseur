import Foundation
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurAgents

/// End-to-end tests against a fake `codex` executable that speaks the app-server protocol over stdio.
@Suite("Codex adapter end-to-end (fake app-server)", .timeLimit(.minutes(1)))
struct CodexEndToEndTests {
    struct Setup {
        let temp: TempDirectory
        let bin: URL
        let worktree: URL
        let provider: CodexAgentProvider
    }

    static func setup(_ scenario: String) throws -> Setup {
        let temp = try TempDirectory()
        let bin = try temp.directory("bin")
        let worktree = try temp.directory("worktree")
        try temp.writeExecutable("codex", in: bin, content: FakeAgents.codex(scenario: scenario, directory: temp.url))
        return Setup(temp: temp, bin: bin, worktree: worktree,
                     provider: Fixtures.codexProvider(bin: bin, workDir: try temp.directory("detect")))
    }

    static func start(_ setup: Setup, snapshot: ConfigurationSnapshot) async throws -> any AgentSession {
        let preparation = await setup.provider.prepareLaunch(snapshot: snapshot, previous: nil)
        let plan = try #require(preparation.plan, "launch not ready: \(preparation)")
        return try await setup.provider.startSession(
            plan: plan,
            request: AgentSessionRequest(jobId: JobID(), workingDirectory: setup.worktree, prompt: "Bitte Tests reparieren."))
    }

    @Test func detectionReportsRuntimeCatalogAcrossPages() async throws {
        let setup = try Self.setup("ok")
        let report = await setup.provider.detect(previous: nil)
        let capability = report.capability
        #expect(capability.installed)
        #expect(capability.authenticated)
        #expect(capability.runnable, "\(report.diagnostics)")
        #expect(capability.version == "0.164.0")
        #expect(capability.capabilitySource == .appServer)
        #expect(capability.modelCatalog.map(\.modelId) == ["gpt-6.1-sol", "gpt-6-luna"])
        #expect(capability.defaultModelId == "gpt-6.1-sol")
        #expect(capability.model("gpt-6-luna")?.supportedEffortIds == [.low, .medium, .high, .xhigh, .max])
        #expect(capability.supportsEffortSelection)
        #expect(capability.supportsRemote == false)
        #expect(capability.capabilityRevision == 1)

        let again = await setup.provider.detect(previous: capability)
        #expect(again.capability.capabilityRevision == 1)

        let received = setup.temp.loggedMessages()
        #expect(received.contains { $0["method"] == "initialize" })
        #expect(received.contains { $0["method"] == "initialized" && $0["id"] == nil })
        #expect(received.filter { $0["method"] == "model/list" }.count == 4) // 2 pages × 2 detections
        #expect(!setup.temp.loggedRawLines().contains { $0.contains("jsonrpc") })
        #expect(!received.contains { $0["method"] == "turn/start" || $0["method"] == "thread/start" })
    }

    @Test func loggedOutCodexIsNotRunnable() async throws {
        let setup = try Self.setup("loggedout")
        let report = await setup.provider.detect(previous: nil)
        #expect(report.capability.installed)
        #expect(!report.capability.authenticated)
        #expect(!report.capability.runnable)
        #expect(report.diagnostics.contains { $0.code == "codex.notAuthenticated" })
        let preparation = await setup.provider.prepareLaunch(snapshot: Fixtures.snapshot(provider: .codex), previous: nil)
        #expect(preparation.plan == nil)
    }

    @Test func brokenCatalogResponseIsAProtocolFailure() async throws {
        let setup = try Self.setup("badcatalog")
        let report = await setup.provider.detect(previous: nil)
        #expect(!report.capability.runnable)
        #expect(report.diagnostics.contains { $0.code == "codex.catalogFailed" })
        #expect(report.capability.modelCatalog.isEmpty)
    }

    @Test func missingExecutableIsReportedAsNotInstalled() async throws {
        let temp = try TempDirectory()
        let provider = Fixtures.codexProvider(bin: try temp.directory("empty"), workDir: temp.url)
        let report = await provider.detect(previous: nil)
        #expect(!report.capability.installed)
        #expect(!report.capability.runnable)
        #expect(report.toolchain == nil)
    }

    @Test func npmShimWithoutNodeIsDiagnosed() async throws {
        let temp = try TempDirectory()
        let bin = try temp.directory("bin")
        try temp.writeExecutable("codex", in: bin, content: FakeAgents.nodeShim)
        let report = await Fixtures.codexProvider(bin: bin, workDir: temp.url).detect(previous: nil)
        #expect(report.capability.installed)
        #expect(!report.capability.runnable)
        #expect(report.diagnostics.contains { $0.code == "codex.nodeMissing" })
    }

    @Test func npmShimRunsWithNodeDirectoryOnChildPath() async throws {
        let temp = try TempDirectory()
        let bin = try temp.directory("bin")
        let nodeBin = try temp.directory("node-bin")
        let real = try temp.writeExecutable("codex-real", in: try temp.directory("lib"),
                                            content: FakeAgents.codex(scenario: "ok", directory: temp.url))
        try temp.writeExecutable("codex", in: bin, content: FakeAgents.nodeShim)
        try temp.writeExecutable("node", in: nodeBin, content: FakeAgents.fakeNode(codexScript: real))
        let provider = Fixtures.codexProvider(bin: bin, extra: [nodeBin], workDir: temp.url)
        let report = await provider.detect(previous: nil)
        #expect(report.capability.runnable, "\(report.diagnostics)")
        let path = try #require(report.toolchain?.environment["PATH"])
        #expect(path.split(separator: ":").first.map { canonicalPath(String($0)) } == canonicalPath(nodeBin))
    }

    @Test func fullRunWithApprovalAnsweredByUser() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex, model: .model("gpt-6-luna"), effort: .high))
        let events = await runSession(session, decide: { _ in .allow })
        let result = try #require(events.result)
        #expect(result.outcome == .completed)
        #expect(result.finalMessage == "Fertig: decision=accept")
        #expect(result.sessionId == "019a0000-0000-7000-8000-0000000000ss")
        #expect(result.suggestedJobState == .finished)

        let approval = try #require(events.approvals.first)
        #expect(approval.kind == .commandExecution)
        #expect(approval.command == "swift test")
        #expect(events.contains(.approvalResolved(approval.id)))
        let confirmed = try #require(events.effectiveConfigurations.first)
        #expect(confirmed.source == .codexThreadStartResponse)
        #expect(confirmed.model == "gpt-6-luna")
        #expect(confirmed.effort == .high)
        #expect(events.contains(.toolActivity(ToolActivity(id: "item-1", kind: .command, summary: "swift test", phase: .completed))))
        #expect(events.contains(.assistantText("Fertig", isDelta: true)))
        if case .finished = events.last {} else { Issue.record("finished must be last") }

        let received = setup.temp.loggedMessages()
        let threadStart = try #require(received.first { $0["method"] == "thread/start" }?["params"])
        #expect(threadStart["sandbox"] == "workspace-write")
        #expect(threadStart["approvalPolicy"] == "on-request")
        #expect(threadStart["model"] == "gpt-6-luna")
        #expect(threadStart["config"]?["model_reasoning_effort"] == "high")
        #expect(threadStart["cwd"]?.stringValue == canonicalPath(setup.worktree))
        let turnStart = try #require(received.first { $0["method"] == "turn/start" }?["params"])
        #expect(turnStart["input"]?.arrayValue?.first?["text"] == "Bitte Tests reparieren.")
        #expect(received.contains { $0["id"] == 0 && $0["result"] == ["decision": "accept"] })
        #expect(!received.contains { $0["method"]?.stringValue?.contains("rateLimitResetCredit") == true })
    }

    @Test func declinedApprovalIsForwardedAsDecline() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex))
        let events = await runSession(session, decide: { _ in .deny(message: nil) })
        #expect(events.result?.finalMessage == "Fertig: decision=decline")
        #expect(events.contains(.toolActivity(ToolActivity(id: "item-1", kind: .command, summary: "swift test", phase: .declined))))
        // Provider default resolved to the catalog default model and its default effort.
        let threadStart = setup.temp.loggedMessages().first { $0["method"] == "thread/start" }?["params"]
        #expect(threadStart?["model"] == "gpt-6.1-sol")
        #expect(threadStart?["config"]?["model_reasoning_effort"] == "low")
    }

    @Test func unknownApprovalIdIsRejected() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex))
        await #expect(throws: AgentSessionError.unknownApprovalRequest(ApprovalRequestID("nope"))) {
            try await session.respond(to: ApprovalRequestID("nope"), with: .allow)
        }
        _ = await runSession(session)
    }

    @Test func crashMidRunFailsWithRedactedStderr() async throws {
        let setup = try Self.setup("crash")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex))
        let events = await runSession(session, decide: { _ in nil })
        guard case let .failed(.processEnded(status, _, tail))? = events.result?.outcome else {
            Issue.record("expected processEnded, got \(String(describing: events.result))")
            return
        }
        #expect(status == 3)
        #expect(tail.contains("simulated crash"))
        #expect(!tail.contains("sk-abcdefghijklmnop"))
        #expect(events.result?.suggestedJobState == .failed)
    }

    @Test func usageLimitEndsInWaitingQuotaWithReportedReset() async throws {
        let setup = try Self.setup("quota")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex))
        let events = await runSession(session)
        guard case let .quotaExhausted(signal)? = events.result?.outcome else {
            Issue.record("expected quotaExhausted, got \(String(describing: events.result))")
            return
        }
        #expect(signal.code == "usageLimitExceeded")
        #expect(signal.resetsAt == Date(timeIntervalSince1970: 1_793_363_552))
        #expect(events.result?.suggestedJobState == .waitingQuota)
        let received = setup.temp.loggedMessages()
        #expect(received.contains { $0["method"] == "account/rateLimits/read" })
        #expect(!received.contains { $0["method"]?.stringValue?.contains("rateLimitResetCredit") == true })
    }

    @Test func cancelInterruptsTheTurn() async throws {
        let setup = try Self.setup("hang")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex))
        let events = await runSession(session, onEvent: { event, session in
            if event == .status(.running) { await session.cancel() }
        })
        #expect(events.result?.outcome == .cancelled)
        #expect(setup.temp.loggedMessages().contains { $0["method"] == "turn/interrupt" })
    }

    @Test func unconfirmedStartParametersAbortTheRun() async throws {
        let setup = try Self.setup("mismatch")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .codex, model: .model("gpt-6-luna")))
        let events = await runSession(session)
        guard case let .failed(.startParameterMismatch(message))? = events.result?.outcome else {
            Issue.record("expected startParameterMismatch, got \(String(describing: events.result))")
            return
        }
        #expect(message.contains("gpt-rerouted"))
        #expect(!setup.temp.loggedMessages().contains { $0["method"] == "turn/start" })
    }

    @Test func invalidWorkingDirectoryIsRejectedBeforeSpawning() async throws {
        let setup = try Self.setup("ok")
        let plan = try #require(await setup.provider.prepareLaunch(snapshot: Fixtures.snapshot(provider: .codex), previous: nil).plan)
        await #expect(throws: AgentSessionError.self) {
            try await setup.provider.startSession(plan: plan, request: AgentSessionRequest(
                jobId: JobID(), workingDirectory: setup.temp.url.appending(path: "missing"), prompt: "x"))
        }
    }
}
