import Foundation
import Testing
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

@Suite("iPhone flows over synced contracts (E2, J6, H3, J2)")
struct CrossDeviceFlowTests {
    let device = DeviceID()
    let host = HostID()

    func folder(_ path: String, _ kind: IndexedFolderKind, root: String = "/Users/me/Developer", linked: ProjectID? = nil) -> IndexedFolder {
        IndexedFolder(hostId: host, canonicalPath: path, displayName: URL(filePath: path).lastPathComponent, kind: kind,
                      repositoryRootPath: kind == .repositorySubfolder ? "/Users/me/Developer/Mono" : nil, scanRootPath: root,
                      depth: 1, projectId: linked, isSelectable: true, lastSeenAt: now)
    }

    // MARK: Neues Projekt (E2)

    @Test func newProjectOptionsAreValidatedBeforeACommandExists() throws {
        let repo = folder("/Users/me/Developer/App", .gitRepository)
        let plain = folder("/Users/me/Developer/Idee", .plainFolder)
        let sub = folder("/Users/me/Developer/Mono/apps", .repositorySubfolder)
        let linked = folder("/Users/me/Developer/Alt", .gitRepository, linked: ProjectID())
        let choices = FolderChoices(folders: [repo, plain, sub, linked])
        #expect(choices.roots == ["/Users/me/Developer"])
        #expect(choices.folders(of: .gitRepository).map(\.displayName) == ["Alt", "App"])
        #expect(choices.folders(of: .subfolderOfRepository) == [sub])
        #expect(choices.folders(of: .notARepository) == [plain])

        func blockers(_ input: NewProjectInput) -> [NewProjectBlocker] { NewProjectPlanner.blockers(input, choices: choices) }
        #expect(blockers(NewProjectInput(name: " ", option: .draft)) == [.emptyName])
        #expect(blockers(NewProjectInput(name: "X", option: .draft, gitInitConsent: true)) == [.gitInitNotPossible])
        #expect(blockers(NewProjectInput(name: "X", option: .newSubfolder(parentPath: "/Users/me/Developer", name: "../x")))
            == [.invalidFolderName])
        #expect(blockers(NewProjectInput(name: "X", option: .newSubfolder(parentPath: "/etc", name: "x"))) == [.parentNotAllowed])
        #expect(blockers(NewProjectInput(name: "X", option: .newSubfolder(parentPath: "/Users/me/Developer/Idee", name: "x"))).isEmpty)
        // Subfolder of a repository: conscious choice whole repository vs. subfolder (E2).
        #expect(blockers(NewProjectInput(name: "X", option: .existingFolder(sub, scope: nil))) == [.scopeChoiceRequired])
        #expect(blockers(NewProjectInput(name: "X", option: .existingFolder(sub, scope: .subfolderOnly), gitInitConsent: true))
            == [.gitInitNotPossible])
        #expect(blockers(NewProjectInput(name: "X", option: .linkRepository(plain))) == [.notARepository])
        #expect(blockers(NewProjectInput(name: "X", option: .linkRepository(linked))) == [.folderAlreadyLinked])
        #expect(NewProjectPlanner.blockers(NewProjectInput(name: "X", option: .newSubfolder(parentPath: "/x", name: "y")),
                                           choices: FolderChoices(folders: [])) == [.noAllowedRoots])
    }

    @Test func newSubfolderWithGitInitConsentCreatesProjectAndCommand() async throws {
        let database = try AppDatabase.inMemory()
        var global = GlobalSettings(defaultAgentId: .codex, updatedAt: now)
        global.folderLayout.requestsRoot = "planung"
        let choices = FolderChoices(folders: [folder("/Users/me/Developer/App", .gitRepository)])
        let plan = try NewProjectPlanner.plan(
            NewProjectInput(name: " Neues Spiel ", option: .newSubfolder(parentPath: "/Users/me/Developer", name: "Neues Spiel"),
                            gitInitConsent: true),
            choices: choices, globalSettings: global, device: device, now: now)
        let project = try #require(plan.project)
        #expect(project.status == .pendingMacSetup && project.name == "Neues Spiel" && project.hostId == host)
        #expect(plan.settings?.requestsRoot == "planung")
        #expect(plan.command.kind == .createProject && plan.command.projectId == project.id)
        #expect(plan.command.target == .newSubfolder(parentPath: "/Users/me/Developer", folderName: "Neues Spiel"))
        #expect(plan.command.initializeGitRepository && plan.command.gitInitConsent?.grantedBy == device)
        #expect(plan.command.requestedBy == device)

        try await NewProjectSubmitter(projects: database.projects, commands: database.projectSetupCommands).submit(plan, at: now)
        #expect(try await database.projects.fetch(project.id) == project)
        let commands = try await database.projectSetupCommands.list(projectId: project.id)
        #expect(commands == [plan.command])
        #expect(SetupCommandStatus.latest(commands) == .waitingForMac)
        var done = plan.command
        done.complete(resultPath: "/Users/me/Developer/Neues Spiel", at: now)
        #expect(SetupCommandStatus(done) == .completed(path: "/Users/me/Developer/Neues Spiel"))
    }

    @Test func withoutConsentNoGitInitAndLinkingADraftUsesLinkProject() throws {
        let plain = folder("/Users/me/Developer/Idee", .plainFolder)
        let repo = folder("/Users/me/Developer/App", .gitRepository)
        let choices = FolderChoices(folders: [plain, repo])
        let existing = try NewProjectPlanner.plan(NewProjectInput(name: "Idee", option: .existingFolder(plain, scope: nil)),
                                                  choices: choices, globalSettings: .defaults, device: device, now: now)
        #expect(!existing.command.initializeGitRepository && existing.command.gitInitConsent == nil)
        #expect(existing.command.target == .indexedFolder(path: plain.canonicalPath))

        let draftId = ProjectID()
        let link = try NewProjectPlanner.plan(NewProjectInput(name: "Entwurf", option: .linkRepository(repo), linkToProject: draftId),
                                              choices: choices, globalSettings: .defaults, device: device, now: now)
        #expect(link.project == nil && link.command.kind == .linkProject && link.command.projectId == draftId)
        let draft = try NewProjectPlanner.plan(NewProjectInput(name: "Entwurf", option: .draft), choices: choices,
                                               globalSettings: .defaults, device: device, now: now)
        #expect(draft.command.target == .draftWithoutRepository && draft.project?.repositoryKind == .notARepository)
        let sub = folder("/Users/me/Developer/Mono/apps", .repositorySubfolder)
        #expect(throws: NewProjectError.blocked([.scopeChoiceRequired])) {
            _ = try NewProjectPlanner.plan(NewProjectInput(name: "Apps", option: .existingFolder(sub, scope: nil)),
                                           choices: FolderChoices(folders: [sub]), globalSettings: .defaults, device: device, now: now)
        }
        let whole = try NewProjectPlanner.plan(NewProjectInput(name: "Apps", option: .existingFolder(sub, scope: .wholeRepository)),
                                               choices: FolderChoices(folders: [sub]), globalSettings: .defaults, device: device, now: now)
        #expect(whole.command.repositoryScope == .wholeRepository)
    }

    // MARK: Approvals (J6 V1 fallback)

    @Test func approvalDecisionsAreExplicitAndSentOnce() async throws {
        let database = try AppDatabase.inMemory()
        let approval = PendingApproval(jobId: JobID(), workItemId: WorkItemID(), hostId: host, requestId: "r1",
                                       kind: .commandExecution, summary: "Der Agent möchte einen Befehl ausführen.",
                                       preview: "swift test", requestedAt: now, expiresAt: now.addingTimeInterval(600))
        try await database.approvals.save(approval, at: now)
        let center = ApprovalCenter(approvals: database.approvals)
        let item = try #require(try await center.openItems().first)
        #expect(item.displayState(at: now) == .awaitingDecision)
        #expect(item.availableDecisions(at: now) == [.allow, .deny])
        #expect(item.availableDecisions(at: now.addingTimeInterval(700)).isEmpty) // expired

        let first = try await center.decide(item, .deny, device: device, message: "Bitte nicht", at: now.addingTimeInterval(5))
        let refreshed = try #require(try await center.items(jobId: approval.jobId).first)
        #expect(refreshed.displayState(at: now.addingTimeInterval(6)) == .decisionSent(.deny))
        // A second tap does not send a second, different decision.
        #expect(try await center.decide(refreshed, .allow, device: device, at: now.addingTimeInterval(7)) == first)
        #expect(try await database.approvals.decisions(approvalId: approval.id) == [first])

        var answered = approval
        answered.recordAnswer(first, at: now.addingTimeInterval(8))
        try await database.approvals.save(answered, at: now.addingTimeInterval(8))
        let final = try #require(try await center.items(jobId: approval.jobId).first)
        #expect(final.displayState(at: now.addingTimeInterval(9)) == .answered(.deny))
        #expect(try await center.openItems().isEmpty)
    }

    // MARK: Drafts and settings migration

    @Test func legacyDraftVersionsAreImportedOnce() async throws {
        let database = try AppDatabase.inMemory()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-drafts-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("imported"))
        }
        let item = UUID()
        let legacyId = UUID()
        // `JSONEncoder` writes `[UUID: …]` dictionaries as [key, value, …] arrays (format of earlier builds).
        let json = """
        ["\(item.uuidString)",[{"id":"\(legacyId.uuidString)","version":1,"createdAt":800000000,"source":"conversation","mode":"kurz",
        "provider":"anthropic","model":"claude-sonnet-5","drafts":[{"type":"bug","title":"Absturz","goal":"","context":"",
        "acceptanceCriteria":[],"technicalNotes":[],"testCases":[],"priority":"critical","dependencies":[],"openQuestions":[]}],
        "inputTokens":12,"outputTokens":34,"adoptedDraftIndexes":[0]}]]
        """
        try Data(json.utf8).write(to: url)
        let store = DraftVersionStore(repository: database.draftVersions, legacyFileURL: url)
        #expect(try await store.importLegacyVersions(at: now) == 1)
        #expect(try await store.importLegacyVersions(at: now) == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let versions = try await store.versions(for: WorkItemID(item))
        let version = try #require(versions.first)
        #expect(version.id == DraftVersionID(legacyId) && version.source == .ai && version.channel == .conversation)
        #expect(version.drafts.first?.title == "Absturz" && version.drafts.first?.priority == .critical)
        #expect(version.contents.first?.priority == .urgent && version.adoptedDraftIndexes == [0] && version.isAccepted)
        #expect(version.usage == TokenUsage(inputTokens: 12, outputTokens: 34) && version.draftMode == .kurz)

        // Original and transcript are versioned separately (H3), without duplicates.
        #expect(try await store.recordText("Notiz", source: .original, for: WorkItemID(item), at: now) != nil)
        #expect(try await store.recordText("Notiz", source: .original, for: WorkItemID(item), at: now) == nil)
        #expect(try await store.versions(for: WorkItemID(item)).map(\.source) == [.ai, .original])
    }

    @Test func legacyDefaultAgentMovesToSyncedSettings() async throws {
        let database = try AppDatabase.inMemory()
        let editor = GlobalDefaultsEditor(repository: database.globalSettings)
        var local = AppSettings(defaultAgent: .claudeCode)
        let first = try await editor.importLegacyDefaultAgent(from: &local, at: now)
        #expect(first)
        #expect(local.defaultAgent == nil)
        #expect(try await editor.load().defaultAgentId == .claudeCode)
        // A synced choice wins over another device's legacy value.
        var other = AppSettings(defaultAgent: .codex)
        let moved = try await editor.importLegacyDefaultAgent(from: &other, at: now)
        #expect(!moved)
        let reloaded = try await editor.load()
        #expect(other.defaultAgent == nil && reloaded.defaultAgentId == .claudeCode)
        _ = try await editor.setDefaultAgent(nil, at: now)
        #expect(try await editor.load().defaultAgentId == nil)
    }

    // MARK: Archive and reclassification (H1)

    @Test func archivedItemsAreHiddenByDefaultAndTypeCanChangeBeforeNumbering() async throws {
        let (database, project, item) = try await Fixture.makeDatabase()
        let editor = TaskEditor(workItems: database.workItems)
        #expect(TaskEditor.canReclassify(item, hasActiveJob: false))
        let (reclassified, previous) = try await editor.reclassify(item, to: .bug, actor: actor, at: now)
        #expect(reclassified.type == .bug && previous == .feature)
        let archived = try await editor.archive(reclassified, actor: actor, at: now)
        let query = TaskQuery(workItems: database.workItems, jobs: database.jobs)
        #expect(try await query.run(TaskFilter(project: .project(project.id))).isEmpty)
        #expect(try await query.run(TaskFilter(project: .project(project.id), archive: .archivedOnly)).map(\.uuid) == [item.uuid])
        #expect(!TaskFilter().matches(archived) && TaskFilter(archive: .any).matches(archived))
        let restored = try await editor.unarchive(archived, actor: actor, at: now)
        #expect(try await query.run(TaskFilter(project: .project(project.id))).map(\.uuid) == [restored.uuid])
    }

    // MARK: Retry when quota available (J2/K2)

    @Test func quotaOptionCreatesQuotaScheduledJob() throws {
        let (project, _) = Fixture.project()
        let item = Fixture.item(projectId: project.id)
        let context = JobRequestContext(workItem: item, project: project, capabilities: [Fixture.codex()])
        let reset = now.addingTimeInterval(7200)
        let job = try JobRequestPlanner.makeJob(JobRequestInput(providerId: .codex, launchOption: .retryWhenQuotaAvailable(expectedReset: reset)),
                                                context: context, idempotencyKey: IdempotencyKey(), now: now)
        guard case let .retryAfterQuota(state) = job.schedule.kind else {
            Issue.record("expected quota schedule")
            return
        }
        #expect(state.isUserRequested && state.nextAttemptAt == reset && state.lastFailureAt == now)
        #expect(job.scheduledAt == reset)
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        #expect(ScheduleStatusText.status(for: job, hostLastSeen: nil, now: now, timeZone: vienna)
            == "Start bei verfügbarem Kontingent, frühestens 13:00 (erwarteter Reset laut Benutzer)")
    }
}
