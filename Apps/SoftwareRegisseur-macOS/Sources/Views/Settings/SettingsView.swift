import AppKit
import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability

/// Einstellungen, Datenschutz/Sicherheit und Release-Status (P macOS 8).
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case service, sync, keys, agents, privacy, about
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .service: "Dienst"
            case .sync: "iCloud"
            case .keys: "KI-Schlüssel"
            case .agents: "Agenten & GitHub"
            case .privacy: "Datenschutz"
            case .about: "Version & Updates"
            }
        }
    }

    @SceneStorage("settings.page") private var page: Page = .service

    var body: some View {
        VStack(spacing: 0) {
            AdaptivePicker("Bereich", selection: $page) {
                ForEach(Page.allCases) { Text($0.title).tag($0) }
            }
            .padding(10)
            Divider()
            Form {
                switch page {
                case .service: ServiceSettingsPage()
                case .sync: SyncSettingsPage()
                case .keys: KeysSettingsPage()
                case .agents: AgentSettingsPage()
                case .privacy: PrivacySettingsPage()
                case .about: AboutSettingsPage()
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: Dienst

private struct ServiceSettingsPage: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(ServiceMonitor.self) private var monitor
    @State private var settings: ServiceSettings?
    @State private var loadError: String?

    var body: some View {
        Section("Hintergrunddienst") {
            ServiceStatusRow()
            ServiceControls()
        }
        Section("Anmeldung") {
            LoginAgentSection()
        }
        Section("Einrichtung") {
            SetupAssistantReopenRow()
        }
        Section {
            if let binding = Binding($settings) {
                minutes("iCloud-Abfrage alle", binding.syncPollInterval)
                minutes("Stammordner-Scan alle", binding.workspaceScanInterval)
                Stepper(value: binding.folderScanDepth, in: ServiceSettings.folderScanDepthRange) {
                    HStack {
                        Text("Ordnertiefe unter Stammordnern")
                        Spacer()
                        Text("\(binding.wrappedValue.folderScanDepth) \(binding.wrappedValue.folderScanDepth == 1 ? "Ebene" : "Ebenen")").monospacedDigit()
                    }
                }
                Text("1 = nur Ordner direkt im Stammordner. Bei mehr Ebenen erscheinen auch Unterordner am iPhone zur Auswahl. Wegfallende Ordner werden auch aus iCloud entfernt; Ordner mit verknüpftem Projekt bleiben erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
                minutes("Markdown-Abgleich alle", binding.reconcileInterval)
                minutes("Agentenerkennung alle", binding.agentDetectionInterval)
                minutes("GitHub-Abgleich alle", binding.gitHubSyncInterval)
                Toggle("Leerlauf-Ruhezustand verhindern, solange ein Agent arbeitet", isOn: binding.preventIdleSleepWhileAgentsRun)
                Text("Bildschirm-Ruhezustand und manuell ausgelöster Ruhezustand bleiben unberührt. Ein nur geplanter Job verhindert nie den Ruhezustand.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("KI-Ausarbeitungen vom iPhone automatisch am Mac ausführen", isOn: binding.processQueuedAIElaborations)
                HStack {
                    Spacer()
                    CommandButton(String(localized: "Diensteinstellungen speichern"), systemImage: "checkmark") {
                        .updateServiceSettings(binding.wrappedValue)
                    } onResult: { outcome in
                        if case let .serviceSettings(saved)? = outcome.result { settings = saved }
                    }
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } header: {
            Text("Diensteinstellungen (nur dieser Mac)")
        }
        .task(id: monitor.isReachable) { await load() }
    }

    private func minutes(_ title: LocalizedStringKey, _ value: Binding<TimeInterval>) -> some View {
        Stepper(value: Binding(get: { value.wrappedValue / 60 }, set: { value.wrappedValue = $0 * 60 }), in: 0.25...1_440, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue / 60).rounded())) min").monospacedDigit()
            }
        }
    }

    private func load() async {
        let outcome = await commands.perform(String(localized: "Diensteinstellungen laden"), .serviceSettings, quiet: true)
        if case let .serviceSettings(loaded)? = outcome.result {
            settings = loaded
            loadError = nil
        } else {
            loadError = outcome.feedback.message
        }
    }
}

/// Einrichtungsassistent ab den Stammordnern erneut zeigen; der Hintergrunddienst bleibt unverändert.
private struct SetupAssistantReopenRow: View {
    @Environment(SetupAssistant.self) private var setup

    var body: some View {
        HStack {
            Text("Stammordner, Agenten und Verbindungen Schritt für Schritt einrichten.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Einrichtungsassistent öffnen") { setup.reopen() }
                .disabled(setup.service.needsPresentation)
        }
    }
}

// MARK: iCloud

private struct SyncSettingsPage: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let sync = monitor.currentSummary?.sync {
            let presentation = SyncPresentation.make(sync, now: .now)
            Section("Status") {
                StatusLabel(title: presentation.title, detail: presentation.detail, level: presentation.level, symbolName: "icloud")
                InfoRow("Zustand", sync.state.displayName)
                InfoRow("iCloud-Account", sync.accountState.displayName)
                InfoRow("Letzter Abruf", sync.lastSuccessfulFetch?.shortDateTime ?? "–")
                InfoRow("Letztes Senden", sync.lastSuccessfulSend?.shortDateTime ?? "–")
                InfoRow("Ausstehende Änderungen", "\(sync.pendingChanges)")
                if let reason = sync.unavailableReason { InfoRow("Grund", reason) }
                if let error = sync.lastError { InfoRow("Letzter Fehler", error) }
                ForEach(sync.attention, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    CommandButton(String(localized: "Jetzt synchronisieren"), systemImage: "arrow.triangle.2.circlepath") { .syncNow }
                        .disabled(sync.state == .unavailable)
                }
            }
            if sync.accountState == .switched {
                Section("iCloud-Account gewechselt") {
                    Text("Lokale Daten bleiben erhalten. Wählen Sie, wie es weitergeht.")
                    HStack {
                        CommandButton(String(localized: "Fortfahren und lokale Daten hochladen"), systemImage: "icloud.and.arrow.up",
                                      confirmation: String(localized: "Alle lokalen Daten werden in den neuen iCloud-Account hochgeladen.")) {
                            .acknowledgeAccountChange(uploadAllLocalData: true)
                        }
                        CommandButton(String(localized: "Fortfahren ohne Hochladen"), systemImage: "icloud") {
                            .acknowledgeAccountChange(uploadAllLocalData: false)
                        }
                    }
                }
            }
            if let deletion = sync.cloudDataDeletion {
                Section("iCloud-Daten auf Ihren Wunsch gelöscht") {
                    CloudDeletionStateView(state: deletion)
                }
            } else if sync.state == .paused {
                Section("iCloud-Daten neu anlegen") {
                    Text("Wurden die iCloud-Daten gelöscht, legt der Dienst die Zone neu an und lädt alles erneut hoch.")
                    CommandButton(String(localized: "Zone neu anlegen und hochladen"), systemImage: "arrow.clockwise.icloud",
                                  confirmation: String(localized: "Die iCloud-Zone wird neu angelegt und alle lokalen Daten werden hochgeladen.")) {
                        .recreateCloudZone
                    }
                }
            }
        } else {
            Section("Status") {
                Text("Der Dienst ist nicht erreichbar; der iCloud-Status ist unbekannt.").foregroundStyle(.secondary)
            }
        }
        Section {
            if library.snapshot.syncConflicts.isEmpty {
                Text("Keine offenen Sync-Konflikte.").foregroundStyle(.secondary)
            }
            ForEach(library.snapshot.syncConflicts) { conflict in
                SyncConflictView(conflict: conflict)
            }
        } header: {
            Text("Sync-Konflikte (\(library.snapshot.syncConflicts.count))")
        }
    }
}

private struct SyncConflictView: View {
    let conflict: SyncConflict
    @State private var showMerge = false

    var body: some View {
        let merge = SyncConflictMerge(conflict: conflict)
        DisclosureGroup {
            SideBySideDiffView(leftTitle: String(localized: "Dieser Mac (Version \(conflict.localVersion))"),
                               rightTitle: String(localized: "iCloud (Version \(conflict.remoteVersion))"),
                               left: PrettyJSON.format(conflict.localPayload), right: PrettyJSON.format(conflict.remotePayload))
                .frame(minHeight: 160, maxHeight: 320)
            HStack {
                if merge != nil {
                    Button {
                        showMerge = true
                    } label: {
                        Label("Texte zusammenführen …", systemImage: "arrow.triangle.merge")
                    }
                }
                CommandButton(String(localized: "Stand dieses Macs behalten"), systemImage: "desktopcomputer") {
                    .resolveSyncConflict(conflictId: conflict.id, choice: .keepLocal)
                }
                CommandButton(String(localized: "iCloud-Stand übernehmen"), systemImage: "icloud") {
                    .resolveSyncConflict(conflictId: conflict.id, choice: .acceptRemote)
                }
            }
        } label: {
            Text("\(conflict.entityType.rawValue) · erkannt \(conflict.detectedAt.shortDateTime)")
        }
        .sheet(isPresented: $showMerge) {
            if let merge { SyncConflictMergeSheet(conflictId: conflict.id, merge: merge) }
        }
    }
}

// MARK: KI-Schlüssel

private struct KeysSettingsPage: View {
    @Environment(ProviderKeyStore.self) private var keys

    var body: some View {
        Section {
            ForEach(ProviderKeyStore.providers, id: \.rawValue) { provider in
                ProviderKeyRow(provider: provider)
            }
        } header: {
            Text("API-Schlüssel für KI-Ausarbeitung und „Mit KI besprechen“ am Mac")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schlüssel liegen nur im Schlüsselbund dieses Macs (gerätebezogen) und werden nie in Datenbank, iCloud, Markdown oder Logs gespeichert. Der Hintergrunddienst liest sie über die gemeinsame Schlüsselbund-Gruppe.")
                if keys.accessGroup == nil {
                    Text("Achtung: Für diesen Build ist keine gemeinsame Schlüsselbund-Gruppe konfiguriert (unsignierter Build oder Platzhalter-Team). Der Dienst kann so gespeicherte Schlüssel nicht lesen.")
                        .foregroundStyle(.orange)
                }
            }
        }
        Section {
            ConversationProviderSection()
        } header: {
            Text("Anbieter und Modell für „Mit KI besprechen“")
        } footer: {
            Text("Gilt nur für diesen Mac. Gesendet wird erst, nachdem Sie den angezeigten Kontext bestätigt haben. Kosten werden nur geschätzt angezeigt.")
        }
        .onAppear { keys.refresh() }
    }
}

