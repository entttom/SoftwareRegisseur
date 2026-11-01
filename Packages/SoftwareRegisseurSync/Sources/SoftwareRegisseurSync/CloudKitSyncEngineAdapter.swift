import CloudKit
import Foundation

/// Production `SyncEngine` backed by `CKSyncEngine` on the private database (ADR-0019, ADR-0011).
///
/// - `automaticallySync = false`: CloudKit is contacted only from `fetchChanges()`/`sendChanges()`.
/// - Requires the CloudKit **and** Remote Notifications entitlements in a signed build (CKSyncEngine
///   uses silent pushes internally; no user-visible notification and no permission prompt; N3).
/// - Not integration-tested in this package: unsigned `swift test` runs have no iCloud entitlement.
///   Coverage comes from `FakeSyncEngine` (same coordinator logic) plus the manual steps in the report.
public final class CloudKitSyncEngineAdapter: SyncEngine {
    private let engine: CKSyncEngine
    private let delegate: Delegate

    /// - Parameter automaticallySync: keep `false` (ADR-0011 explicit triggers). apple-platform.md §2.1
    ///   allows `true` on iOS as an opportunistic optimization; pass it explicitly if decided so.
    public init(setup: SyncEngineSetup, database: CKDatabase, automaticallySync: Bool = false) throws {
        let serialization = try setup.stateSerialization.map {
            try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        delegate = Delegate(handler: setup.handler, zoneID: setup.zoneID)
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: delegate)
        configuration.automaticallySync = automaticallySync
        engine = CKSyncEngine(configuration)
    }

    /// Factory for `SyncCoordinator` using the container's private database (Q1: private DB only).
    public static func factory(containerIdentifier: String, automaticallySync: Bool = false) -> SyncEngineFactory {
        { setup in
            try CloudKitSyncEngineAdapter(
                setup: setup,
                database: CKContainer(identifier: containerIdentifier).privateCloudDatabase,
                automaticallySync: automaticallySync
            )
        }
    }

    public var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { engine.state.pendingRecordZoneChanges }
    public var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { engine.state.pendingDatabaseChanges }

    public func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    public func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        engine.state.remove(pendingRecordZoneChanges: changes)
    }

    public func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        engine.state.add(pendingDatabaseChanges: changes)
    }

    public func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        engine.state.remove(pendingDatabaseChanges: changes)
    }

    public func fetchChanges() async throws {
        try await engine.fetchChanges()
    }

    public func sendChanges() async throws {
        try await engine.sendChanges()
    }

    /// Translates `CKSyncEngine` delegate callbacks into `SyncEngineEvent`s.
    final class Delegate: CKSyncEngineDelegate {
        weak let handler: (any SyncEngineEventHandler)?
        let zoneID: CKRecordZone.ID

        init(handler: any SyncEngineEventHandler, zoneID: CKRecordZone.ID) {
            self.handler = handler
            self.zoneID = zoneID
        }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            guard let handler else { return }
            for translated in Self.translateAll(event) {
                await handler.handle(translated)
            }
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            guard let handler else { return nil }
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
            guard !pending.isEmpty, let batch = await handler.nextRecordZoneChangeBatch(pending: pending) else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.recordsToSave, recordIDsToDelete: batch.recordIDsToDelete)
        }

        /// All engine-agnostic events for one `CKSyncEngine` event (sent database changes can carry zone
        /// saves and zone deletions at once).
        static func translateAll(_ event: CKSyncEngine.Event) -> [SyncEngineEvent] {
            guard case let .sentDatabaseChanges(changes) = event else { return translate(event).map { [$0] } ?? [] }
            var events: [SyncEngineEvent] = []
            if !changes.savedZones.isEmpty || !changes.failedZoneSaves.isEmpty || changes.deletedZoneIDs.isEmpty && changes.failedZoneDeletes.isEmpty {
                events.append(.sentDatabaseChanges(
                    savedZoneIDs: changes.savedZones.map(\.zoneID),
                    failedZoneSaves: changes.failedZoneSaves.map { SyncFailedZoneSave(zoneID: $0.zone.zoneID, error: $0.error) }
                ))
            }
            if !changes.deletedZoneIDs.isEmpty || !changes.failedZoneDeletes.isEmpty {
                events.append(.sentZoneDeletions(
                    deletedZoneIDs: changes.deletedZoneIDs,
                    failedZoneDeletions: changes.failedZoneDeletes.map { SyncFailedZoneDeletion(zoneID: $0.key, error: $0.value) }
                ))
            }
            return events
        }

        static func translate(_ event: CKSyncEngine.Event) -> SyncEngineEvent? {
            switch event {
            case let .stateUpdate(update):
                guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return nil }
                return .stateUpdate(data)
            case let .accountChange(change):
                switch change.changeType {
                case let .signIn(currentUser):
                    return .accountChange(.signedIn(userRecordName: currentUser.recordName))
                case let .signOut(previousUser):
                    return .accountChange(.signedOut(previousUserRecordName: previousUser.recordName))
                case let .switchAccounts(previousUser, currentUser):
                    return .accountChange(.switched(previousUserRecordName: previousUser.recordName,
                                                    currentUserRecordName: currentUser.recordName))
                @unknown default:
                    return nil
                }
            case let .fetchedDatabaseChanges(changes):
                let deletions = changes.deletions.map { deletion -> SyncZoneDeletion in
                    let reason: ZoneDeletionReason = switch deletion.reason {
                    case .deleted: .deleted
                    case .purged: .purged
                    case .encryptedDataReset: .encryptedDataReset
                    @unknown default: .deleted
                    }
                    return SyncZoneDeletion(zoneID: deletion.zoneID, reason: reason)
                }
                return deletions.isEmpty ? nil : .fetchedDatabaseChanges(deletedZones: deletions)
            case let .fetchedRecordZoneChanges(changes):
                return .fetchedRecordZoneChanges(
                    modifications: changes.modifications.map(\.record),
                    deletions: changes.deletions.map { SyncRecordDeletion(recordID: $0.recordID, recordType: $0.recordType) }
                )
            case let .sentDatabaseChanges(changes):
                return .sentDatabaseChanges(
                    savedZoneIDs: changes.savedZones.map(\.zoneID),
                    failedZoneSaves: changes.failedZoneSaves.map { SyncFailedZoneSave(zoneID: $0.zone.zoneID, error: $0.error) }
                )
            case let .sentRecordZoneChanges(changes):
                return .sentRecordZoneChanges(SyncSentRecordZoneChanges(
                    savedRecords: changes.savedRecords,
                    failedRecordSaves: changes.failedRecordSaves.map { SyncFailedRecordSave(record: $0.record, error: $0.error) },
                    deletedRecordIDs: changes.deletedRecordIDs,
                    failedRecordDeletes: changes.failedRecordDeletes
                ))
            case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges,
                 .willSendChanges, .didSendChanges:
                return nil
            @unknown default:
                return nil
            }
        }
    }
}
