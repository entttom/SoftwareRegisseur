import Foundation
import Testing
@testable import SoftwareRegisseurDomain

/// SR-SEC-08: a truncated approval preview can only be denied from synced devices.
@Suite("Approval preview truncation (security audit 2026-10-30)")
struct ApprovalTruncationTests {
    @Test func truncatedPreviewOffersOnlyDenyRemotely() throws {
        let approval = PendingApproval(
            jobId: JobID(), workItemId: WorkItemID(), hostId: HostID(), requestId: "r1", kind: .commandExecution,
            summary: "Befehl", preview: String(repeating: "a", count: 2_000), allowedDecisions: [.deny],
            requestedAt: referenceDate, previewFullLength: 5_000, allowRequiresHostReview: true)
        #expect(approval.isPreviewTruncated)
        #expect(approval.truncationNotice?.contains("gekürzt") == true)
        #expect(approval.hostReviewedDecisions == [.allow, .deny])
        let allow = ApprovalDecision(for: approval, decision: .allow, decidedBy: DeviceID(), at: referenceDate)
        #expect(!approval.accepts(allow, at: referenceDate))
        #expect(try JSONDecoder().decode(PendingApproval.self, from: JSONEncoder().encode(approval)) == approval)
    }

    @Test func truncatedPreviewRejectsAllowEvenWhenPayloadListsIt() {
        let approval = PendingApproval(
            jobId: JobID(), workItemId: WorkItemID(), hostId: HostID(), requestId: "r3", kind: .commandExecution,
            summary: "Befehl", preview: String(repeating: "a", count: 2_000), allowedDecisions: [.allow, .deny],
            requestedAt: referenceDate, previewFullLength: 5_000)
        #expect(approval.remoteDecisions == [.deny])
        let allow = ApprovalDecision(for: approval, decision: .allow, decidedBy: DeviceID(), at: referenceDate)
        #expect(!approval.accepts(allow, at: referenceDate))
        let deny = ApprovalDecision(for: approval, decision: .deny, decidedBy: DeviceID(), at: referenceDate)
        #expect(approval.accepts(deny, at: referenceDate))
    }

    @Test func olderPayloadWithoutTruncationFieldsDecodes() throws {
        let complete = PendingApproval(
            jobId: JobID(), workItemId: WorkItemID(), hostId: HostID(), requestId: "r2", kind: .commandExecution,
            summary: "Befehl", preview: "swift test", requestedAt: referenceDate)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as? [String: Any])
        object["previewFullLength"] = nil
        object["allowRequiresHostReview"] = nil
        let decoded = try JSONDecoder().decode(PendingApproval.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == complete)
        #expect(!decoded.isPreviewTruncated && decoded.truncationNotice == nil)
        #expect(decoded.hostReviewedDecisions == decoded.allowedDecisions)
    }
}
