#if DEBUG
import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurSecrets

// Nur Debug: Beispieldaten für SwiftUI-Vorschauen und Bildschirmfotos (wie #Preview). Sie werden in eine
// In-Memory-Datenbank geschrieben, nie in die Datenbank des Dienstes, und kontaktieren weder den Dienst noch
// SMAppService. Release-Builds enthalten diese Datei nicht.

/// Ersatztransport mit festen Antworten.
struct PreviewServiceClient: ServiceSending {
    let summary: ServiceStatusSummary
    let jobStatuses: [JobID: JobStatusInfo]
    let reviewDetails: [ReviewID: ReviewDetailsInfo]

    func send(_ request: ServiceRequest) async throws(ServiceClientError) -> ServiceResponse {
        switch request {
        case .health:
            return .health(ServiceHealth(serviceVersion: summary.serviceVersion, processIdentifier: 4711,
                                         startedAt: summary.startedAt, uptimeSeconds: Date.now.timeIntervalSince(summary.startedAt),
                                         runState: summary.runState))
        case .statusSummary:
            return .statusSummary(summary)
        case .rootFolders:
            return .result(.rootFolders(RootFolderState(
                folders: [.init(path: "/Users/beispiel/Developer", exists: true, addedAt: .now.addingTimeInterval(-86_400 * 20))],
                suggestion: nil)))
        case let .jobStatus(jobId):
            if let status = jobStatuses[jobId] { return .result(.jobStatus(status)) }
            return .failure("Vorschau: keine Jobdetails.")
        case let .reviewDetails(reviewId):
            if let details = reviewDetails[reviewId] { return .result(.reviewDetails(details)) }
            return .failure("Vorschau: keine Review-Details.")
        case .instructionProposals:
            return .result(.instructionProposals([]))
        case .serviceSettings:
            return .result(.serviceSettings(ServiceSettings()))
        default:
            return .failure("Vorschau: Befehle werden nicht ausgeführt.")
        }
    }
}

/// Ersatzanbieter für „Mit KI besprechen“ mit fester Antwort; keine Netzwerkanfrage, kein Schlüssel.
struct PreviewTextProvider: TextAIProvider {
    let providerID: SoftwareRegisseurAI.AIProviderID = .anthropic

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }

    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        let text = """
        {"reply":"Gern. Ich schlage vor, das Querformat ausdrücklich abzudecken und die Zeilenhöhe an die Dynamic-Type-Größe zu koppeln. Offen ist, ob 13-Zoll-Geräte eine dritte Spalte bekommen sollen.",
         "proposedDrafts":[{"type":"feature","title":"Senderliste auf dem iPad vergrößern (Hoch- und Querformat)",
         "goal":"Die Senderliste ist auf dem iPad ab 11 Zoll in beiden Ausrichtungen gut lesbar.",
         "context":"Rückmeldung aus dem Alltag: Zeilen und Logos sind auf großen Displays zu klein.",
         "acceptanceCriteria":["Zeilenhöhe mindestens 64 pt im Hoch- und Querformat","Logos in voller Auflösung","Zeilenhöhe wächst mit Dynamic Type"],
         "technicalNotes":["Layout über horizontalSizeClass steuern"],"testCases":["Snapshot-Test 11 und 13 Zoll, beide Ausrichtungen"],
         "priority":"high","dependencies":[],"openQuestions":["Dritte Spalte auf 13-Zoll-Geräten?"]}]}
        """
        return TextGenerationResult(provider: providerID, model: request.model, text: text, finishReason: .completed,
                                    usage: AIUsage(inputTokens: 1_840, outputTokens: 412))
    }
}

/// Ersatz für `SMAppService`: registriert nie, meldet ein festes Ergebnis.
@MainActor
final class PreviewRegistrar: BackgroundServiceRegistering {
    var result: BackgroundServiceRegistrationResult
    private(set) var registerCalls = 0

    init(result: BackgroundServiceRegistrationResult = .requiresApproval) {
        self.result = result
    }

    func registerBackgroundService() -> BackgroundServiceRegistrationResult {
        registerCalls += 1
        return result
    }

    func backgroundServiceStatus() -> BackgroundServiceRegistrationResult { result }
    func openLoginItemsSettings() {}
}

