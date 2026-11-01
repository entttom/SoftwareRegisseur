import CloudKit
import Foundation
import SoftwareRegisseurSync
import Synchronization

/// Network and iCloud account of one simulated device, controlled by the test.
public final class FakeDeviceConnection: Sendable {
    private struct State {
        var isOnline = true
        var userRecordName: String?
    }

    private let state: Mutex<State>

    public init(userRecordName: String? = "_user-default", isOnline: Bool = true) {
        state = Mutex(State(isOnline: isOnline, userRecordName: userRecordName))
    }

    public var isOnline: Bool {
        get { state.withLock { $0.isOnline } }
        set { state.withLock { $0.isOnline = newValue } }
    }

    /// nil = signed out of iCloud.
    public var userRecordName: String? {
        get { state.withLock { $0.userRecordName } }
        set { state.withLock { $0.userRecordName = newValue } }
    }
}

/// `SyncEngine` that behaves like `CKSyncEngine` with `automaticallySync = false` against a
/// `FakeCloudDatabase`: persisted state (change token, pending changes, known account) via
/// `.stateUpdate`, account-change events, paged fetch events, ≤ 250 records per request, failed
/// non-retryable saves removed from the pending list (the app re-adds them), transient ones kept.
public final class FakeSyncEngine: SyncEngine {
    struct State: Codable {
        var changeToken = 0
        var pendingSaves: [String] = []
        var pendingDeletes: [String] = []
        var pendingZoneSave = false
        /// Optional so states serialized before zone deletion existed still decode.
        var pendingZoneDelete: Bool?
        var knownUserRecordName: String?
    }

    public static let fetchPageSize = 100

    private let state: Mutex<State>
    private weak let handler: (any SyncEngineEventHandler)?
    private let server: FakeCloudDatabase
    private let connection: FakeDeviceConnection
    private let zoneID: CKRecordZone.ID

    public init(setup: SyncEngineSetup, server: FakeCloudDatabase, connection: FakeDeviceConnection) throws {
        let restored = try setup.stateSerialization.map { try JSONDecoder().decode(State.self, from: $0) }
        state = Mutex(restored ?? State())
        handler = setup.handler
        self.server = server
        self.connection = connection
        zoneID = setup.zoneID
    }

    public static func factory(server: FakeCloudDatabase, connection: FakeDeviceConnection) -> SyncEngineFactory {
        { setup in try FakeSyncEngine(setup: setup, server: server, connection: connection) }
    }

    // MARK: Test controls

    public var changeToken: Int { state.withLock { $0.changeToken } }

    /// Simulates a lost state update (e.g. crash before persisting): records are delivered again.
    public func rewindChangeToken(to token: Int = 0) {
        state.withLock { $0.changeToken = token }
    }

    // MARK: SyncEngine

