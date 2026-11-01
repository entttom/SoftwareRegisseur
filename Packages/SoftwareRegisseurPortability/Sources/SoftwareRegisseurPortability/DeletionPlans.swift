import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Local storage locations of one installation. The app passes its own container paths (iOS:
/// `AppDirectories`; macOS: the Agent Service's App Group container, ADR-0019).
public struct LocalDataLocations: Hashable, Sendable {
    /// App-owned data folder (e.g. `Application Support/SoftwareRegisseur`). "Alle lokalen Daten" removes
    /// its contents, except anything that contains a Git repository.
    public var appDataRoot: URL
    /// SQLite database file; `-wal`, `-shm` and `-journal` siblings are included automatically.
    public var databaseFile: URL
    /// Dictation recordings.
    public var audioDirectory: URL
    /// Caches that can be rebuilt (e.g. sync asset staging). Deleted together with the database.
    public var cacheDirectories: [URL]
    /// Further app-owned files (e.g. `settings.json`), deleted with "Alle lokalen Daten".
    public var additionalFiles: [URL]

    public init(appDataRoot: URL, databaseFile: URL, audioDirectory: URL, cacheDirectories: [URL] = [], additionalFiles: [URL] = []) {
        self.appDataRoot = appDataRoot
        self.databaseFile = databaseFile
        self.audioDirectory = audioDirectory
        self.cacheDirectories = cacheDirectories
        self.additionalFiles = additionalFiles
    }
}

public enum ProviderKeySelection: Hashable, Sendable {
    /// Every key stored under the app's keychain service.
    case all
    /// Keys of these provider profiles (account = keychain reference account, else the profile ID).
    case profiles([ProviderProfileID])
}

/// What a local deletion plan removes. Cloud data is never part of a local scope (see `CloudDeletionPlan`).
public enum LocalDeletionScope: Hashable, Sendable {
    /// (a) Dictation recordings on this device. Recording metadata (consent, transcription state) stays in
    /// the database; the transcript is part of the work item.
    case audioRecordings
    /// (b) API keys in the keychain.
    case apiKeys(ProviderKeySelection)
    /// (c) Local database (closed first) and rebuildable caches.
    case localDatabase
    /// (d) Everything local: recordings, device-only keys, database, caches and other app files.
    case everythingLocal
}

public struct DeletionItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A file or symbolic link (a link is removed itself, its target never).
        case file(URL)
        /// A directory and its contents (checked to contain no Git repository).
        case directory(URL)
        /// A keychain item of the app's service.
        case keychainItem(account: String)
    }

    public let kind: Kind
    /// German, user-facing.
    public let label: String
    /// Size on disk; nil for keychain items.
    public let byteCount: Int64?
    /// The item also disappears on the user's other devices (iCloud Keychain).
    public let affectsOtherDevices: Bool

    public var id: String {
        switch kind {
        case .file(let url): "file:" + url.path
        case .directory(let url): "dir:" + url.path
        case .keychainItem(let account): "keychain:" + account
        }
    }

    public var url: URL? {
        switch kind {
        case .file(let url), .directory(let url): url
        case .keychainItem: nil
        }
    }
}

/// Opaque, single-use confirmation issued with a plan. The UI passes it back only after the user
/// explicitly confirmed the previewed items.
public struct DeletionConfirmationToken: Hashable, Sendable {
    public let value: String

    public init(value: String) { self.value = value }

    static func random() -> DeletionConfirmationToken {
        var generator = SystemRandomNumberGenerator()
        let words = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max, using: &generator)) }
        return DeletionConfirmationToken(value: words.joined())
    }
}

/// Preview of a local deletion. Executing it removes exactly `items`, nothing that appeared later.
public struct LocalDeletionPlan: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let scope: LocalDeletionScope
    public let items: [DeletionItem]
    /// German notes on what is deliberately kept (iCloud data, Git repositories, synced keys, …).
    public let retained: [String]
    public let createdAt: Date
    public let expiresAt: Date
    public let confirmationToken: DeletionConfirmationToken

    /// Local plans never delete iCloud data.
    public var affectsCloudData: Bool { false }
    public var totalBytes: Int64 { items.reduce(0) { $0 + ($1.byteCount ?? 0) } }
    public var isEmpty: Bool { items.isEmpty }
    public var affectsOtherDevices: Bool { items.contains(where: \.affectsOtherDevices) }
    var requiresDatabaseShutdown: Bool {
        scope == .localDatabase || scope == .everythingLocal
    }

    public var title: String {
        switch scope {
        case .audioRecordings: String(localized: "Audioaufnahmen löschen", bundle: .module)
        case .apiKeys: String(localized: "API-Schlüssel löschen", bundle: .module)
        case .localDatabase: String(localized: "Lokale Datenbank und Zwischenspeicher löschen", bundle: .module)
        case .everythingLocal: String(localized: "Alle lokalen Daten löschen", bundle: .module)
        }
    }

    public var summary: String {
        if items.isEmpty { return String(localized: "Es gibt nichts zu löschen.", bundle: .module) }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return String(localized: "\(items.count) Einträge (\(size)) werden auf diesem Gerät endgültig gelöscht.", bundle: .module)
    }
}

