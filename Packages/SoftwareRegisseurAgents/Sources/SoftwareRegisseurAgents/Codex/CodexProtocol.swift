import Foundation
import SoftwareRegisseurDomain

/// Codex app-server request/response shapes, field names from the schema generated with
/// `codex app-server generate-ts` for codex-cli 0.164.0 (spike codex §2–§7).
enum CodexProtocol {
    enum Method {
        static let initialize = "initialize"
        static let initialized = "initialized"
        static let modelList = "model/list"
        static let threadStart = "thread/start"
        static let turnStart = "turn/start"
        static let turnInterrupt = "turn/interrupt"
        static let rateLimitsRead = "account/rateLimits/read"
    }

    /// Fixed safety parameters, set explicitly on every start (ADR-0021; spike §5: the user's
    /// config.toml may contain `approval_policy="never"` / `danger-full-access`).
    static let sandboxMode = "workspace-write"
    static let expectedSandboxPolicyType = "workspaceWrite"
    static let approvalPolicy = "on-request"
    static let approvalsReviewer = "user"
    static let serviceName = "software_regisseur"

    struct ClientInfo: Sendable, Hashable {
        var name: String
        var title: String
        var version: String
    }

    static func initializeParams(_ client: ClientInfo) -> JSONValue {
        [
            "clientInfo": ["name": .string(client.name), "title": .string(client.title), "version": .string(client.version)],
            "capabilities": ["experimentalApi": false, "requestAttestation": false],
        ]
    }

    static func modelListParams(cursor: String?) -> JSONValue {
        var object: [String: JSONValue] = ["includeHidden": false, "limit": 100]
        if let cursor { object["cursor"] = .string(cursor) }
        return .object(object)
    }

    // MARK: model/list

    struct Model: Sendable, Hashable {
        let id: String
        let displayName: String
        let isDefault: Bool
        let hidden: Bool
        let supportedEfforts: [String]
        let defaultEffort: String?
    }

    struct ModelPage: Sendable, Hashable {
        let models: [Model]
        let nextCursor: String?
    }

    static func decodeModelPage(_ result: JSONValue) throws -> ModelPage {
        guard let data = result["data"]?.arrayValue else {
            throw JSONRPCError.invalidResponse(method: Method.modelList, "Feld data fehlt")
        }
        let models = try data.map { entry -> Model in
            guard let id = entry["id"]?.stringValue, !id.isEmpty,
                  let efforts = entry["supportedReasoningEfforts"]?.arrayValue else {
                throw JSONRPCError.invalidResponse(method: Method.modelList, "Modell ohne id/supportedReasoningEfforts")
            }
            return Model(
                id: id,
                displayName: entry["displayName"]?.stringValue ?? id,
                isDefault: entry["isDefault"]?.boolValue ?? false,
                hidden: entry["hidden"]?.boolValue ?? false,
                supportedEfforts: efforts.compactMap { $0["reasoningEffort"]?.stringValue },
                defaultEffort: entry["defaultReasoningEffort"]?.stringValue
            )
        }
        return ModelPage(models: models, nextCursor: result["nextCursor"]?.stringValue)
    }

    static func capabilities(from models: [Model], providerId: ProviderID, at date: Date) -> [AgentModelCapability] {
        models.compactMap { model in
            guard let modelId = ModelID(rawValue: model.id) else { return nil }
            return AgentModelCapability(
                providerId: providerId,
                modelId: modelId,
                displayName: model.displayName,
                supportedEffortIds: model.supportedEfforts.compactMap(EffortLevel.init(rawValue:)),
                defaultEffortId: model.defaultEffort.flatMap(EffortLevel.init(rawValue:)),
                availability: .available,
                source: .appServer,
                lastValidatedAt: date
            )
        }
    }

    // MARK: thread/start, turn/start

