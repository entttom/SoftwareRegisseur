import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("WorkItemRepository")
struct WorkItemRepositoryTests {
    @Test func optimisticRevisionConflictInsteadOfOverwrite() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()

        // Two editors start from revision 1.
        var phone = item
        phone.title = "Vom iPhone"
        var mac = item
        mac.title = "Vom Mac"

        let saved = try await database.workItems.update(phone, expectedRevision: 1, actor: deviceActor, at: at(1))
        #expect(saved.revision == 2)

        await #expect(throws: StoreError.revisionConflict(entity: .workItem, id: item.uuid.uuidString, expected: 1, actual: 2)) {
            _ = try await database.workItems.update(mac, expectedRevision: 1, actor: deviceActor, at: at(2))
        }
        #expect(try await database.workItems.fetch(item.uuid)?.title == "Vom iPhone")

        // Retrying on top of the current revision works.
        let retried = try await database.workItems.update(item.uuid, expectedRevision: 2, actor: deviceActor, at: at(3)) {
            $0.title = "Zusammengeführt"
        }
        #expect(retried.revision == 3)
        #expect(retried.updatedAt == at(3))
    }

    @Test func insertTwiceIsRejected() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        await #expect(throws: StoreError.alreadyExists(entity: .workItem, id: item.uuid.uuidString)) {
            try await database.workItems.insert(item, actor: deviceActor, at: t0)
        }
    }

    @Test func executionMetadataIsProtectedFromTextEdits() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        await #expect(throws: StoreError.humanIDChangeNotAllowed(item.uuid)) {
            _ = try await database.workItems.update(item.uuid, expectedRevision: 1, actor: deviceActor, at: at(1)) {
                try $0.assignHumanID(HumanID(type: .feature, number: 5), at: at(1))
            }
        }
        await #expect(throws: StoreError.identityFieldChanged(entity: .workItem, field: "agentJobIds")) {
            _ = try await database.workItems.update(item.uuid, expectedRevision: 1, actor: deviceActor, at: at(1)) {
                $0.agentJobIds.append(JobID())
            }
        }
        #expect(try await database.workItems.fetch(item.uuid) == item)
    }

    @Test func manualStatusChangeRejectedWhileJobActive() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let created = try await database.jobs.create(Fixture.job(for: item), actor: deviceActor, at: at(1))
        guard case let .created(_, queuedItem) = created else { Issue.record("not created"); return }
        #expect(queuedItem.status == .queued)

        await #expect(throws: StoreError.workItemStatusChange(.activeJobConflict(current: .queued, requested: .open))) {
            _ = try await database.workItems.changeStatus(item.uuid, to: .open, expectedRevision: queuedItem.revision, actor: deviceActor, at: at(2))
        }
        #expect(try await database.workItems.fetch(item.uuid)?.status == .queued)
        #expect(try await database.workItems.hasActiveJob(item.uuid))
    }

    @Test func manualStatusChangeWritesEventAndOutbox() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let before = try database.count("sync_outbox")
        let updated = try await database.workItems.changeStatus(item.uuid, to: .done, expectedRevision: 1, actor: deviceActor, at: at(1))
        #expect(updated.status == .done)
        #expect(try database.count("sync_outbox") == before + 2) // work item + event
        let events = try await database.events.events(forWorkItem: item.uuid)
        #expect(events.last?.kind == .statusChanged)
        #expect(events.last?.payload == ["from": "open", "to": "done"])
    }

    @Test func listFiltersByProjectStatusTypeLabelPriorityAndText() async throws {
        let database = try AppDatabase.inMemory()
        let (projectA, settingsA) = Fixture.project(name: "A")
        let (projectB, settingsB) = Fixture.project(name: "B")
        try await database.projects.create(projectA, settings: settingsA, at: t0)
        try await database.projects.create(projectB, settings: settingsB, at: t0)

        let items = [
            Fixture.workItem(projectId: projectA.id, type: .bug, title: "Absturz beim Öffnen", status: .open, priority: .urgent, labels: ["ios"]),
            Fixture.workItem(projectId: projectA.id, type: .feature, title: "Diktat verbessern", status: .open, priority: .low, labels: ["ios", "audio"]),
            Fixture.workItem(projectId: projectA.id, type: .feature, title: "Sync Statusanzeige", status: .done, priority: .high),
            Fixture.workItem(projectId: projectB.id, type: .todo, title: "Absturz im Dienst", status: .open, priority: .medium, labels: ["mac"]),
            Fixture.workItem(projectId: nil, type: .note, title: "Idee ohne Projekt", status: .inbox),
        ]
        for item in items { try await database.workItems.insert(item, actor: deviceActor, at: t0) }
        let repo = database.workItems

        #expect(try await repo.list(WorkItemFilter(project: .project(projectA.id))).map(\.title)
            == ["Absturz beim Öffnen", "Sync Statusanzeige", "Diktat verbessern"])
        #expect(try await repo.list(WorkItemFilter(project: .withoutProject)).map(\.title) == ["Idee ohne Projekt"])
        #expect(try await repo.list(WorkItemFilter(project: .project(projectA.id), statuses: [.open])).count == 2)
        #expect(try await repo.list(WorkItemFilter(types: [.feature])).count == 2)
        #expect(try await repo.list(WorkItemFilter(label: "ios")).count == 2)
        #expect(try await repo.list(WorkItemFilter(label: "audio")).map(\.title) == ["Diktat verbessern"])
        #expect(try await repo.list(WorkItemFilter(priorities: [.urgent, .high])).count == 2)
        // Full-text search: prefix match, diacritics folded.
        #expect(try await repo.list(WorkItemFilter(text: "absturz")).count == 2)
        #expect(try await repo.list(WorkItemFilter(project: .project(projectB.id), text: "Abst")).map(\.title) == ["Absturz im Dienst"])
        #expect(try await repo.list(WorkItemFilter(text: "offnen")).map(\.title) == ["Absturz beim Öffnen"])
        #expect(try await repo.list(WorkItemFilter(text: "Ziel")).count == 5) // structured body
        #expect(try await repo.list(WorkItemFilter(limit: 1)).count == 1)

        // Search index follows edits (title only, so the original note cannot match).
        let target = WorkItem(projectId: projectB.id, type: .todo, title: "Kaffeemaschine", createdAt: t0)
        try await repo.insert(target, actor: deviceActor, at: t0)
        #expect(try await repo.list(WorkItemFilter(text: "kaffee")).map(\.uuid) == [target.uuid])
        _ = try await repo.update(target.uuid, expectedRevision: 1, actor: deviceActor, at: at(1)) { $0.title = "Spracheingabe" }
        #expect(try await repo.list(WorkItemFilter(text: "kaffee")).isEmpty)
        #expect(try await repo.list(WorkItemFilter(text: "Sprach")).map(\.uuid) == [target.uuid])
    }

    @Test func deleteWritesTombstoneAndIsRefusedWithActiveJob() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let (_, other) = try await database.seedItem()
        _ = try await database.jobs.create(Fixture.job(for: other), actor: deviceActor, at: at(1))
        let otherRevision = try #require(try await database.workItems.fetch(other.uuid)).revision
        await #expect(throws: StoreError.self) {
            try await database.workItems.delete(other.uuid, expectedRevision: otherRevision, at: at(2))
        }

        try await database.workItems.delete(item.uuid, expectedRevision: 1, at: at(2))
        #expect(try await database.workItems.fetch(item.uuid) == nil)
        #expect(try database.count("work_item_texts", "work_item_id = '\(item.uuid.uuidString)'") == 0)
        let tombstone = try #require(try await database.sync.tombstone(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(tombstone.origin == .local)
        #expect(try database.outbox().last?.kind == "delete")
        // History survives deletion of the item (append-only).
        #expect(try await !database.events.events(forWorkItem: item.uuid).isEmpty)
    }
}
