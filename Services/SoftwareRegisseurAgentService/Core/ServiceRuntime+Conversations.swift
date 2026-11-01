import Foundation
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence

/// „Mit KI besprechen“ aus der Mac-UI (seit Protokoll 4, Pflichtenheft H3).
///
/// Das Gespräch selbst führt die UI mit dem Text-KI-Anbieter; der Dienst speichert als einziger Schreiber
/// (ADR-0019) das Gespräch (`AIConversation`) und Vorschläge daraus als eigene `DraftVersion` (Quelle `ai`, Kanal
/// `conversation`) – getrennt von Originalnotiz und Transkript, die als eigene Versionen festgehalten werden. Alles
/// läuft über die Repositories und wird dadurch synchronisiert. Hier wird nie ein Job angelegt oder ein Agent
/// gestartet.
extension ServiceRuntime {
    // MARK: Gespräch speichern

    /// Upsert über die Gesprächs-ID. Nachrichten werden nur angehängt: Eine veraltete Wiederholung (kürzerer Stand
    /// mit gleichem Anfang) ändert nichts, ein abweichender Verlauf wird abgelehnt.
    func saveConversation(_ conversation: AIConversation) async throws -> ConversationSavedInfo {
        _ = try await requireWorkItem(conversation.itemId)
        let stored = try await database.aiRecords.conversation(conversation.id)
        if let stored {
            guard stored.itemId == conversation.itemId else { throw ServiceError.conversationMismatch }
            if conversation.messages.count < stored.messages.count,
               Array(stored.messages.prefix(conversation.messages.count)) == conversation.messages {
                return Self.savedConversation(stored, created: false)
            }
            guard Array(conversation.messages.prefix(stored.messages.count)) == stored.messages else {
                throw ServiceError.conversationDiverged
            }
        }
        var record = conversation
        // Ein schon vermerkter Entwurf geht durch einen älteren UI-Stand nicht verloren.
        record.proposedDraftVersion = [conversation.proposedDraftVersion, stored?.proposedDraftVersion].compactMap { $0 }.max()
        if record != stored {
            try await database.aiRecords.saveConversation(record, at: clock.now())
            sendSoon()
        }
        return Self.savedConversation(record, created: stored == nil)
    }

    // MARK: Vorschlag als Entwurfsversion

