import Foundation
import Testing
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Textanbieter mit fester Antwort; zählt gesendete Anfragen, nie Netzwerk.
final class StubConversationProvider: TextAIProvider, @unchecked Sendable {
    let providerID: SoftwareRegisseurAI.AIProviderID = .anthropic
    private let lock = NSLock()
    private var requests: [TextGenerationRequest] = []

    var requestCount: Int { lock.withLock { requests.count } }
    var lastRequest: TextGenerationRequest? { lock.withLock { requests.last } }

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }

    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        lock.withLock { requests.append(request) }
        let text = """
        {"reply":"Vorschlag anbei.","proposedDrafts":[{"type":"feature","title":"CSV-Export mit Kopfzeile","goal":"Export enthält Spaltennamen",
        "context":"","acceptanceCriteria":["Erste Zeile enthält Spaltennamen"],"technicalNotes":[],"testCases":[],"priority":"high",
        "dependencies":[],"openQuestions":[]}]}
        """
        return TextGenerationResult(provider: providerID, model: request.model, text: text, finishReason: .completed,
                                    usage: AIUsage(inputTokens: 100, outputTokens: 30))
    }
}

/// Zeichnet Dienstbefehle auf und antwortet mit einem festen Ergebnis.
@MainActor
final class RecordingCommands: ServiceCommandPerforming {
    private(set) var requests: [ServiceRequest] = []
    var respond: (ServiceRequest) -> CommandOutcome

    init(respond: @escaping (ServiceRequest) -> CommandOutcome) {
        self.respond = respond
    }

    func perform(_ title: String, _ request: ServiceRequest, quiet: Bool) async -> CommandOutcome {
        requests.append(request)
        return respond(request)
    }
}

/// „Mit KI besprechen“ am Mac (H3): Manifest vor jedem Senden, Gespräch nach jedem Zug gespeichert, Vorschlag nur
/// nach ausdrücklicher Übernahme als Entwurfsversion (Kanal `conversation`), nie ein Agentenstart.
@MainActor
@Suite("Mit KI besprechen am Mac")
struct MacConversationTests {
    static func saved(_ item: WorkItem) -> CommandOutcome {
        CommandOutcome(result: .workItemSaved(savedInfo(item)), feedback: .success("Aufgabe gespeichert."))
    }

    static func savedInfo(_ item: WorkItem) -> WorkItemSavedInfo {
        WorkItemSavedInfo(workItemId: item.uuid, revision: item.revision + 1, status: item.status, type: item.type,
                          projectId: item.projectId, isArchived: false, message: "Aufgabe gespeichert.")
    }

    /// Antwortet wie der Dienst (Protokoll 4) auf Gesprächsbefehle.
    static func serviceResponse(_ request: ServiceRequest, item: WorkItem) -> CommandOutcome {
        switch request {
        case let .saveConversation(conversation):
            CommandOutcome(result: .conversationSaved(ConversationSavedInfo(
                conversationId: conversation.id, workItemId: conversation.itemId, messageCount: conversation.messages.count,
                usage: conversation.usage, wasCreated: true)), feedback: .success("Gespräch gespeichert."))
        case let .appendConversationDraft(command):
            CommandOutcome(result: .conversationDraft(ConversationDraftInfo(
                draftId: command.draftId, workItemId: command.workItemId, version: 3, accepted: command.accept, wasCreated: true,
                workItem: command.accept ? savedInfo(item) : nil, message: "Entwurf Version 3 übernommen.")),
                feedback: .success("Entwurf Version 3 übernommen."))
        default:
            saved(item)
        }
    }

    static func saves(_ commands: RecordingCommands) -> [AIConversation] {
        commands.requests.compactMap { if case let .saveConversation(conversation) = $0 { conversation } else { nil } }
    }

    static func drafts(_ commands: RecordingCommands) -> [ConversationDraftCommand] {
        commands.requests.compactMap { if case let .appendConversationDraft(command) = $0 { command } else { nil } }
    }

    static func makeModel(item: WorkItem = Fixture.item("CSV-Export", labels: ["export"], body: "Alte Beschreibung"),
                          others: [WorkItem] = [], commands: RecordingCommands? = nil)
        -> (MacConversationModel, StubConversationProvider, RecordingCommands) {
        let provider = StubConversationProvider()
        let recorder = commands ?? RecordingCommands { serviceResponse($0, item: item) }
        let model = MacConversationModel(
            item: item, provider: provider, model: "test-modell",
            optionalContext: MacConversationContext.projectItems(for: item, workItems: [item] + others, adrs: []),
            commands: recorder)
        return (model, provider, recorder)
    }

