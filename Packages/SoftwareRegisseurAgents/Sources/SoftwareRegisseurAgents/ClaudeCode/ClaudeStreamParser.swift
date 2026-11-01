import Foundation
import SoftwareRegisseurDomain

/// One decoded line of `claude -p --output-format stream-json --verbose` output. Shapes follow the
/// Agent SDK message types (`SDKSystemMessage`, `SDKAssistantMessage`, `SDKResultMessage`,
/// `SDKRateLimitEvent`, control protocol) referenced in the spike (claude-code 2a, 4b, 5c, 6b, 8).
enum ClaudeStreamMessage: Hashable, Sendable {
    struct ToolUse: Hashable, Sendable {
        let id: String
        let name: String
        let input: JSONValue
    }

    struct ToolResult: Hashable, Sendable {
        let id: String
        let isError: Bool
    }

    struct Result: Hashable, Sendable {
        let subtype: String
        let isError: Bool
        let text: String?
        let sessionId: String?
        let apiErrorStatus: Int64?
        let permissionDenials: [String]
        let errors: [String]
    }

    struct RateLimit: Hashable, Sendable {
        let status: String
        let resetsAt: Date?
        let utilization: Double?
        let rateLimitType: String?
        let errorCode: String?
    }

    case systemInit(sessionId: String?, model: String?, permissionMode: String?, version: String?)
    case apiRetry(attempt: Int64?, retryDelayMs: Int64?, errorStatus: Int64?, error: String?)
    case system(subtype: String)
    case assistant(texts: [String], toolUses: [ToolUse])
    case toolResults([ToolResult])
    case result(Result)
    case rateLimit(RateLimit)
    case controlRequest(id: String, subtype: String, request: JSONValue)
    case controlResponse(id: String, success: Bool, response: JSONValue?, error: String?)
    case controlCancel(id: String)
    case other(type: String)
    case invalid(String)
}

enum ClaudeStreamParser {
    static func parse(_ line: String) -> ClaudeStreamMessage? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let json = try? JSONValue.parse(line), let type = json["type"]?.stringValue else {
            return .invalid(line)
        }
        switch type {
        case "system":
            let subtype = json["subtype"]?.stringValue ?? ""
            switch subtype {
            case "init":
                return .systemInit(
                    sessionId: json["session_id"]?.stringValue,
                    model: json["model"]?.stringValue,
                    permissionMode: json["permissionMode"]?.stringValue,
                    version: json["claude_code_version"]?.stringValue
                )
            case "api_retry":
                return .apiRetry(
                    attempt: json["attempt"]?.int64Value,
                    retryDelayMs: json["retry_delay_ms"]?.int64Value,
                    errorStatus: json["error_status"]?.int64Value,
                    error: json["error"]?.stringValue
                )
            default:
                return .system(subtype: subtype)
            }

        case "assistant":
            let content = json["message"]?["content"]?.arrayValue ?? []
            var texts: [String] = []
            var tools: [ClaudeStreamMessage.ToolUse] = []
            for block in content {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue, !text.isEmpty { texts.append(text) }
                case "tool_use":
                    tools.append(.init(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "?",
                                       input: block["input"] ?? .null))
                default:
                    break
                }
            }
            return .assistant(texts: texts, toolUses: tools)

        case "user":
            let content = json["message"]?["content"]?.arrayValue ?? []
            let results = content.compactMap { block -> ClaudeStreamMessage.ToolResult? in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                return .init(id: id, isError: block["is_error"]?.boolValue ?? false)
            }
            return .toolResults(results)

        case "result":
            let denials = json["permission_denials"]?.arrayValue?.compactMap { $0["tool_name"]?.stringValue } ?? []
            return .result(.init(
                subtype: json["subtype"]?.stringValue ?? "",
                isError: json["is_error"]?.boolValue ?? false,
                text: json["result"]?.stringValue,
                sessionId: json["session_id"]?.stringValue,
                apiErrorStatus: json["api_error_status"]?.int64Value,
                permissionDenials: denials,
                errors: json["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
            ))

        case "rate_limit_event":
            let info = json["rate_limit_info"] ?? .null
            return .rateLimit(.init(
                status: info["status"]?.stringValue ?? "unknown",
                resetsAt: info["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                utilization: info["utilization"]?.doubleValue,
                rateLimitType: info["rateLimitType"]?.stringValue,
                errorCode: info["errorCode"]?.stringValue
            ))

        case "control_request":
            guard let id = json["request_id"]?.stringValue, let request = json["request"] else { return .invalid(line) }
            return .controlRequest(id: id, subtype: request["subtype"]?.stringValue ?? "", request: request)

        case "control_response":
            guard let response = json["response"], let id = response["request_id"]?.stringValue else { return .invalid(line) }
            let success = response["subtype"]?.stringValue == "success"
            return .controlResponse(id: id, success: success, response: response["response"], error: response["error"]?.stringValue)

        case "control_cancel_request":
            guard let id = json["request_id"]?.stringValue else { return .invalid(line) }
            return .controlCancel(id: id)

        default:
            return .other(type: type)
        }
    }

