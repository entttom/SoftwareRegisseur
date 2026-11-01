import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Review, Worktree, Diff und Tests (M1, P macOS 7). Entscheidungen nur durch ausdrückliche Aktionen;
/// integriert wird mit der Projektstrategie (Standard Squash, ADR-0015), nie gepusht.
struct ReviewListView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case open, all
        var id: Self { self }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @State private var scope: Scope = .open

    var body: some View {
        @Bindable var navigation = navigation
        LibraryGate {
            HSplitView {
                VStack(spacing: 0) {
                    Picker("Anzeige", selection: $scope) {
                        Text("Offen (\(library.snapshot.pendingReviews.count))").tag(Scope.open)
                        Text("Alle").tag(Scope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    List(selection: $navigation.selectedReview) {
                        ForEach(reviews) { review in
                            ReviewRow(review: review).tag(review.reviewId)
                        }
                    }
                    .overlay {
                        if reviews.isEmpty {
                            ContentUnavailableView("Keine Reviews", systemImage: "eye",
                                                   description: Text("Nach Abschluss eines Agentenjobs erscheinen hier Diff, Commits und Tests."))
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 340, maxWidth: 460)
                Group {
                    if let id = navigation.selectedReview, let review = library.snapshot.reviews.first(where: { $0.reviewId == id }) {
                        ReviewDetailView(review: review).id(id)
                    } else {
                        ContentUnavailableView("Review auswählen", systemImage: "eye")
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            .splitViewMinimum(width: 240 + 320)
        }
    }

    private var reviews: [Review] {
        let snapshot = library.snapshot
        let list = scope == .open ? snapshot.pendingReviews : snapshot.reviews
        return list.sorted { lhs, rhs in
            let left = snapshot.job(lhs.jobId)?.finishedAt ?? .distantPast
            let right = snapshot.job(rhs.jobId)?.finishedAt ?? .distantPast
            return left > right
        }
    }
}

private struct ReviewRow: View {
    @Environment(LibraryStore.self) private var library
    let review: Review

    var body: some View {
        let snapshot = library.snapshot
        let job = snapshot.job(review.jobId)
        let tests = review.effectiveTestSummary
        VStack(alignment: .leading, spacing: 3) {
            Text(job.flatMap { snapshot.workItem($0.workItemId)?.displayTitle } ?? String(localized: "Unbekannte Aufgabe"))
                .font(.headline).lineLimit(2)
            HStack(spacing: 4) {
                Badge(text: review.decision.displayName, color: decisionColor)
                if review.integrationCommit != nil { Badge(text: String(localized: "integriert"), color: .green) }
                if review.conflict != nil { Badge(text: String(localized: "Konflikt"), color: .red) }
                if tests.total > 0 {
                    Badge(text: String(localized: "Tests \(tests.passed)/\(tests.total)"), color: tests.hasFailures ? .red : .green)
                }
            }
            Text("\(job.map { ProviderNames.displayName($0.providerId) } ?? "") · \(review.diffSummary.filesChanged) Dateien · +\(review.diffSummary.insertions) −\(review.diffSummary.deletions)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var decisionColor: Color {
        switch review.decision {
        case .pending: .orange
        case .approved: .green
        case .changesRequested: .blue
        case .rejected: .red
        }
    }
}

struct ReviewDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @Environment(NavigationModel.self) private var navigation
    let review: Review
    @State private var details: ReviewDetailsInfo?
    @State private var detailsError: String?
    @State private var selectedFile: String?
    @State private var diffText: String?
    @State private var diffError: String?

    var body: some View {
        let snapshot = library.snapshot
        let job = snapshot.job(review.jobId)
        let item = job.flatMap { snapshot.workItem($0.workItemId) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(item: item, job: job)
                decisionBar(item: item, job: job, snapshot: snapshot)
                if let summary = review.summary ?? details?.agentSummary, !summary.isEmpty {
                    GroupBox { MarkdownPreview(text: summary) } label: { Text("Zusammenfassung des Agenten") }
                }
                conflictSection
                GroupBox { testSection } label: { Text("Tests") }
                GroupBox { filesSection } label: { Text("Geänderte Dateien") }
                GroupBox { commitsSection } label: { Text("Commits") }
                notesSection
                GroupBox { worktreeSection(job: job) } label: { Text("Branch und Worktree") }
            }
            .padding(16)
        }
        .task(id: review.reviewId) { await loadDetails() }
    }

    private func header(item: WorkItem?, job: AgentJob?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item {
                Button { navigation.showWorkItem(item) } label: { Text(item.displayTitle).font(.title2.bold()) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Öffnet die Aufgabe"))
            }
            FlowLayout(spacing: 6) {
                Badge(text: review.decision.displayName)
                if let item { Badge(text: item.status.germanDisplayName, color: item.status.level.color) }
            }
            // Eigene Zeile: neben den Plaketten wurde der Text in schmalen Spalten silbenweise umbrochen.
            if let job { Text("\(ProviderNames.displayName(job.providerId)) · \(JobConfigurationText(job: job).resolved)").foregroundStyle(.secondary) }
            Text("\(review.diffSummary.filesChanged) Dateien · +\(review.diffSummary.insertions) −\(review.diffSummary.deletions)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func decisionBar(item: WorkItem?, job: AgentJob?, snapshot: LibrarySnapshot) -> some View {
        let strategy = snapshot.project(job?.projectId)?.settings?.integrationStrategy ?? .default
        VStack(alignment: .leading, spacing: 8) {
            // Umbrechend: in der schmalen Detailspalte wurden die Entscheidungen sonst zu „Freige…“ gekürzt.
            FlowLayout(spacing: 6) {
                if review.decision == .pending {
                    CommandButton(String(localized: "Freigeben"), systemImage: "checkmark.seal") { .approveReview(reviewId: review.reviewId) }
                    CommandButton(String(localized: "Änderungen anfordern"), systemImage: "arrow.uturn.backward") {
                        .requestChanges(reviewId: review.reviewId)
                    }
                    CommandButton(String(localized: "Ablehnen"), systemImage: "xmark", role: .destructive,
                                  confirmation: String(localized: "Das Review wird abgelehnt. Der Branch bleibt erhalten.")) {
                        .rejectReview(reviewId: review.reviewId)
                    }
                }
                if review.decision == .approved && review.integrationCommit == nil {
                    CommandButton(String(localized: "Integrieren (\(strategy.displayName))"), systemImage: "arrow.triangle.merge",
                                  confirmation: String(localized: "Die Änderungen werden per \(strategy.displayName) in den Default-Branch übernommen. Es wird nichts gepusht. Bei Konflikten bleibt das Repository unverändert.")) {
                        .integrateReview(reviewId: review.reviewId)
                    } onResult: { _ in Task { await loadDetails() } }
                }
                if let item, item.status == .integrated {
                    CommandButton(String(localized: "Als erledigt markieren"), systemImage: "checkmark.circle",
                                  confirmation: String(localized: "Die Aufgabe wird erledigt; die Request-Datei wandert in den done-Ordner.")) {
                        .markDone(workItemId: item.uuid)
                    }
                }
            }
            Text("Integrationsstrategie des Projekts: \(strategy.displayName). Ändern Sie sie in den Projekteinstellungen.")
                .font(.caption).foregroundStyle(.secondary)
            if let commit = review.integrationCommit {
                Label("Integriert als \(String(commit.prefix(12)))\(review.integrationStrategy.map { " (\($0.displayName))" } ?? "")",
                      systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var conflictSection: some View {
        let files = details?.integrationConflictFiles ?? review.conflict?.files ?? []
        let message = details?.integrationProblem ?? review.conflict?.message
        if !files.isEmpty || message != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if let message { Text(message) }
                    ForEach(files, id: \.self) { Text(verbatim: $0).font(.system(.callout, design: .monospaced)) }
                    Text("Das Repository wurde nicht verändert. Beheben Sie die Konflikte im Worktree oder fordern Sie Änderungen an.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label("Integrationskonflikt", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private var testSection: some View {
        let summary = review.effectiveTestSummary
        return VStack(alignment: .leading, spacing: 4) {
            if summary.total == 0 {
                Text("Keine Testergebnisse erfasst.").foregroundStyle(.secondary)
            } else {
                Text("\(summary.passed) bestanden · \(summary.failed) fehlgeschlagen · \(summary.skipped) übersprungen · \(summary.notRun) nicht ausgeführt")
                    .foregroundStyle(summary.hasFailures ? .red : .primary)
            }
            ForEach(Array(review.testResults.enumerated()), id: \.offset) { _, result in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: result.outcome == .passed ? "checkmark.circle" : result.outcome == .failed ? "xmark.circle" : "minus.circle")
                        .foregroundStyle(result.outcome == .passed ? Color.green : result.outcome == .failed ? Color.red : Color.secondary)
                        .accessibilityLabel(Text(result.outcome.displayName))
                    Text(result.name)
                    if let detail = result.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var files: [ReviewFileChange] {
        details?.files ?? review.fileChanges
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if files.isEmpty {
                Text(review.diffSummary.files.isEmpty ? String(localized: "Keine Dateiliste erfasst.") : review.diffSummary.files.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.path) { file in
                Button {
                    Task { await loadDiff(file.path) }
                } label: {
                    HStack {
                        Text(verbatim: file.status).font(.system(.callout, design: .monospaced)).frame(width: 40, alignment: .leading)
                        Text(verbatim: file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let additions = file.additions, let deletions = file.deletions {
                            Text(verbatim: "+\(additions)").foregroundStyle(.green)
                            Text(verbatim: "−\(deletions)").foregroundStyle(.red)
                        } else {
                            Text("binär").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selectedFile == file.path ? Color.accentColor.opacity(0.12) : .clear)
                .accessibilityHint(Text("Zeigt den Diff dieser Datei"))
            }
            if let selectedFile {
                Divider()
                Text(verbatim: selectedFile).font(.headline)
                if let diffText {
                    UnifiedDiffView(diff: diffText).frame(minHeight: 200, maxHeight: 480)
                } else if let diffError {
                    Text(diffError).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if details == nil, let detailsError {
                Text(detailsError).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var commitsSection: some View {
        let commits = details?.commits ?? review.commits
        return VStack(alignment: .leading, spacing: 4) {
            if commits.isEmpty { Text("Keine Commits erfasst.").foregroundStyle(.secondary) }
            ForEach(commits, id: \.sha) { commit in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: String(commit.sha.prefix(10))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    Text(commit.subject)
                }
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        let notes = review.notes
        let denials = details?.permissionDenials ?? []
        let autoCommitted = details?.autoCommittedPaths ?? []
        let excludedSecrets = details?.excludedSecretPaths ?? []
        if !notes.isEmpty || !denials.isEmpty || !autoCommitted.isEmpty || !excludedSecrets.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { Text($0) }
                    if !denials.isEmpty {
                        Text("Abgelehnte Berechtigungen").font(.headline)
                        ForEach(denials, id: \.self) { Text($0) }
                    }
                    if !autoCommitted.isEmpty {
                        Text("Automatisch committete Agentenausgaben").font(.headline)
                        ForEach(autoCommitted, id: \.self) { Text(verbatim: $0).font(.system(.callout, design: .monospaced)) }
                    }
                    if !excludedSecrets.isEmpty {
                        Label("Nicht committet – sieht wie ein Geheimnis aus", systemImage: "key.slash")
                            .font(.headline).foregroundStyle(.orange)
                        Text("Diese Agentenausgaben liegen nur im Worktree. Bitte prüfen und dort entfernen; bis dahin ist die Integration gesperrt.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(excludedSecrets, id: \.self) { Text(verbatim: $0).font(.system(.callout, design: .monospaced)) }
                    }
                }
            } label: { Text("Hinweise") }
        }
    }

    private func worktreeSection(job: AgentJob?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let details {
                InfoRow("Branch", details.branch)
                InfoRow("Basis", details.baseCommit.map { String($0.prefix(12)) } ?? details.defaultBranch)
                InfoRow("Kopf", String(details.headCommit.prefix(12)))
                InfoRow("Repository", details.repositoryPath)
                if let worktree = details.worktreePath {
                    InfoRow("Worktree", worktree)
                    HStack {
                        if LocalOpener.exists(worktree) {
                            Button { LocalOpener.revealInFinder(worktree) } label: { Label("Im Finder zeigen", systemImage: "folder") }
                            Button { LocalOpener.openInTerminal(worktree) } label: { Label("Im Terminal öffnen", systemImage: "terminal") }
                        }
                        if let job {
                            CommandButton(String(localized: "Worktree entfernen"), systemImage: "trash", role: .destructive,
                                          confirmation: String(localized: "Der Worktree wird entfernt. Der Branch bleibt erhalten.")) {
                                .removeWorktree(jobId: job.jobId)
                            } onResult: { _ in Task { await loadDetails() } }
                        }
                    }
                } else {
                    Text("Kein Worktree mehr vorhanden (Branch bleibt erhalten).").foregroundStyle(.secondary)
                }
            } else if let detailsError {
                Text(detailsError).foregroundStyle(.secondary)
                Button("Erneut laden") { Task { await loadDetails() } }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func loadDetails() async {
        let outcome = await commands.perform(String(localized: "Review-Details laden"), .reviewDetails(reviewId: review.reviewId), quiet: true)
        if case let .reviewDetails(info)? = outcome.result {
            details = info
            detailsError = nil
        } else {
            detailsError = String(localized: "Pfade, Diffs und Worktree kennt nur der Dienst auf diesem Mac: \(outcome.feedback.message)")
        }
    }

    private func loadDiff(_ path: String) async {
        selectedFile = path
        diffText = nil
        diffError = nil
        guard let details else {
            diffError = detailsError ?? String(localized: "Review-Details sind noch nicht geladen.")
            return
        }
        switch await GitDiffLoader.diff(repository: details.repositoryPath, base: details.baseCommit,
                                        defaultBranch: details.defaultBranch, head: details.headCommit, path: path) {
        case let .success(text): diffText = text
        case let .failure(failure): diffError = failure.message
        }
    }
}
