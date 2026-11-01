import Foundation

// Approvals over sync (spec J6 V1 fallback, L3, M2). The Mac host records what the agent wants as a
// `PendingApproval`; any user device answers with an `ApprovalDecision`; the Mac relays the decision
// to the agent session. Nothing ever answers an approval automatically.

public typealias PendingApprovalID = Identifier<PendingApproval>
public typealias ApprovalDecisionID = Identifier<ApprovalDecision>

/// What the agent asks for (provider-independent).
public enum ApprovalRequestKind: String, Hashable, Sendable, Codable, CaseIterable {
    case commandExecution
    case fileChange
    case permissions
    case toolUse
}

/// The two answers a user device can send (spec J6: minimal approval UI).
public enum ApprovalDecisionKind: String, Hashable, Sendable, Codable, CaseIterable {
    case allow
    case deny
}

public enum PendingApprovalState: String, Hashable, Sendable, Codable, CaseIterable {
    /// Waiting for an explicit user decision.
    case pending
    /// A user decision was relayed to the agent.
    case answered
    /// Not answered in time; later decisions are ignored.
    case expired
    /// The session ended or the agent withdrew the request; later decisions are ignored.
    case withdrawn

    public var isOpen: Bool { self == .pending }
}

/// An approval request of a running agent, mirrored by the Mac host (owner of its state, spec N2).
/// `summary` is German; `preview` is the command/tool preview after secret redaction (spec Q1) and
/// never contains unredacted process environments.
public struct PendingApproval: Hashable, Sendable, Codable, Identifiable {
    public let id: PendingApprovalID
    public let jobId: JobID
    public let workItemId: WorkItemID
    public let hostId: HostID
    /// Agent-side request identifier (opaque, provider-specific).
    public let requestId: String
    public let kind: ApprovalRequestKind
    /// Tool name for `toolUse` requests.
    public let toolName: String?
    /// German description of what the agent wants.
    public let summary: String
    /// Redacted command/tool preview.
    public let preview: String?
    public let filePaths: [String]
    public let reason: String?
    /// Decisions a synced user device (iPhone, iPad, Mac UI via sync) may send for this request. When the
    /// preview was truncated, `allow` is not offered here (SR-SEC-08): the visible text would not show the
    /// whole command, so approving it remotely could hide its dangerous part.
    public let allowedDecisions: [ApprovalDecisionKind]
    /// Length (characters) of the full redacted preview when `preview` is a truncated prefix of it; nil
    /// when the preview is complete. Absent in older payloads.
    public let previewFullLength: Int?
    /// true: `allow` is possible only on the execution host after the full text was shown there and the
    /// user explicitly confirmed having read it (SR-SEC-08). Absent in older payloads (= false).
    public let allowRequiresHostReview: Bool?
    public let requestedAt: Date
    /// After this instant decisions are ignored (nil: answerable until the session ends).
    public let expiresAt: Date?
    public private(set) var state: PendingApprovalState
    /// Approval timeout reached while the job stays answerable (pause policy).
    public private(set) var timedOutAt: Date?
    public private(set) var decisionId: ApprovalDecisionID?
    public private(set) var decision: ApprovalDecisionKind?
    public private(set) var resolvedAt: Date?
    public private(set) var revision: Int
    public private(set) var updatedAt: Date

    public init(
        id: PendingApprovalID = PendingApprovalID(),
        jobId: JobID,
        workItemId: WorkItemID,
        hostId: HostID,
        requestId: String,
        kind: ApprovalRequestKind,
        toolName: String? = nil,
        summary: String,
        preview: String? = nil,
        filePaths: [String] = [],
        reason: String? = nil,
        allowedDecisions: [ApprovalDecisionKind] = ApprovalDecisionKind.allCases,
        requestedAt: Date,
        expiresAt: Date? = nil,
        previewFullLength: Int? = nil,
        allowRequiresHostReview: Bool? = nil
    ) {
        self.id = id
        self.jobId = jobId
        self.workItemId = workItemId
        self.hostId = hostId
        self.requestId = requestId
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.preview = preview
        self.filePaths = filePaths
        self.reason = reason
        self.allowedDecisions = allowedDecisions
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.previewFullLength = previewFullLength
        self.allowRequiresHostReview = allowRequiresHostReview
        state = .pending
        revision = 1
        updatedAt = requestedAt
    }

    public var isOpen: Bool { state.isOpen }