    public var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        state.withLock { state in
            state.pendingSaves.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) }
                + state.pendingDeletes.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) }
        }
    }

    public var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] {
        state.withLock { state in
            (state.pendingZoneSave ? [.saveZone(CKRecordZone(zoneID: zoneID))] : [])
                + (state.pendingZoneDelete == true ? [.deleteZone(zoneID)] : [])
        }
    }

    public func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        state.withLock { state in
            for change in changes where change.recordID.zoneID == zoneID {
                switch change {
                case let .saveRecord(id):
                    if !state.pendingSaves.contains(id.recordName) { state.pendingSaves.append(id.recordName) }
                case let .deleteRecord(id):
                    if !state.pendingDeletes.contains(id.recordName) { state.pendingDeletes.append(id.recordName) }
                @unknown default:
                    break
                }
            }
        }
    }

    public func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        state.withLock { state in
            for change in changes {
                switch change {
                case let .saveRecord(id): state.pendingSaves.removeAll { $0 == id.recordName }
                case let .deleteRecord(id): state.pendingDeletes.removeAll { $0 == id.recordName }
                @unknown default: break
                }
            }
        }
    }

    public func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        state.withLock { state in
            for change in changes {
                switch change {
                case let .saveZone(zone) where zone.zoneID == zoneID:
                    // Like `CKSyncEngine.State`: the later change for the same zone replaces the earlier one.
                    state.pendingZoneSave = true
                    state.pendingZoneDelete = nil
                case let .deleteZone(id) where id == zoneID:
                    state.pendingZoneDelete = true
                    state.pendingZoneSave = false
                default:
                    break
                }
            }
        }
    }

    public func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        state.withLock { state in
            for change in changes {
                switch change {
                case let .saveZone(zone) where zone.zoneID == zoneID: state.pendingZoneSave = false
                case let .deleteZone(id) where id == zoneID: state.pendingZoneDelete = nil
                default: break
                }
            }
        }
    }

    public func fetchChanges() async throws {
        guard let handler else { return }
        try await checkConnection(handler)
        let token = changeToken
        let result = try await server.fetchChanges(since: token, zoneID: zoneID)
        if !result.deletedZones.isEmpty {
            await handler.handle(.fetchedDatabaseChanges(deletedZones: result.deletedZones))
        }
        var pages = stride(from: 0, to: result.modifications.count, by: Self.fetchPageSize).map {
            Array(result.modifications[$0..<min($0 + Self.fetchPageSize, result.modifications.count)])
        }
        if pages.isEmpty { pages = [[]] }
        for (index, page) in pages.enumerated() {
            let deletions = index == pages.count - 1 ? result.deletions : []
            if !page.isEmpty || !deletions.isEmpty {
                await handler.handle(.fetchedRecordZoneChanges(modifications: page, deletions: deletions))
            }
        }
        state.withLock { $0.changeToken = result.newToken }
        await handler.handle(.stateUpdate(serialized()))
    }

    public func sendChanges() async throws {
        guard let handler else { return }
        try await checkConnection(handler)
        if state.withLock({ $0.pendingZoneDelete == true }) {
            // Transient errors propagate and keep the deletion pending, like `CKSyncEngine`.
            let failure = try await server.deleteZoneRequest(zoneID)
            state.withLock { $0.pendingZoneDelete = nil }
            await handler.handle(.sentZoneDeletions(
                deletedZoneIDs: failure == nil ? [zoneID] : [],
                failedZoneDeletions: failure.map { [SyncFailedZoneDeletion(zoneID: zoneID, error: $0)] } ?? []
            ))
            await handler.handle(.stateUpdate(serialized()))
        }
        if state.withLock({ $0.pendingZoneSave }) {
            do {
                try await server.saveZone(zoneID)
                state.withLock { $0.pendingZoneSave = false }
                await handler.handle(.sentDatabaseChanges(savedZoneIDs: [zoneID], failedZoneSaves: []))
            } catch let error as CKError where !SyncErrorText.isTransient(error.code) {
                await handler.handle(.sentDatabaseChanges(savedZoneIDs: [], failedZoneSaves: [SyncFailedZoneSave(zoneID: zoneID, error: error)]))
            }
        }
        var attempted = Set<String>()
        while true {
            let candidates = pendingRecordZoneChanges.filter { !attempted.contains($0.recordID.recordName) }
            guard !candidates.isEmpty,
                  let batch = await handler.nextRecordZoneChangeBatch(pending: candidates), !batch.isEmpty
            else { break }
            batch.recordsToSave.forEach { attempted.insert($0.recordID.recordName) }
            batch.recordIDsToDelete.forEach { attempted.insert($0.recordName) }
            let result = try await server.modify(saving: batch.recordsToSave, deleting: batch.recordIDsToDelete)
            state.withLock { state in
                let done = Set(result.saved.map(\.recordID.recordName))
                    .union(result.failedSaves.filter { !SyncErrorText.isTransient($0.error.code) }.map(\.record.recordID.recordName))
                state.pendingSaves.removeAll { done.contains($0) }
                let deleted = Set(result.deleted.map(\.recordName))
                state.pendingDeletes.removeAll { deleted.contains($0) }
            }
            await handler.handle(.sentRecordZoneChanges(SyncSentRecordZoneChanges(
                savedRecords: result.saved, failedRecordSaves: result.failedSaves, deletedRecordIDs: result.deleted
            )))
            await handler.handle(.stateUpdate(serialized()))
        }
    }

    // MARK: Internals

    /// Account changes are noticed on the next operation, like the real engine after `CKAccountChanged`.
    private func checkConnection(_ handler: any SyncEngineEventHandler) async throws {
        let current = connection.userRecordName
        let known = state.withLock { $0.knownUserRecordName }
        if current != known {
            state.withLock { $0.knownUserRecordName = current }
            let change: SyncAccountChange? = switch (known, current) {
            case let (nil, user?): .signedIn(userRecordName: user)
            case let (previous?, nil): .signedOut(previousUserRecordName: previous)
            case let (previous?, user?): .switched(previousUserRecordName: previous, currentUserRecordName: user)
            case (nil, nil): nil
            }
            if let change {
                await handler.handle(.accountChange(change))
                await handler.handle(.stateUpdate(serialized()))
            }
        }
        guard current != nil else { throw CKError(.notAuthenticated) }
        guard connection.isOnline else { throw CKError(.networkUnavailable) }
    }

    private func serialized() -> Data {
        (try? JSONEncoder().encode(state.withLock { $0 })) ?? Data()
    }
}
