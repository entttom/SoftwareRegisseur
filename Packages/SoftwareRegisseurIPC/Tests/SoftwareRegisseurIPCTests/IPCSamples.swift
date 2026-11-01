import Foundation
import SoftwareRegisseurDomain
@testable import SoftwareRegisseurIPC

/// Beispielwerte für jeden Befehl und jedes Ergebnis (Codable-Rundreise, A01/A21).
enum IPCSamples {
    static let date = Date(timeIntervalSince1970: 1_793_383_200)
    static let project = ProjectID()
    static let job = JobID()
    static let review = ReviewID()
    static let item = WorkItemID()

    static let requests: [ServiceRequest] = [
        .ping, .health, .statusSummary, .pause, .resume, .stop, .serviceSettings,
        .updateServiceSettings(ServiceSettings(syncPollInterval: 90, preventIdleSleepWhileAgentsRun: true)),
        .syncNow,
        .resolveSyncConflict(conflictId: UUID(), choice: .merged(Data("{\"title\":\"x\"}".utf8))),
        .acknowledgeAccountChange(uploadAllLocalData: true),
        .recreateCloudZone,
        .refreshScanner, .rootFolders,
        .addRootFolder(path: "/Users/test/Developer"),
        .removeRootFolder(path: "/Users/test/Developer"),
        .relinkCandidates(projectId: project),
        .relinkProject(projectId: project, path: "/Users/test/Developer/neu", allowDifferentRepository: false),
        .reconcileProject(projectId: project),
        .submitProjectSetup(ProjectSetupCommand(kind: .linkProject, projectName: "App",
                                                target: .indexedFolder(path: "/Users/test/Developer/app"), createdAt: date)),
        .resolveFileConflict(conflictId: FileConflictID(), resolution: .keptDatabase),
        .instructionProposals(projectId: nil),
        .proposeInstructions(projectId: project, createClaudeFileIfMissing: false),
        .applyInstructionProposal(proposalId: UUID()),
        .rejectInstructionProposal(proposalId: UUID()),
        .previewFolderMigration(projectId: project, layout: FolderLayoutPaths(
            adrPath: "doc/adr", requestsRoot: "doc/req", openPath: "open", activePath: "doing", reviewPath: "review", donePath: "done")),
        .applyFolderMigration(planId: UUID()),
        .discardFolderMigration(planId: UUID()),
        .redetectAgents,
        .requestJob(JobRequestCommand(workItemId: item, providerId: .codex, model: .model("gpt-5.5-codex"), effort: .high,
                                      schedule: JobSchedule(kind: .notBefore(date)), priority: .urgent)),
        .jobStatus(jobId: job),
        .answerApproval(approvalId: PendingApprovalID(), decision: .deny, message: "Bitte nicht deployen"),
        .cancelJob(jobId: job), .pauseJob(jobId: job), .resumeJob(jobId: job),
        .retryJob(jobId: job, idempotencyKey: IdempotencyKey()),
        .reprioritizeJob(jobId: job, priority: .high),
        .replaceJobConfiguration(jobId: job, model: .providerDefault, effort: .auto),
        .resolveMissedRun(jobId: job, runNow: true),
        .setExpectedQuotaReset(jobId: job, at: date),
        .terminateOrphanedProcess(jobId: job),
        .removeWorktree(jobId: job),
        .reviewDetails(reviewId: review), .approveReview(reviewId: review), .requestChanges(reviewId: review),
        .rejectReview(reviewId: review), .integrateReview(reviewId: review),
        .markDone(workItemId: item),
        .gitHubAvailability,
        .setGitHubEnabled(projectId: project, enabled: true),
        .gitHubIssues(projectId: project, state: .open),
        .linkGitHubIssue(workItemId: item, issueNumber: 42),
        .importGitHubIssue(projectId: project, issueNumber: 7),
        .exportToGitHub(workItemId: item),
        .resolveGitHubDivergence(conflictId: FileConflictID(), acceptGitHub: false),
        .syncGitHub(projectId: nil),
        .requestMacAIElaboration(MacAIElaborationCommand(workItemId: item, providerId: "anthropic", modelId: "claude-x",
                                                         mode: .technischeDetails, selectedFiles: ["Sources/App.swift"])),
        .macAIElaborationStatus(requestId: AIRequestID()),
    ] + v3Requests + v4Requests

