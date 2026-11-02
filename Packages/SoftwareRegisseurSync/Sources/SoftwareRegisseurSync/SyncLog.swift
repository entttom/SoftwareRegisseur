import CloudKit
import Foundation
import os

/// Unified logging for the sync layer (`log stream --predicate 'subsystem == "SoftwareRegisseur" AND
/// category == "Sync"'`). Only CloudKit error codes, their descriptions and record names (type + UUID) are
/// logged, never payloads or record values (spec N1, AGENTS.md: keine Geheimnisse in Logs).
enum SyncLog {
    static let logger = Logger(subsystem: "SoftwareRegisseur", category: "Sync")

    /// "CKError 11 (unknownItem): …" plus, for a `partialFailure`, the per-item codes.
    static func describe(_ error: any Error) -> String {
        guard let ckError = error as? CKError else { return "\(type(of: error)): \(error.localizedDescription)" }
        var text = "CKError \(ckError.code.rawValue) (\(ckError.code)): \(ckError.localizedDescription)"
        if let retry = ckError.retryAfterSeconds { text += " [retryAfter \(retry)s]" }
        if let items = ckError.partialErrorsByItemID, !items.isEmpty {
            let parts = items.prefix(10).map { key, value -> String in
                let name = (key as? CKRecord.ID)?.recordName ?? (key as? CKRecordZone.ID)?.zoneName ?? "\(key)"
                let code = (value as? CKError).map { "\($0.code.rawValue) (\($0.code))" } ?? "?"
                return "\(name): \(code) \(value.localizedDescription)"
            }
            text += "; Einträge (\(items.count)): " + parts.joined(separator: "; ")
        }
        return text
    }
}