    /// The preview shows only the beginning of the request (SR-SEC-08).
    public var isPreviewTruncated: Bool {
        guard let previewFullLength else { return false }
        return previewFullLength > (preview?.count ?? 0)
    }

    /// German notice for every UI that shows a truncated preview (SR-SEC-08).
    public var truncationNotice: String? {
        guard isPreviewTruncated, let previewFullLength else { return nil }
        let shown = preview?.count ?? 0
        return String(localized: "Vorschau gekürzt: \(shown) von \(previewFullLength) Zeichen sichtbar. Erlauben ist nur am Mac möglich, nachdem der vollständige Text dort angezeigt und bestätigt wurde; hier kann nur abgelehnt werden.", bundle: .module)
    }

    /// Decisions a synced device may send: `allowedDecisions` without `allow` while the preview is
    /// truncated, also when an older or altered payload still lists it (SR-SEC-08).
    public var remoteDecisions: [ApprovalDecisionKind] {
        guard isPreviewTruncated else { return allowedDecisions }
        return allowedDecisions.filter { $0 != .allow }
    }

    /// Decisions the execution host may relay after an explicit, local confirmation that the full text
    /// was read (SR-SEC-08): `allowedDecisions` plus `allow` when it was withheld only because of truncation.
    public var hostReviewedDecisions: [ApprovalDecisionKind] {
        guard allowRequiresHostReview == true, !allowedDecisions.contains(.allow) else { return allowedDecisions }
        return [.allow] + allowedDecisions
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    /// Whether `decision` may still be applied: open, not expired, explicitly allowed (spec L3).
    public func accepts(_ decision: ApprovalDecision, at date: Date) -> Bool {
        decision.approvalId == id && decision.jobId == jobId && isOpen && !isExpired(at: decision.decidedAt)
            && !isExpired(at: date) && remoteDecisions.contains(decision.decision)
    }

    public mutating func recordAnswer(_ decision: ApprovalDecision, at date: Date) {
        guard isOpen else { return }
        state = .answered
        decisionId = decision.id
        self.decision = decision.decision
        resolvedAt = date
        touch(at: date)
    }

    public mutating func markTimedOut(at date: Date) {
        guard isOpen, timedOutAt == nil else { return }
        timedOutAt = date
        touch(at: date)
    }

    public mutating func expire(at date: Date) {
        guard isOpen else { return }
        state = .expired
        resolvedAt = date
        touch(at: date)
    }

    public mutating func withdraw(at date: Date) {
        guard isOpen else { return }
        state = .withdrawn
        resolvedAt = date
        touch(at: date)
    }

    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = max(updatedAt, date)
    }
}

/// An explicit user decision for one `PendingApproval`, created on any user device (iPhone or Mac UI).
/// Immutable once written; the host consumes it exactly once (idempotent per approval).
public struct ApprovalDecision: Hashable, Sendable, Codable, Identifiable {
    public let id: ApprovalDecisionID
    public let approvalId: PendingApprovalID
    public let jobId: JobID
    public let decision: ApprovalDecisionKind
    /// User device that decided (spec M2: beteiligtes Gerät).
    public let decidedBy: DeviceID
    public let decidedAt: Date
    /// Optional note for a denial (sent to the agent where supported).
    public let message: String?

    public init(
        id: ApprovalDecisionID = ApprovalDecisionID(),
        approvalId: PendingApprovalID,
        jobId: JobID,
        decision: ApprovalDecisionKind,
        decidedBy: DeviceID,
        decidedAt: Date,
        message: String? = nil
    ) {
        self.id = id
        self.approvalId = approvalId
        self.jobId = jobId
        self.decision = decision
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.message = message
    }

    public init(for approval: PendingApproval, decision: ApprovalDecisionKind, decidedBy: DeviceID, at date: Date, message: String? = nil) {
        self.init(approvalId: approval.id, jobId: approval.jobId, decision: decision, decidedBy: decidedBy, decidedAt: date, message: message)
    }

    public var actor: EventActor { .user(decidedBy) }

    /// First applicable decision for `approval` (earliest `decidedAt`, then ID); nil if none applies.
    public static func firstApplicable(_ decisions: [ApprovalDecision], for approval: PendingApproval, at date: Date) -> ApprovalDecision? {
        decisions
            .sorted { ($0.decidedAt, $0.id.uuidString) < ($1.decidedAt, $1.id.uuidString) }
            .first { approval.accepts($0, at: date) }
    }
}
