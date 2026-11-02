import CloudKit
import CryptoKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Anything that can run a sync on request (coordinator, or a test double for the scheduler).
public protocol SyncTriggering: Sendable {
    func syncNow(reason: SyncReason) async -> SyncRunResult
}

public struct SyncConfiguration: Sendable {
    public var deviceId: DeviceID
    public var role: DeviceRole
    public var zoneID: CKRecordZone.ID
    /// Records per send request; clamped to CloudKit's 250 (apple-platform.md §2).
    public var batchSize: Int
    /// Re-send passes within one run after merges/zone recreation.
    public var maxSendPasses: Int
    /// Page size when reading the outbox; all pages are drained within one run.
    public var outboxScanLimit: Int
    /// Entities re-queued per transaction during a full re-upload (zone loss, account switch).
    public var fullUploadBatchSize: Int
    public var engineStateScope: String
    public var metadataScope: String
    public var assetDirectory: URL
    /// CloudKit environment this build talks to (`Production`, ADR-0027; from the Info.plist). Engine state
    /// and server change tags of another environment are discarded on `start()`. nil = not checked.
    public var cloudEnvironment: String?

    public init(
        deviceId: DeviceID,
        role: DeviceRole,
        zoneID: CKRecordZone.ID = SyncRecordSchema.zoneID,
        batchSize: Int = SyncRecordSchema.maxRecordsPerBatch,
        maxSendPasses: Int = 3,
        outboxScanLimit: Int = 5_000,
        fullUploadBatchSize: Int = 500,
        engineStateScope: String = "cloudkit.private",
        metadataScope: String = "cloudkit.coordinator",
        assetDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("SoftwareRegisseurSyncAssets", isDirectory: true),
        cloudEnvironment: String? = nil
    ) {
        self.deviceId = deviceId
        self.role = role
        self.zoneID = zoneID
        self.batchSize = min(max(batchSize, 1), SyncRecordSchema.maxRecordsPerBatch)
        self.maxSendPasses = max(maxSendPasses, 1)
        self.outboxScanLimit = max(outboxScanLimit, 1)
        self.fullUploadBatchSize = max(fullUploadBatchSize, 1)
        self.engineStateScope = engineStateScope
        self.metadataScope = metadataScope
        self.assetDirectory = assetDirectory
        self.cloudEnvironment = cloudEnvironment
    }
}

/// Coordinator state that must survive restarts (stored via `GRDBSyncStore.saveEngineState` under its
/// own scope): sync times for the UI (A26) and pauses that need a user decision.
struct CoordinatorMetadata: Codable, Equatable {
    enum AccountPause: String, Codable { case signedOut, switched }

    var lastSuccessfulFetch: Date?
    var lastSuccessfulSend: Date?
    var knownUserRecordName: String?
    var pendingUserRecordName: String?
    var accountPause: AccountPause?
    var zoneDeletion: ZoneDeletionReason?
    /// Present while a full re-upload is queued or in progress (resumable after a crash).
    var fullUpload: FullUploadState?
    /// The user deleted the app's iCloud data (A34). While set, sync stays paused and nothing re-creates
    /// the zone or uploads again until the user explicitly resumes (`recreateZoneAndResume`).
    var cloudDeletion: CloudDeletionState?
    /// The zone is known to exist on the server (saved or seen by this device). A later `zoneNotFound` then
    /// means it was deleted (by another device or in Settings) and needs a user decision instead of a silent
    /// re-creation. nil = metadata from an earlier build (derived from `lastSuccessfulSend`).
    var zoneConfirmed: Bool?
    /// CloudKit environment the engine state and server change tags belong to. nil = metadata from a build
    /// before ADR-0027 (environment unknown).
    var cloudEnvironment: String?

    struct CloudDeletionState: Codable, Equatable {
        var request: CloudDataDeletionRequest
        var startedAt: Date
        /// nil while the zone deletion has not been confirmed by the server (retry needed).
        var completedAt: Date?
        /// German message of the last failed attempt.
        var lastError: String?
    }

    struct FullUploadState: Codable, Equatable {
        /// nil = start from the beginning (also forgets all server change tags).
        var cursor: SyncEntityCursor?
    }
}