/// Anbieter/Modell für das Gespräch (I: Modellwahl, dynamische Modellliste, erklärbar deaktiviert ohne Schlüssel).
private struct ConversationProviderSection: View {
    @Environment(ProviderKeyStore.self) private var keys
    @AppStorage(MacTextAISettings.providerKey) private var providerRaw = ""
    @AppStorage(MacTextAISettings.modelKey) private var modelId = ""
    @State private var models: [AIModelInfo] = []
    @State private var modelError: String?

    var body: some View {
        Picker("Anbieter", selection: $providerRaw) {
            Text("Bitte wählen").tag("")
            ForEach(ProviderKeyStore.providers, id: \.rawValue) { provider in
                Text(ProviderKeyStore.displayName(provider)).tag(provider.rawValue)
            }
        }
        .onChange(of: providerRaw) { _, _ in modelId = "" }
        .task(id: "\(providerRaw)|\(keys.hasKey(SoftwareRegisseurAI.AIProviderID(rawValue: providerRaw)))") { await loadModels() }
        if !providerRaw.isEmpty {
            let provider = SoftwareRegisseurAI.AIProviderID(rawValue: providerRaw)
            if !keys.hasKey(provider) {
                UnavailableNotice(text: String(localized: "Für \(ProviderKeyStore.displayName(provider)) ist noch kein Schlüssel gespeichert (oben eintragen)."))
            }
            if models.isEmpty {
                TextField("Modell-ID", text: $modelId, prompt: Text("Modell-ID des Anbieters"))
                if let modelError { Text(modelError).font(.caption).foregroundStyle(.secondary) }
            } else {
                Picker("Modell", selection: $modelId) {
                    Text("Bitte wählen").tag("")
                    if !modelId.isEmpty, !models.contains(where: { $0.id == modelId }) {
                        Text(verbatim: modelId).tag(modelId)
                    }
                    ForEach(models) { model in
                        Text(model.displayName.isEmpty ? model.id : model.displayName).tag(model.id)
                    }
                }
            }
        }
    }

