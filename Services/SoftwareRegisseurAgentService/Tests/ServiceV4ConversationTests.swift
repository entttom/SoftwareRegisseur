import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import Testing

/// Protokoll 4: „Mit KI besprechen“ am Mac (H3) im Dienst – Gespräch speichern, Vorschlag als Entwurfsversion mit
/// Kanal `conversation`, Übernahme nur mit `accept` und gültiger Revision. Temporäre Datenbank, Fake-Agent; kein
/// echter Anbieter, kein CloudKit.
@Suite("Agent Service: IPC-Protokoll 4 (Mit KI besprechen)", .serialized)
struct ServiceV4ConversationTests {
    static let proposal = DraftContent(
        classification: .feature, title: "  CSV-Export mit Kopfzeile ", goal: "Spaltennamen exportieren",
        acceptanceCriteria: ["Erste Zeile enthält Spaltennamen"], priority: .high)

    static func conversation(for item: WorkItem, at date: Date, turns: Int) -> AIConversation {
        var conversation = AIConversation(itemId: item.uuid, provider: .anthropic, model: "test-modell",
                                          contextScope: item.projectId.map { .project($0) } ?? .itemOnly, createdAt: date)
        for index in 0..<turns {
            conversation.append(AIMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Nachricht \(index)",
                                          createdAt: date.addingTimeInterval(Double(index))),
                                usage: index.isMultiple(of: 2) ? TokenUsage() : TokenUsage(inputTokens: 100, outputTokens: 30))
        }
        return conversation
    }

    @Test func conversationIsUpsertedAppendOnlyAndSynced() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project)

        let first = Self.conversation(for: item, at: harness.clock.now(), turns: 2)
        let created = try conversationInfo(await runtime.handle(.saveConversation(first)))
        #expect(created.wasCreated)
        #expect(created.messageCount == 2)
        #expect(created.usage == TokenUsage(inputTokens: 100, outputTokens: 30))

        // Fortschreibung nach dem nächsten Zug: gleiche ID, mehr Nachrichten.
        let second = Self.conversation(for: item, at: harness.clock.now(), turns: 4)
        var continued = first
        for message in second.messages.dropFirst(2) {
            continued.append(message, usage: message.role == .assistant ? TokenUsage(inputTokens: 100, outputTokens: 30) : TokenUsage())
        }
        let updated = try conversationInfo(await runtime.handle(.saveConversation(continued)))
        #expect(!updated.wasCreated)
        #expect(updated.messageCount == 4)
        let stored = try #require(try await harness.database.aiRecords.conversation(first.id))
        #expect(stored.messages.map(\.text) == ["Nachricht 0", "Nachricht 1", "Nachricht 2", "Nachricht 3"])
        #expect(stored.contextScope == .project(project.id))
        #expect(stored.usage == TokenUsage(inputTokens: 200, outputTokens: 60))
        #expect(try await harness.database.aiRecords.conversations(itemId: item.uuid).count == 1)

        // Veraltete Wiederholung überschreibt nichts.
        let stale = try conversationInfo(await runtime.handle(.saveConversation(first)))
        #expect(stale.messageCount == 4)
        #expect(try await harness.database.aiRecords.conversation(first.id)?.messages.count == 4)

        // Abweichender Verlauf und fremde Aufgabe werden abgelehnt.
        var diverged = AIConversation(id: first.id, itemId: item.uuid, provider: .anthropic, model: "test-modell", createdAt: harness.clock.now())
        diverged.append(AIMessage(role: .user, text: "Etwas anderes", createdAt: harness.clock.now()))
        #expect(try failureMessage(await runtime.handle(.saveConversation(diverged))).contains("fortgesetzt"))
        let other = try await harness.addWorkItem(project, title: "Andere Aufgabe")
        let foreign = AIConversation(id: first.id, itemId: other.uuid, provider: .anthropic, model: "test-modell",
                                     messages: continued.messages, createdAt: harness.clock.now())
        #expect(try failureMessage(await runtime.handle(.saveConversation(foreign))).contains("anderen Aufgabe"))

        // Über die Repositories in der Sync-Outbox (wird mit dem iPhone synchronisiert).
        let pending = try await harness.database.sync.pendingOperations(for: [SyncEntityKey(entityType: .aiConversation, entityId: first.id.rawValue)])
        #expect(!pending.isEmpty)
        #expect(harness.provider.startCount == 0)
    }

    @Test func proposalWithoutAcceptIsStoredAsConversationDraftOnly() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project, title: "Rohidee")
        let conversation = Self.conversation(for: item, at: harness.clock.now(), turns: 2)
        try expectResult(await runtime.handle(.saveConversation(conversation)))

        let command = ConversationDraftCommand(
            workItemId: item.uuid, content: Self.proposal, providerId: "anthropic", modelId: "test-modell",
            conversationId: conversation.id, usage: TokenUsage(inputTokens: 100, outputTokens: 30), accept: false,
            expectedRevision: item.revision)
        let info = try draftInfo(await runtime.handle(.appendConversationDraft(command)))
        #expect(info.wasCreated)
        #expect(!info.accepted)
        #expect(info.workItem == nil)

        let draft = try #require(try await harness.database.draftVersions.fetch(command.draftId))
        #expect(draft.source == .ai)
        #expect(draft.channel == .conversation)
        #expect(draft.providerId == .anthropic)
        #expect(draft.modelId == AIModelID(rawValue: "test-modell"))
        #expect(draft.contents.first?.title == "CSV-Export mit Kopfzeile")
        #expect(draft.usage == TokenUsage(inputTokens: 100, outputTokens: 30))
        #expect(!draft.isAccepted)
        #expect(info.version == draft.version)
        // H3: Originalnotiz getrennt versioniert, Aufgabe unverändert.
        let versions = try await harness.database.draftVersions.versions(workItemId: item.uuid)
        #expect(versions.contains { $0.source == .original && $0.text == item.originalNote })
        let unchanged = try #require(try await harness.database.workItems.fetch(item.uuid))
        #expect(unchanged.revision == item.revision)
        #expect(unchanged.title == "Rohidee")
        #expect(try await harness.database.aiRecords.conversation(conversation.id)?.proposedDraftVersion == draft.version)

        // Wiederholung mit derselben ID legt keine zweite Version an.
        let again = try draftInfo(await runtime.handle(.appendConversationDraft(command)))
        #expect(!again.wasCreated)
        #expect(try await harness.database.draftVersions.versions(workItemId: item.uuid).count == versions.count)
        let pending = try await harness.database.sync.pendingOperations(for: [SyncEntityKey(entityType: .draftVersion, entityId: draft.id.rawValue)])
        #expect(!pending.isEmpty)

        // Später verwerfen wie jeder andere Entwurf.
        try expectResult(await runtime.handle(.rejectDraftVersion(draftId: draft.id)))
        let payloads = try await harness.database.events.events(forWorkItem: item.uuid).map(\.payload)
        #expect(DraftDecisionEvent.rejectedDraftIds(in: payloads) == [draft.id.rawValue])
    }

    @Test func acceptAppliesTheDraftWithRevisionCheckAndNeverStartsAnAgent() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project, title: "Rohidee")
        let conversation = Self.conversation(for: item, at: harness.clock.now(), turns: 2)
        try expectResult(await runtime.handle(.saveConversation(conversation)))

        let command = ConversationDraftCommand(
            workItemId: item.uuid, content: Self.proposal, providerId: "anthropic", modelId: "test-modell",
            conversationId: conversation.id, accept: true, expectedRevision: item.revision)
        let info = try draftInfo(await runtime.handle(.appendConversationDraft(command)))
        #expect(info.accepted)
        #expect(info.wasCreated)
        #expect(info.message.contains("kein Agent"))

        let updated = try #require(try await harness.database.workItems.fetch(item.uuid))
        #expect(updated.title == "CSV-Export mit Kopfzeile")
        #expect(updated.structuredBody.contains("## Akzeptanzkriterien"))
        #expect(updated.structuredBody.contains("- [ ] Erste Zeile enthält Spaltennamen"))
        #expect(updated.priority == .high)
        #expect(updated.originalNote == item.originalNote)
        #expect(info.workItem?.revision == updated.revision)
        let draft = try #require(try await harness.database.draftVersions.fetch(command.draftId))
        #expect(draft.isAccepted)
        #expect(draft.acceptedContentIndexes == [0])
        #expect(draft.channel == .conversation)

        // Verlauf: Bearbeitung durch den Mac-Benutzer und Entscheidung „übernommen“ mit Gesprächsbezug.
        let history = try await harness.database.events.events(forWorkItem: item.uuid)
        #expect(history.contains { $0.kind == .edited && $0.actor == .user(runtime.deviceId) })
        let decision = try #require(history.first { $0.payload[DraftDecisionEvent.decisionKey] == DraftDecisionEvent.accepted })
        #expect(decision.payload[DraftDecisionEvent.draftIdKey] == draft.id.uuidString)
        #expect(decision.payload[DraftDecisionEvent.channelKey] == "conversation")
        #expect(decision.payload[DraftDecisionEvent.conversationIdKey] == conversation.id.uuidString)
        #expect(decision.actor == .user(runtime.deviceId))

        // Wiederholung nach Zeitüberschreitung: keine zweite Übernahme.
        let again = try draftInfo(await runtime.handle(.appendConversationDraft(command)))
        #expect(!again.wasCreated)
        #expect(again.accepted)
        #expect(try await harness.database.workItems.fetch(item.uuid)?.revision == updated.revision)

        // Nie ein Agentenstart (H3: Gespräch ist keine Coding-Agent-Sitzung).
        #expect(try await harness.database.jobs.jobs(forWorkItem: item.uuid).isEmpty)
        await runtime.jobsPass()
        #expect(harness.provider.startCount == 0)
    }

    @Test func staleRevisionIsRejectedWithoutWritingAnything() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project, title: "Rohidee")
        // Jemand anderes (z. B. das iPhone) hat die Aufgabe inzwischen geändert.
        let changed = try await harness.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: .user(DeviceID()),
                                                                   at: harness.clock.now()) { $0.title = "Vom iPhone geändert" }
        let versionsBefore = try await harness.database.draftVersions.versions(workItemId: item.uuid).count

        let command = ConversationDraftCommand(
            workItemId: item.uuid, content: Self.proposal, providerId: "anthropic", modelId: "test-modell", conversationId: nil,
            accept: true, expectedRevision: item.revision)
        #expect(try failureMessage(await runtime.handle(.appendConversationDraft(command))).contains("neu laden"))
        #expect(try await harness.database.draftVersions.fetch(command.draftId) == nil)
        #expect(try await harness.database.draftVersions.versions(workItemId: item.uuid).count == versionsBefore)
        let stored = try #require(try await harness.database.workItems.fetch(item.uuid))
        #expect(stored.title == "Vom iPhone geändert")
        #expect(stored.revision == changed.revision)

        // Mit aktueller Revision gelingt die Übernahme.
        var retry = command
        retry.expectedRevision = changed.revision
        #expect(try draftInfo(await runtime.handle(.appendConversationDraft(retry))).accepted)
        #expect(try await harness.database.workItems.fetch(item.uuid)?.title == "CSV-Export mit Kopfzeile")

        // Ungültige Eingaben.
        var untitled = ConversationDraftCommand(workItemId: item.uuid, content: DraftContent(classification: .todo, title: "  "),
                                                providerId: "anthropic", modelId: "m", conversationId: nil, accept: false, expectedRevision: 0)
        #expect(try failureMessage(await runtime.handle(.appendConversationDraft(untitled))).contains("Titel"))
        untitled.content.title = "Titel"
        untitled.modelId = " "
        #expect(try failureMessage(await runtime.handle(.appendConversationDraft(untitled))).contains("Modell"))
        #expect(try await harness.database.jobs.jobs(forWorkItem: item.uuid).isEmpty)
        #expect(harness.provider.startCount == 0)
    }
}

func conversationInfo(_ response: ServiceResponse, sourceLocation: SourceLocation = #_sourceLocation) throws -> ConversationSavedInfo {
    guard case let .result(.conversationSaved(info)) = try expectResult(response, sourceLocation: sourceLocation) else {
        Issue.record("Gesprächsergebnis erwartet: \(response)", sourceLocation: sourceLocation)
        throw TestFailure("kein conversationSaved")
    }
    return info
}

func draftInfo(_ response: ServiceResponse, sourceLocation: SourceLocation = #_sourceLocation) throws -> ConversationDraftInfo {
    guard case let .result(.conversationDraft(info)) = try expectResult(response, sourceLocation: sourceLocation) else {
        Issue.record("Entwurfsergebnis erwartet: \(response)", sourceLocation: sourceLocation)
        throw TestFailure("kein conversationDraft")
    }
    return info
}
