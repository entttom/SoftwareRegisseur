import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("Cross-device contracts (migration v4)")
struct ContractRepositoryTests {
    private func remoteChange<T: Encodable>(_ type: SyncEntityType, _ id: UUID, _ value: T, version: Int = 1, base: Int? = nil) throws -> RemoteChange {
        RemoteChange(operationId: SyncOperationID(), entityType: type, entityId: id, kind: base == nil ? .create : .update,
                     version: version, baseVersion: base, payload: try SyncPayloadCodec.encode(value), systemFields: nil)
    }

    // MARK: Migration

    @Test func migratesV3DatabaseAndQueuesExistingWorkspaceRows() async throws {
        let directory = try TemporaryDirectory()
        let host = HostID()
        let command = ProjectSetupCommand(kind: .createProject, projectName: "Neu", target: .draftWithoutRepository, createdAt: t0)
        let folder = IndexedFolder(hostId: host, canonicalPath: "/Dev/app", displayName: "app", kind: .gitRepository,
                                   scanRootPath: "/Dev", depth: 1, isSelectable: true, lastSeenAt: t0)
        let (project, item): (Project, WorkItem)
        do {
            let v3 = try AppDatabase.openWriter(at: directory.databaseURL, migratingUpTo: "v3_workspace_host_index")
            (project, item) = try await v3.seedItem()
            // Rows as a v3 host wrote them: host-local, no outbox entries.
            try await v3.writer!.write { db in
                try db.execute(sql: "DELETE FROM sync_outbox")
                try db.execute(sql: """
                    INSERT INTO project_setup_commands (id, project_id, host_id, state, payload, revision, created_at, updated_at)
                    VALUES (?, ?, NULL, 'pending', ?, 1, ?, ?)
                    """, arguments: [command.id.databaseText, command.projectId.databaseText, try JSONColumn.encode(command),
                                     StoredDate.value(t0), StoredDate.value(t0)])
                try db.execute(sql: """
                    INSERT INTO indexed_folders (id, host_id, canonical_path, kind, project_id, repository_identity, is_selectable,
                        is_available, payload, last_seen_at) VALUES (?, ?, ?, 'gitRepository', NULL, NULL, 1, 1, ?, ?)
                    """, arguments: [folder.id.databaseText, host.databaseText, folder.canonicalPath, try JSONColumn.encode(folder),
                                     StoredDate.value(t0)])
            }
            let job = Fixture.job(for: item)
            _ = try await v3.jobs.create(job, actor: deviceActor, at: at(1))
        }
        let database = try AppDatabase.openWriter(at: directory.databaseURL)
        #expect(try database.appliedMigrations() == AppSchema.migrationIdentifiers)
        #expect(try database.appliedMigrations().last == "v4_cross_device_contracts")
        let queued = try database.outbox().filter { $0.kind == "create" }.map(\.type)
        #expect(queued.contains("projectSetupCommand") && queued.contains("indexedFolder"))
        #expect(try await database.projectSetupCommands.fetch(command.id) == command)
        #expect(try await database.indexedFolders.selectable().map(\.id) == [folder.id])
        // Old rows decode with the new defaults.
        #expect(try await database.workItems.fetch(item.uuid)?.isArchived == false)
        #expect(try await database.jobs.jobs(forWorkItem: item.uuid).first?.retryOfJobId == nil)
        #expect(try await database.projects.fetch(project.id) == project)
    }

    // MARK: Approvals

    @Test func approvalsAndDecisionsAreIdempotentAndOnlyForOpenRequests() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        var approval = PendingApproval(jobId: job.jobId, workItemId: item.uuid, hostId: Fixture.host, requestId: "r1",
                                       kind: .commandExecution, summary: "Befehl ausführen: swift test", preview: "swift test",
                                       allowedDecisions: [.allow, .deny], requestedAt: at(2), expiresAt: at(602))
        try await database.approvals.save(approval, at: at(2))
        try await database.approvals.save(approval, at: at(2)) // unchanged → no second outbox entry
        #expect(try await database.approvals.openApprovals(hostId: Fixture.host).map(\.id) == [approval.id])
        #expect(try await database.approvals.openApprovals(hostId: HostID()).isEmpty)