    private func loadModels() async {
        models = []
        modelError = nil
        guard !providerRaw.isEmpty else { return }
        let provider = SoftwareRegisseurAI.AIProviderID(rawValue: providerRaw)
        guard keys.hasKey(provider) else { return }
        switch await keys.models(provider) {
        case let .success(list):
            models = list.sorted { $0.id < $1.id }
        case let .failure(error):
            modelError = String(localized: "Modellliste nicht abrufbar (\(error.message)). Sie können die Modell-ID direkt eingeben.")
        }
    }
}

struct ProviderKeyRow: View {
    @Environment(ProviderKeyStore.self) private var keys
    @Environment(CommandCenter.self) private var commands
    let provider: SoftwareRegisseurAI.AIProviderID
    @State private var newKey = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ProviderKeyStore.displayName(provider)).font(.headline)
                Spacer()
                statusText
            }
            HStack {
                SecureField("Neuen Schlüssel eingeben", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                Button("Speichern") {
                    let message = keys.save(newKey, for: provider)
                    newKey = ""
                    commands.record(title: String(localized: "API-Schlüssel speichern"),
                                    feedback: message.map(CommandFeedback.failure) ?? .success(String(localized: "Schlüssel gespeichert.")))
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if case .stored = keys.status(provider) {
                    Button("Prüfen") { Task { await keys.validate(provider) } }
                        .disabled(keys.check(provider) == .checking)
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                }
            }
            checkText
        }
        .confirmationDialog(Text("Schlüssel löschen?"), isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                let message = keys.delete(provider)
                commands.record(title: String(localized: "API-Schlüssel löschen"),
                                feedback: message.map(CommandFeedback.failure) ?? .success(String(localized: "Schlüssel gelöscht.")))
            }
        } message: {
            Text("Der Schlüssel wird aus dem Schlüsselbund dieses Macs entfernt.")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch keys.status(provider) {
        case .missing:
            Text("kein Schlüssel").foregroundStyle(.secondary)
        case let .stored(mode):
            Text(mode == .deviceOnly ? "gespeichert (nur dieser Mac)" : "gespeichert (iCloud-Schlüsselbund angefordert)")
                .foregroundStyle(.green)
        case let .unreadable(message):
            Text(message).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var checkText: some View {
        switch keys.check(provider) {
        case .unchecked: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .valid: Label("Schlüssel gültig", systemImage: "checkmark.circle").foregroundStyle(.green)
        case let .validWithWarning(text): Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .invalid: Label("Schlüssel ungültig", systemImage: "xmark.circle").foregroundStyle(.red)
        case let .failed(message): Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

// MARK: Agenten & GitHub

private struct AgentSettingsPage: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(NavigationModel.self) private var navigation
    @State private var gitHub: GitHubAvailabilityInfo?

    var body: some View {
        Section("Coding-Agenten") {
            ForEach(monitor.currentSummary?.agents ?? [], id: \.providerId) { agent in
                let presentation = AgentPresentation.make(agent)
                StatusLabel(title: presentation.name, detail: presentation.stateText, level: presentation.level, symbolName: "cpu")
            }
            HStack {
                CommandButton(String(localized: "Agenten neu erkennen"), systemImage: "arrow.clockwise") { .redetectAgents }
                Button("Modellkatalog und Effort-Matrix …") { navigation.show(.agents) }
            }
        }
        Section {
            ExecutablePathsSection()
        } header: {
            Text("Eigene Programmpfade")
        } footer: {
            Text("Ohne eigenen Pfad sucht der Dienst Codex und Claude Code an den dokumentierten Installationsorten. Eine Änderung wirkt sofort: Der Dienst erkennt den Agenten neu, ohne Neustart.")
        }
        Section("GitHub (über gh)") {
            if let available = monitor.currentSummary?.workspace.gitHubAvailable {
                InfoRow("Zuletzt geprüft", available ? String(localized: "gh verfügbar und angemeldet") : String(localized: "gh nicht verfügbar"))
            }
            if let gitHub {
                Label(gitHub.detail, systemImage: gitHub.isAvailable ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(gitHub.isAvailable ? Color.green : Color.orange)
            }
            CommandButton(String(localized: "GitHub-Verbindung prüfen"), systemImage: "checkmark.shield") { .gitHubAvailability } onResult: { outcome in
                if case let .gitHubAvailability(info)? = outcome.result { gitHub = info }
            }
            Text("Software Regisseur speichert kein eigenes GitHub-Token; es verwendet die Anmeldung der GitHub-CLI. Pro Projekt aktivieren Sie GitHub unter „Projekte“.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Programmpfad je Agent (J1 „benutzerdefinierte Pfade“), gespeichert in den Diensteinstellungen.
private struct ExecutablePathsSection: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(ServiceMonitor.self) private var monitor
    @State private var settings: ServiceSettings?
    @State private var drafts: [ProviderID: String] = [:]

    private static let providers: [ProviderID] = [.codex, .claudeCode]

    var body: some View {
        ForEach(Self.providers, id: \.self) { provider in
            let stored = settings?.executablePath(for: provider) ?? ""
            let draft = drafts[provider] ?? stored
            VStack(alignment: .leading, spacing: 4) {
                Text(ProviderNames.displayName(provider)).font(.headline)
                HStack {
                    TextField("automatisch suchen", text: Binding(get: { draft }, set: { drafts[provider] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Auswählen …") {
                        if let path = choose() { drafts[provider] = path }
                    }
                    CommandButton(String(localized: "Pfad übernehmen"), systemImage: "checkmark") {
                        .setAgentExecutablePath(providerId: provider, path: draft.trimmingCharacters(in: .whitespaces).isEmpty ? nil : draft)
                    } onResult: { apply($0, provider: provider) }
                    .disabled(draft == stored || settings == nil)
                    if !stored.isEmpty {
                        CommandButton(String(localized: "Automatisch suchen"), systemImage: "arrow.uturn.backward") {
                            .setAgentExecutablePath(providerId: provider, path: nil)
                        } onResult: { apply($0, provider: provider) }
                    }
                }
            }
        }
        .task(id: monitor.isReachable) {
            let outcome = await commands.perform(String(localized: "Diensteinstellungen laden"), .serviceSettings, quiet: true)
            if case let .serviceSettings(loaded)? = outcome.result { settings = loaded }
        }
    }

    private func apply(_ outcome: CommandOutcome, provider: ProviderID) {
        if case let .serviceSettings(saved)? = outcome.result {
            settings = saved
            drafts[provider] = nil
        }
    }

    private func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = String(localized: "Programm wählen")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}

// MARK: Datenschutz

private struct PrivacySettingsPage: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @State private var progress: String?
    @State private var result: ExportResult?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        Section {
            Text("Exportiert alle Daten (Projekte, Aufgaben, Jobs, Reviews, Verlauf, Konflikte) als JSON und Markdown, optional als ZIP. API-Schlüssel sind nie enthalten; der Export wird vor dem Speichern auf Zugangsdaten geprüft.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    startExport()
                } label: {
                    Label("Daten exportieren …", systemImage: "square.and.arrow.up")
                }
                .disabled(library.database == nil || exportTask != nil)
                if exportTask != nil {
                    Button("Abbrechen") { exportTask?.cancel() }
                }
            }
            if let progress {
                HStack { if exportTask != nil { ProgressView().controlSize(.small) }; Text(progress) }
            }
            if let result {
                InfoRow("Ordner", result.folderURL.path(percentEncoded: false))
                if let archive = result.archiveURL { InfoRow("ZIP", archive.path(percentEncoded: false)) }
                if let archiveError = result.archiveError { Text(archiveError.userMessage).foregroundStyle(.orange) }
                Button("Im Finder zeigen") { LocalOpener.revealInFinder((result.archiveURL ?? result.folderURL).path(percentEncoded: false)) }
            }
        } header: {
            Text("Datenexport")
        }
        Section {
            LocalDeletionSection()
        } header: {
            Text("Lokale Daten löschen")
        } footer: {
            Text("Der Export oben liest nur und ändert nichts. Gelöscht wird ausschließlich durch den Hintergrunddienst und nur, was die Vorschau auflistet. Git-Repositories, Projektordner und Agenten-Worktrees werden nie gelöscht.")
        }
        Section {
            CloudDeletionSection()
        } header: {
            Text("iCloud-Daten löschen")
        }
    }

    private func startExport() {
        guard let database = library.database else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Hier exportieren")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        result = nil
        progress = String(localized: "Export wird vorbereitet …")
        exportTask = Task {
            let exporter = DataExporter(database: database)
            do {
                let exported = try await exporter.export(into: folder) { update in
                    Task { @MainActor in progress = update.localizedDescription }
                }
                result = exported
                progress = String(localized: "Export abgeschlossen.")
                commands.record(title: String(localized: "Daten exportieren"), feedback: .success(String(localized: "Export abgeschlossen.")))
            } catch let error as ExportError {
                progress = error.userMessage
                commands.record(title: String(localized: "Daten exportieren"), feedback: .failure(error.userMessage))
            } catch is CancellationError {
                progress = String(localized: "Export abgebrochen; es wurden keine Teildateien behalten.")
            } catch {
                progress = String(localized: "Export fehlgeschlagen: \(error.localizedDescription)")
                commands.record(title: String(localized: "Daten exportieren"), feedback: .failure(progress ?? ""))
            }
            exportTask = nil
        }
    }
}

// MARK: Version & Updates

private struct AboutSettingsPage: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(SoftwareUpdater.self) private var updater

    var body: some View {
        Section("Version") {
            InfoRow("App", ExportOptions.mainBundleVersion)
            if let summary = monitor.currentSummary {
                InfoRow("Hintergrunddienst", "\(summary.serviceVersion.shortVersion) (\(summary.serviceVersion.build))")
                InfoRow("Protokoll", "\(summary.protocolVersion)")
                InfoRow("Mac", summary.hostName)
                InfoRow("Dienst läuft seit", summary.startedAt.shortDateTime)
            } else {
                InfoRow("Hintergrunddienst", String(localized: "nicht erreichbar"))
            }
        }
        Section("Updates") {
            // Sparkle-Updates (ADR-0017), siehe SoftwareUpdater.swift.
            CheckForUpdatesButton()
        }
    }
}
