import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// CloudKit layout (spec N1/N3, ADR-0003, Q1 "nur eigene iCloud Private Database").
///
/// - One custom zone `SoftwareRegisseur` in the **private** database; all entities live there, so
///   multi-record writes stay atomic per zone and no record is ever public.
/// - One record per synced entity. Record name `<entityType>.<UUID>` (the type prefix is needed because
///   e.g. a `GitHubIssueLink` reuses its work item's UUID); record type per entity, see `recordType(for:)`.
/// - The entity itself travels as the JSON payload produced by `GRDBSyncStore.currentPayload`, so the
///   field-level schema stays owned by Persistence and versioned by `schemaVersion`.
/// - Deletions are sent as **tombstone records** (`isDeleted = 1`, payload removed) instead of
///   CloudKit deletes, so they carry version and operation ID for replay protection (N3). Hard deletions
///   made outside the app are still understood when fetched.
public enum SyncRecordSchema {
    /// Shared with `LocalDataEraser.cloudZoneName` (data deletion) through `CloudSyncZone.name`.
    public static let zoneName = CloudSyncZone.name
    public static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Bumped when the record layout changes incompatibly; newer records are not applied (surfaced).
    public static let currentSchemaVersion = 1

    /// CloudKit limit for one modify request (`limitExceeded` above it).
    public static let maxRecordsPerBatch = 250

    /// Threshold rule for large text: CloudKit allows at most 1 MB of non-asset data per record. Payloads
    /// up to 512 KiB stay inline (end-to-end encrypted via `encryptedValues`); larger payloads (e.g. a long
    /// AI conversation) are stored as a `CKAsset` file, leaving headroom for metadata and system fields.
    public static let inlinePayloadLimit = 512 * 1024

    public enum Field {
        public static let schemaVersion = "schemaVersion"
        public static let entityId = "entityId"
        public static let version = "version"
        public static let baseVersion = "baseVersion"
        public static let operationId = "operationId"
        public static let originDeviceId = "originDeviceId"
        public static let isDeleted = "isDeleted"
        public static let modifiedAt = "modifiedAt"
        /// Encrypted bytes (`encryptedValues`).
        public static let payload = "payload"
        public static let payloadAsset = "payloadAsset"

        public static let all = [schemaVersion, entityId, version, baseVersion, operationId, originDeviceId,
                                 isDeleted, modifiedAt, payload, payloadAsset]
    }

    /// CloudKit record type. Exhaustive on purpose: a new entity kind needs an explicit decision.
    /// `nil` = never leaves the device (spec N1: audio stays local).
    public static func recordType(for type: SyncEntityType) -> CKRecord.RecordType? {
        switch type {
        case .project: "Project"
        case .projectSettings: "ProjectSettings"
        case .repositoryLocation: "RepositoryLocation"
        case .workItem: "WorkItem"
        case .adr: "ADR"
        case .audioNote: nil
        case .aiRequest: "AIRequest"
        case .aiConversation: "AIConversation"
        case .agentHost: "AgentHost"
        case .agentCapability: "AgentCapability"
        case .agentModelPreference: "AgentModelPreference"
        case .agentJob: "AgentJob"
        case .taskLock: "TaskLock"
        case .taskEvent: "TaskEvent"
        case .review: "Review"
        case .gitHubIssueLink: "GitHubIssueLink"
        case .providerProfile: "ProviderProfile"
        case .projectSetupCommand: "ProjectSetupCommand"
        case .indexedFolder: "IndexedFolder"
        case .fileConflict: "FileConflict"
        case .pendingApproval: "PendingApproval"
        case .approvalDecision: "ApprovalDecision"
        case .draftVersion: "DraftVersion"
        case .globalSettings: "GlobalSettings"
        }
    }

    public static func entityType(forRecordType recordType: CKRecord.RecordType) -> SyncEntityType? {
        SyncEntityType.allCases.first { self.recordType(for: $0) == recordType }
    }

