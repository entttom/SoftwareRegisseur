import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("HumanIDAllocator (ADR-0018)")
struct HumanIDAllocatorTests {
    @Test func allocatesSequentiallyPerPrefixAndProject() async throws {
        let database = try AppDatabase.inMemory()
        let projectA = ProjectID()
        let projectB = ProjectID()
        let allocator = database.humanIDs
        #expect(try await allocator.allocate(.feature, projectId: projectA, existingFileIDs: [], at: t0).formatted == "FR-0001")
        #expect(try await allocator.allocate(.feature, projectId: projectA, existingFileIDs: [], at: t0).formatted == "FR-0002")
        #expect(try await allocator.allocate(.bug, projectId: projectA, existingFileIDs: [], at: t0).formatted == "BUG-0001")
        #expect(try await allocator.allocate(.feature, projectId: projectB, existingFileIDs: [], at: t0).formatted == "FR-0001")
        #expect(try await allocator.highestAllocated(.feature, projectId: projectA) == 2)
    }

    @Test func respectsExistingFileIDsAndNeverReuses() async throws {
        let database = try AppDatabase.inMemory()
        let project = ProjectID()
        let files = [try HumanID(parsing: "FR-0007"), try HumanID(parsing: "FR-0003"), try HumanID(parsing: "BUG-0040")]
        let first = try await database.humanIDs.allocate(.feature, projectId: project, existingFileIDs: files, at: t0)
        #expect(first.formatted == "FR-0008")
        // The file FR-0007 disappears (deleted/renamed): its number and FR-0008 are still never reused.
        let second = try await database.humanIDs.allocate(.feature, projectId: project, existingFileIDs: [], at: t0)
        #expect(second.formatted == "FR-0009")
        #expect(try await database.humanIDs.allocate(.bug, projectId: project, existingFileIDs: [], at: t0).formatted == "BUG-0001")
        try await database.humanIDs.observe([try HumanID(parsing: "BUG-0040")], projectId: project, at: t0)
        #expect(try await database.humanIDs.allocate(.bug, projectId: project, existingFileIDs: [], at: t0).formatted == "BUG-0041")
        // The counter cannot be lowered, even directly.
        #expect(throws: DatabaseError.self) {
            try database.writer!.write { db in try db.execute(sql: "UPDATE human_id_counters SET highest_number = 1") }
        }
    }

    @Test func assignWritesItemEventAndOutboxAndSurvivesDeletion() async throws {
        let database = try AppDatabase.inMemory()
        let (project, first) = try await database.seedItem()
        let second = Fixture.workItem(projectId: project.id, title: "Zweite")
        try await database.workItems.insert(second, actor: deviceActor, at: t0)

        let a = try await database.humanIDs.assign(to: first.uuid, existingFileIDs: [], actor: .host(Fixture.host), at: at(1))
        let b = try await database.humanIDs.assign(to: second.uuid, existingFileIDs: [], actor: .host(Fixture.host), at: at(2))
        #expect(a.humanId?.formatted == "FR-0001")
        #expect(b.humanId?.formatted == "FR-0002")
        #expect(try await database.workItems.fetch(first.uuid)?.humanId == a.humanId)
        #expect(try await database.events.events(forWorkItem: first.uuid).last?.kind == .humanIDAssigned)

        await #expect(throws: StoreError.humanID(.humanIDAlreadyAssigned(a.humanId!))) {
            _ = try await database.humanIDs.assign(to: first.uuid, existingFileIDs: [], actor: .host(Fixture.host), at: at(3))
        }

        // Deleting the highest item does not free its number.
        try await database.workItems.delete(second.uuid, expectedRevision: b.revision, at: at(4))
        let third = Fixture.workItem(projectId: project.id, title: "Dritte")
        try await database.workItems.insert(third, actor: deviceActor, at: t0)
        let c = try await database.humanIDs.assign(to: third.uuid, existingFileIDs: [], actor: .host(Fixture.host), at: at(5))
        #expect(c.humanId?.formatted == "FR-0003")
    }

    @Test func importedIDsAdvanceTheRangeAndDuplicatesAreRejected() async throws {
        let database = try AppDatabase.inMemory()
        let (project, _) = try await database.seedItem()
        var imported = Fixture.workItem(projectId: project.id, type: .todo, title: "Import")
        try imported.assignHumanID(HumanID(parsing: "TODO-0010"), at: t0)
        try await database.workItems.insert(imported, actor: .external, at: t0)
        #expect(try await database.humanIDs.allocate(.todo, projectId: project.id, existingFileIDs: [], at: t0).formatted == "TODO-0011")

        let clash = Fixture.workItem(projectId: project.id, type: .todo, title: "Kollision")
        try await database.workItems.insert(clash, actor: deviceActor, at: t0)
        let taken = try HumanID(parsing: "TODO-0010")
        await #expect(throws: StoreError.duplicateHumanID(taken, projectId: project.id)) {
            _ = try await database.humanIDs.adopt(taken, for: clash.uuid, actor: .external, at: at(1))
        }
        let adopted = try await database.humanIDs.adopt(try HumanID(parsing: "TODO-0020"), for: clash.uuid, actor: .external, at: at(1))
        #expect(adopted.humanId?.formatted == "TODO-0020")
        #expect(try await database.humanIDs.highestAllocated(.todo, projectId: project.id) == 20)
    }

    @Test func itemsWithoutProjectGetNoNumber() async throws {
        let database = try AppDatabase.inMemory()
        let inbox = Fixture.workItem(projectId: nil, type: .note, title: "Offline erfasst")
        try await database.workItems.insert(inbox, actor: deviceActor, at: t0)
        await #expect(throws: StoreError.workItemWithoutProject(inbox.uuid)) {
            _ = try await database.humanIDs.assign(to: inbox.uuid, existingFileIDs: [], actor: .host(Fixture.host), at: at(1))
        }
    }

    @Test func concurrentAllocationsAreUnique() async throws {
        let directory = try TemporaryDirectory()
        let database = try AppDatabase.openWriter(at: directory.databaseURL)
        let project = ProjectID()
        let ids = try await withThrowingTaskGroup(of: HumanID.self) { group in
            for _ in 0..<20 {
                group.addTask { try await database.humanIDs.allocate(.feature, projectId: project, existingFileIDs: [], at: t0) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(ids).count == 20)
        #expect(Set(ids.map(\.number)) == Set(1...20))
    }

    @Test func adrNumbersUseTheirOwnRange() async throws {
        let database = try AppDatabase.inMemory()
        let project = ProjectID()
        _ = try await database.humanIDs.allocate(.feature, projectId: project, existingFileIDs: [], at: t0)
        let existing = [try ADRNumber(0), try ADRNumber(19)]
        #expect(try await database.humanIDs.allocateADRNumber(projectId: project, existing: existing, at: t0).formatted == "0020")
        let adr = ADR(projectId: project, decisionNumber: try ADRNumber(25), title: "Import", createdAt: t0)
        try await database.adrs.insert(adr, at: t0)
        #expect(try await database.humanIDs.allocateADRNumber(projectId: project, existing: [], at: t0).formatted == "0026")
        #expect(try await database.humanIDs.allocate(.feature, projectId: project, existingFileIDs: [], at: t0).formatted == "FR-0002")
    }
}
