import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurProcess
import Testing
@testable import SoftwareRegisseurAgents

@Suite("Claude Code command, environment and stream-json parsing")
struct ClaudeCodeProtocolTests {
    static let sessionId = UUID(uuidString: "6F1C2E3A-1111-4222-8333-944455556666")!

    @Test func sessionCommandMatchesADR0021Exactly() {
        let arguments = ClaudeCodeCommand.sessionArguments(sessionId: Self.sessionId, model: "sonnet", effort: .high)
        #expect(arguments == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--session-id", "6f1c2e3a-1111-4222-8333-944455556666",
            "--model", "sonnet", "--effort", "high",
            "--setting-sources", "user", "--strict-mcp-config",
            "--permission-mode", "manual", "--permission-prompt-tool", "stdio",
            "--disallowedTools", "Bash(git push *)", "Bash(git push)", "EnterWorktree",
        ])
        #expect(ClaudeCodeCommand.violations(in: arguments).isEmpty)
    }

    @Test(arguments: [
        (ModelID?.none, EffortLevel?.none), (ModelID?.some("opus[1m]"), EffortLevel?.some(.max)),
        (ModelID?.some("haiku"), EffortLevel?.some(.auto)),
    ])
    func forbiddenFlagsNeverAppear(model: ModelID?, effort: EffortLevel?) {
        let arguments = ClaudeCodeCommand.sessionArguments(sessionId: Self.sessionId, model: model, effort: effort)
        for forbidden in ["-w", "--worktree", "--bg", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                          "bypassPermissions", "--remote-control", "--rc", "--tmux"] {
            #expect(!arguments.contains(forbidden))
        }
        #expect(arguments.contains("--permission-prompt-tool"))
        #expect(arguments[arguments.firstIndex(of: "--permission-mode")! + 1] == "manual")
        #expect(arguments.contains("--effort") == (effort.map { !$0.isAuto } ?? false))
        #expect(arguments.contains("--model") == (model != nil))
        #expect(ClaudeCodeCommand.violations(in: arguments).isEmpty)
    }

    @Test func violationCheckerFindsUnsafeArguments() {
        #expect(ClaudeCodeCommand.violations(in: ["-p", "-w", "x"]) == ["-w"])
        #expect(ClaudeCodeCommand.violations(in: ["--permission-mode", "bypassPermissions"]) == ["--permission-mode bypassPermissions"])
        #expect(ClaudeCodeCommand.violations(in: ["--bg", "--dangerously-skip-permissions"]).count == 2)
        #expect(ClaudeCodeCommand.violations(in: ["--worktree=feature"]) == ["--worktree=feature"])
        // SR-SEC-03: job sessions must be isolated from the repository's settings and MCP servers.
        let session = ClaudeCodeCommand.sessionArguments(sessionId: Self.sessionId, model: nil, effort: nil)
        #expect(session.contains("--strict-mcp-config"))
        #expect(session[session.firstIndex(of: "--setting-sources")! + 1] == "user")
        let withoutIsolation = session.filter { !["--setting-sources", "user", "--strict-mcp-config"].contains($0) }
        #expect(ClaudeCodeCommand.violations(in: withoutIsolation) == ["missing --setting-sources user", "missing --strict-mcp-config"])
        var projectSettings = session
        projectSettings[projectSettings.firstIndex(of: "user")!] = "user,project,local"
        #expect(ClaudeCodeCommand.violations(in: projectSettings) == ["--setting-sources user,project,local"])
        #expect(ClaudeCodeCommand.missingIsolationFlags(inHelp: "  --setting-sources <sources>\n  --strict-mcp-config  Only") == [])
        #expect(ClaudeCodeCommand.missingIsolationFlags(inHelp: "  --settings <file>") == ["--setting-sources", "--strict-mcp-config"])
        // Tool patterns and model names are data, not flags.
        #expect(ClaudeCodeCommand.violations(in: ["--disallowedTools", "Bash(git push *)", "EnterWorktree", "--model", "rc"]).isEmpty)
    }

    @Test func catalogCommandHasNoPromptOrSession() {
        let arguments = ClaudeCodeCommand.catalogArguments()
        #expect(arguments.contains("--no-session-persistence"))
        #expect(!arguments.contains("--session-id"))
        #expect(ClaudeCodeCommand.violations(in: arguments).isEmpty)
    }

    @Test func environmentIsSanitized() {
        let environment = AgentEnvironment.make(
            pathDirectories: [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/Users/x/.local/bin"), URL(filePath: "/opt/homebrew/bin")],
            passthrough: [
                "CLAUDE_CODE_EFFORT_LEVEL": "max", "ANTHROPIC_BASE_URL": "https://proxy", "ANTHROPIC_API_KEY": "sk-ant-secret",
                "ANTHROPIC_MODEL": "x", "CLAUDE_CODE_SIMPLE": "1", "CLAUDECODE": "1", "CLAUDE_EFFORT": "high",
                "DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1", "OPENAI_API_KEY": "sk-x", "CODEX_HOME": "/tmp/x",
                "GIT_DIR": "/elsewhere/.git", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "NODE_OPTIONS": "--require x",
                "PATH": "/evil", "LC_ALL": "de_DE.UTF-8",
            ]
        )
        let names = Set(environment.variables.keys)
        #expect(names.isSubset(of: ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "LC_ALL"]))
        #expect(environment["LC_ALL"] == "de_DE.UTF-8")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/Users/x/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == NSHomeDirectory())
        for forbidden in ["CLAUDE_CODE_EFFORT_LEVEL", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "CLAUDECODE", "GIT_DIR"] {
            #expect(AgentEnvironment.isForbidden(forbidden))
        }
    }

    @Test func userMessageAndControlLines() throws {
        let user = ClaudeCodeInput.userMessage("Bitte X", sessionId: Self.sessionId)
        #expect(user["type"] == "user")
        #expect(user["message"] == ["role": "user", "content": "Bitte X"])
        let initialize = ClaudeCodeInput.controlRequest(id: "r1", subtype: "initialize")
        #expect(try initialize.serializedString() == #"{"request":{"subtype":"initialize"},"request_id":"r1","type":"control_request"}"#)
    }

    @Test func permissionResponsesRoundTrip() throws {
        let input: JSONValue = ["file_path": "probe.txt", "content": "x"]
        let allow = try ClaudeCodeInput.permissionResponse(id: "perm-1", decision: .allow, originalInput: input)
        #expect(allow == ["type": "control_response", "response": ["subtype": "success", "request_id": "perm-1",
                                                                   "response": ["behavior": "allow", "updatedInput": input]]])
        let deny = try ClaudeCodeInput.permissionResponse(id: "perm-1", decision: .deny(message: "Nein"), originalInput: input)
        #expect(deny["response"]?["response"] == ["behavior": "deny", "message": "Nein"])
        let cancel = try ClaudeCodeInput.permissionResponse(id: "perm-1", decision: .cancel, originalInput: input)
        #expect(cancel["response"]?["response"]?["interrupt"] == true)
        #expect(throws: AgentSessionError.self) {
            try ClaudeCodeInput.permissionResponse(id: "p", decision: .allowForSession, originalInput: input)
        }
    }

    @Test func parsesStreamJsonMessages() throws {
        let initLine = #"{"type":"system","subtype":"init","session_id":"6f1c2e3a-1111-4222-8333-944455556666","model":"claude-sonnet-5","permissionMode":"default","cwd":"/w","tools":["Bash"],"claude_code_version":"2.1.212","capabilities":{}}"#
        #expect(ClaudeStreamParser.parse(initLine) == .systemInit(
            sessionId: "6f1c2e3a-1111-4222-8333-944455556666", model: "claude-sonnet-5", permissionMode: "default", version: "2.1.212"))

        let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test"}}]},"session_id":"s"}"#
        guard case let .assistant(texts, tools)? = ClaudeStreamParser.parse(assistant) else { Issue.record("assistant"); return }
        #expect(texts == ["Hi"])
        #expect(tools.first?.name == "Bash")
        #expect(ClaudeStreamParser.toolActivity(tools[0]) == ToolActivity(id: "toolu_1", kind: .command, summary: "swift test", phase: .started))

        let retry = #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":4000,"error_status":429,"error":"rate_limit"}"#
        #expect(ClaudeStreamParser.parse(retry) == .apiRetry(attempt: 2, retryDelayMs: 4000, errorStatus: 429, error: "rate_limit"))

        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Fertig","session_id":"s","total_cost_usd":0.1,"permission_denials":[{"tool_name":"Bash","tool_use_id":"t","tool_input":{}}],"modelUsage":{"claude-sonnet-5":{}}}"#
        guard case let .result(parsed)? = ClaudeStreamParser.parse(result) else { Issue.record("result"); return }
        #expect(parsed.text == "Fertig")
        #expect(parsed.permissionDenials == ["Bash"])
        #expect(!parsed.isError)

        let cancel = #"{"type":"control_cancel_request","request_id":"perm-9"}"#
        #expect(ClaudeStreamParser.parse(cancel) == .controlCancel(id: "perm-9"))
        #expect(ClaudeStreamParser.parse(#"{"type":"stream_event","event":{}}"#) == .other(type: "stream_event"))
        #expect(ClaudeStreamParser.parse("{broken") == .invalid("{broken"))
        #expect(ClaudeStreamParser.parse("") == nil)
    }

    @Test func rateLimitEventMapsToQuota() throws {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793363552,"rateLimitType":"five_hour","utilization":1.0},"session_id":"s"}"#
        guard case let .rateLimit(info)? = ClaudeStreamParser.parse(line) else { Issue.record("rate limit"); return }
        let signal = ClaudeStreamParser.quotaSignal(info)
        #expect(signal.kind == .limitReached)
        #expect(signal.resetsAt == Date(timeIntervalSince1970: 1_793_363_552))
        #expect(signal.usedPercent == 100)
        #expect(signal.code == "five_hour")

        let warning = ClaudeStreamParser.quotaSignal(.init(status: "allowed_warning", resetsAt: nil, utilization: 0.9, rateLimitType: nil, errorCode: nil))
        #expect(warning.kind == .warning)
        #expect(warning.resetsAt == nil) // optional in the SDK type; never invented
        let credits = ClaudeStreamParser.quotaSignal(.init(status: "rejected", resetsAt: nil, utilization: nil, rateLimitType: "x", errorCode: "credits_required"))
        #expect(credits.code == "credits_required")
    }

    @Test func canUseToolBecomesApprovalRequest() throws {
        let line = #"{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build","description":"Clean"},"tool_use_id":"toolu_2","permission_suggestions":[]}}"#
        guard case let .controlRequest(id, subtype, request)? = ClaudeStreamParser.parse(line) else { Issue.record("control"); return }
        #expect(subtype == "can_use_tool")
        let approval = ClaudeStreamParser.approvalRequest(id: id, request: request, now: Fixtures.fixedDate)
        #expect(approval.kind == .commandExecution)
        #expect(approval.command == "rm -rf build")
        #expect(approval.reason == "Clean")
        #expect(approval.availableDecisions == [.allow, .deny(message: nil), .cancel])

        let edit = ClaudeStreamParser.approvalRequest(id: "p2", request: ["tool_name": "Edit", "input": ["file_path": "/w/a.swift"]], now: Fixtures.fixedDate)
        #expect(edit.kind == .fileChange)
        #expect(edit.filePaths == ["/w/a.swift"])
        let mcp = ClaudeStreamParser.approvalRequest(id: "p3", request: ["tool_name": "mcp__x__y", "input": [:]], now: Fixtures.fixedDate)
        #expect(mcp.kind == .toolUse("mcp__x__y"))
    }

    @Test func catalogDecodingFollowsSpikeShape() throws {
        // `control_response.response.models[]` measured in the spike (claude-code 4b).
        let response: JSONValue = ["models": [
            ["value": "default", "resolvedModel": "claude-opus-4-8[1m]", "displayName": "Default", "supportsEffort": true,
             "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
            ["value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001", "displayName": "Haiku"],
        ]]
        let entries = try ClaudeStreamParser.decodeCatalog(response)
        let models = ClaudeStreamParser.capabilities(from: entries, at: Fixtures.fixedDate)
        #expect(models.map(\.modelId) == ["default", "haiku"])
        #expect(models[0].supportedEffortIds == [.low, .medium, .high, .xhigh, .max])
        #expect(models[1].supportedEffortIds.isEmpty)
        #expect(models.allSatisfy { $0.source == .sdk })
        #expect(throws: JSONRPCError.self) { try ClaudeStreamParser.decodeCatalog(["account": [:]]) }
    }

    @Test func authStatusAndVersionParsing() {
        let expired = ClaudeCodeAgentProvider.parseAuthStatus(#"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#)
        #expect(expired.loggedIn == false)
        #expect(expired.apiProvider == "firstParty")
        #expect(ClaudeCodeAgentProvider.parseAuthStatus("Not logged in").loggedIn == nil)
        #expect(ClaudeCodeCommand.parseVersion("2.1.212 (Claude Code)\n") == SemanticVersion(2, 1, 212))
    }
}