    static func threadStartParams(model: String?, effort: String?, cwd: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "cwd": .string(cwd),
            "sandbox": .string(sandboxMode),
            "approvalPolicy": .string(approvalPolicy),
            "approvalsReviewer": .string(approvalsReviewer),
            "serviceName": .string(serviceName),
            "ephemeral": false,
        ]
        if let model { object["model"] = .string(model) }
        if let effort { object["config"] = ["model_reasoning_effort": .string(effort)] }
        return .object(object)
    }

    struct ThreadStart: Sendable, Hashable {
        let threadId: String
        let sessionId: String?
        let model: String?
        let reasoningEffort: String?
        let approvalPolicy: String?
        let sandboxType: String?
        let cwd: String?
        let cliVersion: String?
    }

    static func decodeThreadStart(_ result: JSONValue) throws -> ThreadStart {
        guard let thread = result["thread"], let threadId = thread["id"]?.stringValue else {
            throw JSONRPCError.invalidResponse(method: Method.threadStart, "thread.id fehlt")
        }
        return ThreadStart(
            threadId: threadId,
            sessionId: thread["sessionId"]?.stringValue,
            model: result["model"]?.stringValue,
            reasoningEffort: result["reasoningEffort"]?.stringValue,
            approvalPolicy: result["approvalPolicy"]?.stringValue,
            sandboxType: result["sandbox"]?["type"]?.stringValue,
            cwd: result["cwd"]?.stringValue,
            cliVersion: thread["cliVersion"]?.stringValue
        )
    }

    /// Checks that Codex confirmed the explicit parameters (spike „Jobstart“ step 3). Returns the
    /// mismatches; any mismatch aborts the run.
    static func verify(_ start: ThreadStart, model: String?, effort: String?, cwd: String) -> [String] {
        var problems: [String] = []
        if start.approvalPolicy != approvalPolicy {
            problems.append("approvalPolicy=\(start.approvalPolicy ?? "nil") statt \(approvalPolicy)")
        }
        if start.sandboxType != expectedSandboxPolicyType {
            problems.append("sandbox=\(start.sandboxType ?? "nil") statt \(expectedSandboxPolicyType)")
        }
        if let model, start.model != model {
            problems.append("model=\(start.model ?? "nil") statt \(model)")
        }
        if let effort, start.reasoningEffort != effort {
            problems.append("reasoningEffort=\(start.reasoningEffort ?? "nil") statt \(effort)")
        }
        // SR-SEC-19: a missing `cwd` is a deviation as well – the start is only confirmed when Codex
        // reports the worktree it really works in.
        if let reported = start.cwd {
            if canonicalPath(reported) != canonicalPath(cwd) { problems.append("cwd=\(reported) statt \(cwd)") }
        } else {
            problems.append("cwd=nil statt \(cwd)")
        }
        return problems
    }

    static func turnStartParams(threadId: String, prompt: String, model: String?, effort: String?, clientMessageId: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "threadId": .string(threadId),
            // `text_elements` is required by the 0.164.0 schema (spike „Jobstart“ step 4).
            "input": [["type": "text", "text": .string(prompt), "text_elements": []]],
            "clientUserMessageId": .string(clientMessageId),
        ]
        if let model { object["model"] = .string(model) }
        if let effort { object["effort"] = .string(effort) }
        return .object(object)
    }

    // MARK: Errors and quota (spec K2, spike §7)

    /// `codexErrorInfo` values that mean the account limit is reached → `waiting_quota`.
    static let quotaErrorCodes: Set<String> = ["usageLimitExceeded", "rateLimitExceeded", "sessionBudgetExceeded"]

    /// `CodexErrorInfo` is a string or a single-key object such as `{"httpConnectionFailed": {...}}`.
    static func errorCode(_ info: JSONValue?) -> String? {
        switch JSONValue.nonNull(info) {
        case let .string(code)?: code
        case let .object(object)? where object.count == 1: object.keys.first
        default: nil
        }
    }

    static func quotaSignal(fromRateLimits result: JSONValue, kind: QuotaSignal.Kind, code: String?, message: String?) -> QuotaSignal {
        let snapshot = result["rateLimits"] ?? result
        let windows = [snapshot["primary"], snapshot["secondary"]].compactMap { JSONValue.nonNull($0) }
        // Schema: with `ordinaryUsageAllowed == null` clients must not infer recovery from reset times.
        let trustReset = JSONValue.nonNull(result["ordinaryUsageAllowed"]) != nil || result["rateLimits"] == nil
        let exhausted = windows.filter { ($0["usedPercent"]?.doubleValue ?? 0) >= 100 }
        let resetSource = exhausted.isEmpty ? windows : exhausted
        let resets = trustReset ? resetSource.compactMap { $0["resetsAt"]?.doubleValue }.max() : nil
        return QuotaSignal(
            providerId: .codex,
            kind: kind,
            code: code,
            message: message,
            resetsAt: resets.map { Date(timeIntervalSince1970: $0) },
            usedPercent: windows.compactMap { $0["usedPercent"]?.doubleValue }.max()
        )
    }
}
