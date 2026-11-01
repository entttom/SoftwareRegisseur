import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

/// Every entity of spec table O is written and read back unchanged (including open IDs, optional
/// fields and private(set) state), and every synced entity survives the sync payload round trip.
@Suite("Entity round trips")
struct RoundTripTests {
    @Test func projectSettingsAndLocation() async throws {
        let database = try AppDatabase.inMemory()
        var (project, settings) = Fixture.project()
        let projectPreference = AgentModelPreference(
            scope: .project(project.id), providerId: "custom agent ✓", model: .providerDefault, effort: "ultra-think", updatedAt: at(3)
        )
        settings.setModelPreference(projectPreference, at: at(3))
        settings.defaultAgentId = .claudeCode
        settings.maxParallelJobs = 2
        settings.integrationStrategy = .cherryPick
        try project.transition(to: .ready, at: at(4))
        try await database.projects.create(project, settings: settings, at: t0)

        #expect(try await database.projects.fetch(project.id) == project)
        #expect(try await database.projects.settings(forProject: project.id) == settings)
        #expect(try await database.projects.fetch(repositoryIdentity: project.repositoryIdentity!) == [project])

        let location = RepositoryLocation(projectId: project.id, hostId: Fixture.host, canonicalPath: "/Users/x/Code/Regie",
                                          bookmarkReference: "bookmark-1", scanState: .scanned, lastScanAt: at(7))
        try await database.projects.saveLocation(location, at: t0)
        #expect(try await database.projects.locations(projectId: project.id) == [location])
        #expect(try await database.projects.locations(hostId: Fixture.host) == [location])
    }

    @Test func workItemWithAllFields() async throws {
        let database = try AppDatabase.inMemory()
        let (project, _) = try await database.seedItem()
        let item = WorkItem(
            humanId: try HumanID(type: .bug, number: 12), projectId: project.id, type: .bug, title: "Absturz 🚑",
            originalNote: "Original", transcript: "Transkript", structuredBody: "Body", status: .blocked,
            priority: .urgent, complexity: .large, labels: ["ios", "sync"], dependencies: [WorkItemID()],
            reviewState: .changesRequested, revision: 7, createdAt: t0, updatedAt: at(99)
        )
        try await database.workItems.insert(item, actor: .external, at: t0)
        #expect(try await database.workItems.fetch(item.uuid) == item)

        let inbox = WorkItem(type: .note, title: "Nur Notiz", createdAt: t0)
        try await database.workItems.insert(inbox, actor: deviceActor, at: t0)
        #expect(try await database.workItems.fetch(inbox.uuid) == inbox)
    }

    @Test func adrAudioAndAIRecords() async throws {
        let database = try AppDatabase.inMemory()
        let projectId = ProjectID()
        var adr = ADR(projectId: projectId, decisionNumber: try ADRNumber(19), title: "GRDB", date: at(1),
                      context: "C", decision: "D", alternatives: "A", consequences: "K",
                      supersedes: [try ADRNumber(0), try ADRNumber(3)], createdAt: t0)
        try adr.transition(to: .accepted, at: at(2))
        try await database.adrs.insert(adr, at: t0)
        #expect(try await database.adrs.fetch(adr.uuid) == adr)
        #expect(try await database.adrs.fetch(projectId: projectId, number: try ADRNumber(19)) == adr)

        let note = AudioNote(workItemId: WorkItemID(), localAssetRef: "audio/1.m4a", provider: .openAI,
                             consent: .granted(at: at(4)), transcriptionState: .completed, retentionPolicy: .keepForDays(30), createdAt: t0)
        try await database.aiRecords.saveAudioNote(note, at: t0)
        #expect(try await database.aiRecords.audioNote(note.id) == note)

        let request = AIRequest(itemId: WorkItemID(), provider: .anthropic, model: "claude-sonnet-x", mode: .structureDraft,
                                inputVersion: 2, draftVersion: 3, usage: TokenUsage(inputTokens: 10, outputTokens: 20),
                                costEstimate: CostEstimate(amount: Decimal(string: "0.0123")!, currencyCode: "EUR"),
                                state: .completed, createdAt: t0)
        try await database.aiRecords.saveRequest(request, at: t0)
        #expect(try await database.aiRecords.request(request.id) == request)

        var conversation = AIConversation(itemId: WorkItemID(), provider: .gemini, model: "gemini-x",
                                          contextScope: .repositoryFiles(projectId, paths: ["README.md"]), createdAt: t0)
        conversation.append(AIMessage(role: .user, text: "Hallo", createdAt: at(5)), usage: TokenUsage(inputTokens: 1, outputTokens: 2))
        conversation.proposedDraftVersion = 4
        try await database.aiRecords.saveConversation(conversation, at: t0)
        #expect(try await database.aiRecords.conversation(conversation.id) == conversation)
        #expect(conversation.updatedAt != conversation.createdAt)
    }

