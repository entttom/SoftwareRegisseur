import CloudKit
import Foundation
import SoftwareRegisseurSync

/// In-memory stand-in for the CloudKit private database (spec R: "CloudKit-Adapter mit Fake").
///
/// Models what the coordinator depends on: per-record change tags with `ifServerRecordUnchanged` save
/// semantics (`serverRecordChanged` with the server record in `userInfo`), a global change sequence that
/// devices use as change token, record and zone deletion, `zoneNotFound`/`unknownItem`, the 250-record
/// request limit, zone deletion requested by a device and injectable transient errors with
/// `retryAfterSeconds`.
public actor FakeCloudDatabase {
    struct StoredRecord {
        var record: CKRecord
        var sequence: Int
    }

    struct Zone {
        var records: [String: StoredRecord] = [:]
        var hardDeletions: [String: (sequence: Int, recordType: CKRecord.RecordType)] = [:]
    }

    struct ZoneDeletionEntry {
        let zoneName: String
        let sequence: Int
        let reason: ZoneDeletionReason
    }

    struct FetchResult: Sendable {
        let deletedZones: [SyncZoneDeletion]
        let modifications: [CKRecord]
        let deletions: [SyncRecordDeletion]
        let newToken: Int
    }

    struct ModifyResult: Sendable {
        let saved: [CKRecord]
        let failedSaves: [SyncFailedRecordSave]
        let deleted: [CKRecord.ID]
    }

    private var zones: [String: Zone] = [:]
    private var zoneDeletions: [ZoneDeletionEntry] = []
    private var sequence = 0
    private var injectedFailures: [(code: CKError.Code, retryAfter: TimeInterval?)] = []
    private var lostResponses = 0
    private let assetDirectory: URL

    /// Requests that reached the server (fetch, zone save, modify).
    public private(set) var requestCount = 0
    /// Zone deletions requested by devices (user-requested deletion of the iCloud data).
    public private(set) var zoneDeletionRequests = 0
    /// Size of each modify request, to prove the 250-record limit.
    public private(set) var modifyBatchSizes: [Int] = []

    public init() {
        assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeCloudDatabase-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Test controls

    /// The next `count` requests fail as a whole with `code` (e.g. `.requestRateLimited`).
    public func failNextRequests(_ count: Int = 1, code: CKError.Code, retryAfter: TimeInterval? = nil) {
        injectedFailures.append(contentsOf: Array(repeating: (code, retryAfter), count: count))
    }

    /// The next modify request is applied on the server, but the client gets `networkFailure`
    /// (connection dropped before the response arrived).
    public func loseNextModifyResponse() {
        lostResponses += 1
    }

    /// Deletes a zone like "Delete iCloud data" in Settings (`purged`) or another device (`deleted`).
    public func deleteZone(_ zoneID: CKRecordZone.ID, reason: ZoneDeletionReason = .purged) {
        guard zones.removeValue(forKey: zoneID.zoneName) != nil else { return }
        sequence += 1
        zoneDeletions.append(ZoneDeletionEntry(zoneName: zoneID.zoneName, sequence: sequence, reason: reason))
    }

    /// Hard deletion made outside the app (e.g. CloudKit Console).
    public func deleteRecord(_ recordID: CKRecord.ID) {
        guard let stored = zones[recordID.zoneID.zoneName]?.records.removeValue(forKey: recordID.recordName) else { return }
        sequence += 1
        zones[recordID.zoneID.zoneName]?.hardDeletions[recordID.recordName] = (sequence, stored.record.recordType)
    }

    public func record(_ recordID: CKRecord.ID) -> CKRecord? {
        zones[recordID.zoneID.zoneName]?.records[recordID.recordName].map { $0.record.copy() as! CKRecord }
    }

    public func recordNames(in zoneID: CKRecordZone.ID) -> [String] {
        zones[zoneID.zoneName]?.records.keys.sorted() ?? []
    }

    public func hasZone(_ zoneID: CKRecordZone.ID) -> Bool {
        zones[zoneID.zoneName] != nil
    }

    // MARK: Engine-facing API

    private func takeInjectedFailure() throws {
        requestCount += 1
        guard !injectedFailures.isEmpty else { return }
        let failure = injectedFailures.removeFirst()
        var userInfo: [String: Any] = [:]
        if let retryAfter = failure.retryAfter { userInfo[CKErrorRetryAfterKey] = retryAfter }
        throw CKError(failure.code, userInfo: userInfo)
    }

    func fetchChanges(since token: Int, zoneID: CKRecordZone.ID) throws -> FetchResult {
        try takeInjectedFailure()
        let deletedZones = token == 0 ? [] : zoneDeletions
            .filter { $0.sequence > token && $0.zoneName == zoneID.zoneName }
            .map { SyncZoneDeletion(zoneID: zoneID, reason: $0.reason) }
        let zone = zones[zoneID.zoneName] ?? Zone()
        let modifications = zone.records.values
            .filter { $0.sequence > token }
            .sorted { $0.sequence < $1.sequence }
            .map { $0.record.copy() as! CKRecord }
        let deletions = zone.hardDeletions
            .filter { $0.value.sequence > token }
            .sorted { $0.value.sequence < $1.value.sequence }
            .map { SyncRecordDeletion(recordID: CKRecord.ID(recordName: $0.key, zoneID: zoneID), recordType: $0.value.recordType) }
        return FetchResult(deletedZones: deletedZones, modifications: modifications, deletions: deletions, newToken: sequence)
    }

    func saveZone(_ zoneID: CKRecordZone.ID) throws {
        try takeInjectedFailure()
        if zones[zoneID.zoneName] == nil {
            zones[zoneID.zoneName] = Zone()
            sequence += 1
        }
    }

    /// Zone deletion sent by a device (`CKSyncEngine.PendingDatabaseChange.deleteZone`). Other devices
    /// learn about it as `deleted` on their next fetch; a missing zone fails with `zoneNotFound`.
    func deleteZoneRequest(_ zoneID: CKRecordZone.ID) throws -> CKError? {
        try takeInjectedFailure()
        guard zones[zoneID.zoneName] != nil else { return CKError(.zoneNotFound) }
        deleteZone(zoneID, reason: .deleted)
        zoneDeletionRequests += 1
        return nil
    }

    func modify(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID]) throws -> ModifyResult {
        try takeInjectedFailure()
        modifyBatchSizes.append(records.count + recordIDs.count)
        guard records.count + recordIDs.count <= SyncRecordSchema.maxRecordsPerBatch else {
            throw CKError(.limitExceeded)
        }
        var saved: [CKRecord] = []
        var failed: [SyncFailedRecordSave] = []
        var deleted: [CKRecord.ID] = []
        for record in records {
            let zoneName = record.recordID.zoneID.zoneName
            guard var zone = zones[zoneName] else {
                failed.append(SyncFailedRecordSave(record: record, error: CKError(.zoneNotFound)))
                continue
            }
            let name = record.recordID.recordName
            if let stored = zone.records[name] {
                guard record.recordChangeTag == stored.record.recordChangeTag else {
                    let error = CKError(.serverRecordChanged, userInfo: [
                        CKRecordChangedErrorServerRecordKey: stored.record.copy() as! CKRecord,
                        CKRecordChangedErrorClientRecordKey: record,
                    ])
                    failed.append(SyncFailedRecordSave(record: record, error: error))
                    continue
                }
            } else if record.recordChangeTag != nil {
                failed.append(SyncFailedRecordSave(record: record, error: CKError(.unknownItem)))
                continue
            }
            sequence += 1
            let copy = record.copy() as! CKRecord
            Self.setChangeTag("tag-\(sequence)", on: copy)
            try copyAssets(of: copy)
            zone.records[name] = StoredRecord(record: copy, sequence: sequence)
            zone.hardDeletions[name] = nil
            zones[zoneName] = zone
            saved.append(copy.copy() as! CKRecord)
        }
        for recordID in recordIDs {
            if zones[recordID.zoneID.zoneName]?.records[recordID.recordName] != nil {
                deleteRecord(recordID)
            }
            deleted.append(recordID)
        }
        if lostResponses > 0 {
            lostResponses -= 1
            throw CKError(.networkFailure)
        }
        return ModifyResult(saved: saved, failedSaves: failed, deleted: deleted)
    }

    /// Server-assigned change tag. `recordChangeTag` is read-only in the public API; the private `etag`
    /// setter is used only by this test double and survives `encodeSystemFields` (verified spike).
    static func setChangeTag(_ tag: String, on record: CKRecord) {
        _ = record.perform(NSSelectorFromString("setEtag:"), with: tag as NSString)
    }

    /// Assets are uploaded: the server keeps its own copy, independent of the client's temp file.
    private func copyAssets(of record: CKRecord) throws {
        for key in record.allKeys() {
            guard let asset = record[key] as? CKAsset, let url = asset.fileURL else { continue }
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            let target = assetDirectory.appendingPathComponent(UUID().uuidString)
            try Data(contentsOf: url).write(to: target)
            record[key] = CKAsset(fileURL: target)
        }
    }
}
