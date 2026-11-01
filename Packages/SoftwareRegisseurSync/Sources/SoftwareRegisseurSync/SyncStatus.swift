import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Why a sync was triggered (ADR-0011: no visible push; explicit triggers only).
public enum SyncReason: String, Sendable, Codable, CaseIterable {
    case appLaunch
    case foreground
    case pullToRefresh
    case manual
    /// macOS Agent Service polling (`PollingScheduler`).
    case poll
    /// A local write wants its outbox entry sent (debounced by the caller).
    case localChange
}

/// Device role for merge rules (spec N2: the Mac execution host owns execution metadata).
public enum DeviceRole: Sendable, Equatable {
    case executionHost(HostID)
    case mobile

    public var isExecutionHost: Bool {
        if case .executionHost = self { true } else { false }
    }
}

public enum SyncAccountState: String, Sendable, Codable, Equatable {
    case unknown
    case available
    /// No iCloud account (or signed out). Sync paused; local data stays.
    case signedOut
    /// A different iCloud account than before. Paused until the user confirms (`acknowledgeAccountChange`).
    case switched
    /// `accountTemporarilyUnavailable` (e.g. pending terms, restricted).
    case temporarilyUnavailable
}

/// Situations the UI must show (A26, A42). None of them deletes local data.
public enum SyncAttention: Sendable, Equatable, Hashable {
    case accountSignedOut
    case accountSwitched
    case zoneDeleted(ZoneDeletionReason)
    case openConflicts(Int)
    /// Records refused by `SecretGuard` (spec N1).
    case secretsBlocked(Int)
    case invalidRemoteRecords(Int)
    /// Records from a newer app version were skipped.
    case newerSchema
    case iCloudQuotaExceeded
    /// The user deleted the app's iCloud data on this device (A34). Sync is paused until the user chooses
    /// „Wieder mit iCloud synchronisieren“ (`SyncCoordinator.recreateZoneAndResume`).
    case cloudDataDeletedByUser
    /// The user confirmed the deletion, but iCloud has not confirmed it yet (e.g. offline). Paused as well;
    /// `SyncCoordinator.retryCloudDataDeletion` tries again.
    case cloudDataDeletionPending

    /// German UI text (spec P: German interfaces).
    public var message: String {
        switch self {
        case .accountSignedOut:
            String(localized: "Kein iCloud-Account angemeldet. Die Synchronisierung ist pausiert; lokale Daten bleiben erhalten.", bundle: .module)
        case .accountSwitched:
            String(localized: "Der iCloud-Account wurde gewechselt. Die Synchronisierung ist pausiert, bis Sie bestätigen, mit dem neuen Account fortzufahren. Lokale Daten bleiben erhalten.", bundle: .module)
        case .zoneDeleted(.purged):
            String(localized: "Die iCloud-Daten von Software Regisseur wurden in den Einstellungen gelöscht. Lokale Daten bleiben erhalten; bitte entscheiden Sie, ob sie erneut hochgeladen werden sollen.", bundle: .module)
        case .zoneDeleted(.encryptedDataReset):
            String(localized: "Die verschlüsselten iCloud-Daten wurden zurückgesetzt. Lokale Daten bleiben erhalten; bitte entscheiden Sie, ob sie erneut hochgeladen werden sollen.", bundle: .module)
        case .zoneDeleted(.deleted):
            String(localized: "Der iCloud-Datenbereich von Software Regisseur wurde gelöscht. Lokale Daten bleiben erhalten; bitte entscheiden Sie, ob sie erneut hochgeladen werden sollen.", bundle: .module)
        case let .openConflicts(count):
            count == 1 ? String(localized: "1 Synchronisierungskonflikt wartet auf Ihre Entscheidung.", bundle: .module)
                : String(localized: "\(count) Synchronisierungskonflikte warten auf Ihre Entscheidung.", bundle: .module)
        case let .secretsBlocked(count):
            String(localized: "\(count) Änderung(en) enthalten vermutlich Zugangsdaten und werden nicht synchronisiert.", bundle: .module)
        case let .invalidRemoteRecords(count):
            String(localized: "\(count) Datensatz/Datensätze aus iCloud konnten nicht gelesen werden.", bundle: .module)
        case .newerSchema:
            String(localized: "Ein anderes Gerät nutzt eine neuere Version von Software Regisseur. Bitte aktualisieren Sie diese App.", bundle: .module)
        case .iCloudQuotaExceeded:
            String(localized: "Der iCloud-Speicher ist voll. Neue Änderungen bleiben lokal, bis wieder Speicher frei ist.", bundle: .module)
        case .cloudDataDeletedByUser:
            String(localized: "Ihre iCloud-Daten von Software Regisseur wurden auf Ihren Wunsch gelöscht. Die Synchronisierung ist pausiert; lokale Daten bleiben auf diesem Gerät. Mit „Wieder mit iCloud synchronisieren“ werden sie erneut hochgeladen.", bundle: .module)
        case .cloudDataDeletionPending:
            String(localized: "Das Löschen der iCloud-Daten ist noch nicht abgeschlossen. Die Synchronisierung bleibt pausiert, bis iCloud das Löschen bestätigt hat. Bitte erneut versuchen, sobald eine Verbindung besteht.", bundle: .module)
        }
    }
}

