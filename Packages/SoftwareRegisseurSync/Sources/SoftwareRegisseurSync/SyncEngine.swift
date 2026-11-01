import CloudKit
import Foundation

/// The part of `CKSyncEngine` the coordinator uses (ADR-0019). The real engine is wrapped by
/// `CloudKitSyncEngineAdapter`; tests use `FakeSyncEngine` against an in-memory server, so both run the
/// same `SyncCoordinator` logic.
///
/// Semantics follow `CKSyncEngine` with `automaticallySync = false`: nothing happens until
/// `fetchChanges()`/`sendChanges()` is called, and both return after the handler processed all events.
public protocol SyncEngine: AnyObject, Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { get }
    /// Duplicates are ignored, as in `CKSyncEngine.State`.
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    /// Drops queued zone saves/deletions (`CKSyncEngine.State.remove(pendingDatabaseChanges:)`). Used before
    /// a user-requested zone deletion, so nothing but the deletion is sent.
    func remove(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func fetchChanges() async throws
    func sendChanges() async throws
}

extension SyncEngine {
    /// Default for engines written before zone deletion existed: they never queue a zone deletion, so
    /// there is nothing to drop. Both engines of this package implement it.
    public func remove(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {}
}

/// Receives engine events (the `CKSyncEngineDelegate` role). Engines hold the handler weakly.
public protocol SyncEngineEventHandler: AnyObject, Sendable {
    func handle(_ event: SyncEngineEvent) async
    /// Records for the next send request; at most `SyncRecordSchema.maxRecordsPerBatch` entries.
    func nextRecordZoneChangeBatch(pending: [CKSyncEngine.PendingRecordZoneChange]) async -> SyncRecordBatch?
}

/// Everything an engine factory needs to create an engine for one coordinator.
public struct SyncEngineSetup: Sendable {
    /// Last persisted state serialization (stored through `GRDBSyncStore.saveEngineState`).
    public let stateSerialization: Data?
    public let handler: any SyncEngineEventHandler
    public let zoneID: CKRecordZone.ID

    public init(stateSerialization: Data?, handler: any SyncEngineEventHandler, zoneID: CKRecordZone.ID) {
        self.stateSerialization = stateSerialization
        self.handler = handler
        self.zoneID = zoneID
    }
}

public typealias SyncEngineFactory = @Sendable (SyncEngineSetup) throws -> any SyncEngine

public enum SyncAccountChange: Sendable, Equatable {
    case signedIn(userRecordName: String)
    case signedOut(previousUserRecordName: String)
    case switched(previousUserRecordName: String, currentUserRecordName: String)
}

public enum ZoneDeletionReason: String, Sendable, Codable, Equatable {
    /// Deleted by this app or another device of the user.
    case deleted
    /// The user deleted the app's iCloud data in Settings.
    case purged
    /// The user reset end-to-end encrypted data (Advanced Data Protection / Keychain reset).
    case encryptedDataReset
}

public struct SyncZoneDeletion: Sendable {
    public let zoneID: CKRecordZone.ID
    public let reason: ZoneDeletionReason

    public init(zoneID: CKRecordZone.ID, reason: ZoneDeletionReason) {
        self.zoneID = zoneID
        self.reason = reason
    }
}

public struct SyncRecordDeletion: Sendable {
    public let recordID: CKRecord.ID
    public let recordType: CKRecord.RecordType

    public init(recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        self.recordID = recordID
        self.recordType = recordType
    }
}

public struct SyncFailedRecordSave: Sendable {
    public let record: CKRecord
    public let error: CKError

    public init(record: CKRecord, error: CKError) {
        self.record = record
        self.error = error
    }
}

/// A zone deletion the server refused (`CKSyncEngine.Event.SentDatabaseChanges.failedZoneDeletes`).
public struct SyncFailedZoneDeletion: Sendable {
    public let zoneID: CKRecordZone.ID
    public let error: CKError

    public init(zoneID: CKRecordZone.ID, error: CKError) {
        self.zoneID = zoneID
        self.error = error
    }
}

public struct SyncFailedZoneSave: Sendable {
    public let zoneID: CKRecordZone.ID
    public let error: CKError

    public init(zoneID: CKRecordZone.ID, error: CKError) {
        self.zoneID = zoneID
        self.error = error
    }
}

public struct SyncSentRecordZoneChanges: Sendable {
    public let savedRecords: [CKRecord]
    public let failedRecordSaves: [SyncFailedRecordSave]
    public let deletedRecordIDs: [CKRecord.ID]
    public let failedRecordDeletes: [CKRecord.ID: CKError]

    public init(
        savedRecords: [CKRecord] = [],
        failedRecordSaves: [SyncFailedRecordSave] = [],
        deletedRecordIDs: [CKRecord.ID] = [],
        failedRecordDeletes: [CKRecord.ID: CKError] = [:]
    ) {
        self.savedRecords = savedRecords
        self.failedRecordSaves = failedRecordSaves
        self.deletedRecordIDs = deletedRecordIDs
        self.failedRecordDeletes = failedRecordDeletes
    }
}

/// Engine-agnostic mirror of the `CKSyncEngine.Event` cases the coordinator reacts to.
public enum SyncEngineEvent: Sendable {
    /// Serialized engine state; persist it (it covers all changes delivered before it).
    case stateUpdate(Data)
    case accountChange(SyncAccountChange)
    case fetchedDatabaseChanges(deletedZones: [SyncZoneDeletion])
    case fetchedRecordZoneChanges(modifications: [CKRecord], deletions: [SyncRecordDeletion])
    case sentDatabaseChanges(savedZoneIDs: [CKRecordZone.ID], failedZoneSaves: [SyncFailedZoneSave])
    /// Result of sending queued zone deletions (user-requested deletion of the iCloud data, A34).
    case sentZoneDeletions(deletedZoneIDs: [CKRecordZone.ID], failedZoneDeletions: [SyncFailedZoneDeletion])
    case sentRecordZoneChanges(SyncSentRecordZoneChanges)
}

public struct SyncRecordBatch: Sendable {
    public var recordsToSave: [CKRecord]
    public var recordIDsToDelete: [CKRecord.ID]

    public init(recordsToSave: [CKRecord] = [], recordIDsToDelete: [CKRecord.ID] = []) {
        self.recordsToSave = recordsToSave
        self.recordIDsToDelete = recordIDsToDelete
    }

    public var count: Int { recordsToSave.count + recordIDsToDelete.count }
    public var isEmpty: Bool { count == 0 }
}

extension CKSyncEngine.PendingRecordZoneChange {
    public var recordID: CKRecord.ID {
        switch self {
        case let .saveRecord(id), let .deleteRecord(id): id
        @unknown default: CKRecord.ID(recordName: "")
        }
    }
}