    static let conversation: AIConversation = {
        var conversation = AIConversation(itemId: item, provider: .anthropic, model: "claude-x", contextScope: .project(project),
                                          createdAt: date)
        conversation.append(AIMessage(role: .user, text: "Bitte Kopfzeile ergänzen", createdAt: date))
        conversation.append(AIMessage(role: .assistant, text: "Vorschlag anbei.", createdAt: date.addingTimeInterval(3)),
                            usage: TokenUsage(inputTokens: 120, outputTokens: 40))
        conversation.proposedDraftVersion = 4
        return conversation
    }()

    static let conversationDraftContent = DraftContent(
        classification: .feature, title: "CSV-Export mit Kopfzeile", goal: "Spaltennamen exportieren",
        acceptanceCriteria: ["Erste Zeile enthält Spaltennamen"], priority: .high, openQuestions: ["Trennzeichen?"])

    /// Befehle seit Protokoll 4.
    static let v4Requests: [ServiceRequest] = [
        .saveConversation(conversation),
        .saveConversation(AIConversation(itemId: item, provider: .openAI, model: "gpt-x",
                                         contextScope: .repositoryFiles(project, paths: ["Sources/App.swift"]), createdAt: date)),
        .appendConversationDraft(ConversationDraftCommand(
            workItemId: item, content: conversationDraftContent, providerId: "anthropic", modelId: "claude-x",
            conversationId: conversation.id, usage: TokenUsage(inputTokens: 120, outputTokens: 40), accept: true,
            expectedRevision: 3)),
        .appendConversationDraft(ConversationDraftCommand(
            workItemId: item, content: conversationDraftContent, providerId: "openai", modelId: "gpt-x", conversationId: nil,
            accept: false, expectedRevision: 0)),
        .fullApprovalPreview(approvalId: PendingApprovalID()),
        .answerApprovalOnHost(approvalId: PendingApprovalID(), decision: .allow, message: nil, fullTextConfirmed: true),
        .answerApprovalOnHost(approvalId: PendingApprovalID(), decision: .deny, message: "Zu riskant", fullTextConfirmed: false),
    ]

    /// Befehle seit Protokoll 3.
    static let v3Requests: [ServiceRequest] = [
        .createWorkItem(CreateWorkItemCommand(projectId: project, type: .feature, title: "CSV-Export", text: "Bitte als CSV",
                                              priority: .high, labels: ["export", "csv"])),
        .createWorkItem(CreateWorkItemCommand(title: "Spontane Idee")),
        .updateWorkItem(WorkItemEditCommand(workItemId: item, expectedRevision: 4, title: "Neu", structuredBody: "## Ziel\nx",
                                            priority: .low, labels: ["a"], dependencies: [WorkItemID()])),
        .changeWorkItemStatus(workItemId: item, expectedRevision: 2, status: .cancelled),
        .assignWorkItem(workItemId: item, expectedRevision: 1, projectId: project),
        .assignWorkItem(workItemId: item, expectedRevision: 1, projectId: nil),
        .setWorkItemArchived(workItemId: item, expectedRevision: 3, archived: true),
        .reclassifyWorkItem(workItemId: item, expectedRevision: 3, type: .bug),
        .duplicateWorkItem(workItemId: item, newWorkItemId: WorkItemID()),
        .deleteWorkItem(workItemId: item, expectedRevision: 1),
        .acceptDraftVersion(draftId: DraftVersionID(), contentIndex: 0, expectedRevision: 5),
        .acceptDraftVersion(draftId: DraftVersionID(), contentIndex: nil, expectedRevision: 5),
        .rejectDraftVersion(draftId: DraftVersionID()),
        .createADR(CreateADRCommand(projectId: project, title: "XPC statt Datei", context: "K", decision: "E", supersedes: [3])),
        .changeADRStatus(adrId: ADRID(), expectedRevision: 2, status: .superseded, supersededBy: 7),
        .changeADRStatus(adrId: ADRID(), expectedRevision: 1, status: .accepted, supersededBy: nil),
        .updateProjectSettings(ProjectSettingsCommand(
            projectId: project, expectedRevision: 2, defaultAgentId: .claudeCode,
            modelPreferences: [AgentModelChoice(providerId: .codex, model: .model("gpt-5.5-codex"), effort: .high)],
            integrationStrategy: .mergeCommit, allowParallel: true, maxParallelJobs: 2, projectWideLock: false,
            reviewPolicy: .testsAndManualReview, agentInstructionsPolicy: .proposeOnly)),
        .gitHubProjectState(projectId: project),
        .updateGlobalSettings(GlobalSettingsCommand(
            expectedRevision: 0, defaultAgentId: .codex,
            folderLayout: FolderLayoutPaths(adrPath: "docs/adr", requestsRoot: "docs/requests", openPath: "open",
                                            activePath: "in-progress", reviewPath: "review", donePath: "done"),
            allowParallel: false, projectWideLock: true, maxParallelJobs: nil, reviewPolicy: .manualReview,
            integrationStrategy: .squash, agentInstructionsPolicy: .managedBlock, proposeGitInitForNewFolders: true)),
        .setGlobalModelPreference(AgentModelChoice(providerId: .claudeCode, model: .providerDefault, effort: .max)),
        .setAgentExecutablePath(providerId: .codex, path: "/opt/homebrew/bin/codex"),
        .setAgentExecutablePath(providerId: .claudeCode, path: nil),
        .prepareLocalDeletion(.everythingLocal),
        .executeLocalDeletion(planId: UUID(), confirmationToken: "abc123"),
        .prepareCloudDeletion,
        .confirmCloudDeletion(planId: UUID(), confirmationToken: "def456"),
        .retryCloudDeletion,
    ]