    // MARK: Catalog (SDK `initialize` → `models[]`, spike 4b)

    struct CatalogEntry: Hashable, Sendable {
        let value: String
        let resolvedModel: String?
        let displayName: String
        let supportsEffort: Bool
        let supportedEffortLevels: [String]
    }

    static func decodeCatalog(_ response: JSONValue) throws -> [CatalogEntry] {
        guard let models = response["models"]?.arrayValue else {
            throw JSONRPCError.invalidResponse(method: "initialize", "models[] fehlt")
        }
        return try models.map { model in
            guard let value = model["value"]?.stringValue, !value.isEmpty else {
                throw JSONRPCError.invalidResponse(method: "initialize", "Modell ohne value")
            }
            let supportsEffort = model["supportsEffort"]?.boolValue ?? false
            return CatalogEntry(
                value: value,
                resolvedModel: model["resolvedModel"]?.stringValue,
                displayName: model["displayName"]?.stringValue ?? value,
                supportsEffort: supportsEffort,
                supportedEffortLevels: supportsEffort ? (model["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? []) : []
            )
        }
    }

    static func capabilities(from entries: [CatalogEntry], at date: Date) -> [AgentModelCapability] {
        entries.compactMap { entry in
            guard let id = ModelID(rawValue: entry.value) else { return nil }
            return AgentModelCapability(
                providerId: .claudeCode, modelId: id, displayName: entry.displayName,
                supportedEffortIds: entry.supportedEffortLevels.compactMap(EffortLevel.init(rawValue:)),
                defaultEffortId: nil, availability: .available, source: .sdk, lastValidatedAt: date
            )
        }
    }

    // MARK: Quota (spec K2)

    static func quotaSignal(_ rateLimit: ClaudeStreamMessage.RateLimit) -> QuotaSignal {
        let kind: QuotaSignal.Kind = switch rateLimit.status {
        case "rejected": .limitReached
        case "allowed_warning": .warning
        default: .usageUpdate
        }
        let percent = rateLimit.utilization.map { $0 <= 1 ? $0 * 100 : $0 }
        return QuotaSignal(
            providerId: .claudeCode, kind: kind,
            code: rateLimit.errorCode ?? rateLimit.rateLimitType ?? rateLimit.status,
            message: nil, resetsAt: rateLimit.resetsAt, usedPercent: percent
        )
    }

    // MARK: Approvals

    static func approvalRequest(id: String, request: JSONValue, now: Date) -> AgentApprovalRequest {
        let toolName = request["tool_name"]?.stringValue ?? "?"
        let input = request["input"] ?? .null
        let reason = request["decision_reason"]?.stringValue ?? request["description"]?.stringValue
        let decisions: [AgentApprovalDecision] = [.allow, .deny(message: nil), .cancel]
        switch toolName {
        case "Bash":
            let command = input["command"]?.stringValue
            return AgentApprovalRequest(
                id: ApprovalRequestID(id), kind: .commandExecution, summary: truncated("Befehl ausführen: \(command ?? "?")"),
                command: command, reason: reason ?? input["description"]?.stringValue,
                availableDecisions: decisions, receivedAt: now
            )
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue
            return AgentApprovalRequest(
                id: ApprovalRequestID(id), kind: .fileChange, summary: truncated("\(toolName): \(path ?? "?")"),
                reason: reason, filePaths: path.map { [$0] } ?? [], availableDecisions: decisions, receivedAt: now
            )
        default:
            return AgentApprovalRequest(
                id: ApprovalRequestID(id), kind: .toolUse(toolName), summary: truncated("Werkzeug \(toolName) verwenden"),
                reason: reason, availableDecisions: decisions, receivedAt: now
            )
        }
    }

    static func toolActivity(_ tool: ClaudeStreamMessage.ToolUse) -> ToolActivity {
        let input = tool.input
        switch tool.name {
        case "Bash":
            return ToolActivity(id: tool.id, kind: .command, summary: truncated(input["command"]?.stringValue ?? "Befehl"), phase: .started)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ToolActivity(id: tool.id, kind: .fileChange,
                                summary: truncated("\(tool.name): \(input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? "?")"),
                                phase: .started)
        case "WebSearch", "WebFetch":
            return ToolActivity(id: tool.id, kind: .webSearch,
                                summary: truncated(input["query"]?.stringValue ?? input["url"]?.stringValue ?? tool.name), phase: .started)
        default:
            let kind: ToolActivityKind = tool.name.hasPrefix("mcp__") ? .mcpTool : .other(tool.name)
            return ToolActivity(id: tool.id, kind: kind, summary: truncated(tool.name), phase: .started)
        }
    }
}
