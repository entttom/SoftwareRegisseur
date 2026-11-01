import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Warteschlange mit aktiven, geplanten, pausierten und fehlgeschlagenen Jobs (K1–K3, P macOS 5),
/// offenen Freigaben (L3) und Steueraktionen über den Dienst.
struct QueueView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @State private var showNewJob = false

    var body: some View {
        @Bindable var navigation = navigation
        LibraryGate {
            VStack(spacing: 0) {
                if !library.snapshot.openApprovals.isEmpty {
                    OpenApprovalsPanel(approvals: library.snapshot.openApprovals)
                    Divider()
                }
                HStack {
                    AdaptivePicker("Filter", selection: $navigation.queueFilter) {
                        ForEach(QueueFilter.allCases) { filter in
                            Text("\(filter.title) (\(filter.apply(to: library.snapshot.jobs).count))").tag(filter)
                        }
                    }
                    if let provider = navigation.queueProvider {
                        Button {
                            navigation.queueProvider = nil
                        } label: {
                            Label("Nur \(ProviderNames.displayName(provider))", systemImage: "xmark.circle")
                        }
                        .help(Text("Agentenfilter entfernen"))
                    }
                    Spacer()
                }
                .padding(10)
                HSplitView {
                    JobTable(jobs: navigation.queueFilter.apply(to: library.snapshot.jobs, provider: navigation.queueProvider),
                             selection: $navigation.selectedJob)
                        .frame(minWidth: 360, idealWidth: 700)
                    Group {
                        if let id = navigation.selectedJob, let job = library.snapshot.job(id) {
                            JobDetailView(job: job).id(id)
                        } else {
                            ContentUnavailableView("Job auswählen", systemImage: "clock",
                                                   description: Text("Details, Zeitplan, Modell/Stufe und Steueraktionen erscheinen hier."))
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
                .splitViewMinimum(width: 360 + 300)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showNewJob = true
                } label: {
                    Label("Job starten oder planen …", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewJob) {
            NewJobSheet()
        }
    }
}

private struct JobTable: View {
    @Environment(LibraryStore.self) private var library
    let jobs: [AgentJob]
    @Binding var selection: JobID?

    var body: some View {
        let snapshot = library.snapshot
        let hostSeen = snapshot.hosts.map(\.lastSeen).max()
        Table(jobs, selection: $selection) {
            TableColumn("Aufgabe") { job in
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.workItem(job.workItemId)?.displayTitle ?? job.workItemId.shortString).lineLimit(1)
                    Text(snapshot.projectName(job.projectId)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Agent") { job in Text(ProviderNames.displayName(job.providerId)).lineLimit(1) }
                .width(min: 70, ideal: 95)
            TableColumn("Zustand") { job in
                Text(job.state.germanDisplayName).foregroundStyle(job.state.level.color).lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Plan") { job in
                Text(JobScheduleText.text(for: job, hostLastSeen: hostSeen, now: .now)).lineLimit(2)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Priorität") { job in Text(job.priority.germanDisplayName) }
                .width(min: 60, ideal: 70)
        }
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView("Keine Jobs in dieser Ansicht", systemImage: "tray")
            }
        }
    }
}

/// Offene Freigabeanfragen der Agenten: nur ausdrückliche Antworten, nie automatisch (L3).
struct OpenApprovalsPanel: View {
    let approvals: [PendingApproval]

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(approvals) { approval in
                ApprovalCard(approval: approval)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Offene Freigaben (\(approvals.count))", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ViewThatFits(in: .vertical) {
                cards
                ScrollView { cards }
            }
        }
        .padding(10)
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ApprovalCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    let approval: PendingApproval
    @State private var denyMessage = ""
    @State private var review: ApprovalReviewModel?

    var body: some View {
        let snapshot = library.snapshot
        // Bis `.task` den Zustand angelegt hat (oder in Vorschauen ohne Tasks): zustandsloses Modell, Erlauben dann
        // bei gekürzter Vorschau deaktiviert.
        let model = review ?? ApprovalReviewModel(approval: approval, commands: commands)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(approval.kind.displayName).font(.headline)
                if let tool = approval.toolName { Badge(text: tool) }
                Spacer()
                Text(snapshot.workItem(approval.workItemId)?.displayTitle ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Text(approval.summary).fixedSize(horizontal: false, vertical: true)
            if let preview = approval.preview {
                Text(verbatim: preview)
                    .font(.system(.callout, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            truncatedSection(model)
            if !approval.filePaths.isEmpty {
                Text(verbatim: approval.filePaths.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
            }
            if let reason = approval.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text("Angefragt \(approval.requestedAt.shortDateTime)").font(.caption).foregroundStyle(.secondary)
                if let expires = approval.expiresAt {
                    Text("· gültig bis \(expires.shortDateTime)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                if model.canDeny {
                    TextField("Begründung bei Ablehnung (optional)", text: $denyMessage)
                        .textFieldStyle(.roundedBorder)
                    CommandButton(String(localized: "Ablehnen"), systemImage: "xmark", role: .destructive) {
                        model.denyRequest(message: denyMessage)
                    }
                }
                if model.offersAllow {
                    CommandButton(String(localized: "Erlauben"), systemImage: "checkmark",
                                  confirmation: String(localized: "Der Agent führt die angefragte Aktion aus.")) {
                        // Deaktiviert, solange `allowRequest()` nil ist; Fallback lehnt nie still ab.
                        model.allowRequest() ?? .fullApprovalPreview(approvalId: approval.id)
                    }
                    .disabled(!model.canAllow)
                }
            }
        }
        .task(id: approval) {
            if self.review?.approval != approval { self.review = ApprovalReviewModel(approval: approval, commands: commands) }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// SR-SEC-08: gekürzte Vorschau – Hinweis, Volltext und Bestätigung, bevor „Erlauben“ aktiv wird.
    @ViewBuilder
    private func truncatedSection(_ review: ApprovalReviewModel) -> some View {
        if let notice = review.truncationNotice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if review.needsHostReview {
            switch review.fullText {
            case .notLoaded:
                Button("Vollständigen Text anzeigen") { Task { await review.loadFullText() } }
            case .loading:
                ProgressView().controlSize(.small)
            case let .loaded(text):
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                Toggle("Ich habe den vollständigen Text gelesen.", isOn: Binding(
                    get: { review.confirmedFullText }, set: { review.confirmedFullText = $0 }))
            case let .unavailable(message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
