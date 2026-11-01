import Foundation
import SoftwareRegisseurDomain

/// Opaque, provider-native identifier of one pending approval (Codex JSON-RPC request id, Claude
/// control `request_id`).
public struct ApprovalRequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum ApprovalKind: Hashable, Sendable, Codable {
    /// Shell command (Codex `item/commandExecution/requestApproval`, Claude `Bash`).
    case commandExecution
    /// File edit (Codex `item/fileChange/requestApproval`, Claude `Edit`/`Write`).
    case fileChange
    /// Extra sandbox permissions (Codex `item/permissions/requestApproval`).
    case permissions
    /// Any other tool use (Claude `can_use_tool` for non-shell/non-edit tools).
    case toolUse(String)
}

/// A decision the user made on Mac or iPhone, as sent to the agent. The adapters never decide
/// themselves (spec L3). (Renamed from `ApprovalDecision`; the synced user decision is the Domain
/// `ApprovalDecision`.)
public enum AgentApprovalDecision: Hashable, Sendable, Codable {
    case allow
    /// Allow this and identical requests for the rest of the session (Codex only).
    case allowForSession
    case deny(message: String?)
    /// Deny and stop the current turn.
    case cancel
}

/// Approval forwarded to the user (spec J4, L3). Content fields are display data from the agent.
public struct AgentApprovalRequest: Hashable, Sendable {
    public let id: ApprovalRequestID
    public let kind: ApprovalKind
    /// Short, bounded, human-readable description.
    public let summary: String
    public let command: String?
    public let workingDirectory: String?
    public let reason: String?
    public let filePaths: [String]
    /// Decisions this provider can actually transport.
    public let availableDecisions: [AgentApprovalDecision]
    public let receivedAt: Date

    public init(
        id: ApprovalRequestID, kind: ApprovalKind, summary: String, command: String? = nil,
        workingDirectory: String? = nil, reason: String? = nil, filePaths: [String] = [],
        availableDecisions: [AgentApprovalDecision], receivedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.command = command
        self.workingDirectory = workingDirectory
        self.reason = reason
        self.filePaths = filePaths
        self.availableDecisions = availableDecisions
        self.receivedAt = receivedAt
    }
}

/// Provider-reported quota/rate-limit signal (spec K2). `resetsAt` is only set when the provider
/// explicitly reports it and must be shown as „vom Anbieter gemeldet“, never as a guarantee.
public struct QuotaSignal: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Limit reached; the job should go to `waiting_quota`.
        case limitReached
        /// Approaching a limit (Claude `allowed_warning`).
        case warning
        /// Provider retries on its own after a rate-limit response (Claude `api_retry`, Codex `willRetry`).
        case retrying
        /// Informational usage snapshot (Codex `account/rateLimits/*`).
        case usageUpdate
    }

    public let providerId: ProviderID
    public let kind: Kind
    /// Provider-native code, e.g. `usageLimitExceeded`, `rate_limit`, `rejected`.
    public let code: String?
    public let message: String?
    public let resetsAt: Date?
    /// Used fraction 0…100 when reported.
    public let usedPercent: Double?
    /// Explicit provider retry delay (Claude `retry_delay_ms`). Codex has none (spike §7).
    public let retryAfter: Duration?

    public init(
        providerId: ProviderID, kind: Kind, code: String? = nil, message: String? = nil, resetsAt: Date? = nil,
        usedPercent: Double? = nil, retryAfter: Duration? = nil
    ) {
        self.providerId = providerId
        self.kind = kind
        self.code = code
        self.message = message
        self.resetsAt = resetsAt
        self.usedPercent = usedPercent
        self.retryAfter = retryAfter
    }
}

/// Where an effective-value report came from (ADR-0006: show as confirmed only when reported).
public enum EffectiveConfigurationSource: String, Hashable, Sendable {
    /// Codex `thread/start` response (configured values; not per-turn telemetry, spike §4).
    case codexThreadStartResponse
    /// Codex `thread/settings/updated` notification.
    case codexThreadSettingsUpdated
    /// Codex `model/rerouted` notification (server-side reroute).
    case codexModelRerouted
    /// Claude Code `system/init.model`. Effort is never confirmed headless (spike 5c).
    case claudeSystemInit
}

