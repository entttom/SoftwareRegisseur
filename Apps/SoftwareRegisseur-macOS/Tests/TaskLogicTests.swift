import Foundation
import Testing
import SoftwareRegisseurDomain

@Suite("Aufgabenliste: Filter, Suche, Sortierung, Kanban")
struct TaskLogicTests {
    let items: [WorkItem] = [
        Fixture.item("Senderliste vergrößern", priority: .high, labels: ["ios"], body: "iPad-Layout", number: 3, created: 30),
        Fixture.item("EPG-Fehler", project: Fixture.projectB, type: .bug, status: .inProgress, priority: .urgent, number: 1, created: 20),
        Fixture.item("Spontane Idee", project: nil, type: .note, status: .inbox, created: 10),
        Fixture.item("Alte Aufgabe", status: .done, number: 2, created: 0, archived: true),
        Fixture.item("Im Review", status: .review, number: 4, created: 40),
    ]

    @Test func archivedItemsAreHiddenUnlessRequested() {
        #expect(TaskQuery().apply(to: items).count == 4)
        var query = TaskQuery()
        query.includeArchived = true
        #expect(query.apply(to: items).count == 5)
    }

    @Test func projectScopeFiltersInboxAndProject() {
        #expect(TaskQuery(project: .inbox).apply(to: items).map(\.title) == ["Spontane Idee"])
        #expect(TaskQuery(project: .project(Fixture.projectB)).apply(to: items).map(\.title) == ["EPG-Fehler"])
    }

    @Test func statusGroupsTypesPrioritiesAndLabels() {
        #expect(TaskQuery(groups: [.inProgress]).apply(to: items).map(\.title) == ["EPG-Fehler"])
        #expect(TaskQuery(types: [.bug, .note]).apply(to: items).count == 2)
        #expect(TaskQuery(priorities: [.high, .urgent]).apply(to: items).count == 2)
        #expect(TaskQuery(label: "ios").apply(to: items).map(\.title) == ["Senderliste vergrößern"])
    }

    @Test func searchMatchesBodyAndHumanIDCaseInsensitively() {
        #expect(TaskQuery(searchText: "ipad").apply(to: items).map(\.title) == ["Senderliste vergrößern"])
        #expect(TaskQuery(searchText: "BUG-0001").apply(to: items).map(\.title) == ["EPG-Fehler"])
        #expect(TaskQuery(searchText: "   ").isFiltering == false)
    }

    @Test func sortOrders() {
        #expect(TaskQuery(sort: .priority).apply(to: items).first?.title == "EPG-Fehler")
        #expect(TaskQuery(sort: .created).apply(to: items).first?.title == "Im Review")
        #expect(TaskQuery(sort: .title).apply(to: items).first?.title == "EPG-Fehler")
        // Ohne ID (Inbox) ans Ende.
        #expect(TaskQuery(sort: .identifier).apply(to: items).last?.title == "Spontane Idee")
    }

    @Test func kanbanGroupsByWorkItemStatus() {
        let board = KanbanBoard(items: items)
        #expect(board.count(.inbox) == 1)
        #expect(board.count(.open) == 1)
        #expect(board.count(.inProgress) == 1)
        #expect(board.count(.review) == 1)
        // Archiviert zählt nicht, leere Spalte „Abgebrochen“ entfällt.
        #expect(board.count(.done) == 0)
        #expect(!board.columns.contains { $0.group == .cancelled })
        #expect(TaskStatusGroup.group(of: .waitingApproval) == .inProgress)
        #expect(TaskStatusGroup.group(of: .implementationFinished) == .review)
        #expect(TaskStatusGroup.group(of: .blocked) == .attention)
    }

    @Test func everyStatusBelongsToExactlyOneGroup() {
        for status in WorkItemStatus.allCases {
            #expect(TaskStatusGroup.allCases.filter { $0.statuses.contains(status) }.count == 1)
        }
    }

    @Test func projectOverviewCountsAndSorting() {
        let item = items[0]
        let job = Fixture.job(for: item, state: .running)
        let rows = ProjectOverviewRow.rows(snapshot: Fixture.library(items: items, jobs: [job]))
        let alpha = rows.first { $0.name == "Alpha" }
        #expect(alpha?.openTasks == 2)
        #expect(alpha?.inReview == 1)
        #expect(alpha?.activeAgents == 1)
        #expect(ProjectSortOrder.agents.sort(rows).first?.name == "Alpha")
        #expect(ProjectSortOrder.name.sort(rows).map(\.name) == ["Alpha", "Beta"])
    }

    @Test func manualStatusChangeRespectsActiveJobAndHostOnlyStates() {
        let item = Fixture.item("Offen")
        let free = StatusChangeOptions(item: item, activeJob: nil, lock: nil)
        #expect(free.blockReason == nil)
        #expect(free.allowedTargets.contains(.done))
        #expect(!free.allowedTargets.contains(.inProgress))
        #expect(!free.allowedTargets.contains(.integrated))

        let blocked = StatusChangeOptions(item: item, activeJob: Fixture.job(for: item, state: .running), lock: nil)
        #expect(blocked.allowedTargets.isEmpty)
        #expect(blocked.blockReason != nil)
    }
}
