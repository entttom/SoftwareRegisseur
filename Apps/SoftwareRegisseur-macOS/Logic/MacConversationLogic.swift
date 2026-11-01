import Foundation
import Observation
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Sendet Dienstbefehle (in der App: `CommandCenter`). Eigenes Protokoll, damit Abläufe ohne Dienst testbar sind.
@MainActor
protocol ServiceCommandPerforming: AnyObject {
    func perform(_ title: String, _ request: ServiceRequest, quiet: Bool) async -> CommandOutcome
}

/// Anbieter und Modell für „Mit KI besprechen“ am Mac (H3, I). Gerätebezogen in den App-Einstellungen; der
/// Schlüssel liegt im Schlüsselbund (gemeinsame Gruppe mit dem Dienst).
enum MacTextAISettings {
    static let providerKey = "ai.text.provider"
    static let modelKey = "ai.text.model"

    enum Resolution: Equatable {
        case ready(provider: SoftwareRegisseurAI.AIProviderID, model: String)
        case missingProvider
        case missingModel(SoftwareRegisseurAI.AIProviderID)
        case missingKey(SoftwareRegisseurAI.AIProviderID)

        /// Deutsche Erklärung für deaktivierte Optionen (I: „erklärbare deaktivierte Optionen“).
        var explanation: String? {
            switch self {
            case .ready: nil
            case .missingProvider:
                String(localized: "Für „Mit KI besprechen“ ist noch kein Anbieter gewählt. Bitte wählen Sie in den Einstellungen unter „KI-Schlüssel“ Anbieter und Modell.")
            case let .missingModel(provider):
                String(localized: "Für \(provider.displayName) ist noch kein Modell gewählt. Bitte wählen Sie es in den Einstellungen unter „KI-Schlüssel“.")
            case let .missingKey(provider):
                String(localized: "Für \(provider.displayName) ist am Mac kein API-Schlüssel gespeichert. Bitte hinterlegen Sie ihn in den Einstellungen unter „KI-Schlüssel“.")
            }
        }
    }

    static func resolve(providerRaw: String?, model: String?, hasKey: (SoftwareRegisseurAI.AIProviderID) -> Bool) -> Resolution {
        guard let providerRaw, !providerRaw.isEmpty else { return .missingProvider }
        let provider = SoftwareRegisseurAI.AIProviderID(rawValue: providerRaw)
        guard KeyPurpose.text.providers.contains(provider) else { return .missingProvider }
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { return .missingModel(provider) }
        guard hasKey(provider) else { return .missingKey(provider) }
        return .ready(provider: provider, model: model)
    }
}

/// Kontext eines Gesprächs. Standard: nur Notiz/Request-Text. Synchronisierte Projektdaten und Repo-Kontext
/// (nur über die Mac-Ausarbeitung, H4) gehen ausschließlich nach ausdrücklicher Auswahl mit.
enum MacConversationContext {
    static let requestId = "request-body"
    static let repoId = "mac-repo-elaboration"

    /// Überschriften übernommener Entwürfe – gleich wie Dienst und iPhone.
    static let headings = DraftBodyHeadings(
        goal: "Ziel", context: "Kontext", acceptanceCriteria: "Akzeptanzkriterien", technicalNotes: "Technische Hinweise",
        testCases: "Testfälle", dependencies: "Abhängigkeiten", openQuestions: "Offene Fragen")

    /// Aktueller Inhalt des Requests (immer dabei, sofern vorhanden).
    static func requestItem(for item: WorkItem) -> AIContextItem? {
        let body = item.structuredBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return AIContextItem(id: requestId, kind: .currentDraft, title: String(localized: "Aktueller Request-Inhalt"),
                             content: "# \(item.title)\n\n\(body)")
    }

