import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Review“ (spec P 7, M1): compact result summary and decision on the iPhone; integration runs on the Mac.
struct ReviewListView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [(item: WorkItem, job: AgentJob?, review: Review?)] = []
    @State private var catalog = Catalog()
    @State private var error: String?

    var body: some View {
        RouteList {
            if let error { ErrorText(message: error) }
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Keine offenen Reviews", systemImage: "checkmark.seal")
                } description: {
                    Text("Sobald ein Agent eine Aufgabe umgesetzt hat und der Mac Diff und Tests erfasst hat, erscheint das Ergebnis hier.")
                }
            }
            ForEach(entries, id: \.item.uuid) { entry in
                NavigationLink(value: AppRoute.review(item: entry.item.uuid, review: entry.review?.id, fromTask: false)) {
                    VStack(alignment: .leading, spacing: 4) {
                        WorkItemRow(item: entry.item, projectName: catalog.projectName(entry.item.projectId))
                        if let review = entry.review {
                            Text(review.decision.title).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Ergebnis wird vom Mac noch erfasst").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            catalog = try await model.loadCatalog(includeAgents: false)
            let items = catalog.items.filter { [.implementationFinished, .review, .integrated].contains($0.status) }
                .sorted { $0.updatedAt > $1.updatedAt }
            var result: [(WorkItem, AgentJob?, Review?)] = []
            for item in items {
                let jobs = try await database.jobs.jobs(forWorkItem: item.uuid).sorted { $0.createdAt > $1.createdAt }
                let job = jobs.first { $0.state == .finished } ?? jobs.first
                var review: Review?
                if let job { review = try await database.reviews.reviews(jobId: job.jobId).last }
                result.append((item, job, review))
            }
            entries = result
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }
}

struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    let itemID: WorkItemID
    let reviewID: ReviewID?
    /// False when opened from the task's detail view, which is one step back.
    var offersTaskLink = true

    @State private var item: WorkItem?
    @State private var job: AgentJob?
    @State private var review: Review?
    @State private var settings: ProjectSettings?
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        List {
            if let error { ErrorText(message: error) }
            if let item {
                Section {
                    WorkItemRow(item: item)
                    if offersTaskLink {
                        NavigationLink("Aufgabe öffnen", value: AppRoute.task(item.uuid))
                    }
                }
                if let review {
                    if let conflict = review.conflict { conflictSection(conflict) }
                    if let summary = review.summary { agentSummarySection(summary, notes: review.notes) }
                    summarySection(review)
                    if !review.commits.isEmpty { commitsSection(review) }
                    testsSection(review)
                } else {
                    Section {
                        Text("Der Mac hat für diesen Lauf noch keine Zusammenfassung (Diff, Tests) gemeldet.")
                            .foregroundStyle(.secondary)
                    }
                }
                gitSection
                actionsSection(item)
            } else {
                ProgressView()
            }
        }
        .readableContentWidth()
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    private func summarySection(_ review: Review) -> some View {
        Section {
            LabeledContent { Text(review.decision.title) } label: { Text("Entscheidung") }
            LabeledContent {
                Text("\(review.diffSummary.filesChanged) Dateien, +\(review.diffSummary.insertions) / −\(review.diffSummary.deletions)")
            } label: {
                Text("Änderungen")
            }
            if review.fileChanges.isEmpty {
                ForEach(review.diffSummary.files.prefix(30), id: \.self) { file in
                    Text(verbatim: file).font(.caption.monospaced())
                }
            } else {
                ForEach(review.fileChanges.prefix(30), id: \.path) { change in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: String(change.status.prefix(1))).font(.caption.monospaced().bold()).frame(width: 14)
                        Text(verbatim: change.path).font(.caption.monospaced()).lineLimit(2)
                        Spacer()
                        if let additions = change.additions, let deletions = change.deletions {
                            Text(verbatim: "+\(additions) −\(deletions)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else {
                            Text("binär").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            let fileCount = max(review.fileChanges.count, review.diffSummary.files.count)
            if fileCount > 30 {
                Text("Weitere \(fileCount - 30) Dateien – große Diffs bitte am Mac prüfen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Ergebnis")
        } footer: {
            Text("Den vollständigen Diff prüfen Sie am Mac.")
        }
    }

    private func conflictSection(_ conflict: ReviewConflictInfo) -> some View {
        Section {
            Label {
                Text(verbatim: conflict.message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ForEach(conflict.files, id: \.self) { file in
                Text(verbatim: file).font(.caption.monospaced())
            }
        } header: {
            Text("Integrationskonflikt")
        } footer: {
            Text("Der Default-Branch wurde nicht verändert. Konflikte lösen Sie am Mac.")
        }
    }

    private func agentSummarySection(_ summary: String, notes: [String]) -> some View {
        Section {
            Text(verbatim: summary).textSelection(.enabled)
            ForEach(notes, id: \.self) { note in
                Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle") }
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Zusammenfassung des Agenten")
        }
    }

    private func commitsSection(_ review: Review) -> some View {
        Section {
            ForEach(review.commits, id: \.sha) { commit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: commit.subject.isEmpty ? "–" : commit.subject)
                    Text(verbatim: String(commit.sha.prefix(10))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Commits (\(review.commits.count))")
        }
    }

    private func testsSection(_ review: Review) -> some View {
        Section {
            let summary = review.effectiveTestSummary
            if summary.total > 0 {
                Text("\(summary.passed) bestanden, \(summary.failed) fehlgeschlagen, \(summary.skipped + summary.notRun) nicht ausgeführt")
                    .font(.callout)
                    .foregroundStyle(summary.hasFailures ? .red : .secondary)
            }
            if review.testResults.isEmpty {
                Text("Keine Testergebnisse gemeldet.").foregroundStyle(.secondary)
            }
            ForEach(review.testResults, id: \.name) { result in
                HStack {
                    Image(systemName: result.outcome.symbol).foregroundStyle(result.outcome.tint).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(verbatim: result.name)
                        Text(result.outcome.title).font(.caption).foregroundStyle(.secondary)
                        if let detail = result.detail {
                            Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Tests")
        }
    }

    private var gitSection: some View {
        Section {
            if let branch = job?.branch {
                LabeledContent { Text(verbatim: branch).font(.caption.monospaced()) } label: { Text("Branch") }
            }
            if let head = review?.headCommit, review?.integrationCommit == nil {
                LabeledContent { Text(verbatim: String(head.prefix(12))).font(.caption.monospaced()).textSelection(.enabled) } label: { Text("Branch-Stand") }
            }
            if let commit = review?.integrationCommit {
                LabeledContent { Text(verbatim: commit).font(.caption.monospaced()).textSelection(.enabled) } label: { Text("Commit") }
            }
            if let settings {
                LabeledContent { Text(settings.integrationStrategy.title) } label: { Text("Integration") }
            }
            if job?.branch == nil && review?.integrationCommit == nil {
                Text("Branch und Commit meldet der Mac nach dem Lauf bzw. nach der Übernahme.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Git")
        }
    }

    private func actionsSection(_ item: WorkItem) -> some View {
        let actions = ReviewAction.available(for: item, review: review)
        return Section {
            if actions.isEmpty {
                Text(item.status == .integrated
                     ? "Die Übernahme ist noch nicht im Default-Branch bestätigt."
                     : "Derzeit ist keine Entscheidung möglich.")
                    .foregroundStyle(.secondary)
            }
            ForEach(actions, id: \.self) { action in
                Button(role: action == .reject ? .destructive : nil) {
                    Task { await perform(action, item: item) }
                } label: {
                    Text(action.title)
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Freigabe")
        } footer: {
            Text("Die Freigabe wird synchronisiert; Übernahme in den Default-Branch, Konfliktbehebung und das Verschieben nach „done“ führt der Mac aus. Es wird nie gepusht.")
        }
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            item = try await database.workItems.fetch(itemID)
            let jobs = try await database.jobs.jobs(forWorkItem: itemID).sorted { $0.createdAt > $1.createdAt }
            job = jobs.first { $0.state == .finished } ?? jobs.first
            var all: [Review] = []
            for job in jobs { all += try await database.reviews.reviews(jobId: job.jobId) }
            review = reviewID.flatMap { id in all.first { $0.id == id } } ?? all.last
            if let projectId = item?.projectId { settings = try await database.projects.settings(forProject: projectId) }
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func perform(_ action: ReviewAction, item: WorkItem) async {
        guard let database = model.database else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await ReviewActionPerformer(reviews: database.reviews, workItems: database.workItems)
                .perform(action, item: item, review: review, actor: model.actor, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }
}
