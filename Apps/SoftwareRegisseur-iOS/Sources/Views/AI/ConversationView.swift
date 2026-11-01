import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Mit KI besprechen“ (spec H3): questions, variants and change requests about one note/request.
/// Each turn shows its context manifest first; a proposed draft is adopted only after „Übernehmen“.
/// This is not a coding-agent session and never starts an agent.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem

    @State private var controller: ConversationController?
    @State private var contextItems: [AIContextItem] = []
    @State private var selectedContext: Set<String> = []
    @State private var message = ""
    @State private var conversationRecord: AIConversation?
    @State private var adoptedTitle: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                let resolution = TextProviderResolution.resolve(model)
                if case .ready = resolution, let controller {
                    conversation(controller)
                } else if case .ready = resolution {
                    ProgressView()
                } else {
                    Form { TextProviderSetupHint(resolution: resolution) }
                }
            }
            .navigationTitle("Mit KI besprechen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
            }
        }
        .task { await setUp() }
    }

    private func conversation(_ controller: ConversationController) -> some View {
        List {
            Section {
                Text("Gesprächspartner zur Ausarbeitung – kein Coding-Agent. Vorschläge werden erst nach Ihrer Freigabe übernommen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !contextItems.isEmpty {
                Section {
                    ForEach(contextItems) { entry in
                        Toggle(isOn: Binding(
                            get: { selectedContext.contains(entry.id) },
                            set: { on in if on { selectedContext.insert(entry.id) } else { selectedContext.remove(entry.id) } }
                        )) {
                            Text(entry.kind.title)
                        }
                    }
                } header: {
                    Text("Projektdaten im Kontext")
                }
            }
            Section {
                if controller.turns.isEmpty {
                    Text("Stellen Sie eine Frage oder bitten Sie um eine Änderung des Entwurfs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.turns) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.role == .user ? "Sie" : "KI")
                            .font(.caption.bold())
                            .foregroundStyle(turn.role == .user ? Color.accentColor : .secondary)
                        Text(verbatim: turn.text).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Gespräch")
            }
            if let proposal = controller.pendingProposal {
                Section {
                    DraftContentView(draft: proposal)
                    Button("Als neue Entwurfsversion übernehmen") { Task { await adopt(controller) } }
                        .buttonStyle(.borderedProminent)
                    Button("Vorschlag verwerfen", role: .destructive) { Task { await controller.discardProposal() } }
                } header: {
                    Text("Vorgeschlagene Entwurfsversion")
                }
            }
            if let adoptedTitle {
                Label("Übernommen: \(adoptedTitle)", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            phaseSection(controller)
            if controller.usage.totalTokens > 0 {
                Section {
                    UsageView(usage: controller.usage, provider: controller.providerID, modelID: controller.model)
                }
            }
            if let error { ErrorText(message: error) }
        }
    }

    @ViewBuilder
    private func phaseSection(_ controller: ConversationController) -> some View {
        switch controller.phase {
        case .composing:
            Section {
                TextField("Nachricht", text: $message, axis: .vertical)
                    .lineLimit(1...6)
                Button("Kontext prüfen und senden …") {
                    Task {
                        await applyContextSelection()
                        await controller.prepare(message: message)
                    }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case let .reviewingContext(prepared):
            ManifestView(manifest: prepared.manifest)
            Section {
                Button("Senden") {
                    Task {
                        await controller.confirmSend()
                        if case .composing = controller.phase { message = "" }
                        await persist(controller)
                    }
                }
                Button("Zurück", role: .cancel) { controller.cancelPrepared() }
            }
        case .sending:
            Section {
                HStack {
                    ProgressView()
                    Text("Antwort wird erstellt …")
                }
            }
        case let .failed(text):
            Section {
                ErrorText(message: text)
                Button("OK") { controller.dismissError() }
            }
        }
    }

    private func setUp() async {
        guard controller == nil, case let .ready(provider, modelID) = TextProviderResolution.resolve(model),
              let database = model.database else { return }
        do {
            let current = try await database.workItems.fetch(item.uuid) ?? item
            contextItems = try await ProjectContextBuilder.items(for: current, database: database)
            selectedContext = Set(contextItems.map(\.id))
            let versions = try await model.requireDraftVersions().versions(for: item.uuid)
            let latest = versions.last(where: { !$0.adoptedDraftIndexes.isEmpty }).flatMap { $0.drafts.first }
            let session = ConversationSession(
                provider: provider, model: modelID,
                originalNote: current.originalNote.isEmpty ? current.title : current.originalNote,
                transcript: current.transcript, currentDraft: latest, projectContext: contextItems
            )
            controller = ConversationController(session: session)
            conversationRecord = AIConversation(
                itemId: item.uuid, provider: SoftwareRegisseurDomain.AIProviderID(rawValue: provider.providerID.rawValue) ?? .openAI,
                model: AIModelID(rawValue: modelID) ?? "unknown",
                contextScope: current.projectId.map { .project($0) } ?? .itemOnly, createdAt: .now
            )
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// The session re-reads its context on every prepare; narrow it to the selected items first.
    private func applyContextSelection() async {
        await controller?.setProjectContext(contextItems.filter { selectedContext.contains($0.id) })
    }

    /// Stores the conversation (synced as `AIConversation`, spec H3) after each turn.
    private func persist(_ controller: ConversationController) async {
        guard let database = model.database, var record = conversationRecord else { return }
        let known = record.messages.count
        for turn in controller.turns.dropFirst(known) {
            record.append(SoftwareRegisseurDomain.AIMessage(role: turn.role == .user ? .user : .assistant, text: turn.text, createdAt: turn.date))
        }
        conversationRecord = record
        try? await database.aiRecords.saveConversation(record, at: .now)
        model.noteLocalChange()
    }

    private func adopt(_ controller: ConversationController) async {
        guard let database = model.database, let draft = await controller.acceptProposal() else { return }
        do {
            let version = try await model.requireDraftVersions().append(
                for: item.uuid, source: .conversation, mode: nil, provider: controller.providerID.rawValue,
                model: controller.model, drafts: [draft], usage: .zero, at: .now
            )
            // Title, body and priority are applied; the type of an existing item stays fixed.
            let current = try await database.workItems.fetch(item.uuid) ?? item
            _ = try await DraftAdopter(workItems: database.workItems, headings: model.draftHeadings)
                .apply(draft, to: current, actor: model.actor, at: .now)
            try await model.requireDraftVersions().markAdopted(version.id, draftIndexes: [0], for: item.uuid)
            adoptedTitle = draft.title
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }
}
