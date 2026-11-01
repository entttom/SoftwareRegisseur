import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Agentenverwaltung (J1, J2a, P macOS 6): Installations-/Anmeldediagnose, Modellkatalog, Effort-Matrix,
/// globale Standards und Remote-App-Verknüpfung. Nur belegte Fähigkeiten, keine geratenen Werte.
struct AgentsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        LibraryGate {
            let capabilities = library.snapshot.capabilities(hostId: monitor.currentSummary?.hostId)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlobalDefaultsBox()
                    if capabilities.isEmpty {
                        ContentUnavailableView {
                            Label("Noch keine Agenten erkannt", systemImage: "cpu")
                        } description: {
                            Text("Installieren Sie Codex oder Claude Code und starten Sie die Erkennung neu. Die Erkennung läuft auch beim Dienststart und alle 30 Minuten.")
                        }
                    }
                    ForEach(capabilities, id: \.providerId) { capability in
                        AgentCapabilityBox(capability: capability,
                                           summary: monitor.currentSummary?.agents.first { $0.providerId == capability.providerId })
                    }
                    let others = otherHosts
                    if !others.isEmpty {
                        GroupBox {
                            ForEach(others) { host in
                                InfoRow("Mac", "\(host.name) – zuletzt gesehen \(host.lastSeen.shortDateTime)")
                            }
                        } label: { Text("Weitere Macs") }
                    }
                }
                .padding(16)
            }
        }
        .toolbar {
            ToolbarItem {
                CommandButton(String(localized: "Agenten neu erkennen"), systemImage: "arrow.clockwise") { .redetectAgents }
            }
        }
    }

    private var otherHosts: [AgentHost] {
        guard let hostId = monitor.currentSummary?.hostId else { return [] }
        return library.snapshot.hosts.filter { $0.hostId != hostId }
    }
}

/// Globale Standards (J2a: Auftrag > Projekt > Global > Anbieterstandard) und synchronisierte
/// Benutzer-Standards (`GlobalSettings`, F2). Änderungen über den Dienst, synchronisiert aufs iPhone.
private struct GlobalDefaultsBox: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    @State private var form: GlobalDefaultsForm?
    @State private var choices: [ProviderID: AgentModelChoice] = [:]

    var body: some View {
        let snapshot = library.snapshot
        let capabilities = snapshot.capabilities(hostId: monitor.currentSummary?.hostId)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Modell und Stufe je Agent").font(.headline)
                if capabilities.isEmpty {
                    Text("Ohne erkannten Agenten lassen sich Modell und Stufe nicht prüfen und daher nicht festlegen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(capabilities, id: \.providerId) { capability in
                    let stored = snapshot.globalPreference(for: capability.providerId)
                    let current = choices[capability.providerId]
                        ?? AgentModelChoice(providerId: capability.providerId, model: stored?.model, effort: stored?.effort)
                    HStack {
                        ModelChoicePicker(title: ProviderNames.displayName(capability.providerId), capability: capability,
                                          choice: Binding(get: { current }, set: { choices[capability.providerId] = $0 }))
                        CommandButton(String(localized: "Speichern"), systemImage: "checkmark") {
                            .setGlobalModelPreference(current)
                        } onResult: { outcome in
                            if outcome.succeeded { choices[capability.providerId] = nil }
                        }
                        .disabled(choices[capability.providerId] == nil
                                  || !ModelChoiceOptions(capability: capability).isValid(model: current.model, effort: current.effort))
                    }
                }
                Divider()
                if let binding = Binding($form) {
                    GlobalSettingsEditor(form: binding, providers: capabilities.map(\.providerId))
                    HStack {
                        CommandButton(String(localized: "Globale Standards speichern"), systemImage: "checkmark") {
                            .updateGlobalSettings(binding.wrappedValue.command)
                        } onResult: { outcome in
                            if outcome.succeeded { form = nil }
                        }
                        .disabled(!binding.wrappedValue.problems.isEmpty)
                        Button("Verwerfen") { form = nil }
                    }
                } else {
                    InfoRow("Standardagent", snapshot.globalSettings.defaultAgentId.map(ProviderNames.displayName) ?? String(localized: "keiner festgelegt"))
                    InfoRow("Ordnerstruktur", "\(snapshot.globalSettings.folderLayout.adrPath) · \(snapshot.globalSettings.folderLayout.requestsRoot)")
                    Button("Standards für neue Projekte bearbeiten …") { form = GlobalDefaultsForm(snapshot.globalSettings) }
                }
                Text("Für einzelne Jobs wählen Sie Modell und Stufe direkt beim Start; Projekte können eigene Werte festlegen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Text("Globale Standards")
        }
    }
}

