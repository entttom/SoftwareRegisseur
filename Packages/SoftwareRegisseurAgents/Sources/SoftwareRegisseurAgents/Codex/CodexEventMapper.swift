import Foundation
import SoftwareRegisseurDomain

/// Translates Codex app-server notifications and server requests into `AgentSessionEvent`s
/// (spike codex §2 „Streaming-Events“, §5 approvals, §7 quota). Pure state machine – no I/O.
struct CodexEventMapper: Sendable {
    enum TurnCompletion: Hashable, Sendable {
        case completed
        case interrupted
        case failed(code: String?, message: String)
    }

    struct Output: Sendable {
        var events: [AgentSessionEvent] = []
        var completion: TurnCompletion?
        /// The mapper saw a quota error; the session should read `account/rateLimits/read`.
        var quotaCode: String?
    }

    var threadId: String?
    var requestedModel: String?
    var requestedEffort: String?
    private(set) var lastAgentMessage: String?
    private(set) var lastQuotaSignal: QuotaSignal?
    private var fileChangePaths: [String: [String]] = [:]

    init(requestedModel: String?, requestedEffort: String?) {
        self.requestedModel = requestedModel
        self.requestedEffort = requestedEffort
    }

    // MARK: Notifications

    mutating func map(method: String, params: JSONValue?) -> Output {
        var output = Output()
        let params = params ?? .null
        if let threadId, let other = params["threadId"]?.stringValue, other != threadId { return output }

        switch method {
        case "turn/started":
            output.events.append(.status(.running))

        case "thread/status/changed":
            let status = params["status"]
            switch status?["type"]?.stringValue {
            case "active":
                let flags = status?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
                output.events.append(.status(flags.contains("waitingOnApproval") ? .waitingApproval : .running))
            case "idle": output.events.append(.status(.idle))
            case "systemError": output.events.append(.diagnostic("Codex meldet einen Systemfehler im Thread."))
            default: break
            }

        case "item/started", "item/completed":
            guard let item = params["item"] else { break }
            let completed = method == "item/completed"
            if let activity = toolActivity(item, completed: completed) {
                output.events.append(.toolActivity(activity))
            }
            if completed, item["type"]?.stringValue == "agentMessage", let text = item["text"]?.stringValue {
                lastAgentMessage = text
                output.events.append(.assistantText(text, isDelta: false))
            }

        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue {
                output.events.append(.assistantText(delta, isDelta: true))
            }

        case "thread/settings/updated":
            let settings = params["threadSettings"]
            let model = settings?["model"]?.stringValue
            let effort = settings?["effort"]?.stringValue
            output.events.append(.effectiveConfiguration(EffectiveConfiguration(
                model: model.flatMap(ModelID.init(rawValue:)),
                effort: effort.flatMap(EffortLevel.init(rawValue:)),
                source: .codexThreadSettingsUpdated,
                matchesRequest: matches(model: model, effort: effort),
                note: String(localized: "Konfigurierte Werte, keine Ausführungs-Telemetrie (Codex-Schema).", bundle: .module)
            )))

        case "model/rerouted":
            let toModel = params["toModel"]?.stringValue
            output.events.append(.effectiveConfiguration(EffectiveConfiguration(
                model: toModel.flatMap(ModelID.init(rawValue:)),
                effort: nil,
                source: .codexModelRerouted,
                matchesRequest: toModel == requestedModel,
                note: String(localized: "Codex hat von \(params["fromModel"]?.stringValue ?? "?") auf \(toModel ?? "?") umgeleitet", bundle: .module)
                    + (params["reason"]?.stringValue.map { " (\($0))" } ?? "") + "."
            )))

        case "account/rateLimits/updated":
            if let snapshot = params["rateLimits"] {
                output.events.append(.quota(CodexProtocol.quotaSignal(fromRateLimits: snapshot, kind: .usageUpdate, code: nil, message: nil)))
            }

        case "error":
            let error = params["error"]
            let code = CodexProtocol.errorCode(error?["codexErrorInfo"])
            let message = error?["message"]?.stringValue ?? "Unbekannter Fehler"
            let willRetry = params["willRetry"]?.boolValue ?? false
            if let code, CodexProtocol.quotaErrorCodes.contains(code) {
                let signal = QuotaSignal(providerId: .codex, kind: willRetry ? .retrying : .limitReached, code: code, message: message)
                if !willRetry {
                    lastQuotaSignal = signal
                    output.quotaCode = code
                }
                output.events.append(.quota(signal))
            } else {
                output.events.append(.diagnostic("Codex-Fehler\(code.map { " (\($0))" } ?? "")\(willRetry ? ", wird wiederholt" : ""): \(truncated(message))"))
            }

        case "warning":
            if let message = params["message"]?.stringValue ?? params["warning"]?.stringValue {
                output.events.append(.diagnostic("Codex-Warnung: \(truncated(message))"))
            }

        case "serverRequest/resolved":
            if let requestId = JSONRPCID(params["requestId"]) {
                output.events.append(.approvalResolved(ApprovalRequestID(requestId.description)))
            }

        case "turn/completed":
            let turn = params["turn"]
            switch turn?["status"]?.stringValue {
            case "completed":
                output.completion = .completed
            case "interrupted":
                output.completion = .interrupted
            default:
                let error = turn?["error"]
                let code = CodexProtocol.errorCode(error?["codexErrorInfo"])
                if let code, CodexProtocol.quotaErrorCodes.contains(code), lastQuotaSignal == nil {
                    lastQuotaSignal = QuotaSignal(providerId: .codex, kind: .limitReached, code: code, message: error?["message"]?.stringValue)
                    output.quotaCode = code
                }
                output.completion = .failed(code: code, message: error?["message"]?.stringValue ?? "Turn fehlgeschlagen")
            }

        default:
            break // Unknown/irrelevant notifications are tolerated (spike: „unbekannte Notifications ignorieren“).
        }
        return output
    }

