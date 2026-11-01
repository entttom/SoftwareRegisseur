import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Entity kinds known to persistence and sync. The raw value is the stable record type name used in
/// outbox rows and (later) CloudKit record types.
public enum SyncEntityType: String, Hashable, Sendable, Codable, CaseIterable {
    case project
    case projectSettings
    case repositoryLocation
    case workItem
    case adr
    case audioNote
    case aiRequest
    case aiConversation
    case agentHost
    case agentCapability
    case agentModelPreference
    case agentJob
    case taskLock
    case taskEvent
    case review
    case gitHubIssueLink
    case providerProfile
    // v4: cross-device contracts (appended; raw values are CloudKit record identities).
    /// `CreateProject`/`LinkProject` command: created on any device, state owned by the Mac (E2).
    case projectSetupCommand
    /// Folder index of a Mac host (E1/E2); Mac authoritative.
    case indexedFolder
    /// Database ↔ file/GitHub conflict; the user resolves it on any device (N2).
    case fileConflict
    /// Agent approval request mirrored by the Mac (J6 V1 fallback, L3).
    case pendingApproval
    /// Immutable user decision for a pending approval.
    case approvalDecision
    /// Original/transcript/AI draft versions of a work item (H3).
    case draftVersion
    /// User-wide defaults (F2, J2).
    case globalSettings

    /// Device-local entity kinds that never enter the outbox (spec N1: audio stays on the device).
    /// Provider profiles additionally sync only when their key lives in the iCloud Keychain.
    public var isDeviceLocal: Bool { self == .audioNote }

    var storage: any EntityStorage.Type {
        switch self {
        case .project: ProjectStorage.self
        case .projectSettings: ProjectSettingsStorage.self
        case .repositoryLocation: RepositoryLocationStorage.self
        case .workItem: WorkItemStorage.self
        case .adr: ADRStorage.self
        case .audioNote: AudioNoteStorage.self
        case .aiRequest: AIRequestStorage.self
        case .aiConversation: AIConversationStorage.self
        case .agentHost: AgentHostStorage.self
        case .agentCapability: AgentCapabilityStorage.self
        case .agentModelPreference: AgentModelPreferenceStorage.self
        case .agentJob: AgentJobStorage.self
        case .taskLock: TaskLockStorage.self
        case .taskEvent: TaskEventStorage.self
        case .review: ReviewStorage.self
        case .gitHubIssueLink: GitHubIssueLinkStorage.self
        case .providerProfile: ProviderProfileStorage.self
        case .projectSetupCommand: ProjectSetupCommandStorage.self
        case .indexedFolder: IndexedFolderStorage.self
        case .fileConflict: FileConflictStorage.self
        case .pendingApproval: PendingApprovalStorage.self
        case .approvalDecision: ApprovalDecisionStorage.self
        case .draftVersion: DraftVersionStorage.self
        case .globalSettings: GlobalSettingsStorage.self
        }
    }
}

/// Row mapping of one domain entity plus what the sync bookkeeping needs. Internal: the public API
/// is the repositories and `GRDBSyncStore`.
protocol EntityStorage {
    associatedtype Entity: Codable & Sendable & Equatable
    static var entityType: SyncEntityType { get }
    /// Stable sync identity; deterministic UUIDv5 for composite natural keys.
    static func syncID(of entity: Entity) -> UUID
    static func fetch(_ db: Database, syncID: UUID) throws -> Entity?
    /// Upsert of all rows belonging to the entity.
    static func save(_ db: Database, _ entity: Entity) throws
    static func delete(_ db: Database, syncID: UUID) throws
    /// Whether this value is synced at all (spec N1).
    static func shouldSync(_ entity: Entity) -> Bool
    /// Value sent to other devices; strips parts that sync as their own entities.
    static func syncPayload(_ entity: Entity) -> Entity
}

extension EntityStorage {
    static func shouldSync(_ entity: Entity) -> Bool { !entityType.isDeviceLocal }
    static func syncPayload(_ entity: Entity) -> Entity { entity }

    static func payloadData(_ entity: Entity) throws -> Data {
        try JSONColumn.encodeData(syncPayload(entity))
    }

    static func decodePayload(_ data: Data) throws -> Entity {
        do {
            return try JSONColumn.decode(Entity.self, from: data)
        } catch {
            throw StoreError.invalidRemoteChange("\(entityType.rawValue) payload: \(error)")
        }
    }

    static func fetchPayload(_ db: Database, syncID: UUID) throws -> Data? {
        try fetch(db, syncID: syncID).map(payloadData)
    }

    static func savePayload(_ db: Database, _ data: Data, expectedSyncID: UUID) throws {
        let entity = try decodePayload(data)
        guard syncID(of: entity) == expectedSyncID else {
            throw StoreError.invalidRemoteChange("\(entityType.rawValue) payload ID does not match entity ID")
        }
        try save(db, entity)
    }

    static func exists(_ db: Database, syncID: UUID) throws -> Bool {
        try fetch(db, syncID: syncID) != nil
    }
}
