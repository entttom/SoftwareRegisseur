import Foundation
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurAgents

/// End-to-end tests against a fake `claude` executable speaking stream-json + the control protocol.
@Suite("Claude Code adapter end-to-end (fake CLI)", .timeLimit(.minutes(1)))
struct ClaudeCodeEndToEndTests {
    struct Setup {
        let temp: TempDirectory
        let worktree: URL
        let provider: ClaudeCodeAgentProvider
    }

    /// The passthrough tries to leak overrides; the fake exits with 71 if any `ANTHROPIC_*`/`CLAUDE_*`
    /// variable reaches it.
    static let leakAttempt = ["CLAUDE_CODE_EFFORT_LEVEL": "max", "ANTHROPIC_BASE_URL": "https://proxy.invalid",
                              "ANTHROPIC_API_KEY": "sk-ant-api03-secretsecret", "LC_ALL": "en_US.UTF-8"]

    static func setup(_ scenario: String) throws -> Setup {
        let temp = try TempDirectory()
        let bin = try temp.directory("bin")
        try temp.writeExecutable("claude", in: bin, content: FakeAgents.claude(scenario: scenario, directory: temp.url))
        return Setup(temp: temp, worktree: try temp.directory("worktree"),
                     provider: Fixtures.claudeProvider(bin: bin, workDir: try temp.directory("detect"), environment: leakAttempt))
    }

    static let sessionUUID = UUID(uuidString: "7A0B1C2D-3E4F-4A5B-8C6D-7E8F90A1B2C3")!

    static func start(_ setup: Setup, snapshot: ConfigurationSnapshot) async throws -> any AgentSession {
        let preparation = await setup.provider.prepareLaunch(snapshot: snapshot, previous: nil)
        let plan = try #require(preparation.plan, "launch not ready: \(preparation)")
        return try await setup.provider.startSession(plan: plan, request: AgentSessionRequest(
            jobId: JobID(sessionUUID), workingDirectory: setup.worktree, prompt: "Lege probe.txt an."))
    }

    @Test func detectionUsesInitializeHandshakeForCatalog() async throws {
        let setup = try Self.setup("ok")
        let report = await setup.provider.detect(previous: nil)
        let capability = report.capability
        #expect(capability.installed && capability.authenticated)
        #expect(capability.runnable, "\(report.diagnostics)")
        #expect(capability.version == "2.1.212")
        #expect(capability.capabilitySource == .sdk)
        #expect(capability.modelCatalog.map(\.modelId) == ["default", "sonnet", "haiku"])
        #expect(capability.model("haiku")?.supportedEffortIds == [])
        #expect(capability.defaultModelId == "default")
        #expect(capability.supportsRemote == false)
        #expect(report.modelResolutions["sonnet"] == "claude-sonnet-5")
        #expect(report.diagnostics.contains { $0.code == "claude.remoteControlPending" })
        #expect(report.diagnostics.contains { $0.code == "claude.agentsMarkdownImport" })

        let catalogRun = try #require(setup.temp.loggedMessages().first { $0["argv"]?.arrayValue?.contains("--no-session-persistence") == true })
        #expect(catalogRun["argv"] == .array(ClaudeCodeCommand.catalogArguments().map(JSONValue.string)))
        let initialize = try #require(setup.temp.loggedMessages().first { $0["type"] == "control_request" })
        #expect(initialize["request"]?["subtype"] == "initialize")
        #expect(!setup.temp.loggedMessages().contains { $0["type"] == "user" }) // no prompt, no billing
    }

    @Test func versionWithoutIsolationFlagsIsNotRunnable() async throws {
        // SR-SEC-03: without --setting-sources/--strict-mcp-config the worktree's settings would load.
        let setup = try Self.setup("noisolation")
        let report = await setup.provider.detect(previous: nil)
        #expect(!report.capability.runnable)
        #expect(report.diagnostics.contains { $0.code == "claude.isolationFlagsMissing" && $0.severity == .blocking })
    }

    @Test func expiredLoginIsNotRunnable() async throws {
        let setup = try Self.setup("expired")
        let report = await setup.provider.detect(previous: nil)
        #expect(report.capability.installed)
        #expect(!report.capability.authenticated)
        #expect(!report.capability.runnable)
        #expect(report.diagnostics.contains { $0.code == "claude.notAuthenticated" && $0.message.contains("claude auth login") })
        #expect(!report.capability.modelCatalog.isEmpty) // catalog works unauthenticated (spike 4b)
    }

    @Test func failedCatalogDisablesModelSelectionWithoutBuiltInList() async throws {
        let setup = try Self.setup("catalogfail")
        let report = await setup.provider.detect(previous: nil)
        #expect(report.capability.runnable)
        #expect(!report.capability.supportsModelSelection)
        #expect(!report.capability.supportsEffortSelection)
        #expect(report.capability.modelCatalog.isEmpty)
        #expect(report.diagnostics.contains { $0.code == "claude.catalogFailed" && $0.severity == .warning })
        let blocked = await setup.provider.prepareLaunch(snapshot: Fixtures.snapshot(provider: .claudeCode, model: .model("sonnet")), previous: nil)
        #expect(blocked.suggestedJobState == .needsConfiguration)
    }

