import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// „Mit KI ausarbeiten (Mac, mit Repo-Kontext)“ (H4, A11). Zeigt vorab, dass Repo-Inhalte an den gewählten
/// Anbieter gehen, und danach das Kontext-Manifest: enthaltene Dateien, Ausschlüsse mit Grund, Tokens.
struct MacAIElaborationSheet: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(ProviderKeyStore.self) private var keys
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem
    @State private var provider: SoftwareRegisseurAI.AIProviderID = .openai
    @State private var models: [AIModelInfo] = []
    @State private var modelError: String?
    @State private var modelId = ""
    @State private var mode: MacAIElaborationMode = .ausfuehrlich
    @State private var filesText = ""
    @State private var consent = false
    @State private var info: MacAIElaborationInfo?
    @State private var isStarting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mit KI ausarbeiten (Mac, mit Repo-Kontext)").font(.title2.bold())
            Text(item.displayTitle).foregroundStyle(.secondary)
            if let info {
                ElaborationStatusView(info: info)
            } else {
                setupForm
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if info == nil {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        start()
                    } label: {
                        if isStarting { ProgressView().controlSize(.small) } else { Text("Ausarbeitung starten") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart || isStarting)
                } else {
                    Button("Schließen") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 620)
        .onAppear { keys.refresh() }
        .task(id: provider) { await loadModels() }
        .task(id: info?.requestId) { await poll() }
    }

    private var keyStored: Bool {
        if case .stored = keys.status(provider) { return true }
        return false
    }

    private var canStart: Bool {
        keyStored && consent && !modelId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var setupForm: some View {
        Form {
            Picker("Anbieter", selection: $provider) {
                ForEach(ProviderKeyStore.providers, id: \.rawValue) { provider in
                    Text(ProviderKeyStore.displayName(provider)).tag(provider)
                }
            }
            if !keyStored {
                HStack {
                    UnavailableNotice(text: String(localized: "Für diesen Anbieter ist am Mac kein API-Schlüssel gespeichert."))
                    Button("Einstellungen öffnen") {
                        dismiss()
                        navigation.show(.settings)
                    }
                }
            }
            if models.isEmpty {
                TextField("Modell-ID", text: $modelId, prompt: Text("Modell-ID des Anbieters"))
                if let modelError { Text(modelError).font(.caption).foregroundStyle(.secondary) }
            } else {
                Picker("Modell", selection: $modelId) {
                    Text("Bitte wählen").tag("")
                    ForEach(models) { model in
                        Text(model.displayName.isEmpty ? model.id : model.displayName).tag(model.id)
                    }
                }
            }
            Picker("Art der Ausarbeitung", selection: $mode) {
                ForEach(MacAIElaborationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Zusätzliche Dateien (relativ zum Repository, eine pro Zeile)", text: $filesText, axis: .vertical)
                .lineLimit(3...6)
            Text("Geheimnisse (.env, Schlüssel, Zugangsdaten) werden immer ausgeschlossen und im Manifest begründet.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Ich bin einverstanden, dass Aufgabentext und ausgewählte Repo-Inhalte an \(ProviderKeyStore.displayName(provider)) übermittelt werden.", isOn: $consent)
        }
        .formStyle(.grouped)
    }

    private func loadModels() async {
        models = []
        modelId = ""
        modelError = nil
        guard keyStored else { return }
        switch await keys.models(provider) {
        case let .success(list):
            models = list.sorted { $0.id < $1.id }
        case let .failure(error):
            modelError = String(localized: "Modellliste nicht abrufbar (\(error.message)). Sie können die Modell-ID direkt eingeben.")
        }
    }

    private func start() {
        let files = filesText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let command = MacAIElaborationCommand(workItemId: item.uuid, providerId: provider.rawValue,
                                              modelId: modelId.trimmingCharacters(in: .whitespaces), mode: mode, selectedFiles: files)
        isStarting = true
        error = nil
        Task {
            let outcome = await commands.perform(String(localized: "KI-Ausarbeitung starten"), .requestMacAIElaboration(command))
            isStarting = false
            if case let .macAIElaboration(info)? = outcome.result {
                self.info = info
            } else {
                error = outcome.feedback.message
            }
        }
    }

    /// Fragt den Stand ab, bis die Ausarbeitung fertig oder fehlgeschlagen ist.
    private func poll() async {
        while let current = info, current.state == .pending || current.state == .running, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let outcome = await commands.perform(String(localized: "Stand der KI-Ausarbeitung"),
                                                 .macAIElaborationStatus(requestId: current.requestId), quiet: true)
            if case let .macAIElaboration(updated)? = outcome.result {
                info = updated
            } else if !outcome.succeeded {
                error = outcome.feedback.message
                return
            }
        }
    }
}

/// Kontext-Manifest und Ergebnis einer Ausarbeitung.
struct ElaborationStatusView: View {
    let info: MacAIElaborationInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if info.state == .pending || info.state == .running { ProgressView().controlSize(.small) }
                    Text("Status: \(info.state.displayName)").font(.headline)
                    Spacer()
                    Text(verbatim: "\(info.providerId) · \(info.modelId)").foregroundStyle(.secondary)
                }
                if let message = info.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                if let version = info.draftVersion {
                    Label("Entwurf Version \(version) erstellt. Sie finden ihn in der Aufgabe unter „KI-Entwürfe“.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                Text("Übermittelter Kontext (ca. \(info.estimatedTokens) Tokens)").font(.headline)
                if info.included.isEmpty {
                    Text("Noch kein Kontext ermittelt.").foregroundStyle(.secondary)
                }
                ForEach(Array(info.included.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "doc.text").accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            if let path = entry.path { Text(verbatim: path).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text("\(entry.characterCount) Zeichen").font(.caption).foregroundStyle(.secondary)
                        if entry.redactionCount > 0 {
                            Badge(text: String(localized: "\(entry.redactionCount) geschwärzt"), color: .orange)
                        }
                        if entry.truncated { Badge(text: String(localized: "gekürzt")) }
                    }
                }
                if !info.excluded.isEmpty {
                    Text("Ausgeschlossen").font(.headline)
                    ForEach(Array(info.excluded.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(entry.path ?? entry.title)
                            Spacer()
                            Text(entry.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
