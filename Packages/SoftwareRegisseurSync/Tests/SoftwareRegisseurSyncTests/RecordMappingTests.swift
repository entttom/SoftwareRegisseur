import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
@testable import SoftwareRegisseurSyncTesting
import Testing

@Suite("Record mapping")
struct RecordMappingTests {
    let mapper = SyncRecordMapper(deviceId: DeviceID(),
                                  assetDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("MappingTests-\(UUID().uuidString)"))

    func outgoing(_ type: SyncEntityType, _ id: UUID, payload: Data?, version: Int = 1, base: Int? = nil,
                  systemFields: Data? = nil) -> OutgoingRecord {
        OutgoingRecord(entityType: type, entityId: id, operationId: SyncOperationID(), isDeleted: payload == nil,
                       version: version, baseVersion: base, payload: payload, systemFields: systemFields, modifiedAt: t0)
    }

    @Test func everySyncedEntityHasAUniqueRecordTypeInTheCustomZone() throws {
        var seen = Set<String>()
        for type in SyncEntityType.allCases {
            let recordType = SyncRecordSchema.recordType(for: type)
            #expect((recordType == nil) == type.isDeviceLocal, "\(type)")
            guard let recordType else { continue }
            #expect(seen.insert(recordType).inserted)
            #expect(SyncRecordSchema.entityType(forRecordType: recordType) == type)
            let id = UUID()
            let recordID = SyncRecordSchema.recordID(type, id)
            #expect(recordID.zoneID.zoneName == "SoftwareRegisseur")
            #expect(recordID.zoneID.ownerName == CKCurrentUserDefaultName)
            #expect(SyncRecordSchema.parse(recordName: recordID.recordName)! == (type, id))
        }
        // A work item and its GitHub issue link share the UUID but not the record.
        let shared = UUID()
        #expect(SyncRecordSchema.recordName(.workItem, shared) != SyncRecordSchema.recordName(.gitHubIssueLink, shared))
    }

    @Test func recordRoundTripsPayloadVersionAndOperation() throws {
        let item = Fixture.workItem(projectId: nil)
        let content = outgoing(.workItem, item.uuid.rawValue, payload: try payload(item), version: 4, base: 3)
        let record = try mapper.makeRecord(content)
        #expect(record.recordType == "WorkItem")
        // User text is end-to-end encrypted, not a plain field.
        #expect(record.encryptedValues[SyncRecordSchema.Field.payload] != nil)
        #expect(record[SyncRecordSchema.Field.payloadAsset] == nil)

        let decoded = try mapper.decode(record)
        #expect(decoded.originDeviceId == mapper.deviceId)
        #expect(decoded.change.operationId == content.operationId)
        #expect(decoded.change.entityType == .workItem)
        #expect(decoded.change.entityId == item.uuid.rawValue)
        #expect(decoded.change.kind == .update)
        #expect(decoded.change.version == 4)
        #expect(decoded.change.baseVersion == 3)
        #expect(try decode(WorkItem.self, decoded.change.payload) == item)

        let tombstone = try mapper.decode(try mapper.makeRecord(outgoing(.workItem, item.uuid.rawValue, payload: nil, version: 5, base: 4)))
        #expect(tombstone.change.kind == .delete)
        #expect(tombstone.change.payload == nil)
    }

    @Test func systemFieldsRoundTripKeepsTheServerChangeTag() throws {
        let item = Fixture.workItem(projectId: nil)
        let record = try mapper.makeRecord(outgoing(.workItem, item.uuid.rawValue, payload: try payload(item)))
        FakeCloudDatabase.setChangeTag("tag-42", on: record)
        let fields = SyncRecordMapper.encodeSystemFields(of: record)
        // Stored system fields contain no user data.
        #expect(SyncRecordMapper.record(fromSystemFields: fields)?.allKeys().isEmpty == true)

        let next = try mapper.makeRecord(outgoing(.workItem, item.uuid.rawValue, payload: try payload(item), version: 2, base: 1, systemFields: fields))
        #expect(next.recordChangeTag == "tag-42")
        #expect(next.recordID == record.recordID)
        // Fields of another record are never reused.
        let other = try mapper.makeRecord(outgoing(.workItem, UUID(), payload: try payload(Fixture.workItem(projectId: nil)), systemFields: fields))
        #expect(other.recordChangeTag == nil)
    }