public struct LocalDeletionReport: Hashable, Sendable {
    public let planId: UUID
    public var deleted: [DeletionItem] = []
    /// Listed in the preview but already gone at execution time.
    public var alreadyMissing: [DeletionItem] = []
    /// Item and German error text; the remaining items were still processed.
    public var failed: [FailedItem] = []

    public struct FailedItem: Hashable, Sendable {
        public let item: DeletionItem
        public let message: String

        public init(item: DeletionItem, message: String) {
            self.item = item
            self.message = message
        }
    }

    public var isComplete: Bool { failed.isEmpty }

    public init(planId: UUID, deleted: [DeletionItem] = [], alreadyMissing: [DeletionItem] = [], failed: [FailedItem] = []) {
        self.planId = planId
        self.deleted = deleted
        self.alreadyMissing = alreadyMissing
        self.failed = failed
    }
}

public enum DeletionError: Error, Hashable, Sendable {
    /// Token missing, wrong, or plan not issued by this eraser.
    case confirmationRequired
    case planExpired
    /// Each plan executes at most once.
    case planAlreadyUsed
    /// A path is outside the app's own folders or inside a Git repository.
    case unsafePath(String)
    /// Database deletion needs a `LocalDatabaseShutdown` that stops sync and closes the database.
    case databaseShutdownUnavailable
    /// The app database is required to resolve provider profiles.
    case databaseRequired
    case keychain(String)

    public var userMessage: String {
        switch self {
        case .confirmationRequired:
            String(localized: "Bitte bestätigen Sie die Löschung ausdrücklich.", bundle: .module)
        case .planExpired:
            String(localized: "Die Vorschau ist abgelaufen. Bitte prüfen Sie die Liste erneut und bestätigen Sie dann.", bundle: .module)
        case .planAlreadyUsed:
            String(localized: "Diese Löschung wurde bereits ausgeführt. Bitte erstellen Sie eine neue Vorschau.", bundle: .module)
        case .unsafePath:
            String(localized: "Ein Pfad liegt außerhalb der App-Daten oder in einem Git-Repository und wird nicht gelöscht.", bundle: .module)
        case .databaseShutdownUnavailable:
            String(localized: "Die Datenbank kann gerade nicht geschlossen werden. Bitte beenden Sie laufende Vorgänge und versuchen Sie es erneut.", bundle: .module)
        case .databaseRequired:
            String(localized: "Die Anbieterprofile können nicht gelesen werden.", bundle: .module)
        case .keychain(let message):
            message
        }
    }
}

/// Stops everything that uses the database (sync coordinator, repositories, observers) and closes it.
/// Implemented by the app (iOS) or the Agent Service (macOS, single writer per ADR-0019).
public protocol LocalDatabaseShutdown: Sendable {
    func closeDatabaseForDeletion() async throws
}

// MARK: - Cloud

/// Separate plan for deleting the user's iCloud data. It never deletes anything itself: confirming it
/// yields a `CloudDataDeletionRequest` that the sync coordinator must carry out (zone deletion).
public struct CloudDeletionPlan: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let zoneName: String
    public let createdAt: Date
    public let expiresAt: Date
    public let confirmationToken: DeletionConfirmationToken

    public var title: String { String(localized: "iCloud-Daten löschen", bundle: .module) }

    public var consequences: [String] {
        [
            String(localized: "Alle mit iCloud synchronisierten Projekte, Aufgaben, ADRs, Aufträge und Einstellungen werden aus Ihrer privaten iCloud-Datenbank entfernt.", bundle: .module),
            String(localized: "Ihre anderen Geräte synchronisieren danach nicht mehr, bis Sie die Synchronisierung neu einrichten.", bundle: .module),
            String(localized: "Lokale Daten auf diesem Gerät, API-Schlüssel und Git-Repositories bleiben unverändert.", bundle: .module),
        ]
    }
}

// `CloudDataDeletionRequest` (the instruction for the sync layer) lives in SoftwareRegisseurPersistence,
// shared with SoftwareRegisseurSync, which carries it out (`SyncCoordinator.deleteCloudData(_:)`).
