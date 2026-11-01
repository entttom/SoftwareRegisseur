import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain

/// „Übersicht“ (spec P 1, H1): projects, active agents, scheduled work, open reviews, recently finished.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = Catalog()
    @State private var snapshot = OverviewSnapshot()
    @State private var loadError: String?
    @State private var showsCapture = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var tileIconSize: CGFloat = 28

    var body: some View {
        List {
            SyncStatusSection(showsDetails: false)
            if let loadError {
                ErrorText(message: loadError)
            }
            countsSection
            projectsSection
            jobsSection(title: "Aktive Agenten", jobs: snapshot.activeJobs,
                        empty: "Derzeit arbeitet kein Agent.")
            jobsSection(title: "Geplant und wartend", jobs: snapshot.waitingJobs,
                        empty: "Keine geplanten oder wartenden Agentenaufträge.")
            itemsSection(title: "Offene Reviews", items: snapshot.openReviews,
                         empty: "Keine Ergebnisse warten auf Ihr Review.")
            itemsSection(title: "Zuletzt abgeschlossen", items: snapshot.recentlyFinished,
                         empty: "Noch keine abgeschlossenen Arbeiten.")
        }
        .accessibilityIdentifier("overview.list")
        .readableContentWidth()
        .navigationTitle("Übersicht")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCapture = true
                } label: {
                    Label("Schnell erfassen", systemImage: "plus")
                }
                .accessibilityIdentifier("overview.quickCapture")
            }
        }
        .sheet(isPresented: $showsCapture) {
            QuickCaptureView(defaultProject: nil)
        }
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    /// Three equal tiles side by side; at accessibility text sizes one full-width row per count, so
    /// neither number nor title is truncated.
    private var countsSection: some View {
        Section {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            layout {
                countTile(value: snapshot.inboxCount, title: "Inbox", symbol: "tray", tab: .inbox)
                countTile(value: snapshot.openTaskCount, title: "Offene Aufgaben", symbol: "checklist", tab: .tasks)
                countTile(value: snapshot.openReviews.count, title: "Reviews", symbol: "checkmark.seal", tab: .review)
            }
        }
    }

    private func countTile(value: Int, title: LocalizedStringResource, symbol: String, tab: AppTab) -> some View {
        Button {
            model.show(tab)
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: symbol)
                            .frame(width: tileIconSize)
                        Text(title)
                            .foregroundStyle(Color(.label))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(value, format: .number)
                            .font(.title2.bold())
                    }
                    .padding(.vertical, 6)
                } else {
                    // Fixed-height icon slot (SF Symbols differ in height) and a reserved two-line title
                    // keep icons, numbers and titles of all tiles on the same lines at every text size.
                    VStack(spacing: 4) {
                        Image(systemName: symbol)
                            .font(.title3)
                            .frame(height: tileIconSize)
                        Text(value, format: .number)
                            .font(.title2.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        // Explicit label colour: `.secondary` inside a button is a pale tint (contrast).
                        Text(title)
                            .font(.caption)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.vertical, 4)
                }
            }
            .contentShape(.rect)
            .contentShape(.hoverEffect, .rect(cornerRadius: 12))
        }
        .buttonStyle(.borderless)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value, format: .number))
        .accessibilityHint(Text("Öffnet den Bereich."))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("overview.count.\(tab.rawValue)")
    }

    private var projectsSection: some View {
        Section {
            if snapshot.projects.isEmpty {
                Text("Noch keine Projekte. Projekte erscheinen, sobald der Mac sie erkannt und synchronisiert hat, oder Sie legen einen Projektentwurf an.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.projects) { project in
                    NavigationLink(value: AppRoute.project(project.id)) {
                        ProjectRow(project: project, host: catalog.host(project.hostId))
                    }
                }
            }
        } header: {
            Text("Projekte")
        }
    }

    private func jobsSection(title: LocalizedStringResource, jobs: [AgentJob], empty: LocalizedStringResource) -> some View {
        Section {
            if jobs.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(jobs) { job in
                    NavigationLink(value: AppRoute.task(job.workItemId)) {
                        JobRow(job: job, item: catalog.item(job.workItemId), projectName: catalog.projectName(job.projectId))
                    }
                }
            }
        } header: {
            Text(title)
        }
    }

    private func itemsSection(title: LocalizedStringResource, items: [WorkItem], empty: LocalizedStringResource) -> some View {
        Section {
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.task(item.uuid)) {
                        WorkItemRow(item: item, projectName: catalog.projectName(item.projectId))
                    }
                }
            }
        } header: {
            Text(title)
        }
    }

    private func load() async {
        do {
            catalog = try await model.loadCatalog()
            snapshot = OverviewSnapshot.build(projects: catalog.projects, items: catalog.items, jobs: catalog.jobs)
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }
}

struct JobRow: View {
    let job: AgentJob
    let item: WorkItem?
    let projectName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item?.title ?? String(localized: "Unbekannte Aufgabe"))
                .lineLimit(2)
            AccessibleRowLayout(spacing: 8) {
                Text(verbatim: job.providerId.rawValue)
                    .font(.caption.bold())
                Text(job.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let planned = job.scheduledAt {
                    Text(planned, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .manualPause = job.schedule.kind {
                    Text("wartet auf Freigabe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let projectName {
                Text(projectName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
