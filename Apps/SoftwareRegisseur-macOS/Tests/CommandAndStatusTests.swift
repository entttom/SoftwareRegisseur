import Foundation
import Testing
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

@Suite("Befehlsrückmeldungen und Statusdarstellung")
struct CommandAndStatusTests {
    @Test func failuresAndUnavailableFeaturesAreNeverSilentSuccesses() {
        #expect(CommandOutcome.from(.failure("Nein."), title: "X").feedback == .failure("Nein."))
        let unavailable = CommandOutcome.from(.notAvailable(.cloudSync), title: "Jetzt synchronisieren")
        #expect(unavailable.feedback.isFailure)
        #expect(unavailable.feedback.message.contains("iCloud-Synchronisierung"))
        let mismatch = CommandOutcome.from(ServiceResponse.protocolMismatch(serviceVersion: 3, clientVersion: 2), title: "X")
        #expect(mismatch.feedback.isFailure)
        #expect(!CommandOutcome.from(.failure("x"), title: "X").succeeded)
    }

    @Test func resultsKeepTypedPayloadAndGermanMessage() {
        let done = CommandOutcome.from(.result(.done("Worktree entfernt.")), title: "Worktree entfernen")
        #expect(done.feedback == .success("Worktree entfernt."))
        let silent = CommandOutcome.from(.result(.done(nil)), title: "Abgleichen")
        #expect(silent.feedback.message == "„Abgleichen“ abgeschlossen.")

        let info = JobInfo(jobId: JobID(), workItemId: WorkItemID(), providerId: .codex, state: .scheduled, priority: .high,
                           lastError: nil, wasCreated: true)
        let job = CommandOutcome.from(.result(.job(info)), title: "Job anlegen")
        #expect(job.result == .job(info))
        #expect(job.feedback.message.contains("angelegt"))

        let scan = ScanInfo(createdProjects: 2, updatedProjects: 1, movedProjects: 0, unavailableProjects: 1, relinkCandidates: 0,
                            indexedFolders: 40, issues: ["Ordner X übersprungen."], finishedAt: Fixture.now)
        let scanOutcome = CommandOutcome.from(.result(.scanFinished(scan)), title: "Scanner")
        #expect(scanOutcome.feedback.message.contains("40 Ordner"))
        #expect(scanOutcome.feedback.message.contains("Ordner X übersprungen."))
    }

    @Test func syncOutcomesMapToSuccessOrFailure() {
        #expect(!CommandOutcome.syncFeedback(SyncRunInfo(outcome: .completed, applied: 3, sent: 1)).isFailure)
        #expect(CommandOutcome.syncFeedback(SyncRunInfo(outcome: .failed, message: "Netz weg")).message == "Netz weg")
        #expect(CommandOutcome.syncFeedback(SyncRunInfo(outcome: .paused)).isFailure)
        if case .accepted = CommandOutcome.syncFeedback(SyncRunInfo(outcome: .deferred)) {} else {
            Issue.record("deferred muss als angenommen gelten")
        }
    }

    @Test func clientErrorsExplainWhatToDo() {
        let text = CommandOutcome.from(ServiceClientError.connectionFailed("x"), title: "Pausieren").feedback.message
        #expect(text.contains("nicht erreichbar"))
        #expect(CommandOutcome.from(ServiceClientError.timedOut, title: "Scan").feedback.isFailure)
    }

    @Test func macStateIsNeverGreenWithoutRealAnswer() {
        #expect(MacStatePresentation.make(reachable: nil, summary: nil).level == .unknown)
        let offline = MacStatePresentation.make(reachable: false, summary: nil)
        #expect(offline.title == "Mac offline")
        #expect(offline.level == .error)
        #expect(MacStatePresentation.make(reachable: true, summary: nil).level == .unknown)
        #expect(MacStatePresentation.make(reachable: true, summary: summary(macState: .ready)).level == .ok)
        #expect(MacStatePresentation.make(reachable: true, summary: summary(macState: .paused)).title == "Mac pausiert")
        let degraded = MacStatePresentation.make(reachable: true, summary: summary(macState: .degraded, problems: ["Kein Stammordner."]))
        #expect(degraded.level == .warning)
        #expect(degraded.detail == "Kein Stammordner.")
    }

    @Test func syncPresentationReportsUnavailableConflictsAndErrors() {
        let unavailable = SyncPresentation.make(SyncSummary(state: .unavailable, unavailableReason: "Unsignierter Build"), now: Fixture.now)
        #expect(unavailable.level == .warning)
        #expect(unavailable.detail == "Unsignierter Build")
        let conflicts = SyncPresentation.make(SyncSummary(state: .idle, lastSuccessfulFetch: Fixture.now, openConflicts: 2), now: Fixture.now)
        #expect(conflicts.level == .warning)
        let never = SyncPresentation.make(SyncSummary(state: .idle), now: Fixture.now)
        #expect(never.detail == "Noch nie erfolgreich synchronisiert")
        #expect(SyncPresentation.make(SyncSummary(state: .failed, lastError: "Fehler"), now: Fixture.now).level == .error)
    }

    @Test func agentPresentationRequiresProvenReadiness() {
        func agent(installed: Bool, authenticated: Bool, ready: Bool, active: Int = 0) -> AgentPresentation {
            AgentPresentation.make(AgentProviderSummary(providerId: .codex, displayName: "", installed: installed,
                                                        authenticated: authenticated, ready: ready, version: nil, checkedAt: nil,
                                                        diagnostic: nil, activeJobs: active))
        }
        #expect(agent(installed: false, authenticated: false, ready: false).stateText == "nicht installiert")
        #expect(agent(installed: true, authenticated: false, ready: false).stateText == "nicht angemeldet")
        #expect(agent(installed: true, authenticated: true, ready: false).level == .warning)
        #expect(agent(installed: true, authenticated: true, ready: true).level == .ok)
        #expect(agent(installed: true, authenticated: true, ready: true, active: 2).stateText == "2 aktiv")
        #expect(agent(installed: true, authenticated: true, ready: true).name == "Codex")
    }

    @Test func queuePresentationOnlyShowsProblemsWhenPresent() {
        let calm = QueuePresentation.make(QueueSummary(waiting: 1, scheduled: 2), now: Fixture.now)
        #expect(calm.waitingText == "1 wartend · 2 geplant")
        #expect(calm.problemsText == nil)
        #expect(calm.nextStartText == nil)
        let busy = QueuePresentation.make(QueueSummary(nextPlannedStart: Fixture.now.addingTimeInterval(3_600), openApprovals: 1,
                                                       blocked: 1, failed: 2, reviewsPending: 3), now: Fixture.now)
        #expect(busy.problemsText == "1 blockiert · 2 fehlgeschlagen")
        #expect(busy.reviewsText == "3 zur Review")
        #expect(busy.approvalsText == "1 offene Freigaben")
        #expect(busy.nextStartText != nil)
    }

    private func summary(macState: ServiceStatusSummary.MacState, problems: [String] = []) -> ServiceStatusSummary {
        ServiceStatusSummary(generatedAt: Fixture.now, serviceVersion: ServiceVersion(shortVersion: "1", build: "1"), runState: .running,
                             macState: macState, hostId: Fixture.hostId, hostName: "Mac", startedAt: Fixture.now,
                             sync: SyncSummary(state: .idle), agents: [], queue: QueueSummary(), workspace: WorkspaceSummary(),
                             problems: problems)
    }
}
