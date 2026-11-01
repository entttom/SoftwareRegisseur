import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurSecrets

/// „Einstellungen“ (spec P 8, I, H2): BYOK, providers/models, dictation, sync, folder defaults,
/// default agent, cost table.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var reportedAgents: [AgentCapability] = []
    @State private var settingsError: String?

    var body: some View {
        @Bindable var model = model
        List {
            SyncStatusSection()
            Section {
                NavigationLink("Konflikte") { ConflictListView() }
            }
            Section {
                ForEach(KeyPurpose.allCases, id: \.self) { purpose in
                    ForEach(purpose.providers, id: \.rawValue) { provider in
                        NavigationLink {
                            ProviderKeyView(provider: provider, purpose: purpose)
                        } label: {
                            KeyStatusRow(provider: provider, purpose: purpose)
                        }
                    }
                }
            } header: {
                Text("Eigene API-Schlüssel")
            } footer: {
                Text("Schlüssel liegen nur im Schlüsselbund, nie in iCloud-Datensätzen, Git oder Logs. Ein OpenAI-Schlüssel ist keine Codex-Anmeldung, ein Anthropic-Schlüssel kein Claude-Code-Abonnement.")
            }
            Section {
                NavigationLink("KI-Ausarbeitung") { AISettingsView() }
                NavigationLink("Diktat") { DictationSettingsView() }
                NavigationLink("Kosten") { PriceTableView() }
            } header: {
                Text("Anbieter und Modelle")
            }
            Section {
                Picker(selection: Binding(
                    get: { model.globalSettings.defaultAgentId },
                    set: { provider in Task { await saveGlobal { $0.defaultAgentId = provider } } }
                )) {
                    Text("Keiner").tag(ProviderID?.none)
                    ForEach(Array(Set(reportedAgents.map(\.providerId))).sorted(), id: \.self) { provider in
                        Text(verbatim: reportedAgents.first { $0.providerId == provider }?.displayName ?? provider.rawValue)
                            .tag(ProviderID?.some(provider))
                    }
                } label: {
                    Text("Standardagent")
                }
                NavigationLink("Modell- und Denkstufen-Standards", value: AppRoute.section(.agents))
            } header: {
                Text("Coding-Agenten")
            } footer: {
                Text("Wird vorausgewählt, wenn das Projekt keinen Standardagenten hat. Der Standardagent und die globalen Modell-/Stufenstandards werden mit allen Geräten synchronisiert.")
            }
            Section {
                let layout = model.globalSettings.folderLayout
                LabeledContent { Text(verbatim: layout.requestsRoot) } label: { Text("Requests") }
                LabeledContent {
                    Text(verbatim: "\(layout.openPath), \(layout.activePath), \(layout.reviewPath), \(layout.donePath)")
                } label: {
                    Text("Statusordner")
                }
                LabeledContent { Text(verbatim: layout.adrPath) } label: { Text("ADRs") }
                NavigationLink("Ordnerstandards bearbeiten") { GlobalDefaultsView() }
                if let settingsError { ErrorText(message: settingsError) }
            } header: {
                Text("Ordnerstandards")
            } footer: {
                Text("Standardstruktur neuer Projekte (synchronisiert); projektweise Abweichungen konfiguriert der Mac.")
            }
            DataPrivacySection()
            Section {
                LabeledContent {
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } label: {
                    Text("Version")
                }
                Text("Keine Push-Benachrichtigungen: Die App fragt nie nach der Mitteilungs-Berechtigung.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Einrichtung erneut ansehen") {
                    withAnimation(.smooth) { model.onboarding.reopen() }
                }
                .accessibilityIdentifier("settings.reopenOnboarding")
            } header: {
                Text("Über")
            }
        }
        .readableContentWidth()
        .navigationTitle("Einstellungen")
        .refreshable { await model.sync(.pullToRefresh) }
        .task { await model.reloadGlobalSettings() }
        .reloadOnDataChange {
            reportedAgents = (try? await model.loadCatalog().capabilities) ?? []
        }
    }
}