    /// Wählbare synchronisierte Projektdaten (bestehende Requests, ADR-Index); standardmäßig abgewählt.
    static func projectItems(for item: WorkItem, workItems: [WorkItem], adrs: [ADR]) -> [AIContextItem] {
        guard let projectId = item.projectId else { return [] }
        var result: [AIContextItem] = []
        let others = workItems.filter { $0.projectId == projectId && $0.uuid != item.uuid && !$0.isArchived }.prefix(200)
        if !others.isEmpty {
            let lines = others.map { "- [\($0.type.rawValue)] \($0.humanId?.formatted ?? "—") \($0.title) (\($0.status.rawValue))" }
            result.append(AIContextItem(id: "existing-requests", kind: .existingRequest, title: String(localized: "Bestehende Requests"),
                                        content: lines.joined(separator: "\n")))
        }
        let projectADRs = adrs.filter { $0.projectId == projectId }
        if !projectADRs.isEmpty {
            let lines = projectADRs.map { "- ADR \($0.decisionNumber): \($0.title) (\($0.status.rawValue))" }
            result.append(AIContextItem(id: "adr-index", kind: .adrIndex, title: String(localized: "ADR-Index"),
                                        content: lines.joined(separator: "\n")))
        }
        return result
    }

    /// Ergebnis der Mac-Ausarbeitung mit Repo-Kontext als Gesprächskontext (Quellcode nur über H4).
    static func repoItem(from draft: DraftVersion) -> AIContextItem? {
        let parts = draft.contents.map { content -> String in
            let structured = DraftMapping.structuredDraft(content)
            return "# \(structured.title)\n\n" + DraftMapping.markdownBody(structured, headings: headings)
        }
        let text = (parts.isEmpty ? (draft.text ?? "") : parts.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return AIContextItem(id: repoId, kind: .other,
                             title: String(localized: "Mac-Ausarbeitung mit Repo-Kontext (Version \(draft.version))"), content: text)
    }

    /// Befehl für den Vorschlag als Entwurfsversion (Kanal `conversation`) und – nur nach ausdrücklicher Bestätigung –
    /// die Übernahme: Titel, Inhalt, Priorität; Labels, Abhängigkeiten, Originalnotiz und Transkript bleiben. Läuft
    /// über den Dienst (einziger Schreiber, ADR-0019) mit optimistischer Revision und startet nie einen Agenten.
    static func draftCommand(for draft: StructuredDraft, draftId: DraftVersionID, item: WorkItem, provider: String, model: String,
                             conversationId: AIConversationID?, usage: TokenUsage, accept: Bool) -> ConversationDraftCommand {
        ConversationDraftCommand(
            draftId: draftId, workItemId: item.uuid, content: DraftMapping.content(draft), providerId: provider, modelId: model,
            conversationId: conversationId, usage: usage, accept: accept, expectedRevision: item.revision)
    }

    /// Umfang des Kontexts, den die KI in diesem Gespräch gesehen hat (synchronisiert, H3/H4). Wird nur erweitert:
    /// Notiz/Request → synchronisierte Projektdaten → Repo-Kontext (mit den angegebenen Dateien).
    static func widened(_ scope: AIContextScope, by turn: AIContextScope) -> AIContextScope {
        switch (scope, turn) {
        case (.itemOnly, _): turn
        case (.project, .repositoryFiles): turn
        case let (.repositoryFiles(project, paths), .repositoryFiles(_, more)):
            .repositoryFiles(project, paths: paths + more.filter { !paths.contains($0) })
        default: scope
        }
    }
}

/// „Mit KI besprechen“ am Mac (H3). Ablauf je Nachricht: vorbereiten → Kontext-Manifest anzeigen → erst nach
/// „Senden“ an den Anbieter. Nach jedem Zug speichert der Dienst das Gespräch (`saveConversation`, synchronisiert);
/// ein Vorschlag wird nur nach ausdrücklicher Bestätigung als Entwurfsversion (Kanal `conversation`) angelegt und
/// übernommen (`appendConversationDraft`). „Verwerfen“ behält das Gespräch und legt keinen Entwurf an.
/// Das Gespräch ist keine Coding-Agent-Sitzung: dieses Modell sendet nur diese beiden Befehle und die Befehle der
/// Mac-Ausarbeitung (Repo-Kontext nach Zustimmung) – nie einen Job-Befehl.
@MainActor
@Observable
final class MacConversationModel {
    enum AdoptionState: Equatable {
        case idle
        case saving
        case adopted(String)
        case failed(String)
    }

