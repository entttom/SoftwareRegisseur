import Foundation
import Observation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Freigabe mit gekürzter Vorschau am Mac (SR-SEC-08). Die synchronisierte Vorschau zeigt nur den Anfang; „Erlauben“
/// wird erst aktiv, nachdem der Dienst den vollständigen Text geliefert hat, dieser angezeigt wurde und der Benutzer das
/// Lesen ausdrücklich bestätigt hat. Ablehnen ist immer möglich. Nie automatisch (L3).
@MainActor
@Observable
final class ApprovalReviewModel {
    enum FullTextState: Equatable {
        case notLoaded
        case loading
        case loaded(String)
        /// Kein Volltext verfügbar (z. B. Sitzung beendet) – nur Ablehnen.
        case unavailable(String)
    }

    let approval: PendingApproval
    private(set) var fullText: FullTextState = .notLoaded
    /// „Ich habe den vollständigen Text gelesen“ – nur nach angezeigtem Volltext setzbar.
    var confirmedFullText: Bool {
        get { confirmation }
        set {
            if case .loaded = fullText { confirmation = newValue } else { confirmation = false }
        }
    }
    private var confirmation = false

    @ObservationIgnored private let commands: any ServiceCommandPerforming

    init(approval: PendingApproval, commands: any ServiceCommandPerforming) {
        self.approval = approval
        self.commands = commands
    }

    /// Erlauben nur am Mac nach Prüfung des Volltexts.
    var needsHostReview: Bool { approval.allowRequiresHostReview == true && !approval.allowedDecisions.contains(.allow) }

    var truncationNotice: String? { approval.truncationNotice }

    var canDeny: Bool { approval.allowedDecisions.isEmpty || approval.allowedDecisions.contains(.deny) }

    /// Erlauben wird angeboten (ggf. noch deaktiviert, bis der Volltext bestätigt ist).
    var offersAllow: Bool { approval.hostReviewedDecisions.contains(.allow) }

    var canAllow: Bool {
        guard offersAllow else { return false }
        guard needsHostReview else { return true }
        if case .loaded = fullText { return confirmedFullText }
        return false
    }

    func loadFullText() async {
        guard fullText != .loading else { return }
        fullText = .loading
        confirmation = false
        let outcome = await commands.perform(String(localized: "Vollständigen Text laden"),
                                             .fullApprovalPreview(approvalId: approval.id), quiet: true)
        if case let .approvalPreview(info)? = outcome.result {
            if let text = info.fullText {
                fullText = .loaded(text)
            } else {
                fullText = .unavailable(info.detail ?? String(localized: "Der vollständige Text ist nicht verfügbar. Bitte ablehnen."))
            }
        } else {
            fullText = .unavailable(outcome.feedback.message)
        }
    }

    /// Befehl für „Erlauben“; `nil`, solange die Bedingungen fehlen.
    func allowRequest() -> ServiceRequest? {
        guard canAllow else { return nil }
        if needsHostReview {
            return .answerApprovalOnHost(approvalId: approval.id, decision: .allow, message: nil, fullTextConfirmed: true)
        }
        return .answerApproval(approvalId: approval.id, decision: .allow, message: nil)
    }

    /// Befehl für „Ablehnen“ (bei gekürzter Vorschau direkt über den Host-Weg).
    func denyRequest(message: String) -> ServiceRequest {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String? = trimmed.isEmpty ? nil : trimmed
        if approval.allowRequiresHostReview == true {
            return .answerApprovalOnHost(approvalId: approval.id, decision: .deny, message: text, fullTextConfirmed: false)
        }
        return .answerApproval(approvalId: approval.id, decision: .deny, message: text)
    }
}
