import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// User-editable fields of a work item (spec H1). Type, original note and human ID are fixed.
public struct WorkItemEdit: Hashable, Sendable {
    public var title: String
    public var transcript: String?
    public var structuredBody: String
    public var priority: Priority
    public var complexity: TaskComplexity?
    public var labels: [String]
    public var dependencies: [WorkItemID]
    public var projectId: ProjectID?

    public init(_ item: WorkItem) {
        title = item.title
        transcript = item.transcript
        structuredBody = item.structuredBody
        priority = item.priority
        complexity = item.complexity
        labels = item.labels
        dependencies = item.dependencies
        projectId = item.projectId
    }

    func apply(to item: inout WorkItem) {
        item.title = title
        item.transcript = transcript
        item.structuredBody = structuredBody
        item.priority = priority
        item.complexity = complexity
        item.labels = labels
        item.dependencies = dependencies
        item.projectId = projectId
    }
}

/// Edit, duplicate, assign and undo on top of the optimistic repository (spec H1).
public struct TaskEditor: Sendable {
    public let workItems: any WorkItemRepository

    public init(workItems: any WorkItemRepository) {
        self.workItems = workItems
    }

    /// Saves an edit. Returns the new item and the edit that restores the previous values (undo).
    public func save(_ edit: WorkItemEdit, to item: WorkItem, actor: EventActor, at date: Date) async throws -> (item: WorkItem, undo: WorkItemEdit) {
        let previous = WorkItemEdit(item)
        let updated = try await workItems.update(item.uuid, expectedRevision: item.revision, actor: actor, at: date) {
            edit.apply(to: &$0)
        }
        return (updated, previous)
    }

    /// Assigns an inbox item to a project (spec H1 „Projektzuordnung … nachträglich“) and opens it.
    public func assign(_ item: WorkItem, to project: ProjectID, actor: EventActor, at date: Date) async throws -> WorkItem {
        var updated = try await workItems.update(item.uuid, expectedRevision: item.revision, actor: actor, at: date) {
            $0.projectId = project
        }
        if updated.status == .inbox {
            updated = try await workItems.changeStatus(updated.uuid, to: .open, expectedRevision: updated.revision, actor: actor, at: date)
        }
        return updated
    }

    /// Copy with a new UUID and no human ID, job links or history (ADR-0018).
    public func duplicate(_ item: WorkItem, titleSuffix: String, actor: EventActor, at date: Date) async throws -> WorkItem {
        let copy = WorkItem(
            projectId: item.projectId,
            type: item.type,
            title: item.title + titleSuffix,
            originalNote: item.originalNote,
            transcript: item.transcript,
            structuredBody: item.structuredBody,
            status: item.projectId == nil ? .inbox : .open,
            priority: item.priority,
            complexity: item.complexity,
            labels: item.labels,
            dependencies: item.dependencies,
            createdAt: date
        )
        try await workItems.insert(copy, actor: actor, at: date)
        return copy
    }

    /// Status change by the user; rejected while a job is active (ADR-0012). Returns the previous status for undo.
    public func changeStatus(_ item: WorkItem, to status: WorkItemStatus, actor: EventActor, at date: Date) async throws -> (item: WorkItem, previous: WorkItemStatus) {
        let updated = try await workItems.changeStatus(item.uuid, to: status, expectedRevision: item.revision, actor: actor, at: date)
        return (updated, item.status)
    }

    /// Archives an item (spec H1). Not a status change (ADR-0012); undo with `unarchive`.
    public func archive(_ item: WorkItem, actor: EventActor, at date: Date) async throws -> WorkItem {
        try await workItems.setArchived(item.uuid, true, expectedRevision: item.revision, actor: actor, at: date)
    }

    public func unarchive(_ item: WorkItem, actor: EventActor, at date: Date) async throws -> WorkItem {
        try await workItems.setArchived(item.uuid, false, expectedRevision: item.revision, actor: actor, at: date)
    }

    /// Changes the item type (reclassification, spec H3/F1) with revision bump and `typeChanged` event.
    /// Returns the previous type for undo. Refused once the Mac assigned a human ID or with an active job.
    public func reclassify(_ item: WorkItem, to type: WorkItemType, actor: EventActor, at date: Date) async throws -> (item: WorkItem, previous: WorkItemType) {
        let updated = try await workItems.reclassify(item.uuid, to: type, expectedRevision: item.revision, actor: actor, at: date)
        return (updated, item.type)
    }

    /// Whether the type can still be changed (ADR-0018: not after the Mac assigned a number).
    public static func canReclassify(_ item: WorkItem, hasActiveJob: Bool) -> Bool {
        item.humanId == nil && !hasActiveJob
    }

    /// Statuses the user may pick manually from `status` (state machine, ADR-0012).
    public static func manualTargets(from status: WorkItemStatus, hasActiveJob: Bool) -> [WorkItemStatus] {
        guard !hasActiveJob else { return [] }
        return WorkItemStatus.allCases.filter { (try? status.validateManualChange(to: $0, hasActiveJob: false)) != nil }
    }
}

/// Field-level view of a work item sync conflict (spec N2, A24: both versions kept, user decides).
public struct WorkItemConflictComparison: Hashable, Sendable {
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case title, status, priority, transcript, structuredBody, labels, dependencies, projectId, reviewState, complexity
    }

    public let local: WorkItem?
    public let remote: WorkItem?
    public let differingFields: [Field]

    public init(conflict: SyncConflict) throws {
        let decoder = SyncPayloadCodec.self
        local = try conflict.localPayload.map { try decoder.decode(WorkItem.self, from: $0) }
        remote = try conflict.remotePayload.map { try decoder.decode(WorkItem.self, from: $0) }
        differingFields = Self.diff(local, remote)
    }

    static func diff(_ a: WorkItem?, _ b: WorkItem?) -> [Field] {
        guard let a, let b else { return Field.allCases }
        var fields: [Field] = []
        if a.title != b.title { fields.append(.title) }
        if a.status != b.status { fields.append(.status) }
        if a.priority != b.priority { fields.append(.priority) }
        if a.transcript != b.transcript { fields.append(.transcript) }
        if a.structuredBody != b.structuredBody { fields.append(.structuredBody) }
        if a.labels != b.labels { fields.append(.labels) }
        if a.dependencies != b.dependencies { fields.append(.dependencies) }
        if a.projectId != b.projectId { fields.append(.projectId) }
        if a.reviewState != b.reviewState { fields.append(.reviewState) }
        if a.complexity != b.complexity { fields.append(.complexity) }
        return fields
    }
}
