import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

let t0 = Date(timeIntervalSinceReferenceDate: 815_000_000.123_456_789)
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Fake credentials in the formats the scanner must catch (never real keys).
enum FakeSecrets {
    static let openAIKey = "sk-proj-FAKEFAKEFAKEFAKEFAKEFAKE1234567890"
    static let anthropicKey = "sk-ant-api03-FAKEFAKEFAKEFAKEFAKE0987654321"
}

final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

struct Seeded {
    var project: Project
    var item: WorkItem
    var inboxItem: WorkItem
    var adr: ADR
    var job: AgentJob
    var deviceProfile: ProviderProfile
    var syncedProfile: ProviderProfile
    var audioNote: AudioNote
}

extension AppDatabase {
    /// Writes at least one entity of every `SyncEntityType`, plus an open sync conflict.
    func seedAllEntityTypes() async throws -> Seeded {
        let host = HostID()
        let device = DeviceID()
        let actor = EventActor.user(device)

        var settings = ProjectSettings(updatedAt: t0)
        let preference = AgentModelPreference(scope: .global, providerId: .codex, model: .model("gpt-5.5-codex"), effort: .high, updatedAt: t0)
        let project = Project(name: "Regie Ü", repositoryIdentity: RepositoryIdentity(rawValue: "git:regie"), repositoryKind: .gitRepository,
                              remote: "git@github.com:example/regie.git", hostId: host, settingsId: settings.id, createdAt: t0)
        settings.defaultAgentId = .claudeCode
        try await projects.create(project, settings: settings, at: t0)
        try await projects.saveLocation(RepositoryLocation(projectId: project.id, hostId: host, canonicalPath: "/Users/x/Code/Regie",
                                                           bookmarkReference: "bm", scanState: .scanned, lastScanAt: at(1)), at: t0)
        try await preferences.save(preference, at: t0)

        let item = WorkItem(
            projectId: project.id, type: .feature, title: "Export bauen",
            originalNote: "Bitte Export bauen. Mein Schlüssel ist \(FakeSecrets.anthropicKey)",
            transcript: "Bitte Export bauen", structuredBody: "## Ziel\nExport", labels: ["datenschutz"], createdAt: t0
        )
        try await workItems.insert(item, actor: actor, at: t0)
        let inboxItem = WorkItem(type: .note, title: "Nur eine Notiz", originalNote: "Idee", createdAt: at(1))
        try await workItems.insert(inboxItem, actor: actor, at: at(1))

        var adr = ADR(projectId: project.id, decisionNumber: try ADRNumber(19), title: "GRDB", date: at(1),
                      context: "Kontext", decision: "Entscheidung", alternatives: "SwiftData", consequences: "Mehr Handarbeit",
                      createdAt: t0)
        try adr.transition(to: .accepted, at: at(2))
        try await adrs.insert(adr, at: t0)

        let audioNote = AudioNote(workItemId: item.uuid, localAssetRef: "Diktat-1.m4a", provider: .openAI,
                                  consent: .granted(at: at(1)), transcriptionState: .completed, retentionPolicy: .keepLocally, createdAt: t0)
        try await aiRecords.saveAudioNote(audioNote, at: t0)
        try await aiRecords.saveRequest(AIRequest(itemId: item.uuid, provider: .anthropic, model: "claude-x", mode: .structureDraft,
                                                  inputVersion: 1, draftVersion: 2, usage: TokenUsage(inputTokens: 1, outputTokens: 2),
                                                  costEstimate: CostEstimate(amount: Decimal(string: "0.01")!, currencyCode: "EUR"),
                                                  state: .completed, createdAt: t0), at: t0)
        var conversation = AIConversation(itemId: item.uuid, provider: .gemini, model: "gemini-x", contextScope: .itemOnly, createdAt: t0)
        conversation.append(AIMessage(role: .user, text: "Hallo", createdAt: at(2)), usage: TokenUsage(inputTokens: 1, outputTokens: 1))
        try await aiRecords.saveConversation(conversation, at: t0)

        let capability = AgentCapability(
            providerId: .codex, displayName: "OpenAI Codex", hostId: host, executablePath: "/opt/homebrew/bin/codex",
            version: "0.50.0", supportsRemote: true, supportsResume: true, supportsModelSelection: true, supportsEffortSelection: true,
            modelCatalog: [AgentModelCapability(providerId: .codex, modelId: "gpt-5.5-codex", displayName: "GPT-5.5 Codex",
                                                supportedEffortIds: [.low, .high], defaultEffortId: .low, source: .appServer, lastValidatedAt: t0)],
            defaultModelId: "gpt-5.5-codex", capabilitySource: .appServer, capabilityRevision: 1,
            lastChecked: t0, detectionTimestamp: t0, sessionLinkFormat: nil, diagnostic: "ok"
        )
        try await capabilities.saveHost(AgentHost(hostId: host, name: "Mac Studio", lastSeen: t0, ready: true,
                                                  agentCapabilities: [capability], serviceVersion: "1.0"), at: t0)

        let snapshot = ConfigurationSnapshot(providerId: .codex, requestedModel: .model("gpt-5.5-codex"), requestedEffort: .high,
                                             resolvedModel: .model("gpt-5.5-codex"), resolvedEffort: .high,
                                             profileSource: ProfileSources(model: .job, effort: .project), capabilityRevision: 1,
                                             agentVersion: "0.50.0", createdAt: t0)
        let job = AgentJob(idempotencyKey: IdempotencyKey(), projectId: project.id, workItemId: item.uuid, hostId: host,
                           configSnapshot: snapshot, schedule: JobSchedule(kind: .immediate), priority: .high,
                           workItemStatusBeforeJob: item.status, createdAt: at(1))
        _ = try await jobs.create(job, actor: actor, at: at(1))
        _ = try await locks.acquire(LockRequest(taskId: item.uuid, projectId: project.id, jobId: job.jobId, hostId: host,
                                                owner: "svc", leaseDuration: 60), at: at(2))
        var review = Review(jobId: job.jobId, diffSummary: DiffSummary(filesChanged: 1, insertions: 2, deletions: 0, files: ["a.swift"]),
                            testResults: [TestResult(name: "unit", outcome: .passed)])
        review.decide(.approved, at: at(3))
        try await reviews.save(review, at: t0)
        try await reviews.saveIssueLink(GitHubIssueLink(workItemId: item.uuid, repo: "example/regie", issueNumber: 7,
                                                        url: "https://github.com/example/regie/issues/7", lastSyncedRevision: 1), at: t0)

        // Provider profiles: a key pasted into a settings field must never be exported.
        let deviceProfile = ProviderProfile(providerId: .openAI, purpose: .transcription, model: "gpt-4o-transcribe",
                                            keychainReference: KeychainReference(service: "regie", account: "openai-device"),
                                            deviceScope: .thisDeviceOnly,
                                            settings: ["language": "de", "apiKey": FakeSecrets.openAIKey, "baseNote": FakeSecrets.openAIKey])
        try await providerProfiles.save(deviceProfile, at: t0)
        let syncedProfile = ProviderProfile(providerId: .anthropic, purpose: .textDrafting, model: "claude-x",
                                            keychainReference: KeychainReference(service: "regie", account: "anthropic"),
                                            deviceScope: .iCloudKeychain, settings: ["language": "de"])
        try await providerProfiles.save(syncedProfile, at: t0)

        try await projectSetupCommands.insert(ProjectSetupCommand(kind: .createProject, projectName: "Neu",
                                                                  target: .draftWithoutRepository, createdAt: t0), at: t0)
        _ = try await indexedFolders.upsert(IndexedFolder(hostId: host, canonicalPath: "/Dev/app", displayName: "app", kind: .gitRepository,
                                                          scanRootPath: "/Dev", depth: 1, isSelectable: true, lastSeenAt: t0))
        try await fileConflicts.insert(FileConflict(projectId: project.id, workItemId: item.uuid, location: "docs/requests/a.md",
                                                    kind: .concurrentEdit, databaseRevision: 1, databaseText: "A", externalText: "B", detectedAt: t0))
        let approval = PendingApproval(jobId: job.jobId, workItemId: item.uuid, hostId: host, requestId: "r1",
                                       kind: .commandExecution, summary: "Befehl ausführen: swift test", preview: "swift test",
                                       allowedDecisions: [.allow, .deny], requestedAt: at(2), expiresAt: at(602))
        try await approvals.save(approval, at: at(2))
        try await approvals.recordDecision(ApprovalDecision(for: approval, decision: .allow, decidedBy: device, at: at(3)))
        _ = try await draftVersions.append({ DraftVersion(workItemId: item.uuid, version: $0, source: .original, text: "Bitte Export bauen", createdAt: t0) },
                                           for: item.uuid, at: t0)
        _ = try await draftVersions.append({ version in
            DraftVersion(workItemId: item.uuid, version: version, source: .ai, channel: .composer, providerId: .anthropic, modelId: "claude-x",
                         contents: [DraftContent(classification: .feature, title: "Datenexport", goal: "Alle Daten exportieren",
                                                 acceptanceCriteria: ["Manifest vorhanden"])],
                         createdAt: at(1))
        }, for: item.uuid, at: at(1))
        _ = try await globalSettings.save(GlobalSettings(defaultAgentId: .codex, updatedAt: t0), expectedRevision: 0, at: t0)

        // An open sync conflict: local unsent edit vs. remote edit of the same synced version.
        for operation in try await sync.pendingOperations(limit: 10_000) {
            try await sync.markSent(operation.operationId, systemFields: nil, at: at(5))
        }
        let local = try await workItems.update(inboxItem.uuid, expectedRevision: inboxItem.revision, actor: actor, at: at(10)) {
            $0.structuredBody = "Mac-Text"
        }
        var phone = inboxItem
        phone.structuredBody = "iPhone-Text"
        phone.touch(at: at(11))
        let outcome = try await sync.applyRemoteChanges([RemoteChange(
            operationId: SyncOperationID(), entityType: .workItem, entityId: inboxItem.uuid.rawValue, kind: .update,
            version: 2, baseVersion: 1, payload: try SyncPayloadCodec.encode(phone), systemFields: nil
        )], engineState: nil, at: at(12))
        precondition(outcome == [.conflict])

        return Seeded(project: project, item: item, inboxItem: local, adr: adr, job: job,
                      deviceProfile: deviceProfile, syncedProfile: syncedProfile, audioNote: audioNote)
    }
}

/// Every file below `folder`, as `relative path → contents`.
func allFiles(in folder: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        result[String(path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
    }
    return result
}

extension Data {
    func contains(_ text: String) -> Bool { range(of: Data(text.utf8)) != nil }
}