    @Test func manifestIsShownBeforeAnythingIsSent() async throws {
        let other = Fixture.item("Andere Aufgabe")
        let (model, provider, commands) = Self.makeModel(others: [other])
        #expect(!model.canPrepare)
        model.message = "Bitte Kopfzeile ergänzen"
        await model.prepare()

        let manifest = try #require(model.preparedManifest)
        #expect(provider.requestCount == 0)
        #expect(model.controller.sentRequestCount == 0)
        #expect(manifest.model == "test-modell")
        let kinds = manifest.included.map(\.kind)
        #expect(kinds.contains(.originalNote))
        #expect(kinds.contains(.currentDraft))
        // Standard: nur Notiz/Request – Projektdaten nur nach ausdrücklicher Auswahl.
        #expect(!kinds.contains(.existingRequest))

        await model.confirmSend()
        #expect(provider.requestCount == 1)
        #expect(model.preparedManifest == nil)
        #expect(model.message.isEmpty)
        #expect(model.controller.turns.count == 2)
        // Nach dem Zug wird nur das Gespräch gespeichert – kein Entwurf, keine Änderung der Aufgabe.
        #expect(commands.requests.count == 1)
        let saved = try #require(Self.saves(commands).first)
        #expect(saved.id == model.record.id)
        #expect(saved.itemId == model.item.uuid)
        #expect(saved.messages.map(\.role) == [.user, .assistant])
        #expect(saved.messages.first?.text == "Bitte Kopfzeile ergänzen")
        #expect(saved.contextScope == .itemOnly)
        #expect(saved.usage == TokenUsage(inputTokens: 100, outputTokens: 30))
        #expect(saved.provider == .anthropic)
        #expect(saved.model == AIModelID(rawValue: "test-modell"))
        #expect(model.saveError == nil)
    }

    @Test func sendWithoutPreparedManifestDoesNothing() async {
        let (model, provider, _) = Self.makeModel()
        model.message = "Hallo"
        await model.confirmSend()
        #expect(provider.requestCount == 0)
    }

    @Test func changingTheContextDiscardsTheShownManifest() async throws {
        let other = Fixture.item("Andere Aufgabe")
        let (model, provider, _) = Self.makeModel(others: [other])
        model.message = "Frage"
        await model.prepare()
        #expect(model.preparedManifest != nil)

        model.setSelected("existing-requests", true)
        #expect(model.preparedManifest == nil, "Manifest muss nach Kontextänderung neu angezeigt werden")
        await model.confirmSend()
        #expect(provider.requestCount == 0)

        await model.prepare()
        let manifest = try #require(model.preparedManifest)
        #expect(manifest.included.contains { $0.kind == .existingRequest })
        await model.confirmSend()
        let sent = try #require(provider.lastRequest)
        #expect(sent.messages.first?.content.contains("Andere Aufgabe") == true)
    }

    @Test func proposalIsAdoptedOnlyAfterExplicitAcceptanceViaService() async throws {
        let item = Fixture.item("CSV-Export", labels: ["export"], body: "Alte Beschreibung")
        let (model, _, commands) = Self.makeModel(item: item)
        model.message = "Bitte Kopfzeile ergänzen"
        await model.prepare()
        await model.confirmSend()

        let proposal = try #require(model.controller.pendingProposal)
        #expect(proposal.title == "CSV-Export mit Kopfzeile")
        #expect(Self.drafts(commands).isEmpty, "ohne Bestätigung kein Entwurf")
        #expect(model.adoption == .idle)

        await model.acceptProposal()
        let command = try #require(Self.drafts(commands).first, "Übernahme muss über appendConversationDraft laufen")
        #expect(Self.drafts(commands).count == 1)
        #expect(!commands.requests.contains { if case .updateWorkItem = $0 { true } else { false } })
        #expect(command.accept)
        #expect(command.workItemId == item.uuid)
        #expect(command.expectedRevision == item.revision)
        #expect(command.conversationId == model.record.id)
        #expect(command.providerId == "anthropic")
        #expect(command.modelId == "test-modell")
        #expect(command.usage == TokenUsage(inputTokens: 100, outputTokens: 30))
        #expect(command.content.title == "CSV-Export mit Kopfzeile")
        #expect(command.content.classification == .feature)
        #expect(command.content.acceptanceCriteria == ["Erste Zeile enthält Spaltennamen"])
        #expect(command.content.priority == .high)
        #expect(model.controller.pendingProposal == nil)
        #expect(model.adoption == .adopted("CSV-Export mit Kopfzeile"))
        #expect(model.record.proposedDraftVersion == 3)
    }