    /// Zahl der Befehlsarten; ``kindIndex(_:)`` erzwingt beim Hinzufügen eines Befehls eine Ergänzung hier.
    static let requestKindCount = 84

    /// Exhaustiver Switch: ein neuer Befehl bricht den Test-Build, bis er hier und in `requests` steht.
    static func kindIndex(_ request: ServiceRequest) -> Int {
        switch request {
        case .ping: 0
        case .health: 1
        case .statusSummary: 2
        case .pause: 3
        case .resume: 4
        case .stop: 5
        case .serviceSettings: 6
        case .updateServiceSettings: 7
        case .syncNow: 8
        case .resolveSyncConflict: 9
        case .acknowledgeAccountChange: 10
        case .recreateCloudZone: 11
        case .refreshScanner: 12
        case .rootFolders: 13
        case .addRootFolder: 14
        case .removeRootFolder: 15
        case .relinkCandidates: 16
        case .relinkProject: 17
        case .reconcileProject: 18
        case .submitProjectSetup: 19
        case .resolveFileConflict: 20
        case .instructionProposals: 21
        case .proposeInstructions: 22
        case .applyInstructionProposal: 23
        case .rejectInstructionProposal: 24
        case .previewFolderMigration: 25
        case .applyFolderMigration: 26
        case .discardFolderMigration: 27
        case .redetectAgents: 28
        case .requestJob: 29
        case .jobStatus: 30
        case .answerApproval: 31
        case .cancelJob: 32
        case .pauseJob: 33
        case .resumeJob: 34
        case .retryJob: 35
        case .reprioritizeJob: 36
        case .replaceJobConfiguration: 37
        case .resolveMissedRun: 38
        case .setExpectedQuotaReset: 39
        case .terminateOrphanedProcess: 40
        case .removeWorktree: 41
        case .reviewDetails: 42
        case .approveReview: 43
        case .requestChanges: 44
        case .rejectReview: 45
        case .integrateReview: 46
        case .markDone: 47
        case .gitHubAvailability: 48
        case .setGitHubEnabled: 49
        case .gitHubIssues: 50
        case .linkGitHubIssue: 51
        case .importGitHubIssue: 52
        case .exportToGitHub: 53
        case .resolveGitHubDivergence: 54
        case .syncGitHub: 55
        case .requestMacAIElaboration: 56
        case .macAIElaborationStatus: 57
        case .createWorkItem: 58
        case .updateWorkItem: 59
        case .changeWorkItemStatus: 60
        case .assignWorkItem: 61
        case .setWorkItemArchived: 62
        case .reclassifyWorkItem: 63
        case .duplicateWorkItem: 64
        case .deleteWorkItem: 65
        case .acceptDraftVersion: 66
        case .rejectDraftVersion: 67
        case .createADR: 68
        case .changeADRStatus: 69
        case .updateProjectSettings: 70
        case .gitHubProjectState: 71
        case .updateGlobalSettings: 72
        case .setGlobalModelPreference: 73
        case .setAgentExecutablePath: 74
        case .prepareLocalDeletion: 75
        case .executeLocalDeletion: 76
        case .prepareCloudDeletion: 77
        case .confirmCloudDeletion: 78
        case .retryCloudDeletion: 79
        case .saveConversation: 80
        case .appendConversationDraft: 81
        case .fullApprovalPreview: 82
        case .answerApprovalOnHost: 83
        }
    }

