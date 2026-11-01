import Foundation
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurAgents

@Suite("Codex protocol shapes and event mapping")
struct CodexProtocolTests {
    // Shape of a real `model/list` entry captured in the spike (codex §3, probe-out.json).
    static let modelListResult = #"""
    {"data":[{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","upgrade":null,"upgradeInfo":null,
    "availabilityNux":{"message":"Maximize usage"},"displayName":"GPT-6.1-Sol","description":"Latest workhorse",
    "modelSpecialty":null,"hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},
    {"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"Deep"},
    {"reasoningEffort":"xhigh","description":"Extra"},{"reasoningEffort":"max","description":"Max"},
    {"reasoningEffort":"ultra","description":"Maximum reasoning with automatic task delegation"}],
    "defaultReasoningEffort":"low","inputModalities":["text","image"],"supportsPersonality":false,"multiAgentVersion":"v2",
    "additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"2x speed"}],
    "defaultServiceTier":null,"availableAccessPrograms":{"cyber":["standard"]},"isDefault":true},
    {"id":"gpt-6-luna","model":"gpt-6-luna","displayName":"GPT-6-Luna","description":"","hidden":false,
    "supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"max","description":""}],
    "defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}
    """#

    @Test func modelListDecodesPerModelEffortsLosslessly() throws {
        let page = try CodexProtocol.decodeModelPage(try JSONValue.parse(Self.modelListResult))
        #expect(page.nextCursor == nil)
        let models = CodexProtocol.capabilities(from: page.models, providerId: .codex, at: Fixtures.fixedDate)
        #expect(models.map(\.modelId) == ["gpt-6.1-sol", "gpt-6-luna"])
        #expect(models[0].supportedEffortIds == ["low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(models[0].defaultEffortId == .low)
        #expect(models[1].supportedEffortIds == ["low", "max"])
        #expect(models.allSatisfy { $0.source == .appServer })
        #expect(page.models[0].isDefault)
    }

    @Test func malformedModelListIsAProtocolError() {
        #expect(throws: JSONRPCError.self) { try CodexProtocol.decodeModelPage(["data": [["displayName": "x"]]]) }
        #expect(throws: JSONRPCError.self) { try CodexProtocol.decodeModelPage(["items": []]) }
    }

    @Test func threadStartParamsAlwaysSetSafetyValuesExplicitly() throws {
        let params = CodexProtocol.threadStartParams(model: "gpt-6.1-sol", effort: "high", cwd: "/w")
        #expect(params["sandbox"] == "workspace-write")
        #expect(params["approvalPolicy"] == "on-request")
        #expect(params["approvalsReviewer"] == "user")
        #expect(params["model"] == "gpt-6.1-sol")
        #expect(params["config"] == ["model_reasoning_effort": "high"])
        #expect(params["cwd"] == "/w")
        let serialized = try params.serializedString()
        #expect(!serialized.contains("danger"))
        #expect(!serialized.contains("never"))
        #expect(!serialized.contains("workspaceWrite")) // doc example value is rejected by 0.164.0 (spike §5)
    }

    @Test func turnStartParamsMatchSchema() {
        let params = CodexProtocol.turnStartParams(threadId: "t", prompt: "Hallo", model: "m", effort: "low", clientMessageId: "job")
        #expect(params["input"] == [["type": "text", "text": "Hallo", "text_elements": []]])
        #expect(params["effort"] == "low")
        #expect(params["model"] == "m")
        #expect(params["clientUserMessageId"] == "job")
    }

    @Test func threadStartVerificationDetectsInheritedDangerousConfig() throws {
        // What thread/start returns without overrides on a Mac with approval_policy="never" (spike §5).
        let response: JSONValue = [
            "thread": ["id": "t1", "sessionId": "s1", "cliVersion": "0.164.0"],
            "model": "gpt-6-luna", "reasoningEffort": "high", "approvalPolicy": "never",
            "sandbox": ["type": "dangerFullAccess"], "cwd": "/somewhere/else",
        ]
        let start = try CodexProtocol.decodeThreadStart(response)
        let problems = CodexProtocol.verify(start, model: "gpt-6.1-sol", effort: "low", cwd: "/w")
        #expect(problems.count == 5)

        let ok: JSONValue = [
            "thread": ["id": "t1", "sessionId": "s1"], "model": "gpt-6.1-sol", "reasoningEffort": "low",
            "approvalPolicy": "on-request", "sandbox": ["type": "workspaceWrite", "networkAccess": false], "cwd": "/w",
        ]
        #expect(CodexProtocol.verify(try CodexProtocol.decodeThreadStart(ok), model: "gpt-6.1-sol", effort: "low", cwd: "/w").isEmpty)

        // SR-SEC-19: an unreported cwd is not a confirmed start.
        let withoutCwd: JSONValue = [
            "thread": ["id": "t1", "sessionId": "s1"], "model": "gpt-6.1-sol", "reasoningEffort": "low",
            "approvalPolicy": "on-request", "sandbox": ["type": "workspaceWrite", "networkAccess": false],
        ]
        #expect(CodexProtocol.verify(try CodexProtocol.decodeThreadStart(withoutCwd), model: "gpt-6.1-sol", effort: "low", cwd: "/w")
                == ["cwd=nil statt /w"])
    }

    @Test func usageLimitErrorMapsToQuotaSignalAndFailedTurn() {
        var mapper = CodexEventMapper(requestedModel: "gpt-6.1-sol", requestedEffort: "low")
        mapper.threadId = "t"
        let error: JSONValue = ["message": "You've hit your usage limit", "codexErrorInfo": "usageLimitExceeded", "additionalDetails": nil]
        let first = mapper.map(method: "error", params: ["error": error, "willRetry": false, "threadId": "t", "turnId": "u"])
        #expect(first.quotaCode == "usageLimitExceeded")
        #expect(first.events == [.quota(QuotaSignal(providerId: .codex, kind: .limitReached, code: "usageLimitExceeded",
                                                    message: "You've hit your usage limit"))])
        let done = mapper.map(method: "turn/completed", params: ["threadId": "t", "turn": ["id": "u", "status": "failed", "error": error]])
        #expect(done.completion == .failed(code: "usageLimitExceeded", message: "You've hit your usage limit"))
        #expect(mapper.lastQuotaSignal?.kind == .limitReached)
    }

    @Test func retryingRateLimitIsNotTerminal() {
        var mapper = CodexEventMapper(requestedModel: nil, requestedEffort: nil)
        let output = mapper.map(method: "error", params: [
            "error": ["message": "slow down", "codexErrorInfo": "rateLimitExceeded"], "willRetry": true,
        ])
        #expect(output.quotaCode == nil)
        #expect(output.events.quotaSignals.first?.kind == .retrying)
        #expect(mapper.lastQuotaSignal == nil)
    }

    @Test func objectShapedErrorInfoYieldsItsKey() {
        #expect(CodexProtocol.errorCode(["httpConnectionFailed": ["httpStatusCode": 502]]) == "httpConnectionFailed")
        #expect(CodexProtocol.errorCode("usageLimitExceeded") == "usageLimitExceeded")
        #expect(CodexProtocol.errorCode(nil) == nil)
    }

    @Test func rateLimitSnapshotProvidesReportedResetOnlyWhenTrustworthy() {
        let read: JSONValue = [
            "ordinaryUsageAllowed": false,
            "rateLimits": [
                "primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1_793_363_552],
                "secondary": ["usedPercent": 73, "windowDurationMins": 10080, "resetsAt": 1_793_798_493],
            ],
        ]
        let signal = CodexProtocol.quotaSignal(fromRateLimits: read, kind: .limitReached, code: "usageLimitExceeded", message: nil)
        #expect(signal.resetsAt == Date(timeIntervalSince1970: 1_793_363_552))
        #expect(signal.usedPercent == 100)

        var untrusted = read.objectValue!
        untrusted["ordinaryUsageAllowed"] = .null
        let unknown = CodexProtocol.quotaSignal(fromRateLimits: .object(untrusted), kind: .limitReached, code: nil, message: nil)
        #expect(unknown.resetsAt == nil)
    }

    @Test func notificationsMapToSessionEvents() {
        var mapper = CodexEventMapper(requestedModel: "gpt-6.1-sol", requestedEffort: "low")
        mapper.threadId = "t"
        let started = mapper.map(method: "item/started", params: [
            "threadId": "t", "item": ["type": "fileChange", "id": "f1", "status": "inProgress",
                                      "changes": [["path": "Sources/A.swift", "kind": ["type": "update"], "diff": ""]]],
        ])
        #expect(started.events == [.toolActivity(ToolActivity(id: "f1", kind: .fileChange, summary: "Sources/A.swift", phase: .started))])

        let reroute = mapper.map(method: "model/rerouted", params: ["threadId": "t", "turnId": "u", "fromModel": "gpt-6.1-sol",
                                                                    "toModel": "gpt-6-luna", "reason": "highRiskCyberActivity"])
        let config = reroute.events.effectiveConfigurations.first
        #expect(config?.model == "gpt-6-luna")
        #expect(config?.matchesRequest == false)
        #expect(config?.source == .codexModelRerouted)

        let settings = mapper.map(method: "thread/settings/updated", params: ["threadId": "t", "threadSettings": ["model": "gpt-6.1-sol", "effort": "low"]])
        #expect(settings.events.effectiveConfigurations.first?.matchesRequest == true)

        // Other threads (e.g. sub-agents) are ignored.
        #expect(mapper.map(method: "turn/completed", params: ["threadId": "other", "turn": ["status": "completed"]]).completion == nil)
        #expect(mapper.map(method: "some/future/notification", params: nil).events.isEmpty)

        let delta = mapper.map(method: "item/agentMessage/delta", params: ["threadId": "t", "delta": "Hal"])
        #expect(delta.events == [.assistantText("Hal", isDelta: true)])
        let resolved = mapper.map(method: "serverRequest/resolved", params: ["threadId": "t", "requestId": 0])
        #expect(resolved.events == [.approvalResolved(ApprovalRequestID("0"))])
    }

    @Test func approvalRequestAndResponsesRoundTrip() throws {
        var mapper = CodexEventMapper(requestedModel: nil, requestedEffort: nil)
        _ = mapper.map(method: "item/started", params: ["item": ["type": "fileChange", "id": "f1", "changes": [["path": "a.txt"]]]])
        let request = try #require(mapper.approvalRequest(
            id: .int(4), method: "item/fileChange/requestApproval",
            params: ["threadId": "t", "turnId": "u", "itemId": "f1", "startedAtMs": 1, "reason": nil], now: Fixtures.fixedDate))
        #expect(request.kind == .fileChange)
        #expect(request.filePaths == ["a.txt"])
        #expect(request.id == ApprovalRequestID("4"))

        let command = try #require(mapper.approvalRequest(
            id: .string("c"), method: "item/commandExecution/requestApproval",
            params: ["command": "curl -sI https://example.com", "cwd": "/w", "reason": "network"], now: Fixtures.fixedDate))
        #expect(command.command == "curl -sI https://example.com")
        #expect(command.reason == "network")

        let method = "item/commandExecution/requestApproval"
        #expect(try CodexEventMapper.approvalResponse(method: method, params: nil, decision: .allow) == ["decision": "accept"])
        #expect(try CodexEventMapper.approvalResponse(method: method, params: nil, decision: .allowForSession) == ["decision": "acceptForSession"])
        #expect(try CodexEventMapper.approvalResponse(method: method, params: nil, decision: .deny(message: nil)) == ["decision": "decline"])
        #expect(try CodexEventMapper.approvalResponse(method: method, params: nil, decision: .cancel) == ["decision": "cancel"])

        let permissions: JSONValue = ["permissions": ["network": ["enabled": true], "fileSystem": nil]]
        #expect(try CodexEventMapper.approvalResponse(method: "item/permissions/requestApproval", params: permissions, decision: .allow)
            == ["permissions": ["network": ["enabled": true]], "scope": "turn"])
        #expect(try CodexEventMapper.approvalResponse(method: "item/permissions/requestApproval", params: permissions, decision: .deny(message: nil))
            == ["permissions": [:], "scope": "turn"])
        #expect(throws: AgentSessionError.self) {
            try CodexEventMapper.approvalResponse(method: "item/tool/requestUserInput", params: nil, decision: .allow)
        }
        // Unknown server requests are never turned into approvals.
        #expect(mapper.approvalRequest(id: .int(1), method: "mcpServer/elicitation/request", params: nil, now: Fixtures.fixedDate) == nil)
    }

    @Test func versionParsing() {
        #expect(CodexAgentProvider.parseVersion("codex-cli 0.164.0\n") == SemanticVersion(0, 164, 0))
        #expect(CodexAgentProvider.parseVersion("codex-cli 0.165.0-alpha.1.2") == SemanticVersion(0, 165, 0, prerelease: "alpha.1.2"))
        #expect(SemanticVersion(0, 165, 0, prerelease: "alpha") > SemanticVersion(0, 164, 0))
        #expect(SemanticVersion(0, 165, 0, prerelease: "alpha") < SemanticVersion(0, 165, 0))
        #expect(CodexAgentProvider.parseVersion("garbage") == nil)
    }
}
