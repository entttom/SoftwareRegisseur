import Foundation
import Testing
@testable import SoftwareRegisseurDomain

@Suite("Cross-package contracts: approvals, reviews, drafts, settings, schedules")
struct CrossPackageContractTests {
    // MARK: Event kinds (Codable compatibility)

    @Test func existingEventKindsKeepTheirStoredValues() throws {
        let stored = ["created", "edited", "statusChanged", "humanIDAssigned", "jobRequested", "jobStateChanged",
                      "configurationReplaced", "lockAcquired", "lockReleased", "reviewDecided", "integrated",
                      "externalChangeDetected", "conflictDetected", "comment"]
        for raw in stored {
            let decoded = try JSONDecoder().decode(TaskEventKind.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
        }
        for kind in [TaskEventKind.approvalRequested, .approvalAnswered, .approvalExpired, .quotaWait, .missedRun,
                     .jobRetried, .typeChanged, .archived, .unarchived] {
            #expect(try roundTrip(kind) == kind)
        }
    }

    // MARK: Approvals

    @Test func approvalAcceptsOnlyExplicitAllowedDecisionsWhileOpen() {
        let device = DeviceID()
        var approval = PendingApproval(
            jobId: JobID(), workItemId: WorkItemID(), hostId: HostID(), requestId: "r1", kind: .commandExecution,
            summary: "Befehl ausführen: swift test", preview: "swift test", allowedDecisions: [.allow, .deny],
            requestedAt: referenceDate, expiresAt: referenceDate.addingTimeInterval(600))
        let late = ApprovalDecision(for: approval, decision: .allow, decidedBy: device, at: referenceDate.addingTimeInterval(700))
        let early = ApprovalDecision(for: approval, decision: .deny, decidedBy: device, at: referenceDate.addingTimeInterval(10))
        let second = ApprovalDecision(for: approval, decision: .allow, decidedBy: device, at: referenceDate.addingTimeInterval(20))
        let foreign = ApprovalDecision(approvalId: PendingApprovalID(), jobId: approval.jobId, decision: .allow,
                                       decidedBy: device, decidedAt: referenceDate)
        #expect(!approval.accepts(late, at: referenceDate.addingTimeInterval(700)))
        #expect(!approval.accepts(foreign, at: referenceDate))
        #expect(ApprovalDecision.firstApplicable([second, late, early], for: approval, at: referenceDate.addingTimeInterval(30)) == early)

        approval.recordAnswer(early, at: referenceDate.addingTimeInterval(30))
        #expect(approval.state == .answered && approval.decision == .deny && approval.decisionId == early.id)
        #expect(approval.revision == 2)
        // Idempotent: a second answer or expiry does not change an answered approval.
        approval.recordAnswer(second, at: referenceDate.addingTimeInterval(40))
        approval.expire(at: referenceDate.addingTimeInterval(50))
        #expect(approval.decisionId == early.id && approval.state == .answered && approval.revision == 2)
        #expect(!approval.accepts(second, at: referenceDate.addingTimeInterval(40)))
    }

    @Test func approvalWithoutDenyRejectsDeny() throws {
        var approval = PendingApproval(jobId: JobID(), workItemId: WorkItemID(), hostId: HostID(), requestId: "x",
                                       kind: .toolUse, toolName: "Write", summary: "Werkzeug Write verwenden",
                                       allowedDecisions: [.allow], requestedAt: referenceDate)
        let deny = ApprovalDecision(for: approval, decision: .deny, decidedBy: DeviceID(), at: referenceDate)
        #expect(!approval.accepts(deny, at: referenceDate))
        approval.markTimedOut(at: referenceDate.addingTimeInterval(1))
        #expect(approval.isOpen && approval.timedOutAt != nil)
        approval.withdraw(at: referenceDate.addingTimeInterval(2))
        #expect(approval.state == .withdrawn)
        #expect(try roundTrip(approval) == approval)
    }

    // MARK: Review content

    @Test func reviewContentIsAdditiveAndDecodesOlderPayloads() throws {
        let old = #"{"reviewId":"7B8F3D2C-1111-4222-8333-944455556666","jobId":"6F1C2E3A-1111-4222-8333-944455556666","diffSummary":{"filesChanged":1,"insertions":2,"deletions":0,"files":["a.swift"]},"testResults":[{"name":"swift test","outcome":"failed"}],"decision":"pending"}"#
        let decoded = try JSONDecoder().decode(Review.self, from: Data(old.utf8))
        #expect(decoded.commits.isEmpty && decoded.fileChanges.isEmpty && decoded.summary == nil && decoded.notes.isEmpty)
        #expect(decoded.effectiveTestSummary == TestRunSummary(failed: 1))

        var review = Review(jobId: JobID(), diffSummary: DiffSummary(filesChanged: 1, insertions: 3, deletions: 1),
                            testResults: [TestResult(name: "swift test", outcome: .passed)], summary: "Fertig",
                            commits: [ReviewCommit(sha: "abc", subject: "Export")],
                            fileChanges: [ReviewFileChange(status: "M", path: "a.swift", additions: 3, deletions: 1)])
        review.conflict = ReviewConflictInfo(files: ["a.swift"], message: "Konflikt", detectedAt: referenceDate)
        #expect(try roundTrip(review) == review)
        review.decide(.approved, at: referenceDate)
        try review.recordIntegration(commit: "def", strategy: .squash)
        #expect(review.conflict == nil)
    }

    // MARK: Work item archive / reclassification

    @Test func archivingIsNotAStatusAndReclassificationBumpsRevision() throws {
        var item = WorkItem(projectId: ProjectID(), type: .todo, title: "Idee", status: .open, createdAt: referenceDate)
        item.archive(at: referenceDate.addingTimeInterval(1))
        #expect(item.isArchived && item.status == .open && item.revision == 2)
        item.archive(at: referenceDate.addingTimeInterval(2))
        #expect(item.revision == 2)
        item.unarchive(at: referenceDate.addingTimeInterval(3))
        #expect(!item.isArchived && item.revision == 3)

        try item.reclassify(to: .feature, hasActiveJob: false, at: referenceDate.addingTimeInterval(4))
        #expect(item.type == .feature && item.revision == 4)
        #expect(throws: WorkItemError.typeChangeDuringActiveJob) {
            try item.reclassify(to: .bug, hasActiveJob: true, at: referenceDate)
        }
        let id = try HumanID(type: .feature, number: 1)
        try item.assignHumanID(id, at: referenceDate.addingTimeInterval(5))
        #expect(throws: WorkItemError.typeChangeAfterHumanID(id)) {
            try item.reclassify(to: .bug, hasActiveJob: false, at: referenceDate)
        }
        // Older payloads without `archivedAt` decode as not archived.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json.removeValue(forKey: "archivedAt")
        let decoded = try JSONDecoder().decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.isArchived && decoded.type == .feature)
    }

    // MARK: Retry link and quota schedule

    @Test func retryLinkAndUserRequestedQuotaSchedule() throws {
        let original = Fixtures.job(snapshot: try Fixtures.resolvedSnapshot())
        let snapshot = original.configSnapshot
        let reset = referenceDate.addingTimeInterval(3600)
        let retry = AgentJob(idempotencyKey: IdempotencyKey(), projectId: original.projectId, workItemId: original.workItemId,
                             configSnapshot: snapshot,
                             schedule: JobSchedule(kind: .whenQuotaAvailable(expectedReset: reset, requestedAt: referenceDate)),
                             workItemStatusBeforeJob: .open, retryOfJobId: original.jobId, createdAt: referenceDate)
        #expect(retry.isRetry && retry.retryOfJobId == original.jobId)
        #expect(retry.scheduledAt == reset)
        #expect(try retry.schedule.evaluate(at: referenceDate) == .waitUntil(reset))
        #expect(try retry.schedule.evaluate(at: reset) == .runNow)
        let decoded = try roundTrip(retry)
        #expect(decoded == retry)
        guard case let .retryAfterQuota(state) = decoded.schedule.kind else {
            Issue.record("expected quota schedule")
            return
        }
        #expect(state.isUserRequested && state.basis == .userExpectedReset)
        // Older job payloads have no retry link.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "retryOfJobId")
        #expect(try JSONDecoder().decode(AgentJob.self, from: JSONSerialization.data(withJSONObject: json)).retryOfJobId == nil)
    }

    // MARK: Schedule status texts (K3)

    @Test func scheduleStatusTexts() throws {
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        let now = utc("2026-10-30T21:10:00Z")
        #expect(ScheduleStatusText.planned(utc("2026-10-30T21:00:00Z"), hostLastSeen: utc("2026-10-30T20:30:00Z"), now: now, timeZone: vienna)
            == "für 22:00 geplant, Mac zuletzt online 21:30")
        #expect(ScheduleStatusText.planned(utc("2026-10-31T06:00:00Z"), hostLastSeen: nil, now: now, timeZone: vienna)
            == "für 31.10. 07:00 geplant")
        let state = QuotaRetryState(attempt: 2, nextAttemptAt: utc("2026-10-30T22:00:00Z"), lastFailureAt: now, basis: .backoff)
        #expect(ScheduleStatusText.quota(state, now: now, timeZone: vienna)
            == "wartet auf Kontingent – nächster Versuch 23:00 (begrenzter Backoff, Versuch 2)")
        #expect(ScheduleStatusText.missed(scheduledFor: utc("2026-10-30T21:00:00Z"), hostLastSeen: utc("2026-10-30T20:30:00Z"),
                                          policy: .ask, now: now, timeZone: vienna)
            == "für 22:00 geplant, Mac zuletzt online 21:30 – Termin verpasst, Nachholregel: nachfragen")

        var job = Fixtures.job(snapshot: try Fixtures.resolvedSnapshot())
        job.schedule = JobSchedule(kind: .at(try ZonedLocalDateTime(year: 2026, month: 10, day: 31, hour: 22, minute: 0, timeZoneIdentifier: "Europe/Vienna")))
        #expect(ScheduleStatusText.status(for: job, hostLastSeen: utc("2026-10-30T20:30:00Z"), now: now, timeZone: .gmt)
            == "für 31.10. 22:00 geplant, Mac zuletzt online 21:30")
        job.schedule = JobSchedule(kind: .immediate)
        #expect(ScheduleStatusText.status(for: job, hostLastSeen: utc("2026-10-30T20:30:00Z"), now: now, timeZone: vienna)
            == "wartet auf den Mac, zuletzt online 21:30")
    }

    // MARK: Draft versions

    @Test func draftVersionsAcceptExplicitly() throws {
        let item = WorkItemID()
        let original = DraftVersion(workItemId: item, version: 1, source: .original, text: "Export als CSV", createdAt: referenceDate)
        var ai = DraftVersion(
            workItemId: item, version: DraftVersion.nextVersion(after: [original]), source: .ai, channel: .composer,
            mode: "detailed", providerId: .anthropic, modelId: "claude-sonnet-5",
            contents: [DraftContent(classification: .feature, title: "CSV-Export"), DraftContent(classification: .adr, title: "Format")],
            usage: TokenUsage(inputTokens: 10, outputTokens: 20), createdAt: referenceDate)
        #expect(ai.version == 2 && !ai.isAccepted)
        ai.accept(contentIndexes: [0, 7], at: referenceDate.addingTimeInterval(5))
        #expect(ai.acceptedContentIndexes == [0] && ai.acceptedAt == referenceDate.addingTimeInterval(5) && ai.revision == 2)
        ai.accept(contentIndexes: [0], at: referenceDate.addingTimeInterval(9))
        #expect(ai.revision == 2)
        #expect(DraftClassification.adr.workItemType == nil && DraftClassification(.bug) == .bug)
        #expect(try roundTrip(ai) == ai)
    }

    // MARK: Global settings and setup validation

    @Test func globalSettingsPrefillProjectSettings() {
        var settings = GlobalSettings(defaultAgentId: .claudeCode, updatedAt: referenceDate)
        settings.folderLayout.adrPath = "architecture/decisions"
        settings.workspace.integrationStrategy = .mergeCommit
        let project = settings.makeProjectSettings(updatedAt: referenceDate)
        #expect(project.adrPath == "architecture/decisions" && project.integrationStrategy == .mergeCommit)
        #expect(settings.preferredAgent(project: project) == .claudeCode)
        var withDefault = project
        withDefault.defaultAgentId = .codex
        #expect(settings.preferredAgent(project: withDefault) == .codex)
        #expect(!GlobalSettings.defaults.isStored && settings.isStored)
        #expect(!FolderLayoutDefaults(adrPath: "../out").isValid && FolderLayoutDefaults.standard.isValid)
    }

    @Test func newSubfolderNamesAreValidated() throws {
        for name in ["Neues Projekt", "app-2026", "Übersicht"] {
            try ProjectSetupCommand.validateFolderName(name)
        }
        for name in ["", " ", ".", "..", ".hidden", "a/b", "a:b", "x\u{0007}", " lead", String(repeating: "a", count: 256)] {
            #expect(throws: ProjectSetupFailure.self) { try ProjectSetupCommand.validateFolderName(name) }
        }
    }

    @Test func fileConflictResolutionCanBeRequestedRemotely() {
        let device = DeviceID()
        var conflict = FileConflict(projectId: ProjectID(), location: "docs/requests/open/FR-0001.md", kind: .concurrentEdit,
                                    databaseRevision: 3, detectedAt: referenceDate)
        conflict.requestResolution(.keptDatabase, by: device, at: referenceDate.addingTimeInterval(1))
        #expect(conflict.hasPendingRequest && conflict.requestedBy == device)
        conflict.resolve(.keptDatabase, at: referenceDate.addingTimeInterval(2))
        #expect(!conflict.hasPendingRequest)
        conflict.requestResolution(.acceptedExternal, by: device, at: referenceDate.addingTimeInterval(3))
        #expect(conflict.requestedResolution == .keptDatabase)
    }
}