    static let summary = ServiceStatusSummary(
        generatedAt: date, serviceVersion: ServiceVersion(shortVersion: "1.0.0", build: "42"), runState: .running,
        macState: .ready, hostId: HostID(), hostName: "Mac Studio", startedAt: date,
        sync: SyncSummary(state: .paused, accountState: .available, lastSuccessfulFetch: date, pendingChanges: 2,
                          attention: ["iCloud-Daten gelöscht"], cloudDataDeletion: .deleted),
        agents: [AgentProviderSummary(providerId: .codex, displayName: "OpenAI Codex", installed: true, authenticated: true,
                                      ready: true, version: "0.170.0", checkedAt: date, diagnostic: nil, activeJobs: 1)],
        queue: QueueSummary(waiting: 1, scheduled: 2, nextPlannedStart: date, blocked: 1, failed: 0, reviewsPending: 3,
                            admissionBlocks: [JobID(): "Maximal 2 parallele Läufe erreicht."]),
        workspace: WorkspaceSummary(rootFolders: ["/Users/test/Developer"], projectsReady: 4, lastScanAt: date),
        problems: ["Kein Stammordner bestätigt."]
    )

    static let results: [ServiceResult] = [
        .done("Erledigt"), .done(nil), .accepted("Läuft"),
        .serviceSettings(ServiceSettings()),
        .syncFinished(SyncRunInfo(outcome: .completed, applied: 3, sent: 1)),
        .scanFinished(ScanInfo(createdProjects: 1, updatedProjects: 0, movedProjects: 0, unavailableProjects: 0,
                               relinkCandidates: 0, indexedFolders: 9, issues: [], finishedAt: date)),
        .rootFolders(RootFolderState(folders: [.init(path: "/Users/test/Developer", exists: true, addedAt: date)],
                                     suggestion: "/Users/test/Developer")),
        .paths(["/a", "/b"]),
        .instructionProposals([InstructionProposalInfo(
            id: UUID(), projectId: project, projectName: "App",
            changes: [.init(path: "AGENTS.md", isNewFile: false, proposedText: "x", unifiedDiff: "@@ -1 +1 @@")],
            warnings: ["AGENTS.md hat nicht eingecheckte Änderungen."], createdAt: date)]),
        .folderMigrationPlan(FolderMigrationPlanInfo(
            planId: UUID(), projectId: project,
            layout: FolderLayoutPaths(adrPath: "a", requestsRoot: "r", openPath: "o", activePath: "p", reviewPath: "v", donePath: "d"),
            moves: [.init(kind: "request", source: "docs/requests/open/x.md", destination: "r/o/x.md")],
            collisions: [], instructionsDiff: nil, isApplicable: true)),
        .agents(summary.agents),
        .job(JobInfo(jobId: job, workItemId: item, providerId: .claudeCode, state: .scheduled, priority: .low, lastError: nil,
                     wasCreated: true)),
        .jobStatus(JobStatusInfo(
            job: JobInfo(jobId: job, workItemId: item, providerId: .codex, state: .waitingQuota, priority: .medium, lastError: "Limit"),
            scheduleText: "Wartet auf Kontingent", plannedStart: date, admissionBlock: nil, awaitingMissedRunDecision: false,
            nextQuotaAttempt: date, isLive: false, orphanedProcess: false, processIdentifier: nil, worktreePath: "/w",
            branch: "software-regisseur/x", repositoryPath: "/r", openApprovals: [PendingApprovalID()])),
        .reviewDetails(ReviewDetailsInfo(
            reviewId: review, jobId: job, workItemId: item, repositoryPath: "/r", defaultBranch: "main", branch: "b",
            worktreePath: "/w", baseCommit: "abc", headCommit: "def", commits: [ReviewCommit(sha: "def", subject: "Agent")],
            files: [ReviewFileChange(status: "M", path: "a.swift", additions: 1, deletions: 0)], agentSummary: "Fertig",
            autoCommittedPaths: [], permissionDenials: [], capturedAt: date, integrationConflictFiles: nil,
            integrationProblem: nil, integratedCommit: nil, integratedAt: nil, excludedSecretPaths: [".env.local"])),
        .integration(IntegrationInfo(strategy: "squash", commitSHA: "123", previousDefaultBranchCommit: "abc", integratedCommits: ["def"])),
        .gitHubAvailability(GitHubAvailabilityInfo(isAvailable: false, detail: "gh ist nicht installiert.")),
        .gitHubIssues([GitHubIssueInfo(number: 1, title: "Bug", state: "OPEN", url: "https://github.com/o/r/issues/1",
                                       updatedAt: "2026-10-30T10:00:00Z", labels: ["bug"], linkedWorkItemId: item)]),
        .workItem(item),
        .macAIElaboration(MacAIElaborationInfo(
            requestId: AIRequestID(), workItemId: item, state: .failed, providerId: "openai", modelId: "gpt",
            included: [.init(kind: "repositoryTree", title: "Struktur", path: nil, characterCount: 10, redactionCount: 0, truncated: false)],
            excluded: [.init(title: ".env", path: ".env", reason: "Geheimnis")], estimatedTokens: 3,
            errorMessage: "Kein API-Schlüssel hinterlegt.", updatedAt: date)),
        .serviceSettings(ServiceSettings(agentExecutablePaths: ["codex": "/opt/homebrew/bin/codex"])),
        .workItemSaved(WorkItemSavedInfo(workItemId: item, revision: 3, status: .open, type: .feature, projectId: project,
                                         isArchived: false, wasCreated: true, message: "Aufgabe angelegt.")),
        .adrCreated(ADRCreatedInfo(projectId: project, number: 25, relativePath: "docs/adr/0025-xpc.md", adrId: ADRID())),
        .gitHubProjectState(GitHubProjectStateInfo(projectId: project, enabled: true, repository: "o/r", detail: nil)),
        .localDeletionPreview(LocalDeletionPreviewInfo(
            planId: UUID(), kind: .localDatabase, confirmationToken: "t", title: "Lokale Datenbank löschen", summary: "2 Einträge",
            items: [.init(label: "Datenbankdatei „SoftwareRegisseur.sqlite“", byteCount: 4096, affectsOtherDevices: false)],
            retained: ["iCloud-Daten bleiben erhalten."], consequences: ["Stammordner werden zurückgesetzt."], totalBytes: 4096,
            expiresAt: date)),
        .localDeletionReport(LocalDeletionReportInfo(deleted: ["a"], alreadyMissing: [], failed: ["b: gesperrt"], databaseReopened: true)),
        .cloudDeletionPreview(CloudDeletionPreviewInfo(planId: UUID(), confirmationToken: "c", title: "iCloud-Daten löschen",
                                                       consequences: ["Alles weg"], expiresAt: date)),
        .conversationSaved(ConversationSavedInfo(conversationId: conversation.id, workItemId: item, messageCount: 2,
                                                 usage: TokenUsage(inputTokens: 120, outputTokens: 40), wasCreated: true)),
        .conversationDraft(ConversationDraftInfo(
            draftId: DraftVersionID(), workItemId: item, version: 4, accepted: true, wasCreated: true,
            workItem: WorkItemSavedInfo(workItemId: item, revision: 4, status: .open, type: .feature, projectId: project,
                                        isArchived: false, message: "Entwurf übernommen."),
            message: "Entwurf Version 4 übernommen.")),
        .conversationDraft(ConversationDraftInfo(draftId: DraftVersionID(), workItemId: item, version: 5, accepted: false,
                                                 wasCreated: false, workItem: nil, message: "Entwurf gespeichert.")),
        .approvalPreview(ApprovalPreviewInfo(approvalId: PendingApprovalID(), fullText: String(repeating: "x", count: 2500),
                                             shownLength: 2000, fullLength: 2500, allowRequiresHostReview: true)),
        .approvalPreview(ApprovalPreviewInfo(approvalId: PendingApprovalID(), fullText: nil, shownLength: 2000, fullLength: 2500,
                                             allowRequiresHostReview: true, detail: "Keine laufende Sitzung.")),
    ]
}
