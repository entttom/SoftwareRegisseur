import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Agenten“ (spec P 6, J1/J2): capabilities synced from the Mac, global defaults, job queue.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = Catalog()
    @State private var globalPreferences: [ProviderID: AgentModelPreference] = [:]
    @State private var error: String?

    var body: some View {
        List {
            if let error { ErrorText(message: error) }
            if catalog.hosts.isEmpty {
                ContentUnavailableView {
                    Label("Kein Mac verbunden", systemImage: "desktopcomputer")
                } description: {
                    Text("Coding-Agenten werden vom Mac erkannt und per iCloud gemeldet. Sobald die Mac-App läuft und synchronisiert hat, erscheinen Codex und Claude Code hier.")
                }
            }
            OpenApprovalsSection()
            ForEach(catalog.hosts) { host in
                hostSection(host)
            }
            jobsSection
        }
        .accessibilityIdentifier("agents.list")
        .readableContentWidth()
        .navigationTitle("Agenten")
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    private func hostSection(_ host: AgentHost) -> some View {
        let offline = HostAvailability.isOffline(host, now: .now)
        let capabilities = catalog.capabilities.filter { $0.hostId == host.hostId }
        return Section {
            LabeledContent {
                VStack(alignment: .trailing) {
                    HostReachabilityText(offline: offline)
                    Text(host.lastSeen, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label {
                    Text(verbatim: host.name)
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
            }
            if capabilities.isEmpty {
                Text("Dieser Mac hat keine Coding-Agenten gemeldet.").foregroundStyle(.secondary)
            }
            ForEach(capabilities, id: \.providerId) { capability in
                NavigationLink {
                    AgentCapabilityDetailView(capability: capability, hostOffline: offline,
                                              globalPreference: globalPreferences[capability.providerId])
                } label: {
                    CapabilityRow(capability: capability, hostOffline: offline,
                                  globalPreference: globalPreferences[capability.providerId])
                }
            }
        } header: {
            Text(verbatim: host.name)
        } footer: {
            if offline {
                Text("Zuletzt erkannt – Mac derzeit offline. Aufträge werden gespeichert und starten, sobald der Mac wieder erreichbar ist.")
            }
        }
    }

    private var jobsSection: some View {
        let jobs = catalog.jobs.filter { !$0.state.isTerminal }.sorted { $0.createdAt > $1.createdAt }
        return Section {
            if jobs.isEmpty {
                Text("Keine offenen Agentenaufträge.").foregroundStyle(.secondary)
            }
            ForEach(jobs) { job in
                NavigationLink(value: AppRoute.task(job.workItemId)) {
                    JobRow(job: job, item: catalog.item(job.workItemId), projectName: catalog.projectName(job.projectId))
                }
            }
        } header: {
            Text("Warteschlange")
        }
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            catalog = try await model.loadCatalog()
            let list = try await database.preferences.preferences(scope: .global)
            globalPreferences = Dictionary(list.map { ($0.providerId, $0) }, uniquingKeysWith: { first, _ in first })
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }
}

struct CapabilityRow: View {
    let capability: AgentCapability
    let hostOffline: Bool
    let globalPreference: AgentModelPreference?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: capability.displayName).font(.headline)
                Text(verbatim: capability.version).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            AgentReadinessBadge(capability: capability)
            if hostOffline {
                Text("Zuletzt erkannt – Mac derzeit offline")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            PreferenceSummary(preference: globalPreference, inheritedLabel: "Anbieterstandard")
        }
        .accessibilityElement(children: .combine)
    }
}

/// Whether a reported coding agent can start (installed, signed in, runnable).
struct AgentReadinessBadge: View {
    let capability: AgentCapability

    var body: some View {
        if !capability.installed {
            StatusBadge(title: "Nicht installiert", symbol: "xmark.circle", tint: .red)
        } else if !capability.authenticated {
            StatusBadge(title: "Nicht angemeldet", symbol: "person.crop.circle.badge.exclamationmark", tint: .orange)
        } else if !capability.runnable {
            StatusBadge(title: "Nicht startbereit", symbol: "exclamationmark.triangle", tint: .orange)
        } else {
            StatusBadge(title: "Bereit", symbol: "checkmark.circle", tint: .green)
        }
    }
}

struct AgentCapabilityDetailView: View {
    @Environment(AppModel.self) private var model
    let capability: AgentCapability
    let hostOffline: Bool
    let globalPreference: AgentModelPreference?

    var body: some View {
        List {
            Section {
                LabeledContent { Text(verbatim: capability.version) } label: { Text("Version") }
                LabeledContent { Text(capability.lastChecked, format: .dateTime) } label: { Text("Zuletzt geprüft") }
                LabeledContent { Text(capability.capabilityRevision, format: .number) } label: { Text("Capability-Revision") }
                LabeledContent { Text(capability.supportsModelSelection ? "Ja" : "Nein") } label: { Text("Modellwahl") }
                LabeledContent {
                    if capability.supportsEffortSelection {
                        Text("Ja")
                    } else {
                        Text("Anbieterstandard – nicht einstellbar")
                    }
                } label: {
                    Text("Denkstufe")
                }
                LabeledContent { Text(capability.supportsRemote ? "Ja" : "Nein") } label: { Text("Offizielle mobile Fortsetzung") }
                if let diagnostic = capability.diagnostic {
                    Text(verbatim: diagnostic).font(.caption).foregroundStyle(.secondary)
                }
                if hostOffline {
                    Text("Zuletzt erkannt – Mac derzeit offline").foregroundStyle(.orange)
                }
            } header: {
                Text(verbatim: capability.displayName)
            }
            Section {
                if capability.modelCatalog.isEmpty {
                    Text("Der Mac hat keinen Modellkatalog gemeldet; nur der Anbieterstandard ist wählbar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(capability.modelCatalog, id: \.modelId) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: entry.displayName)
                            if entry.modelId == capability.defaultModelId {
                                Text("Standard").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(verbatim: entry.modelId.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(entry.availability.title).font(.caption)
                        if capability.supportsEffortSelection {
                            Text(verbatim: entry.supportedEffortIds.map { String(localized: $0.title) }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Modelle und Denkstufen")
            }
            Section {
                NavigationLink {
                    AgentDefaultsEditor(capability: capability, scope: .global, current: globalPreference)
                } label: {
                    VStack(alignment: .leading) {
                        Text("Globaler Standard")
                        PreferenceSummary(preference: globalPreference, inheritedLabel: "Anbieterstandard")
                    }
                }
            } footer: {
                Text("Reihenfolge: Auftrag > Projekt > global > Anbieterstandard.")
            }
        }
        .navigationTitle(Text(verbatim: capability.displayName))
    }
}

/// Edits the global or project default of one agent (spec J2a). Unsupported combinations cannot be saved.
struct AgentDefaultsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let capability: AgentCapability
    let scope: PreferenceScope
    let current: AgentModelPreference?

    @State private var modelChoice: ModelSelection?
    @State private var effortChoice: EffortLevel?
    @State private var error: String?
    @State private var didLoad = false

    private var effectiveModel: ModelSelection { modelChoice ?? .providerDefault }
    private var issues: [ConfigurationIssue] {
        AgentPreferenceEditor.issues(model: modelChoice, effort: effortChoice, capability: capability)
    }

    var body: some View {
        Form {
            Section {
                OptionRow(title: inheritTitle, selected: modelChoice == nil) { modelChoice = nil }
                ForEach(JobRequestPlanner.modelChoices(for: capability)) { choice in
                    OptionRow(title: choice.selection.title, detail: choice.isSelectable ? nil : choice.availability.title,
                              selected: modelChoice == choice.selection, enabled: choice.isSelectable) {
                        modelChoice = choice.selection
                    }
                }
            } header: {
                Text("Modell")
            }
            Section {
                if !capability.supportsEffortSelection {
                    Text("Anbieterstandard – nicht einstellbar")
                        .foregroundStyle(.secondary)
                } else {
                    OptionRow(title: inheritTitle, selected: effortChoice == nil) { effortChoice = nil }
                    ForEach(JobRequestPlanner.effortChoices(for: capability, model: effectiveModel), id: \.self) { effort in
                        OptionRow(title: effort.title, detail: effort.explanation, selected: effortChoice == effort) {
                            effortChoice = effort
                        }
                    }
                }
            } header: {
                Text("Denk-/Effort-Stufe")
            }
            if !issues.isEmpty {
                Section {
                    ForEach(issues, id: \.self) { issue in
                        ErrorText(message: String(localized: issue.message))
                    }
                }
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle(scopeTitle)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { Task { await save() } }
                    .disabled(!issues.isEmpty)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let current, !current.inheritsDefault {
                modelChoice = current.model
                effortChoice = current.effort
            }
        }
    }

    private var scopeTitle: LocalizedStringResource {
        switch scope {
        case .global: "Globaler Standard"
        case .project: "Projektstandard"
        }
    }

    private var inheritTitle: LocalizedStringResource {
        switch scope {
        case .global: "Anbieterstandard verwenden"
        case .project: "Globalen Standard übernehmen"
        }
    }

    private func save() async {
        guard let database = model.database else { return }
        do {
            if modelChoice == nil && effortChoice == nil {
                try await database.preferences.remove(scope: scope, providerId: capability.providerId, at: .now)
            } else {
                let preference = AgentPreferenceEditor.makePreference(scope: scope, provider: capability.providerId,
                                                                      model: modelChoice, effort: effortChoice, now: .now)
                try await database.preferences.save(preference, at: .now)
            }
            model.noteLocalChange()
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// Selectable row with checkmark; disabled options show their reason (spec J2a: begründet deaktivieren).
struct OptionRow: View {
    let title: LocalizedStringResource
    var detail: LocalizedStringResource?
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(enabled ? .primary : .secondary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
