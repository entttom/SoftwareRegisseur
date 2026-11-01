import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// „Mit KI besprechen“ am Mac (H3) für Aufgaben und Inbox-Notizen. Jede Nachricht zeigt vor dem Senden ihr
/// Kontext-Manifest; das Gespräch wird nach jedem Zug über den Dienst gespeichert und synchronisiert. Vorschläge
/// werden nur nach ausdrücklicher Übernahme als Entwurfsversion angelegt und übernommen. Kein Coding-Agent, startet
/// nie einen Agenten.
struct ConversationPanel: View {
    @Environment(ProviderKeyStore.self) private var keys
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @Environment(NavigationModel.self) private var navigation
    @AppStorage(MacTextAISettings.providerKey) private var providerRaw = ""
    @AppStorage(MacTextAISettings.modelKey) private var modelId = ""

    let item: WorkItem
    @Binding var model: MacConversationModel?
    @State private var setupError: String?
    @State private var confirmAdoption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gesprächspartner zur Ausarbeitung – kein Coding-Agent. Es wird nie ein Agent gestartet; Vorschläge übernehmen Sie nur ausdrücklich.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let model {
                conversation(model)
            } else {
                setup
            }
        }
        .onAppear { keys.refresh() }
        .onChange(of: item) { _, updated in model?.itemDidChange(updated) }
    }

    // MARK: Einrichtung

    private var resolution: MacTextAISettings.Resolution {
        MacTextAISettings.resolve(providerRaw: providerRaw, model: modelId, hasKey: keys.hasKey)
    }

    @ViewBuilder
    private var setup: some View {
        switch resolution {
        case let .ready(provider, modelName):
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anbieter: \(provider.displayName) · Modell: \(modelName)")
                    Text("Standardmäßig wird nur der Text dieser Notiz bzw. dieses Requests gesendet. Weitere Projektdaten und Repo-Kontext wählen Sie im nächsten Schritt ausdrücklich aus.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let setupError { Label(setupError, systemImage: "xmark.octagon").foregroundStyle(.red) }
                    Button {
                        start(provider: provider, model: modelName)
                    } label: {
                        Label("Gespräch beginnen", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        default:
            HStack(alignment: .firstTextBaseline) {
                UnavailableNotice(text: resolution.explanation ?? "")
                Button("Einstellungen öffnen") { navigation.show(.settings) }
            }
        }
    }

    private func start(provider: SoftwareRegisseurAI.AIProviderID, model modelName: String) {
        do {
            let client = try keys.textProvider(provider)
            let snapshot = library.snapshot
            model = MacConversationModel(
                item: item, provider: client, model: modelName,
                optionalContext: MacConversationContext.projectItems(
                    for: item, workItems: snapshot.workItems, adrs: snapshot.project(item.projectId)?.adrs ?? []),
                commands: commands)
            setupError = nil
        } catch {
            setupError = ProviderKeyStore.message(for: error)
        }
    }

    // MARK: Gespräch

    private func conversation(_ model: MacConversationModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anbieter: \(model.providerID.displayName) · Modell: \(model.modelID)")
                .font(.caption).foregroundStyle(.secondary)
            ConversationContextBox(model: model)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if model.controller.turns.isEmpty {
                        Text("Stellen Sie eine Frage, diskutieren Sie Varianten oder bitten Sie um eine Änderung des Entwurfs.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.controller.turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role == .user ? "Sie" : "KI")
                                .font(.caption.bold())
                                .foregroundStyle(turn.role == .user ? Color.accentColor : .secondary)
                            Text(verbatim: turn.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Gespräch")
            }
            if let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            proposal(model)
            phase(model)
            if model.controller.usage.totalTokens > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nutzung bisher: \(model.controller.usage.inputTokens) Eingabe-, \(model.controller.usage.outputTokens) Ausgabe-Tokens")
                    Text(model.costText())
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func proposal(_ model: MacConversationModel) -> some View {
        if let proposal = model.controller.pendingProposal {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    DraftContentView(content: DraftMapping.content(proposal), accepted: false)
                    Text("Übernehmen legt den Vorschlag als neue Entwurfsversion an und ersetzt Titel, Inhalt und Priorität dieser Aufgabe; Originalnotiz, Transkript, Labels und Abhängigkeiten bleiben. Verwerfen behält das Gespräch und ändert nichts. Es wird kein Agent gestartet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            confirmAdoption = true
                        } label: {
                            if model.adoption == .saving { ProgressView().controlSize(.small) } else { Text("In die Aufgabe übernehmen …") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.adoption == .saving)
                        Button("Vorschlag verwerfen", role: .destructive) { Task { await model.discardProposal() } }
                    }
                }
            } label: {
                Text("Vorgeschlagene neue Fassung")
            }
            .confirmationDialog(Text("Vorschlag übernehmen?"), isPresented: $confirmAdoption) {
                Button("Übernehmen") { Task { await model.acceptProposal() } }
            } message: {
                Text("Der Vorschlag wird als Entwurfsversion gespeichert; Titel, Inhalt und Priorität der Aufgabe werden durch ihn ersetzt. Die Änderung wird synchronisiert. Es wird kein Agent gestartet.")
            }
        }
        switch model.adoption {
        case let .adopted(title):
            Label("Übernommen: \(title)", systemImage: "checkmark.circle").foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        case .idle, .saving:
            EmptyView()
        }
    }

    @ViewBuilder
    private func phase(_ model: MacConversationModel) -> some View {
        @Bindable var model = model
        switch model.controller.phase {
        case .composing:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Nachricht an die KI", text: $model.message, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Kontext prüfen …") { Task { await model.prepare() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canPrepare)
                }
            }
        case let .reviewingContext(prepared):
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ConversationManifestView(manifest: prepared.manifest)
                    HStack {
                        Spacer()
                        Button("Zurück") { model.cancelPrepared() }
                            .keyboardShortcut(.cancelAction)
                        Button("Senden") { Task { await model.confirmSend() } }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } label: {
                Text("Wird gesendet, wenn Sie bestätigen")
            }
        case .sending:
            HStack {
                ProgressView().controlSize(.small)
                Text("Antwort wird erstellt …")
            }
        case let .failed(text):
            HStack {
                Label(text, systemImage: "xmark.octagon").foregroundStyle(.red)
                Spacer()
                Button("OK") { model.dismissError() }
            }
        }
    }
}

/// Kontextwahl: Notiz/Request immer, Projektdaten und Repo-Kontext nur nach Auswahl.
private struct ConversationContextBox: View {
    @Environment(LibraryStore.self) private var library
    @Bindable var model: MacConversationModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Immer enthalten: Originalnotiz bzw. Transkript und der aktuelle Request-Inhalt.", systemImage: "doc.text")
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.optionalContext) { entry in
                    Toggle(isOn: Binding(get: { model.isSelected(entry.id) }, set: { model.setSelected(entry.id, $0) })) {
                        Text("\(entry.title) mitsenden (synchronisierte Projektdaten)")
                    }
                }
                if model.canUseRepoContext {
                    Divider()
                    Toggle(isOn: Binding(get: { model.repoContextEnabled }, set: { model.setRepoContextEnabled($0) })) {
                        Text("Repo-Kontext über die Mac-Ausarbeitung einbeziehen")
                    }
                    if model.repoContextEnabled { repoSection }
                } else {
                    Text("Repo-Kontext ist nur für Aufgaben mit Projekt verfügbar.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Kontext")
        }
    }

    @ViewBuilder
    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Der Hintergrunddienst ermittelt Repository-Struktur, akzeptierte ADRs, bestehende Requests und die angegebenen Dateien und erstellt daraus eine Ausarbeitung. Diese geht anschließend als Kontext in das Gespräch. Geheimnisse (.env, Schlüssel, Zugangsdaten) werden immer ausgeschlossen. Zusätzlich erscheint die Ausarbeitung unter „KI-Entwürfe“ und wird nur nach Ihrer Freigabe übernommen.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Zusätzliche Dateien (relativ zum Repository, eine pro Zeile)", text: $model.repoFilesText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Toggle("Ich bin einverstanden, dass Aufgabentext und ausgewählte Repo-Inhalte an \(model.providerID.displayName) übermittelt werden.",
                   isOn: $model.repoConsent)
            HStack {
                Button("Repo-Kontext ermitteln") { Task { await model.requestRepoContext() } }
                    .disabled(!model.canRequestRepoContext)
                status
            }
            if let context = model.repoContextItem {
                Label("Im Gesprächskontext: \(context.title)", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
        .task(id: runningRequestId) {
            guard runningRequestId != nil else { return }
            while await model.refreshRepoContext(), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
            }
            model.attachRepoDraft(from: await library.drafts(for: model.item.uuid))
        }
        .task(id: library.snapshot.loadedAt) {
            if case .ready = model.repoState, model.repoContextItem == nil {
                model.attachRepoDraft(from: await library.drafts(for: model.item.uuid))
            }
        }
    }

    private var runningRequestId: AIRequestID? {
        if case let .running(info) = model.repoState { return info.requestId }
        return nil
    }

    @ViewBuilder
    private var status: some View {
        switch model.repoState {
        case .idle:
            EmptyView()
        case .requesting:
            ProgressView().controlSize(.small)
        case let .running(info):
            ProgressView().controlSize(.small)
            Text("läuft (ca. \(info.estimatedTokens) Tokens, \(info.included.count) Einträge)").font(.caption)
        case let .ready(info):
            Text("fertig: \(info.included.count) Einträge übermittelt, \(info.excluded.count) ausgeschlossen, ca. \(info.estimatedTokens) Tokens")
                .font(.caption).foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
        }
    }
}

/// Was mit der nächsten Nachricht gesendet wird (H3: „vor dem Senden sichtbar“).
struct ConversationManifestView: View {
    let manifest: ContextManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InfoRow("Anbieter", manifest.provider.displayName)
            InfoRow("Modell", manifest.model)
            InfoRow("Umfang", String(localized: "ca. \(manifest.estimatedTokens) Tokens (geschätzt), \(manifest.totalCharacters) Zeichen"))
            ForEach(manifest.included) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityHidden(true)
                    Text(entry.title)
                    Spacer()
                    Text("\(entry.characterCount) Zeichen").font(.caption).foregroundStyle(.secondary)
                    if entry.redactionCount > 0 {
                        Badge(text: String(localized: "\(entry.redactionCount) geschwärzt"), color: .orange)
                    }
                    if entry.truncated { Badge(text: String(localized: "gekürzt")) }
                }
            }
            ForEach(manifest.excluded) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(entry.path ?? entry.title)
                    Spacer()
                    Text(entry.reason.userMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Inhalte werden als Daten gesendet, nicht als Anweisungen; mögliche Geheimnisse werden geschwärzt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