struct KeyStatusRow: View {
    @Environment(AppModel.self) private var model
    let provider: SoftwareRegisseurAI.AIProviderID
    let purpose: KeyPurpose

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(String(localized: provider.title)) – \(String(localized: purpose.title))")
            switch model.keys.status(provider: provider, purpose: purpose) {
            case .missing:
                Text("Kein Schlüssel").font(.caption).foregroundStyle(.secondary)
            // Coloured symbols, caption text in label colours (A29 contrast).
            case .stored(.deviceOnly):
                StatusBadge(title: "Hinterlegt (nur dieses Gerät)", symbol: "checkmark.circle.fill", tint: .green)
            case .stored(.synchronizableRequested):
                StatusBadge(title: "Hinterlegt (iCloud-Schlüsselbund-Synchronisierung angefordert)", symbol: "checkmark.circle.fill", tint: .green)
            case let .unreadable(message):
                StatusBadge(title: "\(message)", symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// BYOK key entry, check and deletion (spec I).
struct ProviderKeyView: View {
    @Environment(AppModel.self) private var model
    let provider: SoftwareRegisseurAI.AIProviderID
    let purpose: KeyPurpose

    @State private var key = ""
    @State private var syncViaICloud = false
    @State private var message: String?
    @State private var error: String?
    @State private var isChecking = false
    @State private var refresh = 0
    @State private var confirmsDelete = false

    var body: some View {
        let status = model.keys.status(provider: provider, purpose: purpose)
        Form {
            Section {
                switch status {
                case .missing: Text("Noch kein Schlüssel hinterlegt.")
                case .stored: Text("Ein Schlüssel ist hinterlegt. Der Wert wird nicht angezeigt.")
                case let .unreadable(text): ErrorText(message: text)
                }
            }
            .id(refresh)
            Section {
                SecureField("API-Schlüssel", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Über iCloud-Schlüsselbund synchronisieren", isOn: $syncViaICloud)
                Button("Sichern") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Schlüssel")
            } footer: {
                Text("Standard: nur auf diesem Gerät. Mit iCloud-Schlüsselbund wird die Synchronisierung angefordert; ob sie aktiv ist, kann die App nicht prüfen. Niemals Klartext in iCloud-Datensätzen.")
            }
            if case .stored = status {
                Section {
                    Button {
                        Task { await check() }
                    } label: {
                        if isChecking { ProgressView() } else { Text("Schlüssel prüfen") }
                    }
                    .disabled(isChecking)
                    Button("Schlüssel löschen", role: .destructive) { confirmsDelete = true }
                }
            }
            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green) }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle(Text("\(String(localized: provider.title)) – \(String(localized: purpose.title))"))
        // Inline: as a large title „OpenAI – KI-Ausarbeitung“ was cut off on the iPhone.
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Schlüssel löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { delete() }
        }
    }

    private func save() {
        do {
            try model.keys.save(SecretValue(key), provider: provider, purpose: purpose,
                                mode: syncViaICloud ? .synchronizableRequested : .deviceOnly)
            key = ""
            message = String(localized: "Schlüssel gespeichert.")
            error = nil
            refresh += 1
        } catch let keychain as KeychainError {
            error = keychain.userMessage
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func delete() {
        do {
            try model.keys.delete(provider: provider, purpose: purpose)
            message = String(localized: "Schlüssel gelöscht.")
            error = nil
            refresh += 1
        } catch let keychain as KeychainError {
            error = keychain.userMessage
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// Cheap check via the model list endpoint (no generation tokens).
    private func check() async {
        isChecking = true
        defer { isChecking = false }
        do {
            let result: KeyValidationResult = switch purpose {
            case .text: try await model.keys.textProvider(provider).validateAPIKey()
            case .transcription: try await model.keys.transcriptionProvider().validateAPIKey()
            }
            switch result {
            case .valid:
                message = String(localized: "Schlüssel gültig.")
                error = nil
            case let .validWithWarning(warning):
                message = String(localized: "Schlüssel gültig.")
                error = warning
            case .invalid:
                message = nil
                error = String(localized: "Der Anbieter hat den Schlüssel abgelehnt.")
            }
        } catch {
            message = nil
            self.error = errorMessage(error)
        }
    }
}

/// Provider and model for text drafting (spec H3/I: dynamic model list, separate from coding agents).
struct AISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var models: [AIModelInfo] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var manualModel = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(selection: $model.settings.textProvider) {
                    Text("Keiner").tag(String?.none)
                    ForEach(KeyPurpose.text.providers, id: \.rawValue) { Text($0.title).tag(String?.some($0.rawValue)) }
                } label: {
                    Text("Anbieter")
                }
                if let provider = model.settings.textProviderID {
                    KeyStatusRow(provider: provider, purpose: .text)
                    NavigationLink("Schlüssel verwalten") { ProviderKeyView(provider: provider, purpose: .text) }
                }
            } header: {
                Text("KI-Ausarbeitung")
            } footer: {
                Text("Unabhängig von der Transkription und von den Coding-Agenten.")
            }
            if model.settings.textProviderID != nil {
                Section {
                    if let current = model.settings.textModel {
                        LabeledContent { Text(verbatim: current) } label: { Text("Gewählt") }
                    }
                    Button {
                        Task { await loadModels() }
                    } label: {
                        if isLoading { ProgressView() } else { Text("Modelle vom Anbieter laden") }
                    }
                    ForEach(models.filter { $0.capabilities.textGeneration != .unsupported && $0.lifecycle != .retired }) { info in
                        OptionRow(title: "\(info.displayName)",
                                  detail: info.lifecycle == .deprecated ? "Abgekündigt" : nil,
                                  selected: model.settings.textModel == info.id) {
                            model.settings.textModel = info.id
                        }
                    }
                    HStack {
                        TextField("Modell-ID manuell", text: $manualModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Übernehmen") {
                            model.settings.textModel = manualModel.trimmingCharacters(in: .whitespaces)
                            manualModel = ""
                        }
                        .disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Modell")
                }
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle("KI-Ausarbeitung")
        .onChange(of: model.settings.textProvider) { _, _ in
            models = []
            model.settings.textModel = nil
        }
    }

    private func loadModels() async {
        guard let provider = model.settings.textProviderID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await model.keys.textProvider(provider).listModels()
            error = models.isEmpty ? String(localized: "Der Anbieter hat keine Modelle gemeldet.") : nil
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// Dictation settings per device (spec H2).
struct DictationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var hintsText = ""
    @State private var keepDays = 7

    private enum RetentionChoice: Hashable { case delete, keep, days }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(selection: $model.settings.dictationMethod) {
                    ForEach(TranscriptionMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Spracherkennung")
                }
                Toggle("Nach dem Diktat automatisch einen Entwurf vorbereiten", isOn: $model.settings.autoDraftAfterDictation)
            } footer: {
                Text("Der Entwurf wird vorbereitet; Sie sehen den Kontext vor dem Senden und geben ihn selbst frei. Ein Entwurf ist nie eine Zustimmung zum Agentenstart.")
            }
            Section {
                TextField("Modell", text: $model.settings.transcriptionModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                KeyStatusRow(provider: .openai, purpose: .transcription)
                NavigationLink("Schlüssel verwalten") { ProviderKeyView(provider: .openai, purpose: .transcription) }
            } header: {
                Text("OpenAI Speech-to-Text")
            } footer: {
                Text("Standard: gpt-transcribe. „Schlüssel prüfen“ warnt, wenn das Modell für Ihren Schlüssel nicht gelistet ist.")
            }
            Section {
                TextField("Sprache (z. B. de-AT)", text: $model.settings.speechLocaleIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Apple-Spracherkennung")
            }
            Section {
                TextField("Begriffe, durch Komma getrennt", text: $hintsText, axis: .vertical)
                    .onSubmit { model.settings.transcriptionHints = TranscriptionHints.parse(hintsText) }
                Button("Begriffe übernehmen") { model.settings.transcriptionHints = TranscriptionHints.parse(hintsText) }
            } header: {
                Text("Projektbegriffe als Hinweise")
            } footer: {
                Text("Hilft beim Erkennen von Fachbegriffen und Akronymen; sie werden nicht als gesprochener Text eingefügt.")
            }
            Section {
                Picker(selection: Binding<RetentionChoice>(
                    get: {
                        switch model.settings.audioRetention {
                        case .deleteAfterTranscription: .delete
                        case .keepLocally: .keep
                        case .keepForDays: .days
                        }
                    },
                    set: { choice in
                        model.settings.audioRetention = switch choice {
                        case .delete: .deleteAfterTranscription
                        case .keep: .keepLocally
                        case .days: .keepForDays(keepDays)
                        }
                    }
                )) {
                    Text("Nach erfolgreicher Verarbeitung löschen").tag(RetentionChoice.delete)
                    Text(DeviceKind.current.pick(phone: "Auf diesem iPhone behalten", pad: "Auf diesem iPad behalten") as LocalizedStringResource)
                        .tag(RetentionChoice.keep)
                    Text("Für einige Tage behalten").tag(RetentionChoice.days)
                } label: {
                    Text("Originalaufnahme")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if case .keepForDays = model.settings.audioRetention {
                    Stepper(value: $keepDays, in: 1...90) {
                        Text("\(keepDays) Tage")
                    }
                    .onChange(of: keepDays) { _, days in model.settings.audioRetention = .keepForDays(days) }
                }
            } header: {
                Text("Aufbewahrung")
            } footer: {
                Text("Audio wird nie synchronisiert.")
            }
        }
        .navigationTitle("Diktat")
        .onAppear {
            hintsText = model.settings.transcriptionHints.joined(separator: ", ")
            if case let .keepForDays(days) = model.settings.audioRetention { keepDays = days }
        }
    }
}

/// User-maintained prices; estimates are always labelled „geschätzt“ (spec H3, research §2.4).
struct PriceTableView: View {
    @Environment(AppModel.self) private var model
    @State private var provider = "openai"
    @State private var modelID = ""
    @State private var input = ""
    @State private var output = ""
    @State private var audio = ""

    var body: some View {
        @Bindable var model = model
        let entries = model.settings.priceTable.entries.sorted { ($0.key.provider.rawValue, $0.key.model) < ($1.key.provider.rawValue, $1.key.model) }
        Form {
            Section {
                TextField("Währung (ISO, z. B. USD)", text: $model.settings.priceTable.currencyCode)
                    .textInputAutocapitalization(.characters)
                DatePicker(selection: Binding(
                    get: { model.settings.priceTable.asOf ?? .now },
                    set: { model.settings.priceTable.asOf = $0 }
                ), displayedComponents: .date) {
                    Text("Preise geprüft am")
                }
            } footer: {
                Text("Kein Anbieter liefert Preise per API; tragen Sie die Werte aus der Preisliste des Anbieters ein. Alle Kostenangaben sind geschätzt.")
            }
            Section {
                if entries.isEmpty {
                    Text("Noch keine Preise hinterlegt.").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.key) { entry in
                    VStack(alignment: .leading) {
                        Text(verbatim: "\(entry.key.provider.rawValue) · \(entry.key.model)")
                        Text(verbatim: priceSummary(entry.value)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Löschen", role: .destructive) {
                            model.settings.priceTable.setPrice(nil, provider: entry.key.provider, model: entry.key.model)
                        }
                    }
                }
            } header: {
                Text("Preise")
            }
            Section {
                Picker(selection: $provider) {
                    ForEach(KeyPurpose.text.providers, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Text("Anbieter")
                }
                TextField("Modell-ID", text: $modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Eingabe je 1 Mio. Tokens", text: $input).keyboardType(.decimalPad)
                TextField("Ausgabe je 1 Mio. Tokens", text: $output).keyboardType(.decimalPad)
                TextField("Audio je Minute", text: $audio).keyboardType(.decimalPad)
                Button("Preis sichern") { addPrice() }
                    .disabled(modelID.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Preis hinzufügen oder ändern")
            }
        }
        .navigationTitle("Kosten")
    }

    private func decimal(_ text: String) -> Decimal? {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? nil : Decimal(string: normalized)
    }

    private func addPrice() {
        let price = ModelPrice(inputPerMillionTokens: decimal(input), outputPerMillionTokens: decimal(output),
                               perAudioMinute: decimal(audio))
        model.settings.priceTable.setPrice(price, provider: SoftwareRegisseurAI.AIProviderID(rawValue: provider),
                                           model: modelID.trimmingCharacters(in: .whitespaces))
        modelID = ""
        input = ""
        output = ""
        audio = ""
    }

    private func priceSummary(_ price: ModelPrice) -> String {
        let code = model.settings.priceTable.currencyCode
        var parts: [String] = []
        if let value = price.inputPerMillionTokens { parts.append(String(localized: "Eingabe \(value.formatted(.currency(code: code)))/1M")) }
        if let value = price.outputPerMillionTokens { parts.append(String(localized: "Ausgabe \(value.formatted(.currency(code: code)))/1M")) }
        if let value = price.perAudioMinute { parts.append(String(localized: "Audio \(value.formatted(.currency(code: code)))/min")) }
        return parts.joined(separator: " · ")
    }
}

extension SettingsView {
    fileprivate func saveGlobal(_ change: @escaping (inout GlobalSettings) -> Void) async {
        do {
            try await model.updateGlobalSettings(change)
            settingsError = nil
        } catch {
            settingsError = errorMessage(error)
        }
    }
}

/// Synced folder and workspace defaults for new projects (spec F2, P 8).
struct GlobalDefaultsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = GlobalSettings.defaults
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                TextField("Requests", text: $draft.folderLayout.requestsRoot)
                TextField("Offen", text: $draft.folderLayout.openPath)
                TextField("In Arbeit", text: $draft.folderLayout.activePath)
                TextField("Review", text: $draft.folderLayout.reviewPath)
                TextField("Erledigt", text: $draft.folderLayout.donePath)
                TextField("ADRs", text: $draft.folderLayout.adrPath)
            } header: {
                Text("Ordner (relativ zum Repository)")
            } footer: {
                if !draft.folderLayout.isValid {
                    Text("Pfade müssen relativ sein und dürfen kein „..“ enthalten.").foregroundStyle(.red)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Section {
                Toggle("Parallele Läufe erlauben", isOn: $draft.workspace.allowParallel)
                Toggle("Projektweite Sperre", isOn: $draft.workspace.projectWideLock)
                Picker("Integration", selection: $draft.workspace.integrationStrategy) {
                    ForEach(IntegrationStrategy.allCases, id: \.self) { strategy in Text(strategy.title).tag(strategy) }
                }
                Toggle("„git init“ für neue Ordner vorschlagen", isOn: $draft.workspace.proposeGitInitForNewFolders)
            } header: {
                Text("Arbeitsbereich")
            } footer: {
                Text("Gilt für neu angelegte Projekte. „git init“ wird auch mit dieser Voreinstellung nur nach Ihrer ausdrücklichen Zustimmung im jeweiligen Projekt ausgeführt.")
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle("Ordnerstandards")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { Task { await save() } }
                    .disabled(!draft.folderLayout.isValid || isSaving || draft == model.globalSettings)
            }
        }
        .task {
            await model.reloadGlobalSettings()
            draft = model.globalSettings
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let edited = draft
        do {
            try await model.updateGlobalSettings { settings in
                settings.folderLayout = edited.folderLayout
                settings.workspace = edited.workspace
            }
            draft = model.globalSettings
            error = nil
        } catch {
            self.error = errorMessage(error)
            draft = model.globalSettings
        }
    }
}