    @Test func hostCapabilitiesAndPreferences() async throws {
        let database = try AppDatabase.inMemory()
        let host = AgentHost(hostId: Fixture.host, name: "Mac Studio", lastSeen: at(1), ready: true,
                             agentCapabilities: [Fixture.capability()], serviceVersion: "1.0 (42)")
        try await database.capabilities.saveHost(host, at: t0)
        #expect(try await database.capabilities.host(host.hostId) == host)
        #expect(try await database.capabilities.capability(hostId: host.hostId, providerId: .codex) == Fixture.capability())

        let preferences = [
            AgentModelPreference(scope: .global, providerId: .codex, model: .model("gpt-5.5-codex"), effort: .xhigh, updatedAt: t0),
            AgentModelPreference(scope: .global, providerId: .claudeCode, model: nil, effort: nil, inheritsDefault: true, updatedAt: t0),
            AgentModelPreference(scope: .project(ProjectID()), providerId: .codex, model: .providerDefault, effort: .auto, updatedAt: at(1)),
        ]
        for preference in preferences { try await database.preferences.save(preference, at: t0) }
        for preference in preferences {
            #expect(try await database.preferences.preference(scope: preference.scope, providerId: preference.providerId) == preference)
        }
        #expect(try await database.preferences.preferences(scope: .global).count == 2)
    }

    @Test func jobLockEventReviewLinkProfile() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let zoned = try ZonedLocalDateTime(year: 2026, month: 11, day: 2, hour: 7, minute: 0, timeZoneIdentifier: "Europe/Vienna")
        let job = Fixture.job(for: item, schedule: JobSchedule(kind: .at(zoned), missedRunPolicy: .runImmediatelyWhenAvailable))
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        _ = try await database.jobs.transition(job.jobId, to: .scheduled, actor: .host(Fixture.host), at: at(2))
        _ = try await database.jobs.transition(job.jobId, to: .admitted, actor: .host(Fixture.host), at: at(3))
        let change = try await database.jobs.update(job.jobId, expectedRevision: 3, actor: .host(Fixture.host), at: at(4)) {
            try $0.transition(to: .starting, at: at(4))
            $0.sessionId = "session-1"
            $0.branch = "software-regisseur/x/y"
            $0.worktreePath = "/tmp/wt"
            $0.recordConfirmedEffectiveConfiguration(model: "gpt-5.5-codex", effort: .high, at: at(4))
            $0.lastError = "none"
            $0.retryCount = 1
        }
        let stored = try #require(try await database.jobs.fetch(job.jobId))
        #expect(stored == change.job)
        #expect(stored.state == .starting)
        #expect(stored.startedAt == at(4))
        #expect(stored.scheduledAt == zoned.resolveDate())

        var lock = try await database.locks.acquire(
            LockRequest(taskId: item.uuid, projectId: item.projectId!, jobId: job.jobId, hostId: Fixture.host,
                        owner: "AgentService", scope: .task, leaseDuration: 60), at: at(5))
        #expect(try await database.locks.fetch(lock.lockId) == lock)
        lock = try await database.locks.markAwaitingReconciliation(lock.lockId, at: at(6))
        #expect(try await database.locks.fetch(lock.lockId) == lock)

        let events = try await database.events.events(forWorkItem: item.uuid)
        #expect(!events.isEmpty)
        let custom = TaskEvent(workItemId: item.uuid, kind: .comment, actor: .agent(.claudeCode, job.jobId), timestamp: at(7),
                               payload: ["text": "Ä"], sourceRevision: 9)
        try await database.events.append(custom)
        #expect(try await database.events.events(forWorkItem: item.uuid).last == custom)

        var review = Review(jobId: job.jobId, diffSummary: DiffSummary(filesChanged: 2, insertions: 10, deletions: 1, files: ["a", "b"]),
                            testResults: [TestResult(name: "unit", outcome: .passed), TestResult(name: "ui", outcome: .skipped, detail: "no sim")])
        review.decide(.approved, at: at(8))
        try review.recordIntegration(commit: "abc123", strategy: .squash)
        try await database.reviews.save(review, at: t0)
        #expect(try await database.reviews.fetch(review.reviewId) == review)