/// Owns the sync engine and translates between CloudKit records and `GRDBSyncStore` (spec N3,
/// ADR-0011, ADR-0019). Sync runs only on explicit triggers (`syncNow`), never because of a push.
public actor SyncCoordinator: SyncEngineEventHandler, SyncTriggering {
    public nonisolated let configuration: SyncConfiguration
    let store: any SyncStore
    let mapper: SyncRecordMapper
    let now: @Sendable () -> Date
    let engineFactory: SyncEngineFactory

    private var engine: (any SyncEngine)?
    private var metadata = CoordinatorMetadata()
    public private(set) var status = SyncStatus()

    private var isRunning = false
    private var rerunRequested = false
    private var report = SyncRunReport()
    private var needsResend = false
    /// Outbox operations carried by each record of the current send, keyed by record name.
    private var inFlight: [String: [SyncOperationID]] = [:]
    /// Server change tags to use instead of the stored ones (entities without sync state).
    private var overrideSystemFields: [String: Data] = [:]
    private var secretRejectedRecords: Set<String> = []
    private var invalidRemoteRecords = 0
    private var newerSchemaSeen = false
    private var quotaExceeded = false
    private var observers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    public init(
        store: any SyncStore,
        configuration: SyncConfiguration,
        now: @escaping @Sendable () -> Date = { Date() },
        engineFactory: @escaping SyncEngineFactory
    ) {
        self.store = store
        self.configuration = configuration
        self.mapper = SyncRecordMapper(zoneID: configuration.zoneID, deviceId: configuration.deviceId,
                                       assetDirectory: configuration.assetDirectory)
        self.now = now
        self.engineFactory = engineFactory
    }

    // MARK: Lifecycle

    /// Restores the persisted engine state and creates the engine. Does not contact CloudKit.
    public func start() async throws {
        guard engine == nil else { return }
        if let data = try await store.engineState(scope: configuration.metadataScope), !data.isEmpty {
            metadata = (try? JSONDecoder().decode(CoordinatorMetadata.self, from: data)) ?? CoordinatorMetadata()
        }
        try await adoptCloudEnvironment()
        // Crash recovery (spec N3): operations handed to CloudKit but never acknowledged are sent again.
        _ = try await store.resetInFlightOperations(at: now())
        try await createEngine()
        status.lastSuccessfulFetch = metadata.lastSuccessfulFetch
        status.lastSuccessfulSend = metadata.lastSuccessfulSend
        status.accountState = switch metadata.accountPause {
        case .signedOut: .signedOut
        case .switched: .switched
        case nil: .unknown
        }
        await refreshCounts()
        publish()
    }

    /// Engine state, server change tags and zone/account confirmations belong to one CloudKit environment.
    /// Before ADR-0027 Xcode Debug builds used Development and release builds Production on the same local
    /// database, so a release build reused Development state: everything counted as sent, and nothing reached
    /// Production. On a different (or unknown) environment the state is discarded and all local data is
    /// uploaded again; local data itself is never touched. A user's iCloud deletion (A34) stays in force.
    private func adoptCloudEnvironment() async throws {
        guard let current = configuration.cloudEnvironment, metadata.cloudEnvironment != current else { return }
        let stored = try await store.engineState(scope: configuration.engineStateScope)
        let syncedBefore = !(stored?.isEmpty ?? true) || metadata.lastSuccessfulFetch != nil || metadata.lastSuccessfulSend != nil
        let previous = metadata.cloudEnvironment ?? "unbekannt"
        metadata.cloudEnvironment = current
        if syncedBefore {
            SyncLog.logger.notice("CloudKit-Umgebung gewechselt (\(previous, privacy: .public) → \(current, privacy: .public)): Synchronisierungsstand verworfen, alle lokalen Daten werden neu hochgeladen.")
            try await store.saveEngineState(Data(), scope: configuration.engineStateScope, at: now())
            metadata.lastSuccessfulFetch = nil
            metadata.lastSuccessfulSend = nil
            // User record names of the other environment say nothing about this one.
            metadata.knownUserRecordName = nil
            metadata.pendingUserRecordName = nil
            if metadata.accountPause == .switched { metadata.accountPause = nil }
            metadata.zoneDeletion = nil
            metadata.zoneConfirmed = false
            scheduleFullUpload()
        }
        await persistMetadata()
    }

    private func createEngine() async throws {
        let stored = try await store.engineState(scope: configuration.engineStateScope)
        let state = stored.flatMap { $0.isEmpty ? nil : $0 }
        let engine = try engineFactory(SyncEngineSetup(stateSerialization: state, handler: self, zoneID: configuration.zoneID))
        if state == nil {
            engine.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: configuration.zoneID))])
        }
        self.engine = engine
    }

    /// Status changes for the UI (A26). The current status is delivered first.
    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publish() {
        for continuation in observers.values { continuation.yield(status) }
    }

    // MARK: Triggers (ADR-0011)

    /// Fetch, then send. Called on app launch, foreground, pull-to-refresh, manual sync, local changes
    /// and by the macOS `PollingScheduler`. Honors CloudKit `retryAfterSeconds` for every reason.
    @discardableResult
    public func syncNow(reason: SyncReason) async -> SyncRunResult {
        guard let engine else { return .paused(.notStarted) }
        if isRunning {
            rerunRequested = true
            return .coalesced
        }
        if let pause = pauseReason(for: reason) {
            await refreshCounts()
            publish()
            return .paused(pause)
        }
        if let notBefore = status.retryNotBefore, now() < notBefore {
            return .deferred(until: notBefore)
        }
        isRunning = true
        status.isSyncing = true
        publish()
        var result: SyncRunResult
        repeat {
            rerunRequested = false
            result = await runOnce(engine, fetch: true)
        } while rerunRequested && result.report != nil
        if let report = result.report {
            SyncLog.logger.info("Abgleich (\(String(describing: reason), privacy: .public)) fertig: gesendet \(report.sent), Fehler beim Senden \(report.sendFailures), neu eingereiht \(report.requeuedForUpload), ungültig \(report.invalid)")
        }
        isRunning = false
        status.isSyncing = false
        await refreshCounts()
        publish()
        return result
    }

    /// Send-only run (e.g. right after a local write when a fetch just happened).
    @discardableResult
    public func sendChanges() async -> SyncRunResult {
        guard let engine else { return .paused(.notStarted) }
        guard !isRunning else { rerunRequested = true; return .coalesced }
        if let pause = pauseReason(for: .localChange) { return .paused(pause) }
        if let notBefore = status.retryNotBefore, now() < notBefore { return .deferred(until: notBefore) }
        isRunning = true
        let result = await runOnce(engine, fetch: false)
        isRunning = false
        await refreshCounts()
        publish()
        return result
    }

    private func pauseReason(for reason: SyncReason) -> SyncPauseReason? {
        // User-requested deletion of the iCloud data: no run of any kind until the user resumes.
        if metadata.cloudDeletion != nil { return .zoneDeleted }
        if metadata.accountPause == .switched { return .accountSwitched }
        if metadata.zoneDeletion != nil { return .zoneDeleted }
        // A user-triggered run still tries (the user may have signed in again); polling waits.
        if metadata.accountPause == .signedOut, reason == .poll { return .accountUnavailable }
        return nil
    }

    private func runOnce(_ engine: any SyncEngine, fetch: Bool) async -> SyncRunResult {
        report = SyncRunReport()
        var recordError: String?
        do {
            try await drainFullUpload()
            if fetch {
                try await engine.fetchChanges()
                if let pause = pauseReason(for: .manual) {
                    await persistMetadata()
                    return .paused(pause)
                }
                metadata.lastSuccessfulFetch = now()
                status.lastSuccessfulFetch = metadata.lastSuccessfulFetch
            }
            recordError = try await sendPending(engine)
            await releaseInFlight()
            if let pause = pauseReason(for: .manual) {
                await persistMetadata()
                return .paused(pause)
            }
            metadata.lastSuccessfulSend = now()
            status.lastSuccessfulSend = metadata.lastSuccessfulSend
            if metadata.accountPause == .signedOut { metadata.accountPause = nil }
            if status.accountState != .switched { status.accountState = .available }
            if recordError == nil { status.retryNotBefore = nil }
            status.lastError = recordError
            await persistMetadata()
            return .completed(report)
        } catch {
            await releaseInFlight()
            let failure = await handleRunError(error)
            await persistMetadata()
            return .failed(failure)
        }
    }

    /// Operations whose records were handed to the engine but not acknowledged in this run (request
    /// failed, run aborted) go back to `pending` so the next run sends them again.
    private func releaseInFlight() async {
        let operations = inFlight.values.flatMap { $0 }
        inFlight.removeAll()
        guard !operations.isEmpty else { return }
        do {
            try await store.markPending(operations, at: now())
        } catch {
            status.lastError = SyncErrorText.message(for: error)
        }
    }

    /// Re-queues every syncable entity (batch by batch, cursor persisted) when a full upload is due.
    private func drainFullUpload() async throws {
        guard metadata.fullUpload != nil, metadata.cloudDeletion == nil else { return }
        overrideSystemFields.removeAll()
        while let state = metadata.fullUpload {
            let progress = try await store.requeueForFullUpload(after: state.cursor, batchSize: configuration.fullUploadBatchSize, at: now())
            report.requeuedForUpload += progress.requeued
            metadata.fullUpload = progress.next.map { CoordinatorMetadata.FullUploadState(cursor: $0) }
            await persistMetadata()
        }
    }

    private func scheduleFullUpload() {
        guard metadata.cloudDeletion == nil else { return }
        if metadata.fullUpload == nil { metadata.fullUpload = CoordinatorMetadata.FullUploadState(cursor: nil) }
    }

    /// Returns a German message if single records failed while the request itself succeeded.
    private func sendPending(_ engine: any SyncEngine) async throws -> String? {
        var lastRecordError: String?
        for _ in 0..<configuration.maxSendPasses {
            needsResend = false
            try await drainFullUpload()
            try await enqueueOutbox(engine)
            if engine.pendingRecordZoneChanges.isEmpty, engine.pendingDatabaseChanges.isEmpty { break }
            let failuresBefore = report.sendFailures
            try await engine.sendChanges()
            if report.sendFailures > failuresBefore, !needsResend { lastRecordError = status.lastError }
            guard needsResend else { break }
        }
        if !secretRejectedRecords.isEmpty {
            lastRecordError = SyncErrorText.message(for: .secretMaterialRejected(entity: .providerProfile, paths: []))
        }
        return lastRecordError
    }

    /// Mirrors the durable outbox into the engine's pending list (idempotent; survives crashes because
    /// the outbox is re-read every run).
    /// The whole outbox is paged through, so a large backlog drains within one run; the engine then
    /// sends it in requests of at most `batchSize` records.
    private func enqueueOutbox(_ engine: any SyncEngine) async throws {
        let blocked = try await blockedRecordNames()
        var seen = Set<String>()
        // Kinds deleted on the server (ADR-0028): the latest operation decides between save and delete.
        var latestServerDeleting: [String: (type: SyncEntityType, operation: SyncOperation)] = [:]
        var cursor: SyncOutboxCursor?
        repeat {
            let page = try await store.pendingOperations(limit: configuration.outboxScanLimit, after: cursor)
            var changes: [CKSyncEngine.PendingRecordZoneChange] = []
            for operation in page.operations {
                guard let type = SyncEntityType(rawValue: operation.entityType),
                      SyncRecordSchema.recordType(for: type) != nil else { continue }
                let name = SyncRecordSchema.recordName(type, operation.entityId)
                guard !blocked.contains(name) else { continue }
                if SyncRecordSchema.deletesRecordOnServer(type) {
                    if let known = latestServerDeleting[name], known.operation.version >= operation.version { continue }
                    latestServerDeleting[name] = (type, operation)
                    continue
                }
                guard seen.insert(name).inserted else { continue }
                changes.append(.saveRecord(SyncRecordSchema.recordID(type, operation.entityId, zoneID: configuration.zoneID)))
            }
            if !changes.isEmpty { engine.add(pendingRecordZoneChanges: changes) }
            cursor = page.next
        } while cursor != nil

        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        var superseded: [CKSyncEngine.PendingRecordZoneChange] = []
        for (type, operation) in latestServerDeleting.values {
            let recordID = SyncRecordSchema.recordID(type, operation.entityId, zoneID: configuration.zoneID)
            if operation.type == .delete {
                changes.append(.deleteRecord(recordID))
                superseded.append(.saveRecord(recordID))
            } else {
                changes.append(.saveRecord(recordID))
                superseded.append(.deleteRecord(recordID))
            }
        }
        if !superseded.isEmpty { engine.remove(pendingRecordZoneChanges: superseded) }
        if !changes.isEmpty { engine.add(pendingRecordZoneChanges: changes) }
    }

    /// Entities with an open conflict are not sent until the user resolved it.
    private func blockedRecordNames() async throws -> Set<String> {
        Set(try await store.openConflicts().map { SyncRecordSchema.recordName($0.entityType, $0.entityId) })
    }

    // MARK: User decisions

    /// Resolves a conflict (A24) and sends the result with the next run.
    public func resolveConflict(_ id: UUID, resolution: ConflictResolution) async throws {
        try await store.resolveConflict(id, resolution: resolution, at: now())
        await refreshCounts()
        publish()
    }

    /// The user confirmed to continue with the new iCloud account. Local data is kept; the engine starts
    /// from a fresh state and every unsent change is uploaded to the new account. With
    /// `uploadAllLocalData` ("erneut hochladen") every syncable entity is uploaded, not only unsent ones.
    public func acknowledgeAccountChange(uploadAllLocalData: Bool = false) async throws {
        guard metadata.accountPause == .switched else { return }
        metadata.knownUserRecordName = metadata.pendingUserRecordName ?? metadata.knownUserRecordName
        metadata.pendingUserRecordName = nil
        metadata.accountPause = nil
        if uploadAllLocalData { scheduleFullUpload() }
        try await store.saveEngineState(Data(), scope: configuration.engineStateScope, at: now())
        engine = nil
        try await createEngine()
        try? await drainFullUpload()
        status.accountState = .unknown
        await persistMetadata()
        await refreshCounts()
        publish()
    }

    /// The user decided to upload local data again after the zone was deleted, purged or its encrypted
    /// data reset, or after deleting the iCloud data in the app („Wieder mit iCloud synchronisieren“).
    /// Never automatic. Every syncable entity is re-queued (not only unsent changes), because the server
    /// copy is gone.
    ///
    /// The engine starts from a fresh state: an old change token would report the zone deletion again
    /// (pausing right after the user's decision), and a still queued zone deletion is dropped.
    public func recreateZoneAndResume() async {
        guard metadata.zoneDeletion != nil || metadata.cloudDeletion != nil else { return }
        metadata.zoneDeletion = nil
        metadata.cloudDeletion = nil
        metadata.zoneConfirmed = false
        scheduleFullUpload()
        overrideSystemFields.removeAll()
        status.lastError = nil
        do {
            try await store.saveEngineState(Data(), scope: configuration.engineStateScope, at: now())
            engine = nil
            try await createEngine() // fresh state: queues the zone save
        } catch {
            status.lastError = SyncErrorText.message(for: error)
            engine?.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: configuration.zoneID))])
        }
        await persistMetadata()
        // Queue before the next fetch, so records other devices re-upload meanwhile meet the local
        // operations (identical content converges, different content becomes a visible conflict).
        // A failure here is retried at the start of the next run (the cursor is persisted).
        try? await drainFullUpload()
        await refreshCounts()
        publish()
    }

    // MARK: Deleting the iCloud data (A34)

    /// Deletes the app's record zone in the user's private database (spec Q1 „transparente Löschung“,
    /// A34). Only called with a request from a confirmed `CloudDeletionPlan`.
    ///
    /// The "deleted by user" state is persisted **before** anything is sent, so a crash or a failed
    /// attempt never lets a later run, `zoneNotFound`, or a full upload re-create the zone or upload local
    /// data again. Sync stays paused (`SyncPauseReason.zoneDeleted`, attention
    /// `.cloudDataDeletedByUser`/`.cloudDataDeletionPending`) until the user calls
    /// `recreateZoneAndResume()`. Local data is not touched. Repeating the call with the same request
    /// after a failure retries the deletion.
    public func deleteCloudData(_ request: CloudDataDeletionRequest) async throws {
        guard let engine else { throw CloudDataDeletionError.notStarted }
        guard request.scope == .entireZone, request.zoneName == configuration.zoneID.zoneName else {
            throw CloudDataDeletionError.zoneMismatch(expected: configuration.zoneID.zoneName, requested: request.zoneName)
        }
        guard !isRunning else { throw CloudDataDeletionError.syncInProgress }
        // The engine works on the signed-in account; a pending switch must be decided first.
        guard metadata.accountPause != .switched else { throw CloudDataDeletionError.accountChangePending }
        if let existing = metadata.cloudDeletion, existing.request.id == request.id, existing.completedAt != nil { return }
        if metadata.cloudDeletion?.request.id != request.id || metadata.cloudDeletion?.completedAt != nil {
            metadata.cloudDeletion = CoordinatorMetadata.CloudDeletionState(request: request, startedAt: now())
        }
        metadata.fullUpload = nil
        await persistMetadata()

        // Nothing but the deletion may go out: drop queued records and zone saves.
        engine.remove(pendingRecordZoneChanges: engine.pendingRecordZoneChanges)
        engine.remove(pendingDatabaseChanges: engine.pendingDatabaseChanges)
        engine.add(pendingDatabaseChanges: [.deleteZone(configuration.zoneID)])
        inFlight.removeAll()

        isRunning = true
        status.isSyncing = true
        updateAttention()
        publish()
        var thrown: (any Error)?
        do {
            try await engine.sendChanges()
        } catch {
            thrown = error
        }
        isRunning = false
        status.isSyncing = false
        rerunRequested = false
        if let thrown {
            let message = SyncErrorText.message(for: thrown)
            metadata.cloudDeletion?.lastError = message
            let ckError = thrown as? CKError
            status.lastError = message
            await persistMetadata()
            updateAttention()
            publish()
            throw CloudDataDeletionError.failed(SyncFailure(message: message, code: ckError?.code, retryAfter: ckError?.retryAfterSeconds))
        }
        await refreshCounts()
        publish()
        guard let state = metadata.cloudDeletion, state.completedAt != nil else {
            let message = metadata.cloudDeletion?.lastError ?? SyncAttention.cloudDataDeletionPending.message
            throw CloudDataDeletionError.failed(SyncFailure(message: message, code: nil, retryAfter: nil))
        }
    }

    /// Retries a confirmed deletion whose zone deletion has not reached iCloud yet (e.g. offline).
    public func retryCloudDataDeletion() async throws {
        guard let state = metadata.cloudDeletion, state.completedAt == nil else { return }
        try await deleteCloudData(state.request)
    }

    /// True while the user's deletion of the iCloud data holds sync paused (completed or still pending).
    public var isCloudDataDeletedByUser: Bool { metadata.cloudDeletion != nil }

    // MARK: SyncEngineEventHandler

    public func handle(_ event: SyncEngineEvent) async {
        switch event {
        case let .stateUpdate(data):
            do {
                try await store.saveEngineState(data, scope: configuration.engineStateScope, at: now())
            } catch {
                let detail = error.localizedDescription
                status.lastError = String(localized: "Der Synchronisierungsstand konnte nicht gespeichert werden: \(detail)", bundle: .module)
            }
        case let .accountChange(change):
            handleAccountChange(change)
            await persistMetadata()
        case let .fetchedDatabaseChanges(deletedZones):
            for deletion in deletedZones where deletion.zoneID == configuration.zoneID {
                // Surface, never wipe local data (spec Q1: Daten erhalten).
                metadata.zoneDeletion = deletion.reason
                metadata.zoneConfirmed = false
            }
            await persistMetadata()
        case let .fetchedRecordZoneChanges(modifications, deletions):
            await applyFetched(modifications: modifications, deletions: deletions)
        case let .sentDatabaseChanges(savedZoneIDs, failedZoneSaves):
            if savedZoneIDs.contains(configuration.zoneID), metadata.cloudDeletion == nil {
                metadata.zoneConfirmed = true
                await persistMetadata()
            }
            for failure in failedZoneSaves where failure.zoneID == configuration.zoneID {
                SyncLog.logger.error("Zone \(failure.zoneID.zoneName, privacy: .public) nicht angelegt: \(SyncLog.describe(failure.error), privacy: .public)")
                status.lastError = SyncErrorText.message(for: failure.error)
                if failure.error.code == .quotaExceeded { quotaExceeded = true }
            }
        case let .sentRecordZoneChanges(sent):
            await handleSent(sent)
        case let .sentZoneDeletions(deletedZoneIDs, failedZoneDeletions):
            await handleZoneDeletions(deleted: deletedZoneIDs, failed: failedZoneDeletions)
        }
        updateAttention()
        publish()
    }

    public func nextRecordZoneChangeBatch(pending: [CKSyncEngine.PendingRecordZoneChange]) async -> SyncRecordBatch? {
        // Defence in depth: after the user deleted the iCloud data no record leaves the device.
        guard let engine, metadata.cloudDeletion == nil else { return nil }
        do {
            let blocked = try await blockedRecordNames()
            var batch = SyncRecordBatch()
            var batchOperations: [SyncOperationID] = []
            var obsolete: [CKSyncEngine.PendingRecordZoneChange] = []
            // Look up the outbox only for the records of this request (not the whole backlog).
            var remaining = pending[...]
            while batch.count < configuration.batchSize, !remaining.isEmpty {
                let chunk = remaining.prefix(configuration.batchSize)
                remaining = remaining.dropFirst(chunk.count)
                let keys = chunk.compactMap { change -> SyncEntityKey? in
                    guard let parsed = SyncRecordSchema.parse(recordName: change.recordID.recordName) else { return nil }
                    if case .deleteRecord = change, !SyncRecordSchema.deletesRecordOnServer(parsed.type) { return nil }
                    return SyncEntityKey(entityType: parsed.type, entityId: parsed.id)
                }
                let byRecord = Dictionary(grouping: try await store.pendingOperations(for: keys)) { operation in
                    SyncEntityType(rawValue: operation.entityType).map { SyncRecordSchema.recordName($0, operation.entityId) } ?? ""
                }
                for change in chunk where batch.count < configuration.batchSize {
                    let recordID = change.recordID
                    guard recordID.zoneID == configuration.zoneID else { continue }
                    let name = recordID.recordName
                    if case .deleteRecord = change {
                        // ADR-0028: the outbox operations are acknowledged once the server confirms the deletion.
                        if let operations = byRecord[name], !operations.isEmpty {
                            inFlight[name] = operations.map(\.operationId)
                            batchOperations += operations.map(\.operationId)
                        }
                        batch.recordIDsToDelete.append(recordID)
                        continue
                    }
                    guard let parsed = SyncRecordSchema.parse(recordName: name),
                          let entityOperations = byRecord[name], !entityOperations.isEmpty,
                          !blocked.contains(name)
                    else {
                        obsolete.append(change)
                        continue
                    }
                    if SyncRecordSchema.deletesRecordOnServer(parsed.type),
                       entityOperations.max(by: { $0.version < $1.version })?.type == .delete {
                        // Deleted on the server, not uploaded as a tombstone record (ADR-0028).
                        obsolete.append(change)
                        engine.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                        continue
                    }
                    do {
                        let record = try await buildRecord(parsed.type, parsed.id, entityOperations)
                        secretRejectedRecords.remove(name)
                        inFlight[name] = entityOperations.map(\.operationId)
                        batchOperations += entityOperations.map(\.operationId)
                        batch.recordsToSave.append(record)
                    } catch let error as SyncMappingError {
                        if case .secretMaterialRejected = error { secretRejectedRecords.insert(name) }
                        let message = SyncErrorText.message(for: error)
                        for operation in entityOperations {
                            try await store.markFailed(operation.operationId, error: message, at: now())
                        }
                        status.lastError = message
                        obsolete.append(change)
                    }
                }
            }
            if !obsolete.isEmpty { engine.remove(pendingRecordZoneChanges: obsolete) }
            // Durable "handed to CloudKit, not yet acknowledged" marker; reset on restart (crash safety).
            if !batchOperations.isEmpty { try await store.markInFlight(batchOperations, at: now()) }
            updateAttention()
            return batch.isEmpty ? nil : batch
        } catch {
            status.lastError = SyncErrorText.message(for: error)
            return nil
        }
    }

    // MARK: Building records

    private func buildRecord(_ type: SyncEntityType, _ id: UUID, _ operations: [SyncOperation]) async throws -> CKRecord {
        let latest = operations.max { $0.version < $1.version }!
        let state = try await store.entityVersion(entityType: type, entityId: id)
        let payload = latest.type == .delete ? nil : try await store.currentPayload(entityType: type, entityId: id)
        let name = SyncRecordSchema.recordName(type, id)
        let content = OutgoingRecord(
            entityType: type,
            entityId: id,
            operationId: latest.operationId,
            isDeleted: payload == nil,
            version: latest.version,
            baseVersion: state.flatMap { $0.syncedVersion > 0 ? $0.syncedVersion : nil },
            payload: payload,
            systemFields: overrideSystemFields[name] ?? state?.systemFields,
            modifiedAt: now()
        )
        return try mapper.makeRecord(content)
    }

    // MARK: Fetched changes

    /// ADR-0026 / SR-SEC-01: on the execution host, remote changes to data the Mac owns are rejected
    /// before they are applied (not only on conflicts). Mobile devices apply as before.
    private var ownershipPolicy: RemoteOwnershipPolicy? {
        if case let .executionHost(hostId) = configuration.role { return RemoteOwnershipPolicy(executionHostId: hostId) }
        return nil
    }

    private func applyFetched(modifications: [CKRecord], deletions: [SyncRecordDeletion]) async {
        var changes: [RemoteChange] = []
        if modifications.contains(where: { $0.recordID.zoneID == configuration.zoneID }), metadata.cloudDeletion == nil {
            metadata.zoneConfirmed = true
        }
        for record in modifications where record.recordID.zoneID == configuration.zoneID {
            do {
                let decoded = try mapper.decode(record)
                if decoded.originDeviceId == configuration.deviceId {
                    report.ownEchoes += 1
                    continue
                }
                changes.append(decoded.change)
            } catch {
                noteInvalid(error)
            }
        }
        for deletion in deletions where deletion.recordID.zoneID == configuration.zoneID {
            // Hard deletion made outside the app (we send tombstone records ourselves).
            guard let parsed = SyncRecordSchema.parse(recordName: deletion.recordID.recordName) else {
                noteInvalid(SyncMappingError.malformedRecord(recordName: deletion.recordID.recordName, reason: "record name"))
                continue
            }
            let state = try? await store.entityVersion(entityType: parsed.type, entityId: parsed.id)
            let synced = state?.syncedVersion ?? 0
            changes.append(RemoteChange(
                operationId: Self.hardDeletionOperationID(deletion.recordID.recordName, syncedVersion: synced),
                entityType: parsed.type, entityId: parsed.id, kind: .delete,
                version: synced + 1, baseVersion: synced, payload: nil, systemFields: nil
            ))
        }
        guard !changes.isEmpty else { return }
        var conflicted: [SyncEntityKey] = []
        do {
            // One transaction for the whole batch (ADR-0019); replay protection via the inbox.
            let outcomes = try await store.applyRemoteChanges(changes, engineState: nil, ownership: ownershipPolicy, at: now())
            outcomes.forEach { report.count($0) }
            for (change, outcome) in zip(changes, outcomes) where outcome == .conflict {
                conflicted.append(SyncEntityKey(entityType: change.entityType, entityId: change.entityId))
            }
        } catch {
            // One unreadable record must not block the others: apply individually.
            for change in changes {
                do {
                    let outcomes = try await store.applyRemoteChanges([change], engineState: nil, ownership: ownershipPolicy, at: now())
                    outcomes.forEach { report.count($0) }
                    if outcomes.first == .conflict {
                        conflicted.append(SyncEntityKey(entityType: change.entityType, entityId: change.entityId))
                    }
                } catch {
                    noteInvalid(error)
                }
            }
        }
        guard !conflicted.isEmpty, let open = try? await store.openConflicts() else { return }
        for key in conflicted {
            if let conflict = open.last(where: { $0.entityType == key.entityType && $0.entityId == key.entityId }) {
                _ = await attemptAutomaticMerge(conflict)
            }
        }
    }

    /// Spec N2: user content changed on both sides is merged automatically only if a 3-way merge against
    /// the common ancestor finds no overlapping edits. The resolution is recorded (conflict history and,
    /// for work items, an `edited` task event); overlapping edits stay open for the user.
    private func attemptAutomaticMerge(_ conflict: SyncConflict) async -> Bool {
        guard SyncMergePolicy.policy(for: conflict.entityType) == .keepBothForUser,
              conflict.remoteChangeKind != .delete,
              let ancestor = conflict.ancestorPayload, let local = conflict.localPayload, let remote = conflict.remotePayload
        else { return false }
        do {
            guard case let .merged(data, _) = try SyncPayloadMerge.merge(ancestor: ancestor, local: local, remote: remote) else {
                return false
            }
            let canonical = try SyncPayloadCodec.canonicalize(data, entityType: conflict.entityType)
            try await store.resolveConflict(conflict.id, resolution: .merged(canonical), resolvedBy: .automaticMerge, at: now())
            report.mergedAutomatically += 1
            return true
        } catch {
            // Leave the conflict to the user; never guess.
            return false
        }
    }

    private func noteInvalid(_ error: any Error) {
        report.invalid += 1
        SyncLog.logger.error("Datensatz aus iCloud übersprungen: \(SyncLog.describe(error), privacy: .public)")
        if case SyncMappingError.unsupportedSchema = error {
            newerSchemaSeen = true
        } else {
            invalidRemoteRecords += 1
        }
        status.lastError = SyncErrorText.message(for: error)
    }

    /// Deterministic, so a re-delivered hard deletion is recognized as duplicate.
    static func hardDeletionOperationID(_ recordName: String, syncedVersion: Int) -> SyncOperationID {
        var bytes = Array(SHA256.hash(data: Data("hard-delete:\(recordName):\(syncedVersion)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return SyncOperationID(uuid)
    }

    // MARK: Sent changes

    private func handleZoneDeletions(deleted: [CKRecordZone.ID], failed: [SyncFailedZoneDeletion]) async {
        guard metadata.cloudDeletion != nil else { return }
        // A zone that no longer exists is as deleted as it gets.
        if deleted.contains(configuration.zoneID)
            || failed.contains(where: { $0.zoneID == configuration.zoneID && $0.error.code == .zoneNotFound }) {
            metadata.cloudDeletion?.completedAt = now()
            metadata.cloudDeletion?.lastError = nil
            metadata.zoneConfirmed = false
            metadata.zoneDeletion = nil
            status.lastError = nil
        } else if let failure = failed.first(where: { $0.zoneID == configuration.zoneID }) {
            let message = SyncErrorText.message(for: failure.error)
            metadata.cloudDeletion?.lastError = message
            status.lastError = message
            if failure.error.code == .userDeletedZone || failure.error.code == .zoneNotFound {
                metadata.cloudDeletion?.completedAt = now()
            }
        }
        await persistMetadata()
    }

    /// `zoneNotFound` for a zone this device already saved or saw: it was deleted elsewhere (another
    /// device's „iCloud-Daten löschen“, Settings). Surface it instead of silently re-creating the zone and
    /// re-uploading everything; the user decides (`recreateZoneAndResume`). Returns true if paused.
    private func pauseIfKnownZoneVanished() -> Bool {
        if metadata.cloudDeletion != nil { return true }
        let known = metadata.zoneConfirmed ?? (metadata.lastSuccessfulSend != nil)
        guard known else { return false }
        if metadata.zoneDeletion == nil { metadata.zoneDeletion = .deleted }
        metadata.zoneConfirmed = false
        return true
    }

    private func handleSent(_ sent: SyncSentRecordZoneChanges) async {
        if !sent.savedRecords.isEmpty, metadata.cloudDeletion == nil, metadata.zoneConfirmed != true {
            metadata.zoneConfirmed = true
        }
        for record in sent.savedRecords {
            let name = record.recordID.recordName
            let operations = inFlight.removeValue(forKey: name) ?? []
            let fields = SyncRecordMapper.encodeSystemFields(of: record)
            overrideSystemFields[name] = nil
            mapper.cleanUpAsset(of: record)
            for operation in operations {
                do {
                    try await store.markSent(operation, systemFields: fields, at: now())
                } catch {
                    status.lastError = SyncErrorText.message(for: error)
                }
            }
            report.sent += 1
            quotaExceeded = false
        }
        for recordID in sent.deletedRecordIDs {
            for operation in inFlight.removeValue(forKey: recordID.recordName) ?? [] {
                try? await store.markSent(operation, systemFields: nil, at: now())
            }
            report.sent += 1
        }
        for failure in sent.failedRecordSaves {
            await handleFailedSave(failure)
        }
        for (recordID, error) in sent.failedRecordDeletes {
            let operations = inFlight.removeValue(forKey: recordID.recordName) ?? []
            if error.code == .unknownItem {
                // Already gone on the server (never uploaded, or deleted before): that is the goal.
                for operation in operations { try? await store.markSent(operation, systemFields: nil, at: now()) }
                report.sent += 1
                continue
            }
            report.sendFailures += 1
            SyncLog.logger.error("Löschung \(recordID.recordName, privacy: .public) fehlgeschlagen: \(SyncLog.describe(error), privacy: .public)")
            await markFailed(operations, error: error)
        }
    }

    private func handleFailedSave(_ failure: SyncFailedRecordSave) async {
        let record = failure.record
        let name = record.recordID.recordName
        let operations = inFlight.removeValue(forKey: name) ?? []
        mapper.cleanUpAsset(of: record)
        report.sendFailures += 1
        SyncLog.logger.error("Datensatz \(name, privacy: .public) nicht gespeichert: \(SyncLog.describe(failure.error), privacy: .public)")
        // Not acknowledged: back to pending, so a resend in this run (or the next run) picks them up.
        try? await store.markPending(operations, at: now())
        guard let engine, let parsed = SyncRecordSchema.parse(recordName: name) else { return }
        let error = failure.error
        switch error.code {
        case .serverRecordChanged:
            await mergeServerRecordChanged(client: record, server: error.serverRecord, operations: operations,
                                           type: parsed.type, id: parsed.id)
        case .zoneNotFound:
            if pauseIfKnownZoneVanished() {
                // Operations went back to pending above; nothing is lost, nothing re-created. The pause is
                // shown as attention (`zoneDeleted`/`cloudDataDeletedByUser`).
                return
            }
            // Zone never created by this device: create it, upload everything (records that were in a lost
            // zone are gone as well) and retry in the same run.
            engine.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: configuration.zoneID))])
            scheduleFullUpload()
            await forgetSystemFields(parsed.type, parsed.id)
            resend(record.recordID)
        case .unknownItem:
            // The server no longer has the record (zone reset/recreated): upload it as a new record.
            await forgetSystemFields(parsed.type, parsed.id)
            resend(record.recordID)
        case .userDeletedZone:
            metadata.zoneDeletion = .purged
            await markFailed(operations, error: error)
        case .quotaExceeded:
            quotaExceeded = true
            await markFailed(operations, error: error)
        default:
            if SyncErrorText.isTransient(error.code), let seconds = error.retryAfterSeconds {
                noteRetryAfter(seconds)
            }
            // Transient errors stay pending in the engine; the next run retries them.
            await markFailed(operations, error: error)
        }
    }

    /// `serverRecordChanged`: merge into the server record per entity rule or keep both versions as
    /// `SyncConflict` (spec N2; apple-platform.md §2: merge into the server record, then re-save).
    private func mergeServerRecordChanged(
        client: CKRecord, server: CKRecord?, operations: [SyncOperationID], type: SyncEntityType, id: UUID
    ) async {
        guard let server else {
            await markFailed(operations, message: SyncErrorText.message(for: CKError(.serverRecordChanged)))
            return
        }
        let name = SyncRecordSchema.recordName(type, id)
        let serverFields = SyncRecordMapper.encodeSystemFields(of: server)
        let remote: DecodedRecord
        do {
            remote = try mapper.decode(server)
        } catch {
            noteInvalid(error)
            await markFailed(operations, message: SyncErrorText.message(for: error))
            return
        }
        do {
            // Our own earlier write reached the server although the response was lost.
            if remote.originDeviceId == configuration.deviceId, operations.contains(remote.change.operationId) {
                var newer = false
                for operationId in operations {
                    guard let operation = try await store.operation(operationId) else { continue }
                    if operation.version <= remote.change.version {
                        try await store.markSent(operationId, systemFields: serverFields, at: now())
                    } else {
                        newer = true
                    }
                }
                report.mergedOnServerChange += 1
                if newer {
                    // Local edits made after that write still have to go out, on top of the server tag.
                    await adoptSystemFields(serverFields, type, id)
                    resend(client.recordID)
                }
                return
            }
            // Identical content: nothing to merge. If the server version is at least ours, adopt its change
            // tag; otherwise write our version number on top of it, so the server never holds a lower
            // version than the one this device considers synced (a later remote edit would look stale).
            if let local = try? mapper.decode(client),
               local.change.payload == remote.change.payload, (local.change.kind == .delete) == (remote.change.kind == .delete) {
                report.mergedOnServerChange += 1
                if remote.change.version >= local.change.version {
                    for operation in operations { try await store.markSent(operation, systemFields: serverFields, at: now()) }
                } else {
                    await adoptSystemFields(serverFields, type, id)
                    resend(client.recordID)
                }
                return
            }
            // Entity no longer tracked here (became device-local): the removal wins.
            if try await store.entityVersion(entityType: type, entityId: id) == nil {
                overrideSystemFields[name] = serverFields
                resend(client.recordID)
                return
            }
            let outcome = try await store.applyRemoteChanges([remote.change], engineState: nil, ownership: ownershipPolicy, at: now()).first
            switch outcome {
            case .conflict?, .duplicate?:
                guard let conflict = try await store.openConflicts().last(where: { $0.entityType == type && $0.entityId == id }) else {
                    // Server value was applied earlier; only our change tag was outdated.
                    await adoptSystemFields(serverFields, type, id)
                    resend(client.recordID)
                    return
                }
                if outcome == .conflict { report.conflicts += 1 }
                if let resolution = SyncMergePolicy.policy(for: type).automaticResolution(role: configuration.role) {
                    try await store.resolveConflict(conflict.id, resolution: resolution, resolvedBy: .automaticPolicy, at: now())
                    report.mergedOnServerChange += 1
                    if resolution == .keepLocal { resend(client.recordID) }
                } else if await attemptAutomaticMerge(conflict) {
                    report.mergedOnServerChange += 1
                    resend(client.recordID)
                }
            case .stale?:
                // Our version is newer than the server's; re-send on top of the server change tag.
                await adoptSystemFields(serverFields, type, id)
                resend(client.recordID)
            case .applied?, .deleted?, nil:
                // No unsent local edits were pending; the server value is now local. Re-send whatever
                // operations remain with the new change tag (idempotent).
                if !operations.isEmpty { resend(client.recordID) }
            }
        } catch {
            status.lastError = SyncErrorText.message(for: error)
            await markFailed(operations, message: status.lastError ?? "")
        }
    }

    private func resend(_ recordID: CKRecord.ID) {
        engine?.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        needsResend = true
    }

    private func adoptSystemFields(_ fields: Data, _ type: SyncEntityType, _ id: UUID) async {
        do {
            try await store.saveSystemFields(fields, entityType: type, entityId: id, at: now())
        } catch {
            overrideSystemFields[SyncRecordSchema.recordName(type, id)] = fields
        }
    }

    private func forgetSystemFields(_ type: SyncEntityType, _ id: UUID) async {
        overrideSystemFields[SyncRecordSchema.recordName(type, id)] = nil
        // No-op for entities without sync state (Persistence never creates state for unsynced entities).
        try? await store.saveSystemFields(nil, entityType: type, entityId: id, at: now())
    }

    private func markFailed(_ operations: [SyncOperationID], error: CKError) async {
        await markFailed(operations, message: SyncErrorText.message(for: error))
    }

    private func markFailed(_ operations: [SyncOperationID], message: String) async {
        status.lastError = message
        for operation in operations {
            try? await store.markFailed(operation, error: message, at: now())
        }
    }

    private func noteRetryAfter(_ seconds: TimeInterval) {
        let candidate = now().addingTimeInterval(seconds)
        status.retryNotBefore = max(status.retryNotBefore ?? candidate, candidate)
    }

    // MARK: Account and errors

    private func handleAccountChange(_ change: SyncAccountChange) {
        switch change {
        case let .signedIn(user):
            if let known = metadata.knownUserRecordName, known != user {
                SyncLog.logger.notice("Anderer iCloud-Account angemeldet: Synchronisierung pausiert bis zur Bestätigung.")
                metadata.pendingUserRecordName = user
                metadata.accountPause = .switched
                status.accountState = .switched
            } else {
                metadata.knownUserRecordName = user
                if metadata.accountPause == .signedOut { metadata.accountPause = nil }
                status.accountState = metadata.accountPause == .switched ? .switched : .available
            }
        case .signedOut:
            // Pause only. Local data is never deleted because of an account change.
            if metadata.accountPause != .switched { metadata.accountPause = .signedOut }
            status.accountState = metadata.accountPause == .switched ? .switched : .signedOut
        case let .switched(_, current):
            SyncLog.logger.notice("iCloud-Account gewechselt: Synchronisierung pausiert bis zur Bestätigung.")
            metadata.pendingUserRecordName = current
            metadata.accountPause = .switched
            status.accountState = .switched
        }
    }

    private func handleRunError(_ error: any Error) async -> SyncFailure {
        SyncLog.logger.error("Abgleich fehlgeschlagen: \(SyncLog.describe(error), privacy: .public)")
        let ckError = error as? CKError
        if let seconds = ckError?.retryAfterSeconds { noteRetryAfter(seconds) }
        switch ckError?.code {
        case .notAuthenticated?:
            if metadata.accountPause != .switched {
                metadata.accountPause = .signedOut
                status.accountState = .signedOut
            }
        case .accountTemporarilyUnavailable?:
            status.accountState = .temporarilyUnavailable
        case .userDeletedZone?:
            metadata.zoneDeletion = .purged
        case .zoneNotFound?:
            if !pauseIfKnownZoneVanished() {
                engine?.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: configuration.zoneID))])
                scheduleFullUpload()
            }
        case .quotaExceeded?:
            quotaExceeded = true
        default:
            break
        }
        var message = SyncErrorText.message(for: error)
        if ckError?.code == .zoneNotFound, metadata.zoneDeletion != nil || metadata.cloudDeletion != nil {
            // Not re-created (see `pauseIfKnownZoneVanished`): say what actually happens.
            message = metadata.cloudDeletion != nil ? SyncAttention.cloudDataDeletedByUser.message : SyncAttention.zoneDeleted(.deleted).message
        }
        status.lastError = message
        updateAttention()
        return SyncFailure(message: message, code: ckError?.code, retryAfter: ckError?.retryAfterSeconds)
    }

    // MARK: Status

    private func refreshCounts() async {
        // Device-local kinds never enter the outbox, so every unsent operation counts.
        if let count = try? await store.unsentOperationCount() { status.pendingCount = count }
        if let conflicts = try? await store.openConflicts() { status.openConflictCount = conflicts.count }
        updateAttention()
    }

    private func updateAttention() {
        var attention: [SyncAttention] = []
        switch metadata.accountPause {
        case .signedOut?: attention.append(.accountSignedOut)
        case .switched?: attention.append(.accountSwitched)
        case nil: break
        }
        if let deletion = metadata.cloudDeletion {
            attention.append(deletion.completedAt == nil ? .cloudDataDeletionPending : .cloudDataDeletedByUser)
        } else if let reason = metadata.zoneDeletion {
            attention.append(.zoneDeleted(reason))
        }
        if status.openConflictCount > 0 { attention.append(.openConflicts(status.openConflictCount)) }
        if !secretRejectedRecords.isEmpty { attention.append(.secretsBlocked(secretRejectedRecords.count)) }
        if invalidRemoteRecords > 0 { attention.append(.invalidRemoteRecords(invalidRemoteRecords)) }
        if newerSchemaSeen { attention.append(.newerSchema) }
        if quotaExceeded { attention.append(.iCloudQuotaExceeded) }
        status.attention = attention
        status.isPaused = metadata.accountPause != nil || metadata.zoneDeletion != nil || metadata.cloudDeletion != nil
    }

    private func persistMetadata() async {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? await store.saveEngineState(data, scope: configuration.metadataScope, at: now())
    }
}