    public static func recordName(_ type: SyncEntityType, _ id: UUID) -> String {
        "\(type.rawValue).\(id.uuidString)"
    }

    public static func recordID(_ type: SyncEntityType, _ id: UUID, zoneID: CKRecordZone.ID = zoneID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(type, id), zoneID: zoneID)
    }

    /// Parses `<entityType>.<UUID>`.
    public static func parse(recordName: String) -> (type: SyncEntityType, id: UUID)? {
        guard let dot = recordName.firstIndex(of: ".") else { return nil }
        guard let type = SyncEntityType(rawValue: String(recordName[..<dot])),
              let id = UUID(uuidString: String(recordName[recordName.index(after: dot)...]))
        else { return nil }
        return (type, id)
    }
}

public enum SyncMappingError: Error, Equatable, Sendable {
    /// Spec N1: device-local entity kinds never become records.
    case deviceLocalEntity(SyncEntityType)
    /// Spec N1/Q1: the payload looks like it contains key material; it is not sent.
    case secretMaterialRejected(entity: SyncEntityType, paths: [String])
    case unknownRecordType(String)
    case malformedRecord(recordName: String, reason: String)
    /// Written by a newer app version; not applied until this device is updated.
    case unsupportedSchema(recordName: String, version: Int)
    case payloadAssetUnreadable(recordName: String)
}

/// Content of one outgoing record, assembled from the outbox and entity state.
public struct OutgoingRecord: Sendable, Equatable {
    public let entityType: SyncEntityType
    public let entityId: UUID
    public let operationId: SyncOperationID
    public let isDeleted: Bool
    public let version: Int
    public let baseVersion: Int?
    /// JSON payload; nil for tombstones.
    public let payload: Data?
    /// Encoded system fields of the last known server record (change tag).
    public let systemFields: Data?
    public let modifiedAt: Date

    public init(
        entityType: SyncEntityType, entityId: UUID, operationId: SyncOperationID, isDeleted: Bool,
        version: Int, baseVersion: Int?, payload: Data?, systemFields: Data?, modifiedAt: Date
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.operationId = operationId
        self.isDeleted = isDeleted
        self.version = version
        self.baseVersion = baseVersion
        self.payload = payload
        self.systemFields = systemFields
        self.modifiedAt = modifiedAt
    }
}

/// A fetched record decoded for `GRDBSyncStore.applyRemoteChanges`.
public struct DecodedRecord: Sendable {
    public let change: RemoteChange
    public let originDeviceId: DeviceID?
}

/// Converts between outbox content and `CKRecord` (both directions).
public struct SyncRecordMapper: Sendable {
    public let zoneID: CKRecordZone.ID
    public let deviceId: DeviceID
    /// Where payload assets are written before upload (removed after the send completes).
    public let assetDirectory: URL

    public init(
        zoneID: CKRecordZone.ID = SyncRecordSchema.zoneID,
        deviceId: DeviceID,
        assetDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("SoftwareRegisseurSyncAssets", isDirectory: true)
    ) {
        self.zoneID = zoneID
        self.deviceId = deviceId
        self.assetDirectory = assetDirectory
    }

    // MARK: Outgoing