    @Test func fullRunWithApprovalAllowed() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode, model: .model("sonnet"), effort: .low))
        let events = await runSession(session, decide: { _ in .allow })
        let result = try #require(events.result)
        #expect(result.outcome == .completed, "\(events)")
        #expect(result.finalMessage == "Fertig: allow")
        #expect(result.sessionId == "7a0b1c2d-3e4f-4a5b-8c6d-7e8f90a1b2c3")
        #expect(result.permissionDenials.isEmpty)
        #expect(events.sessionIds == ["7a0b1c2d-3e4f-4a5b-8c6d-7e8f90a1b2c3"])

        let effective = try #require(events.effectiveConfigurations.first)
        #expect(effective.model == "claude-sonnet-5")
        #expect(effective.effort == nil) // not confirmable headless (spike 5c)
        #expect(effective.matchesRequest)
        #expect(effective.source == .claudeSystemInit)

        let approval = try #require(events.approvals.first)
        #expect(approval.kind == .fileChange)
        #expect(approval.filePaths == ["probe.txt"])
        #expect(events.assistantTexts == ["Ich lege die Datei an.", "Fertig."])
        #expect(events.contains(.toolActivity(ToolActivity(id: "toolu_1", kind: .fileChange, summary: "Write: probe.txt", phase: .started))))

        let logged = setup.temp.loggedMessages()
        let sessionRun = try #require(logged.last { $0["argv"]?.arrayValue?.contains("--session-id") == true })
        let argv = (sessionRun["argv"]?.arrayValue ?? []).compactMap { $0.stringValue }
        #expect(argv == ClaudeCodeCommand.sessionArguments(sessionId: Self.sessionUUID, model: "sonnet", effort: .low))
        let env = (sessionRun["env"]?.arrayValue ?? []).compactMap { $0.stringValue }
        #expect(!env.contains { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_") })
        #expect(env.contains("LC_ALL"))
        let user = try #require(logged.first { $0["type"] == "user" })
        #expect(user["message"]?["content"] == "Lege probe.txt an.")
        let answer = try #require(logged.first { $0["type"] == "control_response" })
        #expect(answer["response"]?["request_id"] == "perm-1")
        #expect(answer["response"]?["response"]?["behavior"] == "allow")
        #expect(answer["response"]?["response"]?["updatedInput"] == ["file_path": "probe.txt", "content": "x"])
    }

    @Test func deniedApprovalIsReportedAsDenial() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let events = await runSession(session, decide: { _ in .deny(message: "Nicht jetzt") })
        #expect(events.result?.outcome == .completed)
        #expect(events.result?.permissionDenials == ["Write"])
        let answer = setup.temp.loggedMessages().first { $0["type"] == "control_response" }
        #expect(answer?["response"]?["response"] == ["behavior": "deny", "message": "Nicht jetzt"])
        // Provider default: neither --model nor --effort is passed.
        let argv = setup.temp.loggedMessages().last { $0["argv"]?.arrayValue?.contains("--session-id") == true }?["argv"]
        #expect(argv?.arrayValue?.contains("--model") == false)
        #expect(argv?.arrayValue?.contains("--effort") == false)
    }

    @Test func allowForSessionIsNotSupportedByClaude() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let events = await runSession(session, decide: { _ in nil }, onEvent: { event, session in
            guard case let .approvalRequested(request) = event else { return }
            await #expect(throws: AgentSessionError.decisionNotSupported(.allowForSession)) {
                try await session.respond(to: request.id, with: .allowForSession)
            }
            try? await session.respond(to: request.id, with: .allow)
        })
        #expect(events.result?.outcome == .completed)
    }

    @Test func crashMidRunIsReported() async throws {
        let setup = try Self.setup("crash")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let events = await runSession(session, decide: { _ in nil })
        guard case let .failed(.processEnded(status, _, tail))? = events.result?.outcome else {
            Issue.record("expected processEnded, got \(String(describing: events.result))")
            return
        }
        #expect(status == 3)
        #expect(tail.contains("simulated crash"))
    }

    @Test func rejectedRateLimitEndsInWaitingQuota() async throws {
        let setup = try Self.setup("quota")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let events = await runSession(session)
        guard case let .quotaExhausted(signal)? = events.result?.outcome else {
            Issue.record("expected quotaExhausted, got \(String(describing: events.result))")
            return
        }
        #expect(signal.resetsAt == Date(timeIntervalSince1970: 1_793_363_552))
        #expect(signal.kind == .limitReached)
        #expect(events.result?.suggestedJobState == .waitingQuota)
    }

    @Test func cancelWhileWaitingForApprovalInterrupts() async throws {
        let setup = try Self.setup("ok")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let events = await runSession(session, decide: { _ in nil }, onEvent: { event, session in
            if case .approvalRequested = event { await session.cancel() }
        })
        #expect(events.result?.outcome == .cancelled)
        #expect(setup.temp.loggedMessages().contains { $0["request"]?["subtype"] == "interrupt" })
    }

    @Test func foreignSessionIdAbortsTheRun() async throws {
        let setup = try Self.setup("wrongsession")
        let session = try await Self.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let events = await runSession(session)
        guard case .failed(.startParameterMismatch)? = events.result?.outcome else {
            Issue.record("expected startParameterMismatch, got \(String(describing: events.result))")
            return
        }
    }
}
