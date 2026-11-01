import Foundation
import SoftwareRegisseurDomain

/// Errors of this package. (Named `StoreError` to avoid clashing with GRDB's `PersistenceError`.)
public enum StoreError: Error, Hashable, Sendable {
    /// Write attempted through a read-only connection (macOS UI process, ADR-0019).
    case readOnlyDatabase
    /// The database file has not been migrated to the schema this build expects.
    case schemaNotReady
    /// The database was migrated by a newer build (unknown migrations).
    case schemaTooNew
    case notFound(entity: SyncEntityType, id: String)
    case alreadyExists(entity: SyncEntityType, id: String)
    /// Optimistic concurrency: stored revision differs from the caller's base revision (spec O).
    case revisionConflict(entity: SyncEntityType, id: String, expected: Int, actual: Int)
    case corruptValue(column: String, detail: String)

    // Projects
    case projectHasWorkItems(ProjectID)
    case invalidProjectTransition(InvalidStateTransition<ProjectStatus>)
    case invalidADRTransition(InvalidStateTransition<ADRStatus>)
    case settingsMismatch(projectId: ProjectID)

    // Work items
    case workItemStatusChange(WorkItemStatusChangeError)
    case invalidWorkItemTransition(InvalidStateTransition<WorkItemStatus>)
    /// Human IDs are assigned only through `HumanIDAllocator` and never change (ADR-0018).
    case humanIDChangeNotAllowed(WorkItemID)
    case humanID(WorkItemError)
    case duplicateHumanID(HumanID, projectId: ProjectID)
    case workItemWithoutProject(WorkItemID)
    case identityFieldChanged(entity: SyncEntityType, field: String)

    // Jobs
    case jobError(AgentJobError)
    /// A15: the work item already has a non-terminal job.
    case activeJobExists(workItemId: WorkItemID, jobId: JobID)
    case jobWorkItemMismatch(jobId: JobID)

    // Locks
    case lockHeld(existing: LockID, scope: LockScope)
    case lockReleaseRefused(LockReleaseDecision)
    case lockError(TaskLockError)

    // Approvals (v4)
    /// The approval was already answered, expired or withdrawn; later decisions are ignored.
    case approvalClosed(PendingApprovalID, PendingApprovalState)
    case approvalDecisionNotAllowed(PendingApprovalID, ApprovalDecisionKind)
    /// Work item reclassification refused (human ID assigned or active job, ADR-0012/0018).
    case reclassificationRefused(WorkItemError)
    /// Global settings with an invalid folder layout (absolute path or traversal).
    case invalidSettings(String)

    // Sync
    case conflictAlreadyResolved(UUID)
    case invalidRemoteChange(String)
}