    @Test func retriedAdoptionReusesTheDraftId() async throws {
        var failNext = true
        let item = Fixture.item("CSV-Export")
        let commands = RecordingCommands { request in
            if case .appendConversationDraft = request, failNext {
                failNext = false
                return CommandOutcome(result: nil, feedback: .failure("Der Dienst hat nicht rechtzeitig geantwortet."))
            }
            return Self.serviceResponse(request, item: item)
        }
        let (model, _, _) = Self.makeModel(item: item, commands: commands)
        model.message = "Bitte Kopfzeile ergänzen"
        await model.prepare()
        await model.confirmSend()
        await model.acceptProposal()
        #expect(model.controller.pendingProposal != nil)
        await model.acceptProposal()
        let drafts = Self.drafts(commands)
        #expect(drafts.count == 2)
        #expect(drafts[0].draftId == drafts[1].draftId, "Wiederholung darf keine zweite Entwurfsversion anlegen")
        #expect(model.adoption == .adopted("CSV-Export mit Kopfzeile"))
    }

    @Test func failedAdoptionKeepsTheProposalOpen() async throws {
        let item = Fixture.item("CSV-Export")
        let commands = RecordingCommands { request in
            if case .appendConversationDraft = request {
                return CommandOutcome(result: nil, feedback: .failure("Die Aufgabe wurde inzwischen geändert. Bitte neu laden."))
            }
            return Self.serviceResponse(request, item: item)
        }
        let (model, _, _) = Self.makeModel(item: item, commands: commands)
        model.message = "Bitte Kopfzeile ergänzen"
        await model.prepare()
        await model.confirmSend()
        await model.acceptProposal()
        #expect(model.controller.pendingProposal != nil)
        #expect(model.adoption == .failed("Die Aufgabe wurde inzwischen geändert. Bitte neu laden."))
    }

    @Test func discardingTheProposalKeepsTheConversationWithoutDraft() async throws {
        let (model, _, commands) = Self.makeModel()
        model.message = "Bitte Kopfzeile ergänzen"
        await model.prepare()
        await model.confirmSend()
        await model.discardProposal()
        #expect(model.controller.pendingProposal == nil)
        #expect(Self.drafts(commands).isEmpty)
        #expect(commands.requests.allSatisfy { if case .saveConversation = $0 { true } else { false } })
        #expect(try #require(Self.saves(commands).last).messages.count == 2)
        #expect(model.record.messages.count == 2)
    }

    @Test func everyTurnIsSavedAndAFailedSaveIsRetriedWithTheFullState() async throws {
        let other = Fixture.item("Andere Aufgabe")
        let item = Fixture.item("CSV-Export")
        var failSave = true
        let commands = RecordingCommands { request in
            if case .saveConversation = request, failSave {
                return CommandOutcome(result: nil, feedback: .failure("Der Hintergrunddienst ist nicht erreichbar."))
            }
            return Self.serviceResponse(request, item: item)
        }
        let (model, _, _) = Self.makeModel(item: item, others: [other], commands: commands)
        model.message = "Erste Frage"
        await model.prepare()
        await model.confirmSend()
        #expect(model.saveError?.contains("nicht erreichbar") == true)

        failSave = false
        model.setSelected("existing-requests", true)
        model.message = "Zweite Frage"
        await model.prepare()
        await model.confirmSend()
        #expect(model.saveError == nil)
        let saves = Self.saves(commands)
        #expect(saves.count == 2)
        #expect(Set(saves.map(\.id)).count == 1, "ein Gespräch, Upsert über die ID")
        let last = try #require(saves.last)
        #expect(last.messages.map(\.text).prefix(1) == ["Erste Frage"])
        #expect(last.messages.count == 4)
        #expect(last.usage == TokenUsage(inputTokens: 200, outputTokens: 60))
        // Synchronisierte Projektdaten wurden mitgesendet → Umfang „Projekt“.
        #expect(last.contextScope == .project(Fixture.projectA))
    }

