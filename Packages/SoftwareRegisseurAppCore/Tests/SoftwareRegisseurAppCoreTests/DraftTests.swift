import Foundation
import Testing
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

@Suite("AI drafts (H3)")
struct DraftTests {
    let feature = StructuredDraft(type: .feature, title: "PDF-Export", goal: "Berichte teilen",
                                  acceptanceCriteria: ["PDF enthält alle Seiten"], priority: .critical,
                                  openQuestions: ["Welches Seitenformat?"])
    let bug = StructuredDraft(type: .bug, title: "Absturz beim Export")
    let adr = StructuredDraft(type: .adr, title: "PDF-Bibliothek wählen")

    @Test func perItemConfirmationIsRequired() {
        var session = DraftReviewSession(mode: .inAufgabenAufteilen, drafts: [feature, bug, adr])
        #expect(!session.canAdopt)
        #expect(session.openQuestions == ["Welches Seitenformat?"])

        let ids = session.candidates.map(\.id)
        session.decide(.accepted, for: ids[0])
        #expect(!session.canAdopt) // others still pending

        session.decide(.accepted, for: ids[2]) // ADR cannot become a work item
        #expect(session.candidates[2].decision == .pending)
        #expect(!session.candidates[2].isAdoptable)

        session.decide(.rejected, for: ids[1])
        session.decide(.rejected, for: ids[2])
        #expect(session.canAdopt)
        #expect(session.accepted.map(\.draft.title) == ["PDF-Export"])
    }

    @Test func adoptionCreatesOnlyAcceptedItemsAndKeepsOriginal() async throws {
        let database = try AppDatabase.inMemory()
        let source = WorkItem(type: .note, title: "Diktat", originalNote: "PDF Export und Absturz", transcript: "PDF Export und Absturz",
                              status: .inbox, createdAt: now)
        try await database.workItems.insert(source, actor: actor, at: now)
        var session = DraftReviewSession(mode: .inAufgabenAufteilen, drafts: [feature, bug])
        session.decide(.accepted, for: session.candidates[0].id)

        let adopter = DraftAdopter(workItems: database.workItems, headings: headings)
        #expect(try await adopter.createItems(from: session, source: source, actor: actor, at: now).isEmpty) // not all decided

        session.decide(.rejected, for: session.candidates[1].id)
        let created = try await adopter.createItems(from: session, source: source, actor: actor, at: now)
        #expect(created.count == 1)
        let item = try #require(created.first)
        #expect(item.type == .feature)
        #expect(item.priority == .urgent)
        #expect(item.originalNote == source.originalNote)
        #expect(item.transcript == source.transcript)
        #expect(item.status == .inbox)
        #expect(item.structuredBody.contains("## Akzeptanzkriterien\n\n- [ ] PDF enthält alle Seiten"))
        #expect(item.structuredBody.contains("## Offene Fragen"))
        #expect(try await database.jobs.jobs(forWorkItem: item.uuid).isEmpty) // never starts an agent
    }

    @Test func applyingDraftKeepsTypeAndOriginalNote() async throws {
        let (database, _, item) = try await Fixture.makeDatabase()
        let adopter = DraftAdopter(workItems: database.workItems, headings: headings)
        let updated = try await adopter.apply(feature, to: item, actor: actor, at: now)
        #expect(updated.title == "PDF-Export")
        #expect(updated.originalNote == item.originalNote)
        #expect(updated.type == item.type)
        #expect(updated.structuredBody.hasPrefix("## Ziel\n\nBerichte teilen"))
    }

    @Test @MainActor func conversationProposalNeedsExplicitAcceptance() async throws {
        let reply = """
        {"reply": "Ich schlage eine präzisere Fassung vor.", "proposedDrafts": [{"type": "feature", "title": "PDF-Export v2", "goal": "", "context": "", "acceptanceCriteria": [], "technicalNotes": [], "testCases": [], "priority": "unspecified", "dependencies": [], "openQuestions": []}]}
        """
        let provider = StubTextProvider(outputs: [reply])
        let session = ConversationSession(provider: provider, model: "claude-test", originalNote: "PDF Export",
                                          currentDraft: feature)
        let controller = ConversationController(session: session)

        await controller.prepare(message: "Bitte präziser")
        guard case let .reviewingContext(prepared) = controller.phase else {
            Issue.record("Manifest must be shown before sending")
            return
        }
        #expect(prepared.manifest.included.contains { $0.kind == .originalNote })
        #expect(provider.requestCount == 0)

        await controller.confirmSend()
        #expect(provider.requestCount == 1)
        #expect(controller.turns.count == 2)
        #expect(controller.pendingProposal?.title == "PDF-Export v2")
        #expect(await session.currentDraft?.title == "PDF-Export") // not adopted yet

        let accepted = await controller.acceptProposal()
        #expect(accepted?.title == "PDF-Export v2")
        #expect(await session.currentDraft?.title == "PDF-Export v2")
        #expect(controller.pendingProposal == nil)
    }

    @Test func draftVersionsAreAppendedPerItem() async throws {
        // Synced Domain draft versions (gap 7) instead of the device-only JSON file.
        let database = try AppDatabase.inMemory()
        let store = DraftVersionStore(repository: database.draftVersions)
        let item = WorkItemID()
        let first = try await store.append(for: item, source: .composer, mode: .kurz, provider: "anthropic", model: "m",
                                           drafts: [feature], usage: AIUsage(inputTokens: 10, outputTokens: 5), at: now)
        let second = try await store.append(for: item, source: .conversation, mode: nil, provider: "anthropic", model: "m",
                                            drafts: [bug], usage: .zero, at: now)
        try await store.markAdopted(second.id, draftIndexes: [0], for: item)
        let reloaded = try await DraftVersionStore(repository: database.draftVersions).versions(for: item)
        #expect(reloaded.map(\.version) == [first.version, second.version])
        #expect(reloaded.last?.adoptedDraftIndexes == [0])
    }

    @Test func reviewActionsFollowM1() throws {
        let item = Fixture.item(projectId: ProjectID(), status: .review)
        var review = Review(jobId: JobID(), diffSummary: DiffSummary(filesChanged: 2, insertions: 10, deletions: 1))
        #expect(ReviewAction.available(for: Fixture.item(projectId: ProjectID()), review: review).isEmpty) // open item
        #expect(ReviewAction.available(for: item, review: review) == [.approveIntegration, .requestChanges, .reject])
        #expect(ReviewAction.available(for: item, review: nil).isEmpty)
        review.decide(.approved, at: now)
        #expect(ReviewAction.available(for: item, review: review) == [.requestChanges])
        // `done` only after integration into the default branch was recorded (M1 step 6).
        let integrated = Fixture.item(projectId: ProjectID(), status: .integrated)
        #expect(ReviewAction.available(for: integrated, review: review).isEmpty)
        try review.recordIntegration(commit: "abc123", strategy: .squash)
        #expect(ReviewAction.available(for: integrated, review: review) == [.markDone])
    }
}