    func matches(model: String?, effort: String?) -> Bool {
        (requestedModel == nil || model == requestedModel) && (requestedEffort == nil || effort == requestedEffort)
    }

    private mutating func toolActivity(_ item: JSONValue, completed: Bool) -> ToolActivity? {
        let id = item["id"]?.stringValue ?? UUID().uuidString
        let status = item["status"]?.stringValue
        let phase: ToolActivityPhase = switch (completed, status) {
        case (false, _): .started
        case (true, "failed"): .failed
        case (true, "declined"): .declined
        default: .completed
        }
        switch item["type"]?.stringValue {
        case "commandExecution":
            return ToolActivity(id: id, kind: .command, summary: truncated(item["command"]?.stringValue ?? "Befehl"), phase: phase)
        case "fileChange":
            let paths = item["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
            fileChangePaths[id] = paths
            return ToolActivity(id: id, kind: .fileChange, summary: truncated(paths.isEmpty ? "Dateiänderung" : paths.joined(separator: ", ")), phase: phase)
        case "mcpToolCall":
            let name = [item["server"]?.stringValue, item["tool"]?.stringValue].compactMap { $0 }.joined(separator: ".")
            return ToolActivity(id: id, kind: .mcpTool, summary: truncated(name), phase: phase)
        case "webSearch":
            return ToolActivity(id: id, kind: .webSearch, summary: truncated(item["query"]?.stringValue ?? "Websuche"), phase: phase)
        default:
            return nil
        }
    }

    // MARK: Server requests (approvals)

    static let approvalMethods: [String: ApprovalKind] = [
        "item/commandExecution/requestApproval": .commandExecution,
        "item/fileChange/requestApproval": .fileChange,
        "item/permissions/requestApproval": .permissions,
    ]

    func approvalRequest(id: JSONRPCID, method: String, params: JSONValue?, now: Date) -> AgentApprovalRequest? {
        guard let kind = Self.approvalMethods[method] else { return nil }
        let params = params ?? .null
        let reason = JSONValue.nonNull(params["reason"])?.stringValue
        let requestId = ApprovalRequestID(id.description)
        switch kind {
        case .commandExecution:
            let command = params["command"]?.stringValue
            return AgentApprovalRequest(
                id: requestId, kind: kind, summary: truncated("Befehl ausführen: \(command ?? "?")"),
                command: command, workingDirectory: params["cwd"]?.stringValue, reason: reason,
                availableDecisions: [.allow, .allowForSession, .deny(message: nil), .cancel], receivedAt: now
            )
        case .fileChange:
            let paths = params["itemId"]?.stringValue.flatMap { fileChangePaths[$0] } ?? []
            return AgentApprovalRequest(
                id: requestId, kind: kind,
                summary: truncated("Dateien ändern: \(paths.isEmpty ? (reason ?? "?") : paths.joined(separator: ", "))"),
                reason: reason, filePaths: paths,
                availableDecisions: [.allow, .allowForSession, .deny(message: nil), .cancel], receivedAt: now
            )
        default:
            let permissions = params["permissions"]
            var parts: [String] = []
            if JSONValue.nonNull(permissions?["network"]) != nil { parts.append("Netzwerk") }
            if JSONValue.nonNull(permissions?["fileSystem"]) != nil { parts.append("Dateisystem") }
            return AgentApprovalRequest(
                id: requestId, kind: kind,
                summary: truncated("Zusätzliche Berechtigungen: \(parts.isEmpty ? "?" : parts.joined(separator: ", "))"),
                workingDirectory: params["cwd"]?.stringValue, reason: reason,
                availableDecisions: [.allow, .allowForSession, .deny(message: nil)], receivedAt: now
            )
        }
    }

    /// Response payload for a user decision (schema `*RequestApprovalResponse`).
    static func approvalResponse(method: String, params: JSONValue?, decision: AgentApprovalDecision) throws -> JSONValue {
        switch approvalMethods[method] {
        case .commandExecution?, .fileChange?:
            let value: String = switch decision {
            case .allow: "accept"
            case .allowForSession: "acceptForSession"
            case .deny: "decline"
            case .cancel: "cancel"
            }
            return ["decision": .string(value)]
        case .permissions?:
            switch decision {
            case .allow, .allowForSession:
                var granted: [String: JSONValue] = [:]
                if let requested = params?["permissions"]?.objectValue {
                    for (key, value) in requested where !value.isNull { granted[key] = value }
                }
                return ["permissions": .object(granted), "scope": .string(decision == .allow ? "turn" : "session")]
            case .deny:
                return ["permissions": [:], "scope": "turn"]
            case .cancel:
                throw AgentSessionError.decisionNotSupported(decision)
            }
        default:
            throw AgentSessionError.decisionNotSupported(decision)
        }
    }
}