@MainActor
enum PreviewFixtures {
    static let hostId = HostID(UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)

    /// Leere Umgebung für den Start im Bildschirmfoto-Modus (synchron, ohne Dienst).
    static func environment() -> AppEnvironment {
        // swiftlint:disable:next force_try
        let database = try! AppDatabase.inMemory()
        return makeEnvironment(database: database, client: PreviewServiceClient(summary: summary(), jobStatuses: [:], reviewDetails: [:]))
    }

    /// Umgebung mit Beispieldaten in einer In-Memory-Datenbank.
    static func seededEnvironment() async throws -> (AppEnvironment, SeedResult) {
        let database = try AppDatabase.inMemory()
        let seed = try await seed(database)
        let client = PreviewServiceClient(summary: summary(), jobStatuses: seed.jobStatuses, reviewDetails: seed.reviewDetails)
        let environment = makeEnvironment(database: database, client: client)
        await environment.library.reload()
        await environment.monitor.refresh()
        return (environment, seed)
    }

    private static func makeEnvironment(database: AppDatabase, client: PreviewServiceClient) -> AppEnvironment {
        let configuration = AppConfiguration(endpoint: .failure(.missingAppGroup), agentPlistName: nil, keychainAccessGroup: nil)
        let monitor = ServiceMonitor(client: client)
        let commands = CommandCenter(monitor: monitor)
        let flags = InMemoryOnboardingFlags(completed: true)
        let onboarding = BackgroundServiceOnboarding(registrar: PreviewRegistrar(), flags: flags)
        return AppEnvironment(
            configuration: configuration, monitor: monitor, commands: commands, library: LibraryStore(database: database),
            navigation: NavigationModel(), loginAgent: LoginAgentController(configuration: configuration),
            keys: ProviderKeyStore(accessGroup: nil, store: InMemoryKeychainStore()),
            // Bildschirmfotos: Einrichtung gilt als erledigt; registriert wird nie.
            onboarding: onboarding,
            setup: SetupAssistant(service: onboarding, progress: flags)
        )
    }

    struct SeedResult {
        var runningJob: JobID
        var reviewId: ReviewID
        var jobStatuses: [JobID: JobStatusInfo]
        var reviewDetails: [ReviewID: ReviewDetailsInfo]
    }

