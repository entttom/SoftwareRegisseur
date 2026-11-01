import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import Testing
@testable import SoftwareRegisseurWorkspace

func requestFile(id: String, uuid: UUID = UUID(), type: String = "bug", status: String = "open", title: String,
                 body: String = "## Beschreibung\n\nText") -> String {
    """
    ---
    id: \(id)
    uuid: "\(uuid.uuidString.lowercased())"
    type: \(type)
    status: \(status)
    title: "\(title)"
    createdAt: "2026-10-29T20:00:00+01:00"
    updatedAt: "2026-10-29T20:00:00+01:00"
    priority: high
    labels: [ios]
    dependsOn: []
    agentJobIds: []
    reviewState: pending
    custom: behalten
    ---

    # \(id): \(title)

    \(body)
    """ + "\n"
}

@Suite("Request materialization and reconciliation (F3/F5, E3, U4)")
struct RequestMaterializerTests {
    @Test func materializesNewRequestWithIDAfterExistingFiles() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        // Existing file with a higher number (ADR-0018: next number considers files).
        try h.sandbox.write("app/docs/requests/done/FR-0003-alt.md", requestFile(id: "FR-0003", type: "feature", status: "done", title: "Alt"))
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)

        let report = try await materializer.materialize(item.uuid)
        let path = "docs/requests/open/FR-0004-senderliste-vergroessern.md"
        #expect(report.createdFiles == [path])
        let stored = try #require(try await h.database.workItems.fetch(item.uuid))
        #expect(stored.humanId?.formatted == "FR-0004")
        let text = try h.sandbox.read("app/" + path)
        #expect(text.hasPrefix("---\nid: FR-0004\nuuid: \"\(item.uuid.uuidString.lowercased())\"\ntype: feature\nstatus: open\n"))
        #expect(text.contains("# FR-0004: Senderliste vergrößern\n\n## Ziel\n\nGrößere Liste.\n"))
        // Second pass is a no-op (no ping-pong).
        let again = try await materializer.reconcile(projectId: project.id)
        #expect(again.createdFiles.isEmpty && again.updatedFiles.isEmpty && again.conflicts.isEmpty)
        #expect(again.importedItems.count == 1) // the pre-existing FR-0003 file was imported
    }

    @Test func statusChangeTouchesOnlyStatusAndUpdatedAtAndMovesTrackedFile() async throws {
        let h = try Harness()
        let (project, repo) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        let oldPath = "docs/requests/open/FR-0001-senderliste-vergroessern.md"
        let before = try h.sandbox.read("app/" + oldPath)
        try await h.sandbox.commitAll(repo, "request")

        h.clock.advance(3600)
        let current = try #require(try await h.database.workItems.fetch(item.uuid))
        _ = try await h.database.workItems.changeStatus(item.uuid, to: .inProgress, expectedRevision: current.revision,
                                                        actor: .user(DeviceID()), at: h.clock.now)
        let report = try await materializer.materialize(item.uuid)
        let newPath = "docs/requests/in-progress/FR-0001-senderliste-vergroessern.md"
        #expect(report.movedFiles == [.init(from: oldPath, to: newPath)])
        #expect(!h.sandbox.exists("app/" + oldPath))
        let after = try h.sandbox.read("app/" + newPath)
        let changed = try #require(changedLines(before, after))
        #expect(changed.count == 2)
        #expect(changed[0] == "status: in_progress")
        #expect(changed[1].hasPrefix("updatedAt: \""))
        // Tracked file → `git mv` (rename staged in the index).
        let status = try await h.sandbox.gitOutput(["status", "--porcelain"], in: repo)
        #expect(status.hasPrefix("R") && status.contains("\(oldPath) -> \(newPath)"), "\(status)")
    }

    @Test func moveNeverOverwritesAnUnrelatedFile() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        let blocker = "app/docs/requests/in-progress/FR-0001-senderliste-vergroessern.md"
        try h.sandbox.write(blocker, "fremde Datei\n")

        let current = try #require(try await h.database.workItems.fetch(item.uuid))
        _ = try await h.database.workItems.changeStatus(item.uuid, to: .inProgress, expectedRevision: current.revision,
                                                        actor: .user(DeviceID()), at: h.clock.now)
        await #expect(throws: WorkspaceError.self) { try await materializer.materialize(item.uuid) }
        #expect(try h.sandbox.read(blocker) == "fremde Datei\n")
        #expect(h.sandbox.exists("app/docs/requests/open/FR-0001-senderliste-vergroessern.md"))
        // Exclusive creation also refuses existing destinations.
        #expect(throws: WorkspaceError.self) {
            try AtomicFileWriter.write(Data("x".utf8), to: h.sandbox.url(blocker), mode: .createNew)
        }
        #expect(try h.sandbox.read(blocker) == "fremde Datei\n")
    }

    @Test func externalEditUpdatesDatabaseAndFollowsStatusFolder() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        let path = "app/docs/requests/open/FR-0001-senderliste-vergroessern.md"
        var text = try h.sandbox.read(path)
        text = text.replacingOccurrences(of: "status: open", with: "status: in_progress")
            .replacingOccurrences(of: "title: \"Senderliste vergrößern\"", with: "title: \"Senderliste auf dem iPad vergrößern\"")
            .replacingOccurrences(of: "Größere Liste.", with: "Größere Liste mit Logos.")
        try h.sandbox.write(path, text)

        let report = try await materializer.reconcile(projectId: project.id)
        #expect(report.updatedItems == [item.uuid])
        #expect(report.conflicts.isEmpty)
        let stored = try #require(try await h.database.workItems.fetch(item.uuid))
        #expect(stored.title == "Senderliste auf dem iPad vergrößern")
        #expect(stored.status == .inProgress)
        #expect(stored.structuredBody == "## Ziel\n\nGrößere Liste mit Logos.")
        #expect(report.movedFiles.first?.to == "docs/requests/in-progress/FR-0001-senderliste-vergroessern.md")
        let events = try await h.database.events.events(forWorkItem: item.uuid)
        #expect(events.contains { $0.kind == .externalChangeDetected && $0.actor == .external })
        #expect(events.contains { $0.kind == .statusChanged && $0.actor == .external })
        // Unknown frontmatter field is preserved.
        #expect(try h.sandbox.read("app/" + report.movedFiles[0].to).contains("reviewState: pending"))
    }

    @Test func concurrentDatabaseAndFileEditCreatesConflictAndKeepsBoth() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        let path = "app/docs/requests/open/FR-0001-senderliste-vergroessern.md"

        let current = try #require(try await h.database.workItems.fetch(item.uuid))
        _ = try await h.database.workItems.update(item.uuid, expectedRevision: current.revision, actor: .user(DeviceID()), at: h.clock.now) {
            $0.title = "Titel vom iPhone"
        }
        try h.sandbox.write(path, try h.sandbox.read(path).replacingOccurrences(of: "title: \"Senderliste vergrößern\"", with: "title: \"Titel aus dem Editor\""))
        let fileBefore = try h.sandbox.read(path)

        let report = try await materializer.reconcile(projectId: project.id)
        let conflict = try #require(report.conflicts.first)
        #expect(conflict.kind == .concurrentEdit)
        #expect(conflict.externalText == fileBefore)
        #expect(conflict.databaseText?.contains("Titel vom iPhone") == true)
        #expect(try await h.database.workItems.fetch(item.uuid)?.title == "Titel vom iPhone")
        #expect(try h.sandbox.read(path) == fileBefore)
        #expect(try await h.database.events.events(forWorkItem: item.uuid).contains { $0.kind == .conflictDetected })

        // Frozen until resolved: no duplicate conflicts.
        let again = try await materializer.reconcile(projectId: project.id)
        #expect(again.conflicts.isEmpty && again.skippedForOpenConflict == [item.uuid])

        try await materializer.resolveConflict(conflict.id, resolution: .keptDatabase)
        #expect(try h.sandbox.read(path).contains("title: \"Titel vom iPhone\""))
        #expect(try h.sandbox.read(path).contains("# FR-0001: Titel vom iPhone"))
        #expect(try await h.database.fileConflicts.open(projectId: project.id).isEmpty)
    }

    @Test func disjointEditsAreMergedWithoutConflict() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        let path = "app/docs/requests/open/FR-0001-senderliste-vergroessern.md"

        let current = try #require(try await h.database.workItems.fetch(item.uuid))
        _ = try await h.database.workItems.update(item.uuid, expectedRevision: current.revision, actor: .user(DeviceID()), at: h.clock.now) {
            $0.priority = .urgent
        }
        try h.sandbox.write(path, try h.sandbox.read(path).replacingOccurrences(of: "Größere Liste.", with: "Neu aus dem Editor."))
        let report = try await materializer.reconcile(projectId: project.id)
        #expect(report.conflicts.isEmpty)
        let stored = try #require(try await h.database.workItems.fetch(item.uuid))
        #expect(stored.priority == .urgent && stored.structuredBody.contains("Neu aus dem Editor."))
        #expect(try h.sandbox.read(path).contains("priority: urgent"))
    }

    @Test func statusEditsDuringActiveLockAreValidated() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        _ = try await h.database.locks.acquire(LockRequest(taskId: item.uuid, projectId: project.id, jobId: JobID(), hostId: h.hostId,
                                                           owner: "test", leaseDuration: 600), at: h.clock.now)
        let path = "app/docs/requests/open/FR-0001-senderliste-vergroessern.md"

        // Agent sets in_progress itself: expected, recorded, task status stays host-derived.
        try h.sandbox.write(path, try h.sandbox.read(path).replacingOccurrences(of: "status: open", with: "status: in_progress"))
        let report = try await materializer.reconcile(projectId: project.id)
        #expect(report.conflicts.isEmpty)
        #expect(report.agentReportedStatuses[item.uuid] == .inProgress)
        #expect(try await h.database.workItems.fetch(item.uuid)?.status == .open)
        let moved = "app/docs/requests/in-progress/FR-0001-senderliste-vergroessern.md"
        #expect(h.sandbox.exists(moved))

        // `done` during an active run is not something a job may report → conflict.
        try h.sandbox.write(moved, try h.sandbox.read(moved).replacingOccurrences(of: "status: in_progress", with: "status: done"))
        let second = try await materializer.reconcile(projectId: project.id)
        #expect(second.conflicts.map(\.kind) == [.statusChangeDuringActiveJob])
        #expect(try await h.database.workItems.fetch(item.uuid)?.status == .open)
    }

    @Test func unknownRequestFilesAreImportedKeepingTheirIDs() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let uuid = UUID()
        try h.sandbox.write("app/docs/requests/open/BUG-0007-absturz.md", requestFile(id: "BUG-0007", uuid: uuid, title: "Absturz"))
        try h.sandbox.write("app/docs/requests/open/FR-0002-kaputt.md", "---\nid: FR-0002\ntitle: x\n---\n")
        try h.sandbox.write("app/docs/requests/README.md", "# Requests\n")
        let materializer = RequestMaterializer(environment: h.environment)
        let report = try await materializer.reconcile(projectId: project.id)
        #expect(report.importedItems == [WorkItemID(uuid)])
        #expect(report.incompatibleFiles.keys.contains("docs/requests/open/FR-0002-kaputt.md"))
        let imported = try #require(try await h.database.workItems.fetch(WorkItemID(uuid)))
        #expect(imported.humanId?.formatted == "BUG-0007")
        #expect(imported.type == .bug && imported.priority == .high && imported.labels == ["ios"])
        #expect(imported.structuredBody == "## Beschreibung\n\nText")
        // The next bug gets BUG-0008, never a reused number.
        let bug = try await h.item(project.id, title: "Neuer Fehler", type: .bug)
        try await materializer.materialize(bug.uuid)
        #expect(try await h.database.workItems.fetch(bug.uuid)?.humanId?.formatted == "BUG-0008")
        // Imported file untouched.
        #expect(try h.sandbox.read("app/docs/requests/open/BUG-0007-absturz.md") == requestFile(id: "BUG-0007", uuid: uuid, title: "Absturz"))
    }

    @Test func deletedFileBecomesConflictNotDataLoss() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app", git: false)
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        try FileManager.default.removeItem(at: h.sandbox.url("app/docs/requests/open/FR-0001-senderliste-vergroessern.md"))
        let report = try await materializer.reconcile(projectId: project.id)
        let conflict = try #require(report.conflicts.first)
        #expect(conflict.kind == .fileDeleted)
        #expect(try await h.database.workItems.fetch(item.uuid) != nil)
        // User decides to restore the file from the database.
        try await materializer.resolveConflict(conflict.id, resolution: .keptDatabase)
        #expect(h.sandbox.exists("app/docs/requests/open/FR-0001-senderliste-vergroessern.md"))
    }
}