    enum RepoContextState: Equatable {
        case idle
        case requesting
        case running(MacAIElaborationInfo)
        case ready(MacAIElaborationInfo)
        case failed(String)
    }

    /// Befehle, die dieses Modell überhaupt senden darf (Testbarkeit von „startet nie einen Agenten“).
    static func isPermitted(_ request: ServiceRequest) -> Bool {
        switch request {
        case .saveConversation, .appendConversationDraft, .requestMacAIElaboration, .macAIElaborationStatus: true
        default: false
        }
    }

    let controller: ConversationController
    private(set) var item: WorkItem
    var message = ""
    let optionalContext: [AIContextItem]
    private(set) var selectedOptionalContext: Set<String> = []
    /// Repo-Kontext ist ausdrücklich gewünscht (Standard aus).
    private(set) var repoContextEnabled = false
    var repoConsent = false
    var repoFilesText = ""
    private(set) var repoState: RepoContextState = .idle
    private(set) var repoContextItem: AIContextItem?
    private(set) var adoption: AdoptionState = .idle
    /// Synchronisierter Stand des Gesprächs (H3); nach jedem Zug über den Dienst gespeichert.
    private(set) var record: AIConversation
    /// Deutsche Meldung, falls das letzte Speichern scheiterte (das nächste Speichern sendet den ganzen Stand).
    private(set) var saveError: String?

    @ObservationIgnored private let commands: any ServiceCommandPerforming
    /// Nicht gespeicherte Änderungen am Gespräch.
    @ObservationIgnored private var recordDirty = false
    /// Nutzung des Zugs, der den offenen Vorschlag erzeugt hat.
    @ObservationIgnored private var lastTurnUsage = TokenUsage()
    /// Eine Entwurfs-ID je Vorschlag: Wiederholungen legen keine zweite Version an (Idempotenz im Dienst).
    @ObservationIgnored private var proposalDraft: (proposal: StructuredDraft, id: DraftVersionID)?

    init(item: WorkItem, provider: any TextAIProvider, model: String, optionalContext: [AIContextItem],
         commands: any ServiceCommandPerforming) {
        self.item = item
        self.optionalContext = optionalContext
        self.commands = commands
        let session = ConversationSession(
            provider: provider, model: model,
            originalNote: item.originalNote.isEmpty ? item.title : item.originalNote,
            transcript: item.transcript)
        controller = ConversationController(session: session)
        record = AIConversation(
            itemId: item.uuid, provider: SoftwareRegisseurDomain.AIProviderID(rawValue: provider.providerID.rawValue) ?? .openAI,
            model: AIModelID(rawValue: model) ?? "unknown", contextScope: .itemOnly, createdAt: .now)
    }

    var providerID: SoftwareRegisseurAI.AIProviderID { controller.providerID }
    var modelID: String { controller.model }

    /// Manifest der vorbereiteten Nachricht; nur dann ist „Senden“ möglich.
    var preparedManifest: ContextManifest? {
        if case let .reviewingContext(prepared) = controller.phase { return prepared.manifest }
        return nil
    }

