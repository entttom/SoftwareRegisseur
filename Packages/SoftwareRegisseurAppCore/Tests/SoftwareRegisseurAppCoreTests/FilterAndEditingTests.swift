import Foundation
import Testing
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

@Suite("Task filter and editing (H1)")
struct FilterAndEditingTests {
    @Test func inMemoryMatching() {
        let project = ProjectID()
        let bug = Fixture.item(projectId: project, title: "Absturz beim Export", status: .open, type: .bug, priority: .high, labels: ["pdf"])
        let inbox = Fixture.item(projectId: nil, title: "Idee Dunkelmodus", status: .inbox, type: .note, priority: .low)

        #expect(TaskFilter(project: .project(project)).matches(bug))
        #expect(!TaskFilter(project: .project(project)).matches(inbox))
        #expect(TaskFilter(project: .withoutProject).matches(inbox))
        #expect(TaskFilter(statuses: TaskFilter.StatusGroup.open.statuses).matches(inbox))
        #expect(!TaskFilter(types: [.feature]).matches(bug))
        #expect(TaskFilter(priorities: [.high, .urgent]).matches(bug))
        #expect(TaskFilter(label: "pdf").matches(bug))
        #expect(!TaskFilter(label: "pdf").matches(inbox))
        #expect(TaskFilter(searchText: "  export absturz ").matches(bug))
        #expect(!TaskFilter(searchText: "export dunkel").matches(bug))
        #expect(TaskFilter(agent: .codex).matches(bug, jobProviders: [.codex]))
        #expect(!TaskFilter(agent: .codex).matches(bug, jobProviders: [.claudeCode]))
        #expect(!TaskFilter().isActive)
        #expect(TaskFilter(searchText: "x").isActive)
        #expect(TaskFilter.labels(in: [bug, inbox]) == ["pdf"])
    }

    @Test func repositoryQueryAppliesAllCriteria() async throws {
        let (database, project, feature) = try await Fixture.makeDatabase()
        let bug = Fixture.item(projectId: project.id, title: "Absturz beim Export", type: .bug, priority: .urgent, labels: ["pdf"])
        let note = Fixture.item(projectId: nil, title: "Dunkelmodus", status: .inbox, type: .note)
        try await database.workItems.insert(bug, actor: actor, at: now)
        try await database.workItems.insert(note, actor: actor, at: now)
        let query = TaskQuery(workItems: database.workItems, jobs: database.jobs)

        #expect(try await query.run(TaskFilter()).count == 3)
        #expect(try await query.run(TaskFilter(project: .withoutProject)).map(\.uuid) == [note.uuid])
        #expect(try await query.run(TaskFilter(types: [.bug], priorities: [.urgent])).map(\.uuid) == [bug.uuid])
        #expect(try await query.run(TaskFilter(label: "pdf")).map(\.uuid) == [bug.uuid])
        #expect(try await query.run(TaskFilter(searchText: "Absturz")).map(\.uuid) == [bug.uuid])
        #expect(try await query.run(TaskFilter(statuses: [.inbox])).map(\.uuid) == [note.uuid])

        // Agent filter uses the job table.
        let submitter = JobRequestSubmitter(jobs: database.jobs)
        _ = try await submitter.submit(JobRequestInput(providerId: .codex),
                                       context: JobRequestContext(workItem: feature, project: project, capabilities: [Fixture.codex()]),
                                       actor: actor, now: now)
        #expect(try await query.run(TaskFilter(agent: .codex)).map(\.uuid) == [feature.uuid])
        #expect(try await query.run(TaskFilter(agent: .claudeCode)).isEmpty)
    }

    @Test func editUndoAssignAndDuplicate() async throws {
        let (database, project, item) = try await Fixture.makeDatabase()
        let editor = TaskEditor(workItems: database.workItems)
        var edit = WorkItemEdit(item)
        edit.title = "Export als PDF und CSV"
        let (saved, undo) = try await editor.save(edit, to: item, actor: actor, at: now)
        #expect(saved.title == "Export als PDF und CSV")
        let (restored, _) = try await editor.save(undo, to: saved, actor: actor, at: now)
        #expect(restored.title == item.title)
        #expect(restored.originalNote == item.originalNote)

        let inbox = Fixture.item(projectId: nil, title: "Idee", status: .inbox, type: .note)
        try await database.workItems.insert(inbox, actor: actor, at: now)
        let assigned = try await editor.assign(inbox, to: project.id, actor: actor, at: now)
        #expect(assigned.projectId == project.id)
        #expect(assigned.status == .open)

        let copy = try await editor.duplicate(restored, titleSuffix: " (Kopie)", actor: actor, at: now)
        #expect(copy.uuid != restored.uuid)
        #expect(copy.humanId == nil)
        #expect(copy.title == "Export als PDF (Kopie)")

        #expect(TaskEditor.manualTargets(from: .open, hasActiveJob: true).isEmpty)
        #expect(TaskEditor.manualTargets(from: .integrated, hasActiveJob: false) == [.done])
    }
}
