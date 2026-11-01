import CryptoKit
import Foundation
import GRDB
import SoftwareRegisseurDomain

// Storage conventions (see also Schema/Migrations.swift):
// - UUIDs as uppercase TEXT (`uuidString`), open string IDs as verbatim TEXT (lossless, ADR-0006).
// - Dates as REAL seconds since the Foundation reference date (2001-01-01), which round-trips `Date`
//   exactly. GRDB's default text format would truncate to milliseconds.
// - Structured values as JSON TEXT with sorted keys, using Foundation's default `Date` strategy.

enum StoredDate {
    static func value(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }
    static func value(_ date: Date?) -> Double? { date?.timeIntervalSinceReferenceDate }
}

enum JSONColumn {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try SyncPayloadCodec.encode(value), as: UTF8.self)
    }

    static func encodeData<T: Encodable>(_ value: T) throws -> Data {
        try SyncPayloadCodec.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try SyncPayloadCodec.decode(type, from: Data(string.utf8))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try SyncPayloadCodec.decode(type, from: data)
    }
}

/// Rebuilds domain values whose stored properties are partly `private(set)` and not accepted by any
/// public initializer (e.g. `AgentJob.state`, `TaskLock.releasedAt`). The domain types are `Codable`,
/// so the stored columns are re-encoded under the synthesized coding keys and decoded through the
/// domain's own `Decodable` conformance. Round-trip tests guard the key names.
enum DomainBridge {
    struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct Fields: Encodable {
        let values: [String: any Encodable]

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicKey(key))
            }
        }
    }

    /// `nil` values are omitted, matching the synthesized `encodeIfPresent` behaviour.
    static func make<T: Decodable>(_ type: T.Type, _ values: [String: (any Encodable)?]) throws -> T {
        let present = values.compactMapValues { $0 }
        let data = try JSONColumn.encodeData(Fields(values: present))
        return try SyncPayloadCodec.decode(type, from: data)
    }
}

/// Deterministic name-based UUID (RFC 9562 version 5) for entities with a composite natural key,
/// so they get a stable sync entity ID (spec N3: unique IDs).
enum DeterministicUUID {
    private static let namespace = UUID(uuidString: "6F1D3C1E-6A8B-4E62-9C8D-2B7A4F0E5D11")!

    static func make(_ components: [String]) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(components.joined(separator: "\u{1F}").utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}

// MARK: - Row decoding helpers

extension Row {
    func required<T: DatabaseValueConvertible>(_ column: String, as type: T.Type = T.self) throws -> T {
        guard let value: T = self[column] else {
            throw StoreError.corruptValue(column: column, detail: "missing or NULL")
        }
        return value
    }

    func uuid(_ column: String) throws -> UUID {
        let string: String = try required(column)
        guard let uuid = UUID(uuidString: string) else {
            throw StoreError.corruptValue(column: column, detail: "invalid UUID '\(string)'")
        }
        return uuid
    }

    func optionalUUID(_ column: String) throws -> UUID? {
        guard let string: String = self[column] else { return nil }
        guard let uuid = UUID(uuidString: string) else {
            throw StoreError.corruptValue(column: column, detail: "invalid UUID '\(string)'")
        }
        return uuid
    }

    func id<Tag>(_ column: String) throws -> Identifier<Tag> {
        Identifier(rawValue: try uuid(column))
    }

    func optionalID<Tag>(_ column: String) throws -> Identifier<Tag>? {
        try optionalUUID(column).map { Identifier(rawValue: $0) }
    }

    func date(_ column: String) throws -> Date {
        Date(timeIntervalSinceReferenceDate: try required(column, as: Double.self))
    }

    func optionalDate(_ column: String) -> Date? {
        (self[column] as Double?).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    func bool(_ column: String) throws -> Bool {
        try required(column, as: Int64.self) != 0
    }

    func int(_ column: String) throws -> Int {
        Int(try required(column, as: Int64.self))
    }

    func optionalInt(_ column: String) -> Int? {
        (self[column] as Int64?).map { Int($0) }
    }

    func string(_ column: String) throws -> String {
        try required(column, as: String.self)
    }

    func enumValue<T: RawRepresentable>(_ column: String, as type: T.Type = T.self) throws -> T where T.RawValue == String {
        let raw: String = try required(column)
        guard let value = T(rawValue: raw) else {
            throw StoreError.corruptValue(column: column, detail: "unknown \(T.self) '\(raw)'")
        }
        return value
    }

    func optionalEnum<T: RawRepresentable>(_ column: String, as type: T.Type = T.self) throws -> T? where T.RawValue == String {
        guard let raw: String = self[column] else { return nil }
        guard let value = T(rawValue: raw) else {
            throw StoreError.corruptValue(column: column, detail: "unknown \(T.self) '\(raw)'")
        }
        return value
    }

    func open<T: OpenStringIdentifier>(_ column: String, as type: T.Type = T.self) throws -> T {
        try enumValue(column, as: T.self)
    }

    func optionalOpen<T: OpenStringIdentifier>(_ column: String, as type: T.Type = T.self) throws -> T? {
        try optionalEnum(column, as: T.self)
    }

    func json<T: Decodable>(_ column: String, as type: T.Type = T.self) throws -> T {
        let text: String = try required(column)
        do {
            return try JSONColumn.decode(T.self, from: text)
        } catch {
            throw StoreError.corruptValue(column: column, detail: "invalid JSON for \(T.self): \(error)")
        }
    }

    func optionalJSON<T: Decodable>(_ column: String, as type: T.Type = T.self) throws -> T? {
        guard let text: String = self[column] else { return nil }
        do {
            return try JSONColumn.decode(T.self, from: text)
        } catch {
            throw StoreError.corruptValue(column: column, detail: "invalid JSON for \(T.self): \(error)")
        }
    }
}

// MARK: - SQL helpers

typealias ColumnValues = KeyValuePairs<String, (any DatabaseValueConvertible)?>

extension Database {
    /// Whether `table` has `column` (schema-version-tolerant writes; GRDB caches the schema).
    func hasColumn(_ column: String, in table: String) throws -> Bool {
        try columns(in: table).contains { $0.name == column }
    }

    /// `INSERT … ON CONFLICT(keys) DO UPDATE` keeps the rowid and never cascades deletes into child
    /// tables, unlike `INSERT OR REPLACE`.
    /// With `ignoreExisting`, an existing row is left untouched (`DO NOTHING`).
    func upsert(into table: String, _ values: ColumnValues, conflictKeys: [String], ignoreExisting: Bool = false) throws {
        let columns = values.map(\.key)
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updates = columns.filter { !conflictKeys.contains($0) }.map { "\($0) = excluded.\($0)" }
        let action = ignoreExisting || updates.isEmpty ? "DO NOTHING" : "DO UPDATE SET \(updates.joined(separator: ", "))"
        let sql = """
            INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
            ON CONFLICT(\(conflictKeys.joined(separator: ", "))) \(action)
            """
        try execute(sql: sql, arguments: StatementArguments(values.map { $0.value?.databaseValue ?? .null }))
    }

    func insert(into table: String, _ values: ColumnValues) throws {
        let columns = values.map(\.key)
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try execute(
            sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
            arguments: StatementArguments(values.map { $0.value?.databaseValue ?? .null })
        )
    }
}

extension Identifier {
    var databaseText: String { rawValue.uuidString }
}