/// Standards für neue Projekte (F2 Defaultstruktur, J2 Standardagent, L1, ADR-0015).
private struct GlobalSettingsEditor: View {
    @Binding var form: GlobalDefaultsForm
    let providers: [ProviderID]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Standardagent", selection: $form.defaultAgentId) {
                Text("keiner").tag(ProviderID?.none)
                ForEach(Array(Set(providers + [ProviderID.codex, .claudeCode])).sorted(), id: \.self) { provider in
                    Text(ProviderNames.displayName(provider)).tag(ProviderID?.some(provider))
                }
            }
            Grid(alignment: .leading, verticalSpacing: 4) {
                row("ADR-Ordner", $form.layout.adrPath)
                row("Requests-Ordner", $form.layout.requestsRoot)
                row("Offen", $form.layout.openPath)
                row("In Arbeit", $form.layout.activePath)
                row("Review", $form.layout.reviewPath)
                row("Erledigt", $form.layout.donePath)
            }
            Picker("Integrationsstrategie", selection: $form.integrationStrategy) {
                ForEach(IntegrationStrategy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Review", selection: $form.reviewPolicy) {
                ForEach(ReviewPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Agentenanweisungen", selection: $form.agentInstructionsPolicy) {
                ForEach(AgentInstructionsPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Parallele Jobs erlauben", isOn: $form.allowParallel)
            HStack {
                Toggle("Höchstens", isOn: $form.limitParallelJobs)
                Stepper(value: $form.maxParallelJobs, in: ProjectSettingsCommand.parallelJobsRange) {
                    Text("\(form.maxParallelJobs) Jobs gleichzeitig").monospacedDigit()
                }
                .disabled(!form.limitParallelJobs)
            }
            .disabled(!form.allowParallel)
            Toggle("Projektweite Sperre", isOn: $form.projectWideLock)
            Toggle("Für neue Ordner „git init“ vorschlagen", isOn: $form.proposeGitInitForNewFolders)
            ForEach(form.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("Gilt für neu angelegte Projekte; bestehende Projekte behalten ihre Einstellungen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: Binding<String>) -> some View {
        GridRow {
            Text(label)
            TextField(text: value) { Text(label) }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
    }
}

private struct AgentCapabilityBox: View {
    let capability: AgentCapability
    let summary: AgentProviderSummary?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                diagnostics
                Divider()
                Text("Modellkatalog und Effort-Matrix").font(.headline)
                if !capability.supportsModelSelection {
                    UnavailableNotice(text: String(localized: "Dieser Agent erlaubt keine Modellwahl; es gilt der Anbieterstandard."))
                }
                if let hint = capability.effortSelectionHint {
                    UnavailableNotice(text: hint)
                }
                EffortMatrix(capability: capability)
            }
        } label: {
            HStack {
                Text(capability.displayName.isEmpty ? ProviderNames.displayName(capability.providerId) : capability.displayName)
                    .font(.title3.bold())
                Text(verbatim: capability.version).foregroundStyle(.secondary)
                Badge(text: readiness.0, color: readiness.1)
            }
        }
    }

    private var readiness: (String, Color) {
        if !capability.installed { return (String(localized: "nicht installiert"), .red) }
        if !capability.authenticated { return (String(localized: "nicht angemeldet"), .orange) }
        if !capability.runnable { return (String(localized: "nicht ausführbar"), .orange) }
        return (String(localized: "einsatzbereit"), .green)
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let diagnostic = capability.diagnostic ?? summary?.diagnostic {
                Label(diagnostic, systemImage: "stethoscope").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let path = capability.executablePath { InfoRow("Programm", path) }
            if let bundle = capability.appBundleId { InfoRow("App", bundle) }
            InfoRow("Quelle", capability.capabilitySource.displayName)
            InfoRow("Fähigkeitsstand", "\(capability.capabilityRevision)")
            InfoRow("Zuletzt geprüft", capability.lastChecked.shortDateTime)
            if let summary { InfoRow("Aktive Läufe", "\(summary.activeJobs)") }
            InfoRow("Fähigkeiten", features)
            InfoRow("Remote-App", capability.supportsRemote
                    ? (capability.sessionLinkFormat.map { String(localized: "offiziell mobil fortsetzbar (\($0))") } ?? String(localized: "offiziell mobil fortsetzbar"))
                    : String(localized: "keine offizielle mobile Fortsetzung erkannt"))
        }
    }

    private var features: String {
        var list: [String] = []
        if capability.supportsAutomaticStart { list.append(String(localized: "automatischer Start")) }
        if capability.supportsResume { list.append(String(localized: "Fortsetzen")) }
        if capability.supportsApprovals { list.append(String(localized: "Freigaben")) }
        if capability.supportsModelSelection { list.append(String(localized: "Modellwahl")) }
        if capability.supportsEffortSelection { list.append(String(localized: "Denkstufe")) }
        return list.isEmpty ? String(localized: "keine") : list.joined(separator: ", ")
    }
}

/// Modell × Stufe; nur belegte Kombinationen sind markiert (J2a, A37).
private struct EffortMatrix: View {
    let capability: AgentCapability

    var body: some View {
        let levels = columns
        if capability.modelCatalog.isEmpty {
            Text("Der Agent meldet keinen Modellkatalog.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Modell").font(.caption.weight(.semibold))
                    Text("Verfügbarkeit").font(.caption.weight(.semibold))
                    ForEach(levels, id: \.self) { level in
                        Text(level.germanDisplayName).font(.caption.weight(.semibold))
                    }
                }
                Divider()
                ForEach(capability.modelCatalog, id: \.modelId) { model in
                    GridRow {
                        VStack(alignment: .leading) {
                            Text(model.displayName.isEmpty ? model.modelId.rawValue : model.displayName)
                            Text(verbatim: model.modelId.rawValue).font(.caption).foregroundStyle(.secondary)
                            if model.modelId == capability.defaultModelId {
                                Text("Standardmodell").font(.caption).foregroundStyle(.blue)
                            }
                        }
                        Text(model.availability.displayName)
                            .foregroundStyle(model.availability == .available ? Color.primary : Color.orange)
                        ForEach(levels, id: \.self) { level in
                            cell(model: model, level: level)
                        }
                    }
                }
            }
        }
    }

    private var columns: [EffortLevel] {
        var levels = EffortLevel.knownLevels
        for model in capability.modelCatalog {
            for level in model.supportedEffortIds where !levels.contains(level) { levels.append(level) }
        }
        return levels
    }

    @ViewBuilder
    private func cell(model: AgentModelCapability, level: EffortLevel) -> some View {
        let supported = capability.supportsEffortSelection ? model.supports(level) : level.isAuto
        Image(systemName: supported ? (model.defaultEffortId == level ? "checkmark.circle.fill" : "checkmark") : "minus")
            .foregroundStyle(supported ? Color.green : Color.secondary)
            .accessibilityLabel(supported
                ? (model.defaultEffortId == level ? Text("unterstützt, Standard") : Text("unterstützt"))
                : Text("nicht unterstützt"))
    }
}
