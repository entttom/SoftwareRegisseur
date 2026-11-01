import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Agent approvals relayed by the Mac (spec J6 V1 fallback, L3): what the agent wants, a redacted preview
/// and explicit Allow/Deny. Nothing is ever answered automatically; the Mac forwards the decision.
struct ApprovalRows: View {
    @Environment(AppModel.self) private var model
    let items: [ApprovalItem]
    var onDecision: () -> Void = {}
    @State private var error: String?
    @State private var working: PendingApprovalID?

    var body: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(verbatim: item.approval.summary).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: item.approval.kind.symbol)
                }
                if let preview = item.approval.preview {
                    Text(verbatim: preview)
                        .font(.caption.monospaced())
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                // SR-SEC-08: a shortened preview may hide the dangerous part; say so before any button.
                if let notice = item.approval.truncationNotice {
                    Label {
                        Text(verbatim: notice)
                            .foregroundStyle(Color(.label))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("approval.truncationNotice.\(item.approval.requestId)")
                }
                if !item.approval.filePaths.isEmpty {
                    Text(verbatim: item.approval.filePaths.prefix(5).joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                stateText(item)
                let decisions = item.availableDecisions(at: .now)
                let allowOnlyOnHost = Self.allowRequiresHost(item.approval)
                if !decisions.isEmpty {
                    AdaptiveButtonRow {
                        if decisions.contains(.allow) || allowOnlyOnHost {
                            // Shown but disabled when the full request can only be checked on the Mac (SR-SEC-08).
                            Button("Erlauben") { Task { await decide(item, .allow) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(allowOnlyOnHost)
                                .accessibilityHint(allowOnlyOnHost ? Text("Vollständige Anfrage nur am Mac prüfbar") : Text(verbatim: ""))
                                .accessibilityIdentifier("approval.allow.\(item.approval.requestId)")
                        }
                        if decisions.contains(.deny) {
                            // Destructive tint on the background only: red text on light red failed the
                            // contrast audit (A29).
                            Button("Ablehnen", role: .destructive) { Task { await decide(item, .deny) } }
                                .buttonStyle(.bordered)
                                .foregroundStyle(Color(.label))
                                .accessibilityIdentifier("approval.deny.\(item.approval.requestId)")
                        }
                    }
                    .disabled(working != nil)
                    if allowOnlyOnHost {
                        Text("Vollständige Anfrage nur am Mac prüfbar – hier ist nur „Ablehnen“ möglich.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("approval.allowUnavailable.\(item.approval.requestId)")
                    }
                }
                if let error { ErrorText(message: error) }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func stateText(_ item: ApprovalItem) -> some View {
        switch item.displayState(at: .now) {
        case .awaitingDecision:
            // Orange symbol, text in the label colour (A29 contrast).
            if let expires = item.approval.expiresAt {
                StatusBadge(title: "Wartet auf Ihre Entscheidung – gültig bis \(expires.formatted(.dateTime.hour().minute()))",
                            symbol: "hourglass", tint: .orange)
            } else {
                StatusBadge(title: "Wartet auf Ihre Entscheidung", symbol: "hourglass", tint: .orange)
            }
        case let .decisionSent(decision):
            Text(decision == .allow ? "Erlaubt – der Mac übermittelt die Entscheidung, sobald er erreichbar ist."
                 : "Abgelehnt – der Mac übermittelt die Entscheidung, sobald er erreichbar ist.")
                .font(.caption).foregroundStyle(.secondary)
        case let .answered(decision):
            Text(decision == .allow ? "Erlaubt" : "Abgelehnt").font(.caption).foregroundStyle(.secondary)
        case let .closed(state):
            Text(state == .expired ? "Abgelaufen – eine Entscheidung hat keine Wirkung mehr."
                 : "Nicht mehr offen – die Agentensitzung wurde beendet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// „Erlauben“ is never offered on synced devices for a shortened preview, even if an older host still
    /// lists `allow` (SR-SEC-08); the Mac shows the full text and takes the decision there.
    static func allowRequiresHost(_ approval: PendingApproval) -> Bool {
        approval.isPreviewTruncated || approval.allowRequiresHostReview == true
    }

    private func decide(_ item: ApprovalItem, _ decision: ApprovalDecisionKind) async {
        guard let database = model.database else { return }
        if decision == .allow, Self.allowRequiresHost(item.approval) { return }
        working = item.id
        defer { working = nil }
        do {
            try await ApprovalCenter(approvals: database.approvals).decide(item, decision, device: model.deviceId, at: .now)
            error = nil
            onDecision()
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// Open approvals over all jobs (Agenten view).
struct OpenApprovalsSection: View {
    @Environment(AppModel.self) private var model
    @State private var items: [ApprovalItem] = []

    var body: some View {
        Section {
            if items.isEmpty {
                Text("Keine offenen Freigaben.").foregroundStyle(.secondary)
            } else {
                ApprovalRows(items: items) { Task { await load() } }
            }
        } header: {
            Text("Freigaben")
        } footer: {
            Text("Der Agent wartet am Mac. Ihre Entscheidung wird synchronisiert und vom Mac an den Agenten weitergegeben – nie automatisch.")
        }
        .reloadOnDataChange { await load() }
    }

    private func load() async {
        guard let database = model.database else { return }
        items = (try? await ApprovalCenter(approvals: database.approvals).openItems()) ?? []
    }
}

extension ApprovalRequestKind {
    var symbol: String {
        switch self {
        case .commandExecution: "terminal"
        case .fileChange: "doc.badge.ellipsis"
        case .permissions: "lock.open"
        case .toolUse: "wrench.and.screwdriver"
        }
    }
}
