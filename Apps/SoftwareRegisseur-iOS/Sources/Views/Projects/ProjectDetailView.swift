import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let projectID: ProjectID

    @State private var catalog = Catalog()
    @State private var settings: ProjectSettings?
    @State private var adrs: [ADR] = []
    @State private var preferences: [ProviderID: AgentModelPreference] = [:]
    @State private var error: String?
    @State private var confirmsArchive = false
    @State private var setupCommands: [ProjectSetupCommand] = []

    private var project: Project? { catalog.project(projectID) }
    private var items: [WorkItem] { catalog.items.filter { $0.projectId == projectID } }

    var body: some View {
        List {
            if let error { ErrorText(message: error) }
            if let project {
                infoSection(project)
                tasksSection
                agentSection
                foldersSection
                adrSection
                archiveSection(project)
            } else {
                ContentUnavailableView("Projekt nicht gefunden", systemImage: "folder.badge.questionmark")
            }
        }
        .readableContentWidth()
        .navigationTitle(project?.name ?? "")
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
        .confirmationDialog("Projekt archivieren?", isPresented: $confirmsArchive, titleVisibility: .visible) {
            Button("Archivieren", role: .destructive) { Task { await transition(to: .archived) } }
        } message: {
            Text("Archivierte Projekte bleiben erhalten und können wiederhergestellt werden.")
        }
    }

    private func infoSection(_ project: Project) -> some View {
        Section {
            LabeledContent { Text(project.status.title) } label: { Text("Status") }
            if let reason = project.statusReason {
                Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent { Text(project.repositoryKind.title) } label: { Text("Art") }
            if let status = SetupCommandStatus.latest(setupCommands) {
                SetupCommandStatusRow(status: status)
            }
            if let remote = project.remote {
                LabeledContent { Text(verbatim: remote).font(.caption.monospaced()) } label: { Text("Remote") }
            }
            if let host = catalog.host(project.hostId) {
                LabeledContent {
                    VStack(alignment: .trailing) {
                        Text(verbatim: host.name)
                        Text(host.lastSeen, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(HostAvailability.isOffline(host, now: .now) ? .orange : .secondary)
                    }
                } label: {
                    Text("Mac-Host")
                }
            } else {
                Label("Kein Mac-Host zugeordnet. Repo-Schreibvorgänge und Agentenstarts warten, bis ein Mac das Projekt übernimmt.",
                      systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Projekt")
        }
    }

    private var tasksSection: some View {
        Section {
            NavigationLink(value: AppRoute.projectTasks(projectID, title: project?.name ?? "")) {
                LabeledContent {
                    Text(items.count, format: .number)
                } label: {
                    Text("Alle Aufgaben")
                }
            }
            let active = catalog.jobs.filter { $0.projectId == projectID && OverviewSnapshot.activeJobStates.contains($0.state) }
            LabeledContent {
                Text(active.count, format: .number)
            } label: {
                Text("Aktive Agentenläufe")
            }
        } header: {
            Text("Aufgaben und Agentenstatus")
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        let providers = Array(Set(catalog.capabilities.map(\.providerId))).sorted()
        Section {
            if let settings {
                Picker(selection: Binding(
                    get: { settings.defaultAgentId },
                    set: { value in Task { await saveDefaultAgent(value) } }
                )) {
                    Text("Kein Projektstandard").tag(ProviderID?.none)
                    ForEach(providers, id: \.self) { provider in
                        Text(verbatim: catalog.capabilities.first { $0.providerId == provider }?.displayName ?? provider.rawValue)
                            .tag(ProviderID?.some(provider))
                    }
                } label: {
                    Text("Standardagent")
                }
            }
            if providers.isEmpty {
                Text("Der Mac hat noch keine Coding-Agenten gemeldet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(providers, id: \.self) { provider in
                if let capability = catalog.capabilities.first(where: { $0.providerId == provider }) {
                    NavigationLink {
                        AgentDefaultsEditor(capability: capability, scope: .project(projectID), current: preferences[provider])
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: capability.displayName)
                            PreferenceSummary(preference: preferences[provider], inheritedLabel: "Globaler Standard")
                        }
                    }
                }
            }
        } header: {
            Text("Agenten-Standards dieses Projekts")
        } footer: {
            Text("Gilt für neue Aufträge. Bereits geplante Aufträge behalten ihre gespeicherte Konfiguration.")
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        if let settings {
            Section {
                LabeledContent { Text(verbatim: settings.requestsRoot) } label: { Text("Requests") }
                LabeledContent { Text(verbatim: "\(settings.openPath), \(settings.activePath), \(settings.reviewPath), \(settings.donePath)") } label: {
                    Text("Statusordner")
                }
                LabeledContent { Text(verbatim: settings.adrPath) } label: { Text("ADRs") }
                LabeledContent { Text(settings.integrationStrategy.title) } label: { Text("Integration") }
            } header: {
                Text("Ordnerzuordnung")
            } footer: {
                Text("Pfade relativ zum Repository; geändert werden sie am Mac.")
            }
        }
    }

    private var adrSection: some View {
        Section {
            if adrs.isEmpty {
                Text("Keine ADRs synchronisiert.").foregroundStyle(.secondary)
            }
            ForEach(adrs) { adr in
                VStack(alignment: .leading) {
                    Text(verbatim: "\(adr.decisionNumber) – \(adr.title)")
                    Text(verbatim: adr.status.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("ADRs")
        }
    }

    @ViewBuilder
    private func archiveSection(_ project: Project) -> some View {
        Section {
            if project.status == .archived {
                Button("Archivierung aufheben") {
                    Task { await transition(to: project.hostId == nil ? .pendingMacSetup : .ready) }
                }
            } else {
                Button("Projekt archivieren", role: .destructive) { confirmsArchive = true }
            }
        }
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            catalog = try await model.loadCatalog()
            settings = try await database.projects.settings(forProject: projectID)
            adrs = try await database.adrs.list(projectId: projectID)
            setupCommands = try await database.projectSetupCommands.list(projectId: projectID)
            let list = try await database.preferences.preferences(scope: .project(projectID))
            preferences = Dictionary(list.map { ($0.providerId, $0) }, uniquingKeysWith: { first, _ in first })
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func saveDefaultAgent(_ provider: ProviderID?) async {
        guard let database = model.database, var settings else { return }
        let revision = settings.revision
        settings.defaultAgentId = provider
        do {
            self.settings = try await database.projects.saveSettings(settings, expectedRevision: revision, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func transition(to status: ProjectStatus) async {
        guard let database = model.database, let project else { return }
        do {
            _ = try await database.projects.transition(project.id, to: status, expectedRevision: project.revision, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// One-line summary of a stored model/effort preference.
struct PreferenceSummary: View {
    let preference: AgentModelPreference?
    let inheritedLabel: LocalizedStringResource

    var body: some View {
        Group {
            if let preference, !preference.inheritsDefault {
                let model: LocalizedStringResource = preference.model?.title ?? inheritedLabel
                let effort: LocalizedStringResource = preference.effort?.title ?? inheritedLabel
                Text("Modell: \(String(localized: model)) · Stufe: \(String(localized: effort))")
            } else {
                Text("Übernimmt: \(String(localized: inheritedLabel))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
