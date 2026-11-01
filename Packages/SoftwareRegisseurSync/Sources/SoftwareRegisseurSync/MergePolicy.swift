import Foundation
import SoftwareRegisseurPersistence

/// How a `serverRecordChanged` collision is resolved per entity kind (spec N2/N3, ADR-0012).
/// Identical payloads always merge trivially (adopt the server change tag, no conflict).
public enum SyncMergePolicy: String, Sendable, Equatable {
    /// User-editable content: keep both versions as `SyncConflict`; the user decides (no silent
    /// last-writer-wins, A24).
    case keepBothForUser
    /// Execution metadata owned by the Mac host (N2: jobs, locks, host/capability state, repository
    /// paths). On the host the local value is re-sent on top of the server record; other devices adopt the
    /// server value. Either way the collision is recorded as a resolved `SyncConflict` for traceability.
    case executionHostWins
    /// Append-only history (task events): never edited, so the server copy is adopted.
    case appendOnly

    public static func policy(for type: SyncEntityType) -> SyncMergePolicy {
        switch type {
        case .agentJob, .taskLock, .agentHost, .agentCapability, .repositoryLocation:
            .executionHostWins
        // Created on the iPhone, executed by the Mac: the Mac owns state, failure and result path (E2).
        case .projectSetupCommand:
            .executionHostWins
        // The Mac's folder index is authoritative (E1/E2, N2: Mac owns local paths).
        case .indexedFolder:
            .executionHostWins
        // Approval requests mirror the agent session on the Mac (J6, L3).
        case .pendingApproval:
            .executionHostWins
        case .taskEvent:
            .appendOnly
        // Explicit user decisions are immutable; the host takes the first applicable one.
        case .approvalDecision:
            .appendOnly
        case .project, .projectSettings, .workItem, .adr, .audioNote, .aiRequest, .aiConversation,
             .agentModelPreference, .review, .gitHubIssueLink, .providerProfile:
            .keepBothForUser
        // Resolved by the user on either device; concurrent choices are shown, never dropped (N2).
        case .fileConflict:
            .keepBothForUser
        case .draftVersion, .globalSettings:
            .keepBothForUser
        }
    }

    /// Automatic resolution of a conflict detected while sending; nil = leave it open for the user.
    func automaticResolution(role: DeviceRole) -> ConflictResolution? {
        switch self {
        case .keepBothForUser: nil
        case .executionHostWins: role.isExecutionHost ? .keepLocal : .acceptRemote
        case .appendOnly: .acceptRemote
        }
    }
}