    static func summary(now: Date = .now) -> ServiceStatusSummary {
        let tonight = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3_600)
        return ServiceStatusSummary(
            generatedAt: now, serviceVersion: ServiceVersion(shortVersion: "1.0", build: "100"), runState: .running,
            macState: .ready, hostId: hostId, hostName: "Mac Studio", startedAt: now.addingTimeInterval(-3 * 3_600),
            sync: SyncSummary(state: .idle, accountState: .available, lastSuccessfulFetch: now.addingTimeInterval(-90),
                              lastSuccessfulSend: now.addingTimeInterval(-60)),
            agents: [
                AgentProviderSummary(providerId: .codex, displayName: "Codex", installed: true, authenticated: true, ready: true,
                                     version: "1.4.0", checkedAt: now.addingTimeInterval(-600), diagnostic: nil, activeJobs: 1),
                AgentProviderSummary(providerId: .claudeCode, displayName: "Claude Code", installed: true, authenticated: true,
                                     ready: true, version: "2.1.0", checkedAt: now.addingTimeInterval(-600), diagnostic: nil, activeJobs: 1),
            ],
            queue: QueueSummary(waiting: 0, scheduled: 1, nextPlannedStart: tonight > now ? tonight : nil, waitingApproval: 1,
                                openApprovals: 1, failed: 1, reviewsPending: 1),
            workspace: WorkspaceSummary(rootFolders: ["/Users/beispiel/Developer"], projectsReady: 2, projectsUnavailable: 1,
                                        lastScanAt: now.addingTimeInterval(-900), gitHubAvailable: true),
            problems: []
        )
    }

    // MARK: Beispieldaten

    private static func seed(_ database: AppDatabase) async throws -> SeedResult {
        let now = Date.now
        let host = AgentHost(hostId: hostId, name: "Mac Studio", lastSeen: now, ready: true, serviceVersion: "1.0")
        try await database.capabilities.saveHost(host)
        _ = try await database.capabilities.replaceCapabilities(hostId: hostId, with: capabilities(now: now))
        try await database.preferences.save(AgentModelPreference(scope: .global, providerId: .codex,
                                                                 model: .model("vorschau-modell-gross"), effort: .high, updatedAt: now))

        let player = try await project("SAT>IP Player", path: "/Users/beispiel/Developer/satip-player", database: database, now: now)
        let regisseur = try await project("Software Regisseur", path: "/Users/beispiel/Developer/SoftwareRegisseur", database: database, now: now)
        _ = try await project("Altes Archiv", path: "/Users/beispiel/Developer/archiv", status: .unavailable, database: database, now: now)

        let actor = EventActor.host(hostId)
        func item(_ number: Int, _ type: WorkItemType, _ title: String, project: ProjectID?, status: WorkItemStatus = .open,
                  priority: Priority = .medium, labels: [String] = [], body: String = "") async throws -> WorkItem {
            let created = now.addingTimeInterval(-Double(number) * 7_200)
            let item = WorkItem(humanId: project == nil ? nil : try HumanID(type: type, number: number), projectId: project, type: type,
                                title: title, originalNote: title, structuredBody: body, status: status, priority: priority,
                                labels: labels, createdAt: created)
            try await database.workItems.insert(item, actor: actor, at: created)
            return item
        }

        let body = """
        ## Problem
        Auf dem iPad ist die Senderliste zu klein.

        ## Ziel
        - Größere Zeilen ab 11 Zoll
        - Logos in voller Auflösung

        ## Akzeptanzkriterien
        - [ ] Zeilenhöhe mindestens 64 pt
        - [x] VoiceOver liest Sendername und Programm
        """
        let running = try await item(1, .feature, "Senderliste auf dem iPad vergrößern", project: player.id, priority: .high,
                                     labels: ["ios", "ux"], body: body)
        let approval = try await item(2, .bug, "EPG lädt nach Senderwechsel nicht", project: player.id, priority: .urgent, labels: ["epg"])
        let review = try await item(3, .improvement, "Sync-Fehlermeldungen vereinheitlichen", project: regisseur.id)
        let scheduled = try await item(4, .todo, "Abnahmematrix A01–A42 aktualisieren", project: regisseur.id)
        let failed = try await item(5, .feature, "Aufnahmen planen", project: player.id, priority: .low)
        _ = try await item(6, .feature, "Kanban-Filter nach Label", project: regisseur.id, labels: ["mac"])
        _ = try await item(7, .bug, "Absturz beim Beenden im Hintergrund", project: player.id, status: .done)
        _ = try await item(8, .note, "Idee: Diktat direkt aus der Menüleiste", project: nil, status: .inbox)
        _ = try await item(9, .note, "Lizenzhinweise prüfen", project: nil, status: .inbox)

        func job(_ item: WorkItem, _ provider: ProviderID, model: String?, effort: EffortLevel, priority: Priority,
                 schedule: JobSchedule = JobSchedule(kind: .immediate), steps: [AgentJobState]) async throws -> AgentJob {
            let snapshot = ConfigurationSnapshot(
                providerId: provider, requestedModel: model.map { .model(ModelID(rawValue: $0)!) }, requestedEffort: effort,
                resolvedModel: model.map { .model(ModelID(rawValue: $0)!) } ?? .providerDefault, resolvedEffort: effort,
                profileSource: ProfileSources(model: model == nil ? .providerDefault : .job, effort: .job),
                capabilityRevision: 3, agentVersion: provider == .codex ? "1.4.0" : "2.1.0", createdAt: now)
            let job = AgentJob(idempotencyKey: IdempotencyKey(), projectId: item.projectId!, workItemId: item.uuid, hostId: hostId,
                               configSnapshot: snapshot, schedule: schedule, priority: priority, workItemStatusBeforeJob: item.status,
                               createdAt: now.addingTimeInterval(-1_800))
            _ = try await database.jobs.create(job, actor: actor)
            for step in steps {
                _ = try await database.jobs.transition(job.jobId, to: step, actor: actor)
            }
            return job
        }

        let runningJob = try await job(running, .codex, model: "vorschau-modell-gross", effort: .high, priority: .high,
                                       steps: [.admitted, .starting, .running])
        let approvalJob = try await job(approval, .claudeCode, model: nil, effort: .auto, priority: .urgent,
                                        steps: [.admitted, .starting, .running, .waitingApproval])
        let reviewJob = try await job(review, .claudeCode, model: "vorschau-modell-sonett", effort: .medium, priority: .medium,
                                      steps: [.admitted, .starting, .running, .finished])
        _ = try await database.workItems.applyHostStatus(review.uuid, to: .review, actor: actor)
        let tonight = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now
        let plannedDate = tonight > now ? tonight : now.addingTimeInterval(3_600)
        _ = try await job(scheduled, .codex, model: "vorschau-modell-schnell", effort: .low, priority: .medium,
                          schedule: JobSchedule(kind: .notBefore(plannedDate)), steps: [.scheduled])
        let failedJob = try await job(failed, .codex, model: "vorschau-modell-gross", effort: .xhigh, priority: .low,
                                      steps: [.admitted, .starting, .running, .failed])
        _ = try await database.jobs.update(failedJob.jobId, expectedRevision: (try await database.jobs.fetch(failedJob.jobId))!.revision,
                                           actor: actor) { $0.lastError = "Der Agent hat mit einem Kontingentfehler beendet; Wiederholung möglich." }

        try await database.approvals.save(PendingApproval(
            jobId: approvalJob.jobId, workItemId: approval.uuid, hostId: hostId, requestId: "req-1", kind: .commandExecution,
            summary: "Claude Code möchte die Tests des EPG-Moduls ausführen.", preview: "swift test --filter EPGTests",
            reason: "Prüfung der Korrektur", requestedAt: now.addingTimeInterval(-300)))

        var reviewRecord = Review(
            jobId: reviewJob.jobId, diffSummary: DiffSummary(filesChanged: 3, insertions: 48, deletions: 17),
            testResults: [TestResult(name: "SyncErrorTextTests", outcome: .passed), TestResult(name: "SyncSummaryTests", outcome: .passed),
                          TestResult(name: "UITests", outcome: .skipped, detail: "Simulator nicht verfügbar")],
            summary: "Fehlermeldungen der Synchronisierung nutzen jetzt einen gemeinsamen Katalog. Drei Texte wurden vereinheitlicht.",
            commits: [ReviewCommit(sha: "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345", subject: "Sync-Fehlertexte vereinheitlichen")],
            fileChanges: [
                ReviewFileChange(status: "M", path: "Packages/SoftwareRegisseurSync/Sources/SyncErrorText.swift", additions: 31, deletions: 12),
                ReviewFileChange(status: "M", path: "Apps/SoftwareRegisseur-iOS/Sources/Views/SyncStatusView.swift", additions: 9, deletions: 5),
                ReviewFileChange(status: "A", path: "Packages/SoftwareRegisseurSync/Tests/SyncErrorTextTests.swift", additions: 8, deletions: 0),
            ],
            headCommit: "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345")
        reviewRecord.decide(.pending, at: now)
        try await database.reviews.save(reviewRecord)

        try await database.adrs.insert(ADR(projectId: regisseur.id, decisionNumber: try ADRNumber(15), title: "Integrationsstrategie Squash",
                                           status: .proposed, date: now, context: "Agentenbranches enthalten viele Zwischencommits.",
                                           decision: "Standard ist **Squash-Merge** in den Default-Branch.", createdAt: now))

        let jobStatuses: [JobID: JobStatusInfo] = [
            runningJob.jobId: JobStatusInfo(
                job: JobInfo(jobId: runningJob.jobId, workItemId: running.uuid, providerId: .codex, state: .running, priority: .high, lastError: nil),
                scheduleText: "läuft seit 14 Minuten", plannedStart: nil, admissionBlock: nil, awaitingMissedRunDecision: false,
                nextQuotaAttempt: nil, isLive: true, orphanedProcess: false, processIdentifier: 51_234,
                worktreePath: "/Users/beispiel/Library/Group Containers/SoftwareRegisseur/Worktrees/FR-0001-a1b2c3d4",
                branch: "software-regisseur/FR-0001/\(runningJob.jobId.shortString)",
                repositoryPath: "/Users/beispiel/Developer/satip-player", openApprovals: []),
        ]
        let details: [ReviewID: ReviewDetailsInfo] = [
            reviewRecord.reviewId: ReviewDetailsInfo(
                reviewId: reviewRecord.reviewId, jobId: reviewJob.jobId, workItemId: review.uuid,
                repositoryPath: "/Users/beispiel/Developer/SoftwareRegisseur", defaultBranch: "main",
                branch: "software-regisseur/IMP-0003/\(reviewJob.jobId.shortString)",
                worktreePath: "/Users/beispiel/Library/Group Containers/SoftwareRegisseur/Worktrees/IMP-0003",
                baseCommit: "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b", headCommit: "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
                commits: reviewRecord.commits, files: reviewRecord.fileChanges, agentSummary: reviewRecord.summary,
                autoCommittedPaths: [], permissionDenials: [], capturedAt: now, integrationConflictFiles: nil,
                integrationProblem: nil, integratedCommit: nil, integratedAt: nil),
        ]
        return SeedResult(runningJob: runningJob.jobId, reviewId: reviewRecord.reviewId, jobStatuses: jobStatuses, reviewDetails: details)
    }

    private static func project(_ name: String, path: String, status: ProjectStatus = .ready, database: AppDatabase,
                                now: Date) async throws -> Project {
        let settings = GlobalSettings.defaults.makeProjectSettings(updatedAt: now)
        let project = Project(name: name, repositoryIdentity: RepositoryIdentity(rawValue: "repo-\(name)"), repositoryKind: .gitRepository,
                              remote: "git@github.com:beispiel/\(name.lowercased().replacingOccurrences(of: " ", with: "-")).git",
                              hostId: hostId, status: status, settingsId: settings.id, createdAt: now.addingTimeInterval(-86_400 * 30),
                              statusReason: status == .unavailable ? "Ordner nicht gefunden – bitte neu verknüpfen." : nil)
        try await database.projects.create(project, settings: settings)
        try await database.projects.saveLocation(RepositoryLocation(projectId: project.id, hostId: hostId, canonicalPath: path,
                                                                    scanState: status == .ready ? .scanned : .unreachable,
                                                                    lastScanAt: now.addingTimeInterval(-900)))
        return project
    }

    private static func capabilities(now: Date) -> [AgentCapability] {
        func model(_ provider: ProviderID, _ id: String, _ name: String, _ efforts: [EffortLevel], default effort: EffortLevel?,
                   availability: ModelAvailability = .available) -> AgentModelCapability {
            AgentModelCapability(providerId: provider, modelId: ModelID(rawValue: id)!, displayName: name, supportedEffortIds: efforts,
                                 defaultEffortId: effort, availability: availability, source: .documentedCLI, lastValidatedAt: now)
        }
        return [
            AgentCapability(
                providerId: .codex, displayName: "Codex", hostId: hostId, executablePath: "/opt/homebrew/bin/codex", version: "1.4.0",
                supportsRemote: false, supportsResume: true, supportsApprovals: true, supportsModelSelection: true,
                supportsEffortSelection: true,
                modelCatalog: [
                    model(.codex, "vorschau-modell-gross", "Vorschau Groß", [.low, .medium, .high, .xhigh], default: .medium),
                    model(.codex, "vorschau-modell-schnell", "Vorschau Schnell", [.low, .medium], default: .low),
                ],
                defaultModelId: ModelID(rawValue: "vorschau-modell-gross"), capabilitySource: .documentedCLI, capabilityRevision: 3,
                lastChecked: now.addingTimeInterval(-600)),
            AgentCapability(
                providerId: .claudeCode, displayName: "Claude Code", hostId: hostId, executablePath: "/usr/local/bin/claude",
                version: "2.1.0", supportsRemote: true, supportsResume: true, supportsApprovals: true, supportsModelSelection: true,
                supportsEffortSelection: true,
                modelCatalog: [
                    model(.claudeCode, "vorschau-modell-opus", "Vorschau Opus", [.low, .medium, .high, .max], default: .high),
                    model(.claudeCode, "vorschau-modell-sonett", "Vorschau Sonett", [.low, .medium, .high], default: .medium),
                    model(.claudeCode, "vorschau-modell-alt", "Vorschau Alt", [], default: nil, availability: .deprecated),
                ],
                capabilitySource: .documentedCLI, capabilityRevision: 3, lastChecked: now.addingTimeInterval(-600),
                sessionLinkFormat: "Claude-App"),
        ]
    }
}
#endif