    /// Legt den Vorschlag als Entwurfsversion an und übernimmt ihn nur bei `accept` (ausdrückliche Bestätigung in der
    /// UI) mit optimistischer Revisionsprüfung. Übernahme wie `acceptDraftVersion`: Titel, Inhalt, Priorität;
    /// Originalnotiz, Transkript, Labels und Abhängigkeiten bleiben. Dazu ein synchronisierter Verlaufseintrag.
    ///
    /// Reihenfolge, weil die Repositories je Aufruf eine eigene Transaktion öffnen: Die Revision wird geprüft, bevor
    /// etwas geschrieben wird (veraltet → nichts gespeichert). Ändert sich die Aufgabe genau zwischen Anlegen und
    /// Übernehmen, bleibt der Entwurf als nicht übernommene Version stehen und der Befehl meldet den Konflikt; eine
    /// Wiederholung mit derselben `draftId` und neuer Revision übernimmt ihn dann.
    func appendConversationDraft(_ command: ConversationDraftCommand) async throws -> ConversationDraftInfo {
        let item = try await requireWorkItem(command.workItemId)
        if let existing = try await database.draftVersions.fetch(command.draftId) {
            guard existing.workItemId == item.uuid, existing.source == .ai, existing.channel == .conversation else {
                throw ServiceError.draftIdInUse
            }
            guard command.accept, !existing.isAccepted else {
                return ConversationDraftInfo(
                    draftId: existing.id, workItemId: item.uuid, version: existing.version, accepted: existing.isAccepted,
                    wasCreated: false, workItem: existing.isAccepted ? Self.saved(item, message: "Bereits übernommen.") : nil,
                    message: existing.isAccepted ? "Entwurf Version \(existing.version) war bereits übernommen."
                        : "Entwurf Version \(existing.version) ist gespeichert.")
            }
            return try await adoptConversationDraft(existing, command: command, created: false)
        }

        var content = command.content
        content.title = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.title.isEmpty else { throw ServiceError.titleMissing }
        guard let provider = SoftwareRegisseurDomain.AIProviderID(rawValue: command.providerId) else { throw ServiceError.invalidAIProvider(command.providerId) }
        guard let model = AIModelID(rawValue: command.modelId) else { throw ServiceError.invalidModel(command.modelId) }
        var conversation: AIConversation?
        if let conversationId = command.conversationId {
            conversation = try await database.aiRecords.conversation(conversationId)
            if let conversation, conversation.itemId != item.uuid { throw ServiceError.conversationMismatch }
        }
        // Veraltete Revision: abgelehnt, bevor irgendetwas gespeichert wird.
        if command.accept, item.revision != command.expectedRevision {
            throw Self.revisionConflict(item, expected: command.expectedRevision)
        }

        let now = clock.now()
        // H3: Originalnotiz und Transkript getrennt versioniert (keine neue Version, wenn unverändert).
        let store = DraftVersionStore(repository: database.draftVersions)
        try await store.recordText(item.originalNote, source: .original, for: item.uuid, at: now)
        if let transcript = item.transcript { try await store.recordText(transcript, source: .transcript, for: item.uuid, at: now) }
        let finalContent = content
        let draft = try await database.draftVersions.append({ next in
            DraftVersion(
                id: command.draftId, workItemId: item.uuid, version: next, source: .ai, channel: .conversation,
                providerId: provider, modelId: model, contents: [finalContent], usage: command.usage, createdAt: now)
        }, for: item.uuid, at: now)
        if var conversation {
            conversation.proposedDraftVersion = draft.version
            try await database.aiRecords.saveConversation(conversation, at: now)
        }
        guard command.accept else {
            sendSoon()
            return ConversationDraftInfo(
                draftId: draft.id, workItemId: item.uuid, version: draft.version, accepted: false, wasCreated: true, workItem: nil,
                message: "Gesprächsvorschlag als Entwurf Version \(draft.version) gespeichert. Übernommen wird er erst nach Ihrer Freigabe.")
        }
        return try await adoptConversationDraft(draft, command: command, created: true)
    }

    private func adoptConversationDraft(_ draft: DraftVersion, command: ConversationDraftCommand, created: Bool) async throws
        -> ConversationDraftInfo {
        let saved = try await acceptDraft(draft.id, contentIndex: 0, expectedRevision: command.expectedRevision)
        var payload = [
            DraftDecisionEvent.decisionKey: DraftDecisionEvent.accepted,
            DraftDecisionEvent.draftIdKey: draft.id.uuidString,
            DraftDecisionEvent.versionKey: String(draft.version),
            DraftDecisionEvent.channelKey: DraftGenerationChannel.conversation.rawValue,
        ]
        if let conversationId = command.conversationId { payload[DraftDecisionEvent.conversationIdKey] = conversationId.uuidString }
        try await database.events.append(TaskEvent(
            workItemId: draft.workItemId, kind: .comment, actor: userActor, timestamp: clock.now(), payload: payload,
            sourceRevision: saved.revision))
        sendSoon()
        return ConversationDraftInfo(
            draftId: draft.id, workItemId: draft.workItemId, version: draft.version, accepted: true, wasCreated: created,
            workItem: saved,
            message: "Gesprächsvorschlag als Entwurf Version \(draft.version) übernommen. Es wurde kein Agent gestartet.")
    }

    static func savedConversation(_ conversation: AIConversation, created: Bool) -> ConversationSavedInfo {
        ConversationSavedInfo(conversationId: conversation.id, workItemId: conversation.itemId, messageCount: conversation.messages.count,
                              usage: conversation.usage, wasCreated: created)
    }
}