    public func makeRecord(_ content: OutgoingRecord) throws -> CKRecord {
        guard let recordType = SyncRecordSchema.recordType(for: content.entityType) else {
            throw SyncMappingError.deviceLocalEntity(content.entityType)
        }
        if let payload = content.payload {
            let violations = SecretGuard.violations(inJSON: payload)
            if !violations.isEmpty {
                throw SyncMappingError.secretMaterialRejected(entity: content.entityType, paths: violations)
            }
        }
        let recordID = SyncRecordSchema.recordID(content.entityType, content.entityId, zoneID: zoneID)
        let record = content.systemFields.flatMap(Self.record(fromSystemFields:))
            .flatMap { $0.recordID == recordID && $0.recordType == recordType ? $0 : nil }
            ?? CKRecord(recordType: recordType, recordID: recordID)

        typealias F = SyncRecordSchema.Field
        record[F.schemaVersion] = SyncRecordSchema.currentSchemaVersion
        record[F.entityId] = content.entityId.uuidString
        record[F.version] = content.version
        record[F.baseVersion] = content.baseVersion
        record[F.operationId] = content.operationId.uuidString
        record[F.originDeviceId] = deviceId.uuidString
        record[F.isDeleted] = content.isDeleted ? 1 : 0
        record[F.modifiedAt] = content.modifiedAt
        record.encryptedValues[F.payload] = nil
        record[F.payloadAsset] = nil
        if !content.isDeleted, let payload = content.payload {
            if payload.count <= SyncRecordSchema.inlinePayloadLimit {
                record.encryptedValues[F.payload] = payload
            } else {
                try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
                let file = assetDirectory.appendingPathComponent("\(recordID.recordName)-\(content.operationId.uuidString).json")
                try payload.write(to: file, options: .atomic)
                record[F.payloadAsset] = CKAsset(fileURL: file)
            }
        }
        return record
    }

    /// Removes the temporary asset file of a sent record.
    public func cleanUpAsset(of record: CKRecord) {
        guard let url = (record[SyncRecordSchema.Field.payloadAsset] as? CKAsset)?.fileURL,
              url.path.hasPrefix(assetDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Incoming

    public func decode(_ record: CKRecord) throws -> DecodedRecord {
        typealias F = SyncRecordSchema.Field
        let name = record.recordID.recordName
        guard let type = SyncRecordSchema.entityType(forRecordType: record.recordType) else {
            throw SyncMappingError.unknownRecordType(record.recordType)
        }
        guard let parsed = SyncRecordSchema.parse(recordName: name), parsed.type == type else {
            throw SyncMappingError.malformedRecord(recordName: name, reason: "record name")
        }
        let schema = (record[F.schemaVersion] as? Int) ?? 0
        guard schema >= 1 else { throw SyncMappingError.malformedRecord(recordName: name, reason: "schemaVersion") }
        guard schema <= SyncRecordSchema.currentSchemaVersion else {
            throw SyncMappingError.unsupportedSchema(recordName: name, version: schema)
        }
        guard let version = record[F.version] as? Int,
              let operationText = record[F.operationId] as? String,
              let operationId = SyncOperationID(uuidString: operationText)
        else { throw SyncMappingError.malformedRecord(recordName: name, reason: "version/operationId") }
        if let entityText = record[F.entityId] as? String, UUID(uuidString: entityText) != parsed.id {
            throw SyncMappingError.malformedRecord(recordName: name, reason: "entityId")
        }
        let isDeleted = ((record[F.isDeleted] as? Int) ?? 0) != 0
        var payload: Data?
        if !isDeleted {
            if let inline = record.encryptedValues[F.payload] as? Data {
                payload = inline
            } else if let asset = record[F.payloadAsset] as? CKAsset {
                guard let url = asset.fileURL, let data = try? Data(contentsOf: url) else {
                    throw SyncMappingError.payloadAssetUnreadable(recordName: name)
                }
                payload = data
            } else {
                throw SyncMappingError.malformedRecord(recordName: name, reason: "payload missing")
            }
        }
        let change = RemoteChange(
            operationId: operationId,
            entityType: type,
            entityId: parsed.id,
            kind: isDeleted ? .delete : (record[F.baseVersion] as? Int == nil ? .create : .update),
            version: version,
            baseVersion: record[F.baseVersion] as? Int,
            payload: payload,
            systemFields: Self.encodeSystemFields(of: record)
        )
        let origin = (record[F.originDeviceId] as? String).flatMap(DeviceID.init(uuidString:))
        return DecodedRecord(change: change, originDeviceId: origin)
    }

    // MARK: System fields

    /// `encodeSystemFields(with:)` round-trip; this is what `sync_entity_state.system_fields` stores.
    public static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
