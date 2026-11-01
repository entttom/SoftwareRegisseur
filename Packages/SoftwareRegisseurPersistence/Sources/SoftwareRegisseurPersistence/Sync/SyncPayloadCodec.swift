import Foundation
import GRDB

/// The canonical JSON format of sync payloads and JSON columns: sorted keys, unescaped slashes and
/// Foundation's default `Date` strategy (`deferredToDate`, i.e. a `Double` of seconds since
/// 2001-01-01, which round-trips `Date` exactly). `currentPayload`, `RemoteChange.payload`,
/// `SyncConflict` payloads and `ConflictResolution.merged` all use it, so callers that build payloads
/// (e.g. a merged conflict value) must use this codec instead of configuring their own encoder.
public enum SyncPayloadCodec {
    public static let outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// Decodes `data` as the domain value of `entityType` and re-encodes it canonically. Use it for
    /// payloads assembled outside Persistence (e.g. a generic JSON merge): it validates the value and
    /// yields exactly the bytes `currentPayload` would produce for it.
    /// Throws `StoreError.invalidRemoteChange` if the data is not a valid value of that kind.
    public static func canonicalize(_ data: Data, entityType: SyncEntityType) throws -> Data {
        func open<S: EntityStorage>(_ storage: S.Type) throws -> Data {
            try encode(try S.decodePayload(data))
        }
        return try open(entityType.storage)
    }
}
