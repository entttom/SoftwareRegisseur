import Foundation

/// Name of the app's custom record zone in the user's private CloudKit database. Single source for the
/// sync layer (`SyncRecordSchema.zoneName`) and for data deletion (`LocalDataEraser.cloudZoneName`), so a
/// deletion request always names the zone the coordinator actually syncs.
public enum CloudSyncZone {
    public static let name = "SoftwareRegisseur"
}

/// Instruction for the sync layer: delete the app's record zone in the user's private database
/// (spec Q1 "transparente Löschung", A34). Created only from a confirmed `CloudDeletionPlan`
/// (SoftwareRegisseurPortability) and carried out only by `SyncCoordinator.deleteCloudData(_:)`.
///
/// Lives in Persistence so Portability (which issues it) and Sync (which performs it) share one type
/// without depending on each other.
public struct CloudDataDeletionRequest: Hashable, Sendable, Codable, Identifiable {
    public enum Scope: String, Hashable, Sendable, Codable {
        /// The whole app zone (all synced records, including tombstones).
        case entireZone
    }

    public let id: UUID
    public let zoneName: String
    public let scope: Scope
    public let requestedAt: Date
    /// After deletion the coordinator must not re-create the zone or re-upload local data on its own.
    public let suppressAutomaticReupload: Bool

    public init(id: UUID, zoneName: String, scope: Scope, requestedAt: Date, suppressAutomaticReupload: Bool) {
        self.id = id
        self.zoneName = zoneName
        self.scope = scope
        self.requestedAt = requestedAt
        self.suppressAutomaticReupload = suppressAutomaticReupload
    }
}