/// UI-facing sync state (A26: sync time visible without push).
public struct SyncStatus: Sendable, Equatable {
    public var lastSuccessfulFetch: Date?
    public var lastSuccessfulSend: Date?
    /// Unsent outbox operations.
    public var pendingCount: Int
    public var openConflictCount: Int
    /// German, user-presentable.
    public var lastError: String?
    public var accountState: SyncAccountState
    public var attention: [SyncAttention]
    public var isPaused: Bool
    public var isSyncing: Bool
    /// CloudKit `retryAfterSeconds` honoured until then.
    public var retryNotBefore: Date?

    public var needsAttention: Bool { !attention.isEmpty }
    /// The user deleted the iCloud data (completed or still pending); sync is paused until they resume.
    public var isCloudDataDeletedByUser: Bool {
        attention.contains(.cloudDataDeletedByUser) || attention.contains(.cloudDataDeletionPending)
    }

    public init(
        lastSuccessfulFetch: Date? = nil, lastSuccessfulSend: Date? = nil, pendingCount: Int = 0,
        openConflictCount: Int = 0, lastError: String? = nil, accountState: SyncAccountState = .unknown,
        attention: [SyncAttention] = [], isPaused: Bool = false, isSyncing: Bool = false, retryNotBefore: Date? = nil
    ) {
        self.lastSuccessfulFetch = lastSuccessfulFetch
        self.lastSuccessfulSend = lastSuccessfulSend
        self.pendingCount = pendingCount
        self.openConflictCount = openConflictCount
        self.lastError = lastError
        self.accountState = accountState
        self.attention = attention
        self.isPaused = isPaused
        self.isSyncing = isSyncing
        self.retryNotBefore = retryNotBefore
    }
}

public enum SyncPauseReason: String, Sendable, Equatable {
    case accountUnavailable
    case accountSwitched
    case zoneDeleted
    case notStarted
}

/// Counts of one run, e.g. to prove "exactly once" (A10).
public struct SyncRunReport: Sendable, Equatable {
    public var applied = 0
    public var deleted = 0
    public var duplicates = 0
    public var stale = 0
    public var conflicts = 0
    /// Own records echoed back by the server.
    public var ownEchoes = 0
    public var invalid = 0
    public var sent = 0
    public var sendFailures = 0
    public var mergedOnServerChange = 0
    /// Conflicts resolved by a clean 3-way merge (recorded, not silent; spec N2).
    public var mergedAutomatically = 0
    /// Entities re-queued for a full upload (zone loss, account switch).
    public var requeuedForUpload = 0

    public init() {}

    mutating func count(_ outcome: RemoteApplyOutcome) {
        switch outcome {
        case .applied: applied += 1
        case .deleted: deleted += 1
        case .duplicate: duplicates += 1
        case .stale: stale += 1
        case .conflict: conflicts += 1
        }
    }
}

public struct SyncFailure: Sendable, Equatable, Error {
    /// German, user-presentable.
    public let message: String
    public let code: CKError.Code?
    public let retryAfter: TimeInterval?
}

public enum SyncRunResult: Sendable, Equatable {
    case completed(SyncRunReport)
    /// CloudKit asked to wait (`retryAfterSeconds`); nothing was sent to the server.
    case deferred(until: Date)
    case paused(SyncPauseReason)
    case failed(SyncFailure)
    /// Another run is in progress; this trigger is merged into a follow-up run.
    case coalesced

    public var report: SyncRunReport? {
        if case let .completed(report) = self { report } else { nil }
    }
}

/// Why `SyncCoordinator.deleteCloudData(_:)` did not (yet) delete the iCloud data.
public enum CloudDataDeletionError: Error, Equatable, Sendable {
    /// The coordinator was not started (no iCloud in this build or start failed).
    case notStarted
    /// The request names another zone than the one this coordinator syncs.
    case zoneMismatch(expected: String, requested: String)
    /// A sync run is in progress; try again in a moment.
    case syncInProgress
    /// The iCloud account changed; the user must confirm the new account first.
    case accountChangePending
    /// The deletion was sent but not confirmed. Sync stays paused; retry with the same request.
    case failed(SyncFailure)

    /// German, user-presentable.
    public var userMessage: String {
        switch self {
        case .notStarted:
            String(localized: "Die iCloud-Synchronisierung ist auf diesem Gerät nicht aktiv. iCloud-Daten können hier nicht gelöscht werden.", bundle: .module)
        case .zoneMismatch:
            String(localized: "Die Löschanforderung passt nicht zum iCloud-Datenbereich dieser App. Es wurde nichts gelöscht.", bundle: .module)
        case .syncInProgress:
            String(localized: "Gerade läuft eine Synchronisierung. Bitte versuchen Sie es in einem Moment erneut.", bundle: .module)
        case .accountChangePending:
            String(localized: "Der iCloud-Account wurde gewechselt. Bitte bestätigen Sie zuerst den neuen Account.", bundle: .module)
        case let .failed(failure):
            String(localized: "Die iCloud-Daten konnten noch nicht gelöscht werden: \(failure.message) Die Synchronisierung bleibt pausiert.", bundle: .module)
        }
    }
}

