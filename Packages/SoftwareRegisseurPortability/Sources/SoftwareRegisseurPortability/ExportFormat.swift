import Foundation
import SoftwareRegisseurPersistence

// MARK: - Export folder layout (format version 1)
//
//   SoftwareRegisseur-Export-<yyyyMMdd-HHmmss>/
//     manifest.json                 ExportManifest (ISO 8601 dates, pretty printed)
//     LIESMICH.md                   German explanation of the contents
//     data/<entityType>.json        one JSON array per SyncEntityType (all 24 kinds, also when empty),
//                                   one element per line; every element is the canonical SyncPayloadCodec payload of one entity,
//                                   byte-identical to `GRDBSyncStore.currentPayload` (provider profiles:
//                                   key-like settings removed, see `ExportManifest.SecretScan`)
//     data/syncConflicts.json       open and resolved sync conflicts (`ExportedSyncConflict`)
//     markdown/requests/<project>/  one human-readable Markdown file per work item (incl. original note,
//                                   transcript and all draft versions)
//     markdown/adrs/<project>/      one Markdown file per ADR (repository template structure)
//     audio/                        optional copies of local dictation recordings
//
//   Payload dates use Foundation's `deferredToDate` (seconds since 2001-01-01 as Double) exactly like
//   sync payloads, so a payload can be fed back into `SyncPayloadCodec.decode` / `applyRemoteChanges`.

/// Device that produced the export.
public struct ExportDeviceInfo: Hashable, Sendable, Codable {
    public var name: String
    public var platform: String
    public var osVersion: String

    public init(name: String, platform: String, osVersion: String) {
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
    }

    /// Best effort from `ProcessInfo`; apps may pass the user-visible device name instead.
    public static var current: ExportDeviceInfo {
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "unknown"
        #endif
        let info = ProcessInfo.processInfo
        return ExportDeviceInfo(name: info.hostName, platform: platform, osVersion: info.operatingSystemVersionString)
    }
}

public struct ExportManifest: Hashable, Sendable, Codable {
    public static let formatIdentifier = "software-regisseur-export"
    public static let currentFormatVersion = 1
    public static let fileName = "manifest.json"

    public struct EntityFile: Hashable, Sendable, Codable {
        public var entityType: SyncEntityType
        public var path: String
        public var count: Int
    }

    public struct FileChecksum: Hashable, Sendable, Codable {
        /// Path relative to the export folder, `/`-separated.
        public var path: String
        public var bytes: Int64
        /// Lowercase hex SHA-256 of the file contents.
        public var sha256: String
    }

    public struct UserContentFinding: Hashable, Sendable, Codable {
        public var path: String
        /// JSON path (`$[3].originalNote`) or `line <n>` for Markdown.
        public var location: String
    }

    /// Outcome of the secret scan (rules: `ExportSecretScanner`).
    ///
    /// Policy: key material of provider profiles is never exported. Settings entries of provider profiles
    /// whose name or value looks like a credential are removed (`removedProviderSettings` lists profile ID
    /// and setting name, never the value); the export fails if provider data still matches afterwards.
    /// Text the user wrote (notes, transcripts, drafts, ADRs, events) is exported unchanged because it is
    /// the user's own content; credential-looking passages are only listed in `userContentFindings` so
    /// the app can warn before the export is shared.
    public struct SecretScan: Hashable, Sendable, Codable {
        public var rulesVersion: Int
        public var removedProviderSettings: [String]
        public var userContentFindings: [UserContentFinding]
    }

    public struct MarkdownSummary: Hashable, Sendable, Codable {
        public var requests: Int
        public var adrs: Int
    }

    public var format: String
    public var formatVersion: Int
    public var createdAt: Date
    public var device: ExportDeviceInfo
    public var appVersion: String
    /// Applied database migrations of the source database.
    public var databaseSchema: [String]
    public var payloadEncoding: String
    public var entities: [EntityFile]
    public var syncConflicts: Int
    public var markdown: MarkdownSummary
    public var audioFiles: Int
    /// Every file of the export except `manifest.json` itself.
    public var files: [FileChecksum]
    public var secretScan: SecretScan
    /// German list of what is deliberately not part of the export.
    public var excluded: [String]

    public func count(of type: SyncEntityType) -> Int {
        entities.first { $0.entityType == type }?.count ?? 0
    }

    public var totalEntityCount: Int { entities.reduce(0) { $0 + $1.count } }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads `manifest.json` of an export folder.
    public static func load(fromExportFolder folder: URL) throws -> ExportManifest {
        try makeDecoder().decode(ExportManifest.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }
}

/// Sync conflict as written to `data/syncConflicts.json` (payloads embedded as JSON, not base64).
public struct ExportedSyncConflict: Hashable, Sendable, Codable {
    public var id: UUID
    public var entityType: SyncEntityType
    public var entityId: UUID
    public var baseVersion: Int?
    public var localVersion: Int
    public var remoteVersion: Int
    public var localPayload: JSONValue?
    public var remotePayload: JSONValue?
    public var ancestorPayload: JSONValue?
    public var remoteChangeKind: String
    public var detectedAt: Date
    public var resolvedAt: Date?
    public var resolution: String?
    public var resolvedBy: String?
}

/// Minimal JSON tree for embedding canonical payloads in export DTOs.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }
}

/// Reads the entity files of an export folder (verification, tests, a later import).
public enum ExportReader {
    /// Raw canonical payloads of one entity kind, in file order and byte-identical to what was exported.
    /// Entity files hold one compact payload per line (JSON escapes newlines inside strings), so the
    /// lines between `[` and `]` are the payloads; each one is validated as JSON.
    public static func payloads(of type: SyncEntityType, inExportFolder folder: URL) throws -> [Data] {
        let url = folder.appendingPathComponent(DataExporter.entityFilePath(type))
        let data = try Data(contentsOf: url)
        _ = try JSONSerialization.jsonObject(with: data) // whole file is a valid JSON array
        var payloads: [Data] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            var element = Data(line)
            if element == Data("[".utf8) || element == Data("]".utf8) || element == Data("[]".utf8) { continue }
            if element.last == UInt8(ascii: ",") { element.removeLast() }
            _ = try JSONSerialization.jsonObject(with: element)
            payloads.append(element)
        }
        return payloads
    }

    /// Decodes the entity file of `type` into domain values with the canonical payload codec.
    public static func entities<T: Decodable>(_: T.Type, of type: SyncEntityType, inExportFolder folder: URL) throws -> [T] {
        let url = folder.appendingPathComponent(DataExporter.entityFilePath(type))
        return try SyncPayloadCodec.decode([T].self, from: Data(contentsOf: url))
    }

    public static func syncConflicts(inExportFolder folder: URL) throws -> [ExportedSyncConflict] {
        let url = folder.appendingPathComponent(DataExporter.syncConflictsPath)
        return try SyncPayloadCodec.decode([ExportedSyncConflict].self, from: Data(contentsOf: url))
    }
}