public struct EffectiveConfiguration: Hashable, Sendable {
    public let model: ModelID?
    /// `nil` = „nicht bestätigt“.
    public let effort: EffortLevel?
    public let source: EffectiveConfigurationSource
    /// False when the agent reports something other than what was requested (e.g. reroute).
    public let matchesRequest: Bool
    public let note: String?

    public init(model: ModelID?, effort: EffortLevel?, source: EffectiveConfigurationSource, matchesRequest: Bool, note: String? = nil) {
        self.model = model
        self.effort = effort
        self.source = source
        self.matchesRequest = matchesRequest
        self.note = note
    }
}

public enum AgentSessionStatus: String, Hashable, Sendable {
    case starting
    case running
    case waitingApproval
    case idle
}

public enum ToolActivityKind: Hashable, Sendable {
    case command
    case fileChange
    case mcpTool
    case webSearch
    case other(String)
}

public enum ToolActivityPhase: String, Hashable, Sendable {
    case started, completed, failed, declined
}

/// Bounded summary of one tool action for status displays (not a full transcript).
public struct ToolActivity: Hashable, Sendable {
    public let id: String
    public let kind: ToolActivityKind
    public let summary: String
    public let phase: ToolActivityPhase

    public init(id: String, kind: ToolActivityKind, summary: String, phase: ToolActivityPhase) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.phase = phase
    }
}

public enum AgentFailure: Hashable, Sendable, CustomStringConvertible {
    /// The agent process ended before reporting a result (crash, kill).
    case processEnded(exitStatus: Int32?, signal: Int32?, stderrTail: String)
    /// Unexpected or undecodable protocol data.
    case protocolViolation(String)
    /// The agent reported an error for the turn.
    case agentError(code: String?, message: String)
    /// The agent did not confirm the explicitly set safety/model parameters; the run was aborted.
    case startParameterMismatch(String)
    case startFailed(String)

    public var description: String {
        switch self {
        case let .processEnded(status, signal, tail):
            String(localized: "Agentenprozess unerwartet beendet (Exit \(status.map(String.init) ?? "–"), Signal \(signal.map(String.init) ?? "–")). \(tail)", bundle: .module)
        case let .protocolViolation(message): "Protokollfehler: \(message)"
        case let .agentError(code, message): "Agentenfehler\(code.map { " (\($0))" } ?? ""): \(message)"
        case let .startParameterMismatch(message): String(localized: "Startparameter nicht bestätigt: \(message)", bundle: .module)
        case let .startFailed(message): String(localized: "Start fehlgeschlagen: \(message)", bundle: .module)
        }
    }
}

public struct AgentSessionResult: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case completed
        case failed(AgentFailure)
        case cancelled
        /// Provider limit reached; job keeps its data and waits (spec K2).
        case quotaExhausted(QuotaSignal)
    }

    public let outcome: Outcome
    public let finalMessage: String?
    public let sessionId: String?
    /// Tools the agent was not allowed to use (Claude `permission_denials`).
    public let permissionDenials: [String]

    public init(outcome: Outcome, finalMessage: String?, sessionId: String?, permissionDenials: [String] = []) {
        self.outcome = outcome
        self.finalMessage = finalMessage
        self.sessionId = sessionId
        self.permissionDenials = permissionDenials
    }

    /// Job state the host should move to (ADR-0012). `finished` still needs diff/test capture.
    public var suggestedJobState: AgentJobState {
        switch outcome {
        case .completed: .finished
        case .failed: .failed
        case .cancelled: .cancelled
        case .quotaExhausted: .waitingQuota
        }
    }
}

/// Everything a running session reports. `.finished` is always the last event.
public enum AgentSessionEvent: Hashable, Sendable {
    /// Provider session identity: Claude `session_id`; Codex `thread.sessionId` + `thread.id`.
    case sessionIdentified(sessionId: String, threadId: String?)
    case status(AgentSessionStatus)
    case assistantText(String, isDelta: Bool)
    case toolActivity(ToolActivity)
    case approvalRequested(AgentApprovalRequest)
    case approvalResolved(ApprovalRequestID)
    case quota(QuotaSignal)
    case effectiveConfiguration(EffectiveConfiguration)
    /// Redacted warnings/diagnostics (stderr, agent warnings).
    case diagnostic(String)
    case finished(AgentSessionResult)
}