/// German texts for CloudKit errors (no raw codes in the UI).
public enum SyncErrorText {
    public static func message(for error: any Error, retryAfter: TimeInterval? = nil) -> String {
        guard let ckError = error as? CKError else {
            if let mapping = error as? SyncMappingError { return message(for: mapping) }
            let detail = error.localizedDescription
            return String(localized: "Synchronisierung fehlgeschlagen: \(detail)", bundle: .module)
        }
        // `partialFailure` only says "some items failed"; the cause is in the per-item errors.
        if ckError.code == .partialFailure, let primary = primaryError(of: ckError) {
            return message(for: primary, retryAfter: retryAfter ?? ckError.retryAfterSeconds)
        }
        let wait = (retryAfter ?? ckError.retryAfterSeconds).map { value in
            let seconds = Int(value.rounded(.up))
            return " " + String(localized: "Nächster Versuch in \(seconds) Sekunden.", bundle: .module)
        } ?? ""
        switch ckError.code {
        case .networkUnavailable, .networkFailure:
            return String(localized: "Keine Verbindung zu iCloud. Änderungen bleiben lokal gespeichert und werden beim nächsten Abgleich übertragen.", bundle: .module) + wait
        case .notAuthenticated:
            return String(localized: "Kein iCloud-Account angemeldet. Bitte in den Einstellungen bei iCloud anmelden; lokale Daten bleiben erhalten.", bundle: .module)
        case .accountTemporarilyUnavailable:
            return String(localized: "Der iCloud-Account ist vorübergehend nicht verfügbar.", bundle: .module) + wait
        case .requestRateLimited:
            return String(localized: "iCloud drosselt Anfragen.", bundle: .module) + wait
        case .serviceUnavailable, .zoneBusy:
            return String(localized: "iCloud ist vorübergehend nicht erreichbar.", bundle: .module) + wait
        case .quotaExceeded:
            return SyncAttention.iCloudQuotaExceeded.message
        case .zoneNotFound, .userDeletedZone:
            return String(localized: "Der iCloud-Datenbereich fehlt und wird neu angelegt.", bundle: .module)
        case .serverRecordChanged:
            return String(localized: "Ein Datensatz wurde gleichzeitig auf einem anderen Gerät geändert.", bundle: .module)
        case .limitExceeded:
            return String(localized: "Zu viele Änderungen in einer Anfrage; sie werden in kleineren Paketen übertragen.", bundle: .module)
        case .changeTokenExpired:
            return String(localized: "Der Synchronisierungsstand ist abgelaufen; alle Daten werden neu abgeglichen.", bundle: .module)
        case .operationCancelled:
            return String(localized: "Die Synchronisierung wurde abgebrochen.", bundle: .module) + wait
        case .serverRejectedRequest:
            // Typical cause: record types missing in the CloudKit environment of this build (Production
            // schema not deployed for TestFlight/App Store builds).
            return String(localized: "iCloud hat die Änderungen abgelehnt. Möglicherweise passt das iCloud-Datenschema nicht zu dieser App-Version; Änderungen bleiben lokal gespeichert.", bundle: .module)
        default:
            let code = ckError.code.rawValue
            return String(localized: "iCloud-Synchronisierung fehlgeschlagen (Code \(code)).", bundle: .module) + wait
        }
    }

    /// The per-item error that explains a `partialFailure`. `batchRequestFailed` only marks items that
    /// were rejected because another item of the same atomic batch failed, so it is skipped when a real
    /// cause exists. Deterministic (lowest code first), so the shown text does not flicker between runs.
    static func primaryError(of error: CKError) -> CKError? {
        let itemErrors = (error.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }
        let causes = itemErrors.filter { $0.code != .batchRequestFailed && $0.code != .partialFailure }
        return (causes.isEmpty ? itemErrors.filter { $0.code != .partialFailure } : causes)
            .min { $0.code.rawValue < $1.code.rawValue }
    }

    public static func message(for error: SyncMappingError) -> String {
        switch error {
        case .deviceLocalEntity:
            String(localized: "Dieser Datentyp bleibt nur auf diesem Gerät.", bundle: .module)
        case .secretMaterialRejected:
            String(localized: "Die Änderung enthält vermutlich Zugangsdaten und wird nicht synchronisiert. Schlüssel gehören in den Schlüsselbund.", bundle: .module)
        case .unknownRecordType, .malformedRecord, .payloadAssetUnreadable:
            String(localized: "Ein Datensatz aus iCloud ist unvollständig und wurde übersprungen.", bundle: .module)
        case .unsupportedSchema:
            SyncAttention.newerSchema.message
        }
    }

    /// Errors `CKSyncEngine` retries by itself; the change stays pending (apple-platform.md §2).
    public static func isTransient(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
             .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
            true
        default:
            false
        }
    }
}
