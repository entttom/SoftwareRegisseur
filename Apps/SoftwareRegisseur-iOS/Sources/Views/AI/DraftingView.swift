import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Mit KI ausarbeiten“ (spec H3/H4): mode → visible context manifest → send → drafts with per-item
/// confirmation and open questions. Never auto-approved, never starts an agent.
struct DraftingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem
    /// Settings option „nach Diktat automatisch Entwurf erzeugen“: prepares the request at once; the
    /// manifest is still shown and sending stays a user action (spec H3).
    var autoPrepare = false

    private enum Phase {
        case configure
        case manifest(PreparedDraftRequest, DraftComposer)
        case sending
        case result(DraftComposition, versionID: DraftVersionID)
        case adopted(Int)
    }

    @State private var mode: DraftMode = .kurz
    @State private var includeProjectData = true
    @State private var phase: Phase = .configure
    @State private var session = DraftReviewSession(mode: .kurz, drafts: [])
    @State private var error: String?
    @State private var completeSourceNote = true
    @State private var queuedForMac = false
    @State private var latestDraft: StructuredDraft?

    var body: some View {
        NavigationStack {
            Form {
                let resolution = TextProviderResolution.resolve(model)
                if case .ready = resolution {
                    content(resolution)
                } else {
                    TextProviderSetupHint(resolution: resolution)
                    repoContextSection
                }
                if let error { ErrorText(message: error) }
            }
            .navigationTitle("Mit KI ausarbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .task {
            guard autoPrepare, case .configure = phase else { return }
            await prepare(TextProviderResolution.resolve(model))
        }
    }

    @ViewBuilder
    private func content(_ resolution: TextProviderResolution) -> some View {
        switch phase {
        case .configure:
            Section {
                Picker(selection: $mode) {
                    ForEach(DraftMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Modus")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Modus")
            }
            Section {
                Toggle("Projektdaten mitsenden (bestehende Requests, ADR-Index)", isOn: $includeProjectData)
                    .disabled(item.projectId == nil)
                Button("Kontext prüfen") { Task { await prepare(resolution) } }
            } footer: {
                Text("Vor dem Senden sehen Sie genau, welche Inhalte an den Anbieter gehen.")
            }
            repoContextSection
        case let .manifest(prepared, composer):
            ManifestView(manifest: prepared.manifest)
            Section {
                Button("Senden") { Task { await send(prepared, composer: composer) } }
                Button("Zurück", role: .cancel) { phase = .configure }
            }
        case .sending:
            Section {
                HStack {
                    ProgressView()
                    Text("Entwurf wird erstellt …")
                }
            }
        case let .result(composition, versionID):
            resultSections(composition, versionID: versionID)
        case let .adopted(count):
            Section {
                Label(count == 1 ? "Entwurf übernommen." : "\(count) Aufgaben angelegt.", systemImage: "checkmark.circle")
                Button("Erneut ausarbeiten") { phase = .configure }
                Button("Fertig") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var repoContextSection: some View {
        if item.projectId != nil {
            Section {
                if queuedForMac {
                    Label("In der Warteschlange für den Mac.", systemImage: "hourglass")
                } else {
                    Button("Am Mac mit Repo-Kontext ausarbeiten") { Task { await queueForMac() } }
                        .disabled(model.settings.textProviderID == nil || (model.settings.textModel ?? "").isEmpty)
                }
            } header: {
                Text("Vertiefte Ausarbeitung")
            } footer: {
                Text("Der Mac ergänzt Repository-Struktur, akzeptierte ADRs und ausgewählte Quelldateien (ohne Secrets) und legt das Ergebnis als prüfbaren Entwurf ab. Ist der Mac nicht erreichbar, wartet der Auftrag.")
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ composition: DraftComposition, versionID: DraftVersionID) -> some View {
        Section {
            UsageView(usage: composition.usage, provider: composition.provider, modelID: composition.model)
        } header: {
            Text("Nutzung")
        }
        if !session.openQuestions.isEmpty {
            Section {
                ForEach(session.openQuestions, id: \.self) { Text(verbatim: $0) }
            } header: {
                Text("Offene Fragen der KI")
            } footer: {
                Text("Beantworten Sie die Fragen im Gespräch („Mit KI besprechen“) oder ergänzen Sie die Notiz und arbeiten Sie erneut aus.")
            }
        }
        ForEach(session.candidates) { candidate in
            Section {
                DraftContentView(draft: candidate.draft)
                if candidate.isAdoptable {
                    Picker(selection: Binding(
                        get: { candidate.decision },
                        set: { session.decide($0, for: candidate.id) }
                    )) {
                        Text("Offen").tag(DraftDecision.pending)
                        Text("Übernehmen").tag(DraftDecision.accepted)
                        Text("Verwerfen").tag(DraftDecision.rejected)
                    } label: {
                        Text("Entscheidung")
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("ADR-Vorschläge werden am Mac als ADR angelegt (Nummern vergibt der Mac).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Verwerfen") { session.decide(.rejected, for: candidate.id) }
                        .disabled(candidate.decision == .rejected)
                }
            }
        }
        Section {
            let accepted = session.accepted
            let singleSameType = composition.drafts.count == 1 && accepted.count == 1
                && DraftMapping.workItemType(accepted[0].draft.type) == item.type
            if singleSameType {
                Button("In diese Aufgabe übernehmen") { Task { await applyToItem(accepted[0].draft, versionID: versionID) } }
                    .disabled(!session.canAdopt)
            }
            Button(accepted.count > 1 ? "\(accepted.count) neue Aufgaben anlegen" : "Als neue Aufgabe anlegen") {
                Task { await createItems(versionID: versionID) }
            }
            .disabled(!session.canAdopt)
            if item.status == .inbox || item.type == .note {
                Toggle("Ursprungsnotiz danach als erledigt markieren", isOn: $completeSourceNote)
            }
            Button("Erneut ausarbeiten") {
                latestDraft = composition.drafts.first
                phase = .configure
            }
        } footer: {
            if !session.allDecided {
                Text("Bitte jeden Entwurf einzeln übernehmen oder verwerfen.")
            } else if session.accepted.isEmpty {
                Text("Kein Entwurf zum Übernehmen ausgewählt.")
            }
        }
    }

    // MARK: Actions

    private func prepare(_ resolution: TextProviderResolution) async {
        guard case let .ready(provider, modelID) = resolution, let database = model.database else { return }
        do {
            let context = includeProjectData ? try await ProjectContextBuilder.items(for: item, database: database) : []
            let current = try await database.workItems.fetch(item.uuid) ?? item
            let composer = DraftComposer(provider: provider, model: modelID)
            let input = DraftInput(originalNote: current.originalNote.isEmpty ? current.title : current.originalNote,
                                   transcript: current.transcript, currentDraft: latestDraft, projectContext: context)
            phase = .manifest(try composer.prepare(input, mode: mode), composer)
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func send(_ prepared: PreparedDraftRequest, composer: DraftComposer) async {
        guard let database = model.database else { return }
        phase = .sending
        let request = AIRequest(itemId: item.uuid, provider: domainProvider(composer.provider.providerID),
                                model: AIModelID(rawValue: composer.model) ?? "unknown", mode: requestMode,
                                inputVersion: item.revision, state: .running, createdAt: .now)
        try? await database.aiRecords.saveRequest(request, at: .now)
        do {
            let composition = try await composer.compose(prepared)
            let store = try model.requireDraftVersions()
            // Original note and transcript are versioned separately from the AI draft (spec H3).
            let current = try await database.workItems.fetch(item.uuid) ?? item
            try await store.recordText(current.originalNote, source: .original, for: item.uuid, at: .now)
            if let transcript = current.transcript {
                try await store.recordText(transcript, source: .transcript, for: item.uuid, at: .now)
            }
            let version = try await store.append(
                for: item.uuid, source: .composer, mode: mode, provider: composition.provider.rawValue,
                model: composition.model, drafts: composition.drafts, usage: composition.usage, at: .now
            )
            var completed = request
            completed.state = .completed
            completed.draftVersion = version.version
            completed.usage = TokenUsage(inputTokens: composition.usage.inputTokens, outputTokens: composition.usage.outputTokens)
            if let estimate = model.costEstimator.estimate(usage: composition.usage, provider: composition.provider, model: composition.model) {
                completed.costEstimate = CostEstimate(amount: estimate.amount, currencyCode: estimate.currencyCode)
            }
            try? await database.aiRecords.saveRequest(completed, at: .now)
            session = DraftReviewSession(mode: mode, drafts: composition.drafts)
            phase = .result(composition, versionID: version.id)
            error = nil
            model.noteLocalChange()
        } catch {
            var failed = request
            failed.state = .failed
            try? await database.aiRecords.saveRequest(failed, at: .now)
            self.error = errorMessage(error)
            phase = .configure
        }
    }

    private func applyToItem(_ draft: StructuredDraft, versionID: DraftVersionID) async {
        guard let database = model.database else { return }
        do {
            let current = try await database.workItems.fetch(item.uuid) ?? item
            _ = try await DraftAdopter(workItems: database.workItems, headings: model.draftHeadings)
                .apply(draft, to: current, actor: model.actor, at: .now)
            try await model.requireDraftVersions().markAdopted(versionID, draftIndexes: [0], for: item.uuid)
            model.noteLocalChange()
            phase = .adopted(1)
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func createItems(versionID: DraftVersionID) async {
        guard let database = model.database else { return }
        do {
            let current = try await database.workItems.fetch(item.uuid) ?? item
            let created = try await DraftAdopter(workItems: database.workItems, headings: model.draftHeadings)
                .createItems(from: session, source: current, actor: model.actor, at: .now)
            let indexes = session.candidates.enumerated().filter { $0.element.decision == .accepted }.map(\.offset)
            try await model.requireDraftVersions().markAdopted(versionID, draftIndexes: indexes, for: item.uuid)
            if completeSourceNote, (current.status == .inbox || current.type == .note), current.status.canTransition(to: .done),
               !(try await database.workItems.hasActiveJob(current.uuid)) {
                _ = try await TaskEditor(workItems: database.workItems).changeStatus(current, to: .done, actor: model.actor, at: .now)
            }
            model.noteLocalChange()
            phase = .adopted(created.count)
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func queueForMac() async {
        guard let database = model.database, let provider = model.settings.textProviderID,
              let modelID = model.settings.textModel.flatMap(AIModelID.init(rawValue:)) else { return }
        let request = AIRequest(itemId: item.uuid, provider: domainProvider(provider), model: modelID,
                                mode: .withRepositoryContext, inputVersion: item.revision, state: .pending, createdAt: .now)
        do {
            try await database.aiRecords.saveRequest(request, at: .now)
            queuedForMac = true
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private var requestMode: AIRequestMode {
        switch mode {
        case .inAufgabenAufteilen: .splitIntoTasks
        case .kurz, .ausfuehrlich: .structureDraft
        case .akzeptanzkriterienErgaenzen, .technischeDetails: .improveText
        }
    }

    private func domainProvider(_ id: SoftwareRegisseurAI.AIProviderID) -> SoftwareRegisseurDomain.AIProviderID {
        SoftwareRegisseurDomain.AIProviderID(rawValue: id.rawValue) ?? .openAI
    }
}