    @Test func contextScopeOnlyWidens() {
        let project = ProjectID()
        #expect(MacConversationContext.widened(.itemOnly, by: .project(project)) == .project(project))
        #expect(MacConversationContext.widened(.project(project), by: .itemOnly) == .project(project))
        #expect(MacConversationContext.widened(.project(project), by: .repositoryFiles(project, paths: ["a"]))
                == .repositoryFiles(project, paths: ["a"]))
        #expect(MacConversationContext.widened(.repositoryFiles(project, paths: ["a"]), by: .repositoryFiles(project, paths: ["a", "b"]))
                == .repositoryFiles(project, paths: ["a", "b"]))
        #expect(MacConversationContext.widened(.repositoryFiles(project, paths: ["a"]), by: .project(project))
                == .repositoryFiles(project, paths: ["a"]))
    }

    @Test func repoContextNeedsOptInAndConsentAndNeverStartsAnAgent() async throws {
        let item = Fixture.item("CSV-Export", body: "Text")
        let info = MacAIElaborationInfo(requestId: AIRequestID(), workItemId: item.uuid, state: .completed, providerId: "anthropic",
                                        modelId: "test-modell", estimatedTokens: 900, draftVersion: 2, updatedAt: Fixture.now)
        let commands = RecordingCommands { request in
            switch request {
            case .requestMacAIElaboration, .macAIElaborationStatus:
                CommandOutcome(result: .macAIElaboration(info), feedback: .accepted("läuft"))
            default:
                Self.serviceResponse(request, item: item)
            }
        }
        let (model, _, _) = Self.makeModel(item: item, commands: commands)
        #expect(model.canUseRepoContext)
        #expect(!model.canRequestRepoContext)
        model.setRepoContextEnabled(true)
        #expect(!model.canRequestRepoContext, "ohne Zustimmung keine Übermittlung")
        model.repoConsent = true
        model.repoFilesText = "Sources/Export.swift\n\n"
        await model.requestRepoContext()

        guard case let .requestMacAIElaboration(command) = try #require(commands.requests.first) else {
            Issue.record("Repo-Kontext muss über die Mac-Ausarbeitung laufen")
            return
        }
        #expect(command.providerId == "anthropic")
        #expect(command.modelId == "test-modell")
        #expect(command.selectedFiles == ["Sources/Export.swift"])
        #expect(model.repoState == MacConversationModel.RepoContextState.ready(info))

        let draft = DraftVersion(workItemId: item.uuid, version: 2, source: .ai, mode: "technischeDetails",
                                 contents: [DraftContent(classification: .feature, title: "CSV-Export", goal: "Export über ExportService")],
                                 createdAt: Fixture.now)
        model.attachRepoDraft(from: [draft])
        #expect(model.effectiveContext.contains { $0.id == MacConversationContext.repoId })

        model.message = "Welche Datei ist betroffen?"
        await model.prepare()
        #expect(model.preparedManifest?.included.contains { $0.kind == AIContextKind.other } == true)
        await model.confirmSend()
        #expect(Self.saves(commands).last?.contextScope == .repositoryFiles(try #require(item.projectId), paths: ["Sources/Export.swift"]))
        await model.acceptProposal()
        #expect(Self.drafts(commands).count == 1)

        model.setRepoContextEnabled(false)
        #expect(!model.effectiveContext.contains { $0.id == MacConversationContext.repoId })

        #expect(!commands.requests.isEmpty)
        #expect(commands.requests.allSatisfy(MacConversationModel.isPermitted))
        #expect(!MacConversationModel.isPermitted(.cancelJob(jobId: JobID())))
        #expect(!MacConversationModel.isPermitted(.requestJob(JobRequestCommand(workItemId: item.uuid, providerId: .codex))))
        #expect(!MacConversationModel.isPermitted(.retryJob(jobId: JobID(), idempotencyKey: IdempotencyKey())))
    }

    @Test func inboxNotesHaveNoRepoContext() {
        let note = Fixture.item("Idee", project: nil, type: .note, status: .inbox)
        let (model, _, _) = Self.makeModel(item: note)
        #expect(!model.canUseRepoContext)
        model.setRepoContextEnabled(true)
        #expect(!model.repoContextEnabled)
        #expect(model.optionalContext.isEmpty)
    }

    @Test func costsAreOnlyShownAsEstimate() async {
        let (model, _, _) = Self.makeModel()
        model.message = "Frage"
        await model.prepare()
        await model.confirmSend()
        #expect(model.costText().contains("geschätzt"))
        var table = PriceTable()
        table.setPrice(ModelPrice(inputPerMillionTokens: 3, outputPerMillionTokens: 15), provider: .anthropic, model: "test-modell")
        #expect(model.costText(priceTable: table).contains("geschätzt"))
    }

    @Test func providerSettingsExplainWhatIsMissing() {
        #expect(MacTextAISettings.resolve(providerRaw: nil, model: nil) { _ in true } == .missingProvider)
        #expect(MacTextAISettings.resolve(providerRaw: "unbekannt", model: "m") { _ in true } == .missingProvider)
        #expect(MacTextAISettings.resolve(providerRaw: "anthropic", model: " ") { _ in true } == .missingModel(.anthropic))
        #expect(MacTextAISettings.resolve(providerRaw: "openai", model: "m") { _ in false } == .missingKey(.openai))
        #expect(MacTextAISettings.resolve(providerRaw: "gemini", model: "m") { _ in true } == .ready(provider: .gemini, model: "m"))
        #expect(MacTextAISettings.Resolution.missingKey(.openai).explanation?.contains("Sie") == true)
    }
}