    @Test func largePayloadBecomesAnAssetAboveTheThreshold() throws {
        let long = String(repeating: "Lange Anforderung. ", count: 40_000) // ≈ 760 KB
        let item = Fixture.workItem(projectId: nil, body: long)
        let data = try payload(item)
        #expect(data.count > SyncRecordSchema.inlinePayloadLimit)
        let record = try mapper.makeRecord(outgoing(.workItem, item.uuid.rawValue, payload: data))
        #expect(record.encryptedValues[SyncRecordSchema.Field.payload] == nil)
        let asset = try #require(record[SyncRecordSchema.Field.payloadAsset] as? CKAsset)
        #expect(try decode(WorkItem.self, try mapper.decode(record).change.payload).structuredBody == long)
        mapper.cleanUpAsset(of: record)
        #expect(!FileManager.default.fileExists(atPath: asset.fileURL!.path))

        let small = Fixture.workItem(projectId: nil)
        #expect(try mapper.makeRecord(outgoing(.workItem, small.uuid.rawValue, payload: try payload(small)))[SyncRecordSchema.Field.payloadAsset] == nil)
    }

    @Test func deviceLocalEntitiesAreNeverMapped() throws {
        #expect(throws: SyncMappingError.deviceLocalEntity(.audioNote)) {
            try mapper.makeRecord(outgoing(.audioNote, UUID(), payload: Data("{}".utf8)))
        }
    }

    /// Spec N1/Q1, A27: provider profiles sync only their Keychain coordinates, never key material.
    @Test func providerProfilesCarryNoKeyMaterial() throws {
        let secret = "sk-ant-api03-" + String(repeating: "x", count: 40)
        let profile = ProviderProfile(
            providerId: .anthropic, purpose: .textDrafting, model: "claude-opus",
            keychainReference: KeychainReference(service: "de.softwareregisseur.ai", account: "anthropic"),
            deviceScope: .iCloudKeychain, settings: ["language": "de"]
        )
        let record = try mapper.makeRecord(outgoing(.providerProfile, profile.id.rawValue, payload: try payload(profile)))
        for key in record.allKeys() + record.encryptedValues.allKeys() {
            for forbidden in ["key", "token", "secret", "password"] {
                #expect(!key.lowercased().contains(forbidden), "field \(key)")
            }
        }
        let synced = try mapper.decode(record).change.payload!
        #expect(SecretGuard.violations(inJSON: synced).isEmpty)
        #expect(!String(decoding: synced, as: UTF8.self).contains(secret))
        let object = try #require(try JSONSerialization.jsonObject(with: synced) as? [String: Any])
        #expect(Set(object.keys).allSatisfy { !SecretGuard.isForbiddenKeyName($0) })

        // A key that slipped into the settings is refused before it becomes a record.
        var leaking = profile
        leaking.settings["apiKey"] = secret
        #expect(throws: SyncMappingError.secretMaterialRejected(entity: .providerProfile, paths: ["$.settings.apiKey"])) {
            try mapper.makeRecord(outgoing(.providerProfile, leaking.id.rawValue, payload: try payload(leaking)))
        }
        var pasted = profile
        pasted.settings["baseURL"] = "Bearer " + String(repeating: "a", count: 32)
        #expect(throws: SyncMappingError.self) {
            try mapper.makeRecord(outgoing(.providerProfile, pasted.id.rawValue, payload: try payload(pasted)))
        }
    }

    @Test func secretGuardKeepsLegitimateFieldNames() {
        for name in ["keychainReference", "idempotencyKey", "inputTokens", "outputTokens", "authenticated", "sessionId"] {
            #expect(!SecretGuard.isForbiddenKeyName(name), "\(name)")
        }
        for name in ["apiKey", "api_key", "openAIApiKey", "accessToken", "refresh-token", "clientSecret", "password", "token"] {
            #expect(SecretGuard.isForbiddenKeyName(name), "\(name)")
        }
    }

    @Test func recordsOfANewerSchemaOrForeignShapeAreRejected() throws {
        let item = Fixture.workItem(projectId: nil)
        let record = try mapper.makeRecord(outgoing(.workItem, item.uuid.rawValue, payload: try payload(item)))
        record[SyncRecordSchema.Field.schemaVersion] = SyncRecordSchema.currentSchemaVersion + 1
        #expect(throws: SyncMappingError.unsupportedSchema(recordName: record.recordID.recordName, version: 2)) {
            try mapper.decode(record)
        }
        let foreign = CKRecord(recordType: "Unknown", recordID: CKRecord.ID(recordName: "x", zoneID: SyncRecordSchema.zoneID))
        #expect(throws: SyncMappingError.unknownRecordType("Unknown")) { try mapper.decode(foreign) }
    }
}