    var canPrepare: Bool {
        guard case .composing = controller.phase else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canUseRepoContext: Bool { item.projectId != nil }

    /// Kontext außer Notiz/Transkript, der mit der nächsten Nachricht gesendet wird.
    var effectiveContext: [AIContextItem] {
        var items: [AIContextItem] = []
        if let request = MacConversationContext.requestItem(for: item) { items.append(request) }
        items += optionalContext.filter { selectedOptionalContext.contains($0.id) }
        if repoContextEnabled, let repoContextItem { items.append(repoContextItem) }
        return items
    }

    func isSelected(_ contextId: String) -> Bool { selectedOptionalContext.contains(contextId) }

    /// Änderungen am Kontext verwerfen ein angezeigtes Manifest, damit nie etwas anderes gesendet wird als angezeigt.
    func setSelected(_ contextId: String, _ selected: Bool) {
        if selected { selectedOptionalContext.insert(contextId) } else { selectedOptionalContext.remove(contextId) }
        controller.cancelPrepared()
    }

    func setRepoContextEnabled(_ enabled: Bool) {
        repoContextEnabled = enabled && canUseRepoContext
        if !repoContextEnabled { repoConsent = false }
        controller.cancelPrepared()
    }

    /// Schritt 1: Anfrage bauen und Manifest zeigen. Es wird nichts gesendet.
    func prepare() async {
        guard canPrepare else { return }
        await controller.setProjectContext(effectiveContext)
        await controller.prepare(message: message)
    }

    /// Schritt 2: genau die vorbereitete Anfrage senden; danach das Gespräch über den Dienst speichern.
    func confirmSend() async {
        guard preparedManifest != nil else { return }
        let scope = turnScope
        let turnsBefore = controller.turns.count
        await controller.confirmSend()
        if case .composing = controller.phase { message = "" }
        guard controller.turns.count > turnsBefore else { return }
        record.contextScope = MacConversationContext.widened(record.contextScope, by: scope)
        await persist()
    }

    /// Kontextumfang der gerade gesendeten Nachricht.
    private var turnScope: AIContextScope {
        guard let projectId = item.projectId else { return .itemOnly }
        if repoContextEnabled, repoContextItem != nil { return .repositoryFiles(projectId, paths: repoFiles) }
        if !selectedOptionalContext.isEmpty { return .project(projectId) }
        return .itemOnly
    }

    /// Hängt neue Züge an den gespeicherten Stand und speichert ihn (Upsert über die Gesprächs-ID, synchronisiert).
    func persist() async {
        let known = record.messages.count
        let newTurns = controller.turns.dropFirst(known)
        let total = TokenUsage(inputTokens: controller.usage.inputTokens, outputTokens: controller.usage.outputTokens)
        let delta = TokenUsage(inputTokens: max(0, total.inputTokens - record.usage.inputTokens),
                               outputTokens: max(0, total.outputTokens - record.usage.outputTokens))
        for (offset, turn) in newTurns.enumerated() {
            let isLast = offset == newTurns.count - 1
            record.append(AIMessage(role: turn.role == .user ? .user : .assistant, text: turn.text, createdAt: turn.date),
                          usage: isLast ? delta : TokenUsage())
        }
        if !newTurns.isEmpty {
            lastTurnUsage = delta
            recordDirty = true
        }
        guard recordDirty else { return }
        let outcome = await commands.perform(String(localized: "Gespräch speichern"), .saveConversation(record), quiet: true)
        if outcome.succeeded, case .conversationSaved? = outcome.result {
            recordDirty = false
            saveError = nil
        } else {
            saveError = String(localized: "Das Gespräch wurde nicht gespeichert: \(outcome.feedback.message)")
        }
    }

    func cancelPrepared() { controller.cancelPrepared() }

    func dismissError() { controller.dismissError() }

    /// Hält die Aufgabe aktuell (Revision für die optimistische Übernahme, Request-Inhalt im Kontext).
    func itemDidChange(_ updated: WorkItem) {
        guard updated.uuid == item.uuid else { return }
        item = updated
    }

    /// Ausdrückliche Übernahme des Vorschlags (nach Bestätigung in der Oberfläche): Der Dienst legt ihn als
    /// Entwurfsversion (Kanal `conversation`) an und übernimmt ihn mit optimistischer Revisionsprüfung.
    func acceptProposal() async {
        guard let proposal = controller.pendingProposal, adoption != .saving else { return }
        adoption = .saving
        // Das Gespräch zuerst speichern, damit der Dienst den Entwurf dort vermerken kann.
        if recordDirty { await persist() }
        let draftId = proposalDraftId(for: proposal)
        let command = MacConversationContext.draftCommand(
            for: proposal, draftId: draftId, item: item, provider: providerID.rawValue, model: modelID, conversationId: record.id,
            usage: lastTurnUsage, accept: true)
        let outcome = await commands.perform(String(localized: "KI-Vorschlag übernehmen"), .appendConversationDraft(command), quiet: false)
        guard outcome.succeeded, case let .conversationDraft(info)? = outcome.result, info.accepted else {
            // Vorschlag bleibt offen; nichts wurde übernommen (ein gespeicherter Entwurf wird bei Wiederholung genutzt).
            adoption = .failed(outcome.feedback.message)
            return
        }
        // Die neue Revision kommt über den Datenbankabgleich (`itemDidChange`).
        record.proposedDraftVersion = info.version
        proposalDraft = nil
        _ = await controller.acceptProposal()
        adoption = .adopted(proposal.title)
    }

    /// „Verwerfen“: Das Gespräch bleibt gespeichert, es entsteht kein Entwurf und die Aufgabe bleibt unverändert.
    func discardProposal() async {
        await controller.discardProposal()
        proposalDraft = nil
        adoption = .idle
    }

    private func proposalDraftId(for proposal: StructuredDraft) -> DraftVersionID {
        if let proposalDraft, proposalDraft.proposal == proposal { return proposalDraft.id }
        let id = DraftVersionID()
        proposalDraft = (proposal, id)
        return id
    }

    // MARK: Repo-Kontext (H4, nur nach Zustimmung)

    var repoFiles: [String] {
        repoFilesText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var canRequestRepoContext: Bool {
        guard repoContextEnabled, repoConsent, canUseRepoContext else { return false }
        switch repoState {
        case .requesting, .running: return false
        default: return true
        }
    }

    /// Stößt die Mac-Ausarbeitung mit Repo-Kontext an (Dienst, IPC); deren Ergebnis wird Gesprächskontext.
    func requestRepoContext() async {
        guard canRequestRepoContext else { return }
        repoState = .requesting
        repoContextItem = nil
        let command = MacAIElaborationCommand(workItemId: item.uuid, providerId: providerID.rawValue, modelId: modelID,
                                              mode: .technischeDetails, selectedFiles: repoFiles)
        let outcome = await commands.perform(String(localized: "Repo-Kontext am Mac ermitteln"), .requestMacAIElaboration(command), quiet: false)
        if case let .macAIElaboration(info)? = outcome.result {
            apply(info)
        } else {
            repoState = .failed(outcome.feedback.message)
        }
    }

    /// Fragt den Stand ab; `true`, solange weiter abgefragt werden soll.
    @discardableResult
    func refreshRepoContext() async -> Bool {
        guard case let .running(info) = repoState else { return false }
        let outcome = await commands.perform(String(localized: "Stand der KI-Ausarbeitung"),
                                             .macAIElaborationStatus(requestId: info.requestId), quiet: true)
        if case let .macAIElaboration(updated)? = outcome.result {
            apply(updated)
        } else if !outcome.succeeded {
            repoState = .failed(outcome.feedback.message)
        }
        if case .running = repoState { return true }
        return false
    }

    /// Übernimmt den vom Dienst erstellten Entwurf (synchronisierte `DraftVersion`) als Kontext.
    func attachRepoDraft(from drafts: [DraftVersion]) {
        guard case let .ready(info) = repoState, let version = info.draftVersion else { return }
        let match = drafts.filter { $0.source == .ai && $0.version == version }.max { $0.createdAt < $1.createdAt }
        guard let match, let context = MacConversationContext.repoItem(from: match) else { return }
        if repoContextItem != context {
            repoContextItem = context
            controller.cancelPrepared()
        }
    }

    private func apply(_ info: MacAIElaborationInfo) {
        switch info.state {
        case .pending, .running: repoState = .running(info)
        case .completed: repoState = .ready(info)
        case .failed: repoState = .failed(info.errorMessage ?? String(localized: "Die Mac-Ausarbeitung ist fehlgeschlagen."))
        }
    }

    // MARK: Nutzung und Kosten

    /// Kosten nur als Schätzung (H3); ohne hinterlegten Preis wird keine Zahl erfunden.
    func costText(priceTable: PriceTable = .empty) -> String {
        if let estimate = CostEstimator(priceTable: priceTable).estimate(usage: controller.usage, provider: providerID, model: modelID) {
            return String(localized: "Kosten: \(estimate.formatted())")
        }
        return String(localized: "Kosten: geschätzt – für dieses Modell ist am Mac kein Preis hinterlegt; maßgeblich ist die Abrechnung Ihres Anbieters.")
    }
}