        let link = GitHubIssueLink(workItemId: item.uuid, repo: "example/regie", issueNumber: 42,
                                   url: "https://github.com/example/regie/issues/42", lastSyncedRevision: 3)
        try await database.reviews.saveIssueLink(link, at: t0)
        #expect(try await database.reviews.issueLink(workItemId: item.uuid) == link)

        let profile = ProviderProfile(providerId: .openAI, purpose: .transcription, model: "gpt-4o-transcribe",
                                      keychainReference: KeychainReference(service: "regie.openai", account: "default"),
                                      deviceScope: .iCloudKeychain, settings: ["language": "de"])
        try await database.providerProfiles.save(profile, at: t0)
        #expect(try await database.providerProfiles.fetch(profile.id) == profile)
    }

    @Test func outboxOperationDecodesToDomainSyncOperation() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let operations = try await database.sync.pendingOperations(limit: 100)
        let itemOperation = try #require(operations.first { $0.entityId == item.uuid.rawValue })
        #expect(itemOperation.entityType == SyncEntityType.workItem.rawValue)
        #expect(itemOperation.type == .create)
        #expect(itemOperation.state == .pending)
        try await database.sync.markFailed(itemOperation.operationId, error: "network", at: at(1))
        let failed = try #require(try await database.sync.operation(itemOperation.operationId))
        #expect(failed.attempts == 1)
        #expect(failed.lastError == "network")
        #expect(failed.state == .failed)
    }

    /// Payload produced on one device is applied on another and yields an equal entity.
    @Test func syncPayloadRoundTripForEverySyncedEntity() async throws {
        let source = try AppDatabase.inMemory()
        let target = try AppDatabase.inMemory()
        let (project, item) = try await source.seedItem()
        let job = Fixture.job(for: item)
        _ = try await source.jobs.create(job, actor: deviceActor, at: at(1))
        try await source.capabilities.saveHost(AgentHost(hostId: Fixture.host, name: "Mac", lastSeen: t0, ready: true,
                                                         agentCapabilities: [Fixture.capability()], serviceVersion: "1"), at: t0)
        _ = try await source.locks.acquire(LockRequest(taskId: item.uuid, projectId: project.id, jobId: job.jobId,
                                                       hostId: Fixture.host, owner: "svc", leaseDuration: 30), at: at(2))
        try await source.preferences.save(AgentModelPreference(scope: .global, providerId: .codex, effort: .low, updatedAt: t0), at: t0)

        let operations = try await source.sync.pendingOperations(limit: 1000)
        let entities = Set(operations.map { "\($0.entityType)|\($0.entityId.uuidString)" })
        var changes: [RemoteChange] = []
        for key in entities.sorted() {
            let parts = key.split(separator: "|").map(String.init)
            let type = try #require(SyncEntityType(rawValue: parts[0]))
            let id = try #require(UUID(uuidString: parts[1]))
            let payload = try #require(try await source.sync.currentPayload(entityType: type, entityId: id))
            changes.append(RemoteChange(operationId: SyncOperationID(), entityType: type, entityId: id, kind: .create,
                                        version: 1, baseVersion: nil, payload: payload))
        }
        let outcomes = try await target.sync.applyRemoteChanges(changes, engineState: nil, at: at(10))
        #expect(outcomes.allSatisfy { $0 == .applied })
        #expect(Set(changes.map(\.entityType)).isSuperset(of: [.project, .projectSettings, .workItem, .agentJob, .taskLock,
                                                              .taskEvent, .agentHost, .agentCapability, .agentModelPreference]))

        #expect(try await target.projects.fetch(project.id) == project)
        #expect(try await target.workItems.fetch(item.uuid) == source.workItems.fetch(item.uuid))
        #expect(try await target.jobs.fetch(job.jobId) == source.jobs.fetch(job.jobId))
        #expect(try await target.capabilities.host(Fixture.host) == source.capabilities.host(Fixture.host))
        #expect(try await target.events.events(forWorkItem: item.uuid) == source.events.events(forWorkItem: item.uuid))
        #expect(try await target.locks.activeLock(forTask: item.uuid) == source.locks.activeLock(forTask: item.uuid))
    }
}

extension ZonedLocalDateTime {
    func resolveDate() -> Date? { try? resolve().date }
}
