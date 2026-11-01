import Foundation
import Testing
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// SR-SEC-08: Freigaben mit gekürzter Vorschau – „Erlauben“ erst nach Volltext und ausdrücklicher Bestätigung am Mac.
@MainActor
@Suite("Gekürzte Freigaben am Mac")
struct ApprovalReviewTests {
    static func approval(truncated: Bool) -> PendingApproval {
        PendingApproval(
            jobId: JobID(), workItemId: WorkItemID(), hostId: Fixture.hostId, requestId: "req-1", kind: .commandExecution,
            summary: "Befehl ausführen", preview: truncated ? String(repeating: "a", count: 20) : "make test",
            allowedDecisions: truncated ? [.deny] : [.allow, .deny], requestedAt: Fixture.now,
            previewFullLength: truncated ? 2_500 : nil, allowRequiresHostReview: truncated ? true : nil)
    }

    static func commands(fullText: String?) -> RecordingCommands {
        RecordingCommands { request in
            if case let .fullApprovalPreview(id) = request {
                return CommandOutcome(result: .approvalPreview(ApprovalPreviewInfo(
                    approvalId: id, fullText: fullText, shownLength: 20, fullLength: 2_500, allowRequiresHostReview: true,
                    detail: fullText == nil ? "Sitzung beendet." : nil)), feedback: .success("ok"))
            }
            return CommandOutcome(result: .done(nil), feedback: .success("ok"))
        }
    }

    @Test func allowNeedsLoadedFullTextAndConfirmation() async throws {
        let approval = Self.approval(truncated: true)
        let commands = Self.commands(fullText: String(repeating: "a", count: 2_480) + " && rm -rf ~")
        let model = ApprovalReviewModel(approval: approval, commands: commands)
        #expect(model.needsHostReview)
        #expect(model.truncationNotice?.contains("gekürzt") == true)
        #expect(model.offersAllow)
        #expect(!model.canAllow)
        #expect(model.allowRequest() == nil)

        // Ohne Volltext lässt sich nichts bestätigen.
        model.confirmedFullText = true
        #expect(!model.confirmedFullText)

        await model.loadFullText()
        guard case let .loaded(text) = model.fullText else {
            Issue.record("Volltext erwartet")
            return
        }
        #expect(text.hasSuffix("rm -rf ~"))
        #expect(!model.canAllow, "Erlauben erst nach ausdrücklicher Bestätigung")
        model.confirmedFullText = true
        #expect(model.canAllow)
        #expect(model.allowRequest() == .answerApprovalOnHost(approvalId: approval.id, decision: .allow, message: nil,
                                                             fullTextConfirmed: true))
        // Ablehnen bei gekürzter Vorschau über den Host-Weg, ohne Bestätigung.
        #expect(model.denyRequest(message: "  ") == .answerApprovalOnHost(approvalId: approval.id, decision: .deny, message: nil,
                                                                         fullTextConfirmed: false))
        #expect(commands.requests == [.fullApprovalPreview(approvalId: approval.id)])
    }

    @Test func withoutFullTextOnlyDenyRemains() async {
        let model = ApprovalReviewModel(approval: Self.approval(truncated: true), commands: Self.commands(fullText: nil))
        await model.loadFullText()
        #expect(model.fullText == .unavailable("Sitzung beendet."))
        model.confirmedFullText = true
        #expect(!model.canAllow)
        #expect(model.canDeny)
    }

    @Test func completePreviewKeepsTheDirectPath() {
        let approval = Self.approval(truncated: false)
        let model = ApprovalReviewModel(approval: approval, commands: Self.commands(fullText: nil))
        #expect(!model.needsHostReview)
        #expect(model.truncationNotice == nil)
        #expect(model.canAllow)
        #expect(model.allowRequest() == .answerApproval(approvalId: approval.id, decision: .allow, message: nil))
        #expect(model.denyRequest(message: "Nein") == .answerApproval(approvalId: approval.id, decision: .deny, message: "Nein"))
    }
}
