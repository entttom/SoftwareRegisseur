import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// What the approval UI shows for one request (spec J6 V1 fallback: minimal approval UI, the Mac relays).
public enum ApprovalDisplayState: Hashable, Sendable {
    /// Waiting for a decision on any device.
    case awaitingDecision
    /// This device (or another) decided; the Mac has not relayed it yet (e.g. Mac offline).
    case decisionSent(ApprovalDecisionKind)
    case answered(ApprovalDecisionKind)
    /// Expired or withdrawn; a decision no longer has any effect.
    case closed(PendingApprovalState)
}

public struct ApprovalItem: Hashable, Sendable, Identifiable {
    public let approval: PendingApproval
    public let decisions: [ApprovalDecision]

    public var id: PendingApprovalID { approval.id }

    public func displayState(at date: Date) -> ApprovalDisplayState {
        switch approval.state {
        case .answered:
            return .answered(approval.decision ?? .deny)
        case .expired, .withdrawn:
            return .closed(approval.state)
        case .pending:
            if approval.isExpired(at: date) { return .closed(.expired) }
            if let sent = ApprovalDecision.firstApplicable(decisions, for: approval, at: date) { return .decisionSent(sent.decision) }
            return .awaitingDecision
        }
    }

    /// Buttons offered: only while undecided, never a default/automatic answer.
    public func availableDecisions(at date: Date) -> [ApprovalDecisionKind] {
        guard displayState(at: date) == .awaitingDecision else { return [] }
        return approval.remoteDecisions
    }
}

/// Loads approvals and records explicit user decisions (synced; the Mac host relays them).
public struct ApprovalCenter: Sendable {
    public let approvals: any ApprovalRepository

    public init(approvals: any ApprovalRepository) {
        self.approvals = approvals
    }

    /// Approvals of one job, newest first (open ones first).
    public func items(jobId: JobID) async throws -> [ApprovalItem] {
        var items: [ApprovalItem] = []
        for approval in try await approvals.approvals(jobId: jobId) {
            items.append(ApprovalItem(approval: approval, decisions: try await approvals.decisions(approvalId: approval.id)))
        }
        return items.sorted { lhs, rhs in
            if lhs.approval.isOpen != rhs.approval.isOpen { return lhs.approval.isOpen }
            return lhs.approval.requestedAt > rhs.approval.requestedAt
        }
    }

    /// All open approvals over all jobs (Agenten view badge/list).
    public func openItems() async throws -> [ApprovalItem] {
        var items: [ApprovalItem] = []
        for approval in try await approvals.openApprovals(hostId: nil) {
            items.append(ApprovalItem(approval: approval, decisions: try await approvals.decisions(approvalId: approval.id)))
        }
        return items
    }

    /// Explicit decision from this device. Refused for closed or expired requests and for decisions the
    /// agent does not offer; repeated taps return the first decision instead of sending a second one.
    @discardableResult
    public func decide(
        _ item: ApprovalItem, _ decision: ApprovalDecisionKind, device: DeviceID, message: String? = nil, at date: Date
    ) async throws -> ApprovalDecision {
        if let existing = ApprovalDecision.firstApplicable(item.decisions, for: item.approval, at: date) { return existing }
        guard item.availableDecisions(at: date).contains(decision) else {
            throw StoreError.approvalDecisionNotAllowed(item.approval.id, decision)
        }
        let record = ApprovalDecision(for: item.approval, decision: decision, decidedBy: device, at: date, message: message)
        try await approvals.recordDecision(record)
        return record
    }
}