        let device = DeviceID()
        let decision = ApprovalDecision(for: approval, decision: .allow, decidedBy: device, at: at(3))
        try await database.approvals.recordDecision(decision)
        try await database.approvals.recordDecision(decision) // idempotent
        #expect(try await database.approvals.decisions(approvalId: approval.id) == [decision])
        await #expect(throws: StoreError.notFound(entity: .pendingApproval, id: PendingApprovalID(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!).uuidString)) {
            try await database.approvals.recordDecision(ApprovalDecision(
                approvalId: PendingApprovalID(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!), jobId: job.jobId,
                decision: .allow, decidedBy: device, decidedAt: at(3)))
        }

        approval.recordAnswer(decision, at: at(4))
        try await database.approvals.save(approval, at: at(4))
        #expect(try await database.approvals.openApprovals(hostId: nil).isEmpty)
        let late = ApprovalDecision(for: approval, decision: .deny, decidedBy: device, at: at(5))
        await #expect(throws: StoreError.approvalClosed(approval.id, .answered)) { try await database.approvals.recordDecision(late) }
        #expect(try await database.approvals.approvals(jobId: job.jobId).first?.decisionId == decision.id)

        let types = try database.outbox().map(\.type)
        #expect(types.filter { $0 == "pendingApproval" }.count == 2)
        #expect(types.filter { $0 == "approvalDecision" }.count == 1)
    }

    @Test func remoteDecisionsAndApprovalsApplyOnAnotherDevice() async throws {
        let phone = try AppDatabase.inMemory()
        let approval = PendingApproval(jobId: JobID(), workItemId: WorkItemID(), hostId: HostID(), requestId: "perm-1",
                                       kind: .toolUse, toolName: "Write", summary: "Werkzeug Write verwenden",
                                       allowedDecisions: [.allow, .deny], requestedAt: t0)
        let outcome = try await phone.sync.applyRemoteChanges(
            [try remoteChange(.pendingApproval, approval.id.rawValue, approval)], engineState: nil, at: t0)
        #expect(outcome == [.applied])
        #expect(try await phone.approvals.openApprovals(hostId: nil) == [approval])
        let decision = ApprovalDecision(for: approval, decision: .deny, decidedBy: DeviceID(), at: at(1), message: "Nicht jetzt")
        try await phone.approvals.recordDecision(decision)
        let payload = try #require(try await phone.sync.currentPayload(entityType: .approvalDecision, entityId: decision.id.rawValue))
        #expect(try SyncPayloadCodec.decode(ApprovalDecision.self, from: payload) == decision)
    }

    // MARK: Draft versions

    @Test func draftVersionsAreNumberedPerItemAndSync() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let original = try await database.draftVersions.append({ DraftVersion(workItemId: item.uuid, version: $0, source: .original,
                                                                               text: item.originalNote, createdAt: t0) },
                                                               for: item.uuid, at: t0)
        let ai = try await database.draftVersions.append({ DraftVersion(
            workItemId: item.uuid, version: $0, source: .ai, channel: .composer, mode: "short", providerId: .openAI,
            modelId: "gpt-5.5", contents: [DraftContent(classification: .feature, title: "Export")], createdAt: at(1)) },
            for: item.uuid, at: at(1))
        #expect(original.version == 1 && ai.version == 2)
        let accepted = try await database.draftVersions.accept(ai.id, contentIndexes: [0], at: at(2))
        #expect(accepted.acceptedAt == at(2))
        #expect(try await database.draftVersions.versions(workItemId: item.uuid).map(\.id) == [original.id, ai.id])
        #expect(try await database.draftVersions.fetch(ai.id) == accepted)
        #expect(try database.outbox().filter { $0.type == "draftVersion" }.count == 3)
    }

    // MARK: Global settings

    @Test func globalSettingsSaveWithRevisionCheck() async throws {
        let database = try AppDatabase.inMemory()
        var settings = try await database.globalSettings.fetch()
        #expect(!settings.isStored && settings.defaultAgentId == nil)
        settings.defaultAgentId = .claudeCode
        let saved = try await database.globalSettings.save(settings, expectedRevision: 0, at: t0)
        #expect(saved.revision == 1 && saved.defaultAgentId == .claudeCode)
        await #expect(throws: StoreError.self) { _ = try await database.globalSettings.save(settings, expectedRevision: 0, at: t0) }
        var invalid = saved
        invalid.folderLayout.adrPath = "/etc"
        await #expect(throws: StoreError.invalidSettings("folderLayout")) {
            _ = try await database.globalSettings.save(invalid, expectedRevision: 1, at: at(1))
        }
        #expect(try await database.globalSettings.save(saved, expectedRevision: 1, at: at(2)).revision == 1) // unchanged
        #expect(try await database.globalSettings.fetch() == saved)
        #expect(try database.outbox().filter { $0.type == "globalSettings" }.count == 1)
    }

    // MARK: Work items

    @Test func reclassifyAndArchiveWriteEventsAndFilter() async throws {
        let database = try AppDatabase.inMemory()
        let (project, item) = try await database.seedItem(type: .todo)
        let reclassified = try await database.workItems.reclassify(item.uuid, to: .bug, expectedRevision: item.revision,
                                                                   actor: deviceActor, at: at(1))
        #expect(reclassified.type == .bug && reclassified.revision == item.revision + 1)
        var archiveCandidate = reclassified
        archiveCandidate.archive(at: at(2))
        await #expect(throws: StoreError.identityFieldChanged(entity: .workItem, field: "archivedAt")) {
            _ = try await database.workItems.update(archiveCandidate, expectedRevision: reclassified.revision, actor: deviceActor, at: at(2))
        }
        let archived = try await database.workItems.setArchived(item.uuid, true, expectedRevision: reclassified.revision,
                                                                actor: deviceActor, at: at(3))
        #expect(archived.isArchived && archived.status == item.status)
        #expect(try await database.workItems.list(WorkItemFilter(project: .project(project.id), archive: .activeOnly)).isEmpty)
        #expect(try await database.workItems.list(WorkItemFilter(archive: .archivedOnly)).map(\.uuid) == [item.uuid])
        #expect(try await database.workItems.list(WorkItemFilter()).count == 1)
        let restored = try await database.workItems.setArchived(item.uuid, false, expectedRevision: archived.revision,
                                                                actor: deviceActor, at: at(4))
        #expect(!restored.isArchived)
        let kinds = try await database.events.events(forWorkItem: item.uuid).map(\.kind)
        #expect(kinds.suffix(3) == [.typeChanged, .archived, .unarchived])

        let humanId = try HumanID(type: .bug, number: 7)
        let numbered = try await database.humanIDs.adopt(humanId, for: item.uuid, actor: deviceActor, at: at(5))
        await #expect(throws: StoreError.reclassificationRefused(.typeChangeAfterHumanID(humanId))) {
            _ = try await database.workItems.reclassify(item.uuid, to: .feature, expectedRevision: numbered.revision,
                                                        actor: deviceActor, at: at(6))
        }
    }

    // MARK: Jobs and reviews

    @Test func retryLinkQuotaScheduleAndReviewContentPersist() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let first = Fixture.job(for: item)
        _ = try await database.jobs.create(first, actor: deviceActor, at: at(1))
        _ = try await database.jobs.transition(first.jobId, to: .cancelled, actor: deviceActor, at: at(2))
        let reset = at(3600)
        let retry = AgentJob(idempotencyKey: IdempotencyKey(), projectId: first.projectId, workItemId: item.uuid, hostId: Fixture.host,
                             configSnapshot: first.configSnapshot,
                             schedule: JobSchedule(kind: .whenQuotaAvailable(expectedReset: reset, requestedAt: at(3))),
                             workItemStatusBeforeJob: .open, retryOfJobId: first.jobId, createdAt: at(3))
        _ = try await database.jobs.create(retry, actor: deviceActor, at: at(3))
        let stored = try #require(try await database.jobs.fetch(retry.jobId))
        #expect(stored.retryOfJobId == first.jobId && stored.schedule == retry.schedule && stored.scheduledAt == reset)
        #expect(try await database.jobs.retries(of: first.jobId).map(\.jobId) == [retry.jobId])
        #expect(try await database.jobs.dueJobs(at: at(10)).isEmpty)
        #expect(try await database.jobs.dueJobs(at: reset).map(\.jobId) == [retry.jobId])

        var review = Review(jobId: first.jobId, diffSummary: DiffSummary(filesChanged: 1, insertions: 2, deletions: 1, files: ["a.swift"]),
                            testResults: [TestResult(name: "swift test", outcome: .failed)], summary: "Fertig",
                            commits: [ReviewCommit(sha: "abc123", subject: "Export")],
                            fileChanges: [ReviewFileChange(status: "M", path: "a.swift", additions: 2, deletions: 1)],
                            testSummary: TestRunSummary(failed: 1), headCommit: "abc123", notes: ["Automatisch committet"])
        try await database.reviews.save(review, at: at(4))
        review.conflict = ReviewConflictInfo(files: ["a.swift"], message: "Konflikt", detectedAt: at(5))
        try await database.reviews.save(review, at: at(5))
        #expect(try await database.reviews.fetch(review.reviewId) == review)
        let payload = try #require(try await database.sync.currentPayload(entityType: .review, entityId: review.reviewId.rawValue))
        #expect(try SyncPayloadCodec.decode(Review.self, from: payload) == review)
    }

    // MARK: Workspace entities

    @Test func indexedFolderRescansStayLocalAndDeletionsTombstone() async throws {
        let database = try AppDatabase.inMemory()
        let host = HostID()
        let folder = IndexedFolder(hostId: host, canonicalPath: "/Dev/app/sub", displayName: "sub", kind: .repositorySubfolder,
                                   repositoryRootPath: "/Dev/app", scanRootPath: "/Dev", depth: 2,
                                   documents: DetectedProjectDocuments(hasAgentsFile: true, adrFolder: "docs/adr", adrFileCount: 3),
                                   isSelectable: true, lastSeenAt: t0)
        let saved = try await database.indexedFolders.upsert(folder)
        var rescanned = saved
        rescanned.lastSeenAt = at(60)
        _ = try await database.indexedFolders.upsert(rescanned)
        #expect(try database.outbox().filter { $0.type == "indexedFolder" }.count == 1)
        #expect(try await database.indexedFolders.fetch(hostId: host, path: folder.canonicalPath)?.lastSeenAt == at(60))
        try await database.indexedFolders.delete(hostId: host, path: folder.canonicalPath)
        #expect(try database.outbox().filter { $0.type == "indexedFolder" }.map(\.kind) == ["create", "delete"])
        #expect(try database.count("sync_tombstones", "entity_type = 'indexedFolder'") == 1)

        // The iPhone receives the Mac's folder with kind and detected documents (spec E2/E3).
        let phone = try AppDatabase.inMemory()
        _ = try await phone.sync.applyRemoteChanges([try remoteChange(.indexedFolder, folder.id.rawValue, folder)], engineState: nil, at: t0)
        #expect(try await phone.indexedFolders.selectable() == [folder])
    }

    @Test func fileConflictResolutionRequestedOnPhone() async throws {
        let database = try AppDatabase.inMemory()
        let conflict = FileConflict(projectId: ProjectID(), location: "docs/requests/open/FR-0001.md", kind: .concurrentEdit,
                                    databaseRevision: 2, detectedAt: t0)
        try await database.fileConflicts.insert(conflict)
        let device = DeviceID()
        let requested = try await database.fileConflicts.requestResolution(conflict.id, resolution: .acceptedExternal, by: device, at: at(1))
        #expect(requested.requestedResolution == .acceptedExternal && requested.requestedBy == device)
        #expect(try await database.fileConflicts.pendingRequests().map(\.id) == [conflict.id])
        _ = try await database.fileConflicts.resolve(conflict.id, resolution: .acceptedExternal, at: at(2))
        #expect(try await database.fileConflicts.pendingRequests().isEmpty)
        await #expect(throws: StoreError.conflictAlreadyResolved(conflict.id.rawValue)) {
            _ = try await database.fileConflicts.requestResolution(conflict.id, resolution: .keptDatabase, by: device, at: at(3))
        }
        #expect(try database.outbox().filter { $0.type == "fileConflict" }.count == 3)
    }

    @Test func setupCommandsCreatedOnPhoneListPerProject() async throws {
        let database = try AppDatabase.inMemory()
        let projectId = ProjectID()
        let command = ProjectSetupCommand(kind: .createProject, projectId: projectId, projectName: "App",
                                          target: .newSubfolder(parentPath: "/Dev", folderName: "App"),
                                          initializeGitRepository: true, gitInitConsent: GitInitConsent(grantedBy: DeviceID(), grantedAt: t0),
                                          requestedBy: DeviceID(), createdAt: t0)
        try await database.projectSetupCommands.insert(command, at: t0)
        await #expect(throws: StoreError.alreadyExists(entity: .projectSetupCommand, id: command.id.uuidString)) {
            try await database.projectSetupCommands.insert(command, at: t0)
        }
        #expect(try await database.projectSetupCommands.list(projectId: projectId) == [command])
        #expect(try database.outbox().filter { $0.type == "projectSetupCommand" }.map(\.kind) == ["create"])
    }
}
