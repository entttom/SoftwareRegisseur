import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurSecrets

/// Controlled deletion of local data (spec Q1 "transparente Löschung", A27, A34).
///
/// Two steps: `preparePlan` lists exactly what would be removed and issues a single-use confirmation
/// token; `execute` removes only the listed items and only with that token, before it expires.
/// Guarantees:
/// - Only paths inside the app's own folders (`LocalDataLocations`) are touched; anything inside a Git
///   repository (a `.git` entry in the item or between it and its root) or inside `protectedPaths`
///   (e.g. known repository locations) is refused, both when planning and again when executing.
/// - Symbolic links are removed as links; their targets are never followed.
/// - Cloud data is never deleted here: `prepareCloudDeletion`/`confirmCloudDeletion` only produce a
///   `CloudDataDeletionRequest` for the sync coordinator.
public actor LocalDataEraser {
    public static let defaultValidity: TimeInterval = 10 * 60
    /// Same constant as `SoftwareRegisseurSync.SyncRecordSchema.zoneName` (both read `CloudSyncZone.name`).
    public static let cloudZoneName = CloudSyncZone.name

    private struct Issued {
        let token: DeletionConfirmationToken
        let fingerprint: [String]
        let expiresAt: Date
    }

    private let locations: LocalDataLocations
    private let keychain: any KeychainStore
    private let database: AppDatabase?
    private let databaseShutdown: (any LocalDatabaseShutdown)?
    private let protectedPaths: [URL]
    private let validity: TimeInterval
    private let clock: @Sendable () -> Date
    private var issued: [UUID: Issued] = [:]
    private var used: Set<UUID> = []

    public init(
        locations: LocalDataLocations,
        keychain: any KeychainStore,
        database: AppDatabase? = nil,
        databaseShutdown: (any LocalDatabaseShutdown)? = nil,
        protectedPaths: [URL] = [],
        validity: TimeInterval = LocalDataEraser.defaultValidity,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locations = locations
        self.keychain = keychain
        self.database = database
        self.databaseShutdown = databaseShutdown
        self.protectedPaths = protectedPaths.map(Self.canonical)
        self.validity = validity
        self.clock = clock
    }

    // MARK: Planning

    public func preparePlan(_ scope: LocalDeletionScope) async throws -> LocalDeletionPlan {
        var items: [DeletionItem] = []
        var retained = [
            String(localized: "iCloud-Daten bleiben erhalten. Sie können sie separat löschen.", bundle: .module),
            String(localized: "Git-Repositories und Dateien in Ihren Projektordnern werden nie gelöscht.", bundle: .module),
        ]
        switch scope {
        case .audioRecordings:
            items = try audioItems()
            retained.append(String(localized: "Transkripte und Aufgaben bleiben erhalten.", bundle: .module))
        case .apiKeys(let selection):
            items = try await keyItems(selection, includeSynchronizable: true)
            retained.append(String(localized: "Anbieterprofile bleiben erhalten; ohne Schlüssel sind die zugehörigen KI-Funktionen nicht verfügbar.", bundle: .module))
        case .localDatabase:
            items = try databaseItems()
            retained.append(String(localized: "Audioaufnahmen und API-Schlüssel bleiben erhalten.", bundle: .module))
        case .everythingLocal:
            let keys = try await keyItems(.all, includeSynchronizable: false)
            items = try audioItems() + keys + databaseItems() + appFileItems()
            let syncedKeys = try synchronizableAccounts()
            if !syncedKeys.isEmpty {
                retained.append(String(localized: "\(syncedKeys.count) API-Schlüssel im iCloud-Schlüsselbund bleiben erhalten, weil ihr Löschen auch Ihre anderen Geräte beträfe. Sie können sie unter „API-Schlüssel löschen“ entfernen.", bundle: .module))
            }
        }
        items = Self.deduplicated(items)
        for item in items { try validate(item) }
        retained += skippedRepositoryNotes(for: scope)

        let now = clock()
        let plan = LocalDeletionPlan(
            id: UUID(), scope: scope, items: items, retained: retained, createdAt: now,
            expiresAt: now.addingTimeInterval(validity), confirmationToken: .random()
        )
        issued[plan.id] = Issued(token: plan.confirmationToken, fingerprint: items.map(\.id), expiresAt: plan.expiresAt)
        return plan
    }

    // MARK: Execution

    public func execute(_ plan: LocalDeletionPlan, confirmation: DeletionConfirmationToken?) async throws -> LocalDeletionReport {
        try consume(planId: plan.id, token: confirmation, fingerprint: plan.items.map(\.id))
        for item in plan.items { try validate(item) }

        var report = LocalDeletionReport(planId: plan.id)
        let keys = plan.items.filter { if case .keychainItem = $0.kind { true } else { false } }
        let files = plan.items.filter { $0.url != nil }

        for item in keys {
            guard case .keychainItem(let account) = item.kind else { continue }
            do {
                if try keychain.delete(account: account) { report.deleted.append(item) } else { report.alreadyMissing.append(item) }
            } catch let error as KeychainError {
                report.failed.append(.init(item: item, message: error.userMessage))
            }
        }

        if plan.requiresDatabaseShutdown, files.contains(where: { touchesDatabase($0.url!) }) {
            guard let databaseShutdown else { throw DeletionError.databaseShutdownUnavailable }
            try await databaseShutdown.closeDatabaseForDeletion()
        }

        let fileManager = FileManager.default
        for item in files {
            let url = item.url!
            guard (try? url.checkResourceIsReachable()) == true || Self.isSymbolicLink(url) else {
                report.alreadyMissing.append(item)
                continue
            }
            do {
                if touchesDatabase(url), !Self.isSymbolicLink(url) {
                    try Self.coordinatedRemove(url, fileManager: fileManager)
                } else {
                    try fileManager.removeItem(at: url) // removes a symbolic link itself, never its target
                }
                report.deleted.append(item)
            } catch {
                report.failed.append(.init(item: item, message: String(localized: "„\(url.lastPathComponent)“ konnte nicht gelöscht werden.", bundle: .module)))
            }
        }
        return report
    }

    // MARK: Cloud (request only)

    public func prepareCloudDeletion() -> CloudDeletionPlan {
        let now = clock()
        let plan = CloudDeletionPlan(id: UUID(), zoneName: Self.cloudZoneName, createdAt: now,
                                     expiresAt: now.addingTimeInterval(validity), confirmationToken: .random())
        issued[plan.id] = Issued(token: plan.confirmationToken, fingerprint: ["cloud:" + plan.zoneName], expiresAt: plan.expiresAt)
        return plan
    }

    /// Returns the request for the sync coordinator. Deletes nothing, neither locally nor in iCloud.
    public func confirmCloudDeletion(_ plan: CloudDeletionPlan, confirmation: DeletionConfirmationToken?) throws -> CloudDataDeletionRequest {
        try consume(planId: plan.id, token: confirmation, fingerprint: ["cloud:" + plan.zoneName])
        return CloudDataDeletionRequest(id: plan.id, zoneName: plan.zoneName, scope: .entireZone, requestedAt: clock(),
                                        suppressAutomaticReupload: true)
    }

    // MARK: Token handling

    private func consume(planId: UUID, token: DeletionConfirmationToken?, fingerprint: [String]) throws {
        if used.contains(planId) { throw DeletionError.planAlreadyUsed }
        guard let issuedPlan = issued[planId], let token, token == issuedPlan.token, fingerprint == issuedPlan.fingerprint else {
            throw DeletionError.confirmationRequired
        }
        guard clock() <= issuedPlan.expiresAt else {
            issued[planId] = nil
            throw DeletionError.planExpired
        }
        issued[planId] = nil
        used.insert(planId)
    }

    // MARK: Item collection

    private func audioItems() throws -> [DeletionItem] {
        try contents(of: locations.audioDirectory).map { url in
            let isDirectory = Self.isDirectory(url)
            return DeletionItem(
                kind: isDirectory ? .directory(url) : .file(url),
                label: String(localized: "Audioaufnahme „\(url.lastPathComponent)“", bundle: .module),
                byteCount: Self.size(of: url), affectsOtherDevices: false
            )
        }.filter { !containsGitRepository($0.url!) }
    }

    private func keyItems(_ selection: ProviderKeySelection, includeSynchronizable: Bool) async throws -> [DeletionItem] {
        let stored: [String]
        do { stored = try keychain.listAccounts() } catch let error as KeychainError { throw DeletionError.keychain(error.userMessage) }
        let profiles = try await database?.providerProfiles.list() ?? []
        func account(of profile: ProviderProfile) -> String {
            profile.keychainReference?.account ?? profile.id.rawValue.uuidString
        }
        let accounts: [String]
        switch selection {
        case .all:
            accounts = stored
        case .profiles(let ids):
            guard database != nil else { throw DeletionError.databaseRequired }
            let wanted = Set(ids)
            let selected = Set(profiles.filter { wanted.contains($0.id) }.map(account(of:)))
                .union(ids.map(\.rawValue.uuidString))
            accounts = stored.filter(selected.contains)
        }
        var items: [DeletionItem] = []
        for name in accounts.sorted() {
            let mode: KeychainStorageMode?
            do { mode = try keychain.storageMode(account: name) } catch let error as KeychainError { throw DeletionError.keychain(error.userMessage) }
            let synchronizable = mode == .synchronizableRequested
            if synchronizable, !includeSynchronizable { continue }
            let owners = profiles.filter { account(of: $0) == name }
            let label: String = if let owner = owners.first {
                String(localized: "API-Schlüssel für \(owner.providerId.rawValue) (\(owner.purpose.rawValue))", bundle: .module)
            } else {
                String(localized: "API-Schlüssel „\(name)“", bundle: .module)
            }
            items.append(DeletionItem(kind: .keychainItem(account: name), label: label, byteCount: nil, affectsOtherDevices: synchronizable))
        }
        return items
    }

    private func synchronizableAccounts() throws -> [String] {
        do {
            return try keychain.listAccounts().filter { try keychain.storageMode(account: $0) == .synchronizableRequested }
        } catch let error as KeychainError {
            throw DeletionError.keychain(error.userMessage)
        }
    }

    private func databaseItems() throws -> [DeletionItem] {
        var items: [DeletionItem] = []
        let database = locations.databaseFile
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            guard Self.exists(url) else { continue }
            items.append(DeletionItem(
                kind: .file(url),
                label: String(localized: "Datenbankdatei „\(url.lastPathComponent)“", bundle: .module),
                byteCount: Self.size(of: url), affectsOtherDevices: false
            ))
        }
        for cache in locations.cacheDirectories {
            for url in try contents(of: cache) where !containsGitRepository(url) {
                items.append(DeletionItem(
                    kind: Self.isDirectory(url) ? .directory(url) : .file(url),
                    label: String(localized: "Zwischenspeicher „\(url.lastPathComponent)“", bundle: .module),
                    byteCount: Self.size(of: url), affectsOtherDevices: false
                ))
            }
        }
        return items
    }

    /// Remaining top-level entries of the app data folder and the configured extra files.
    private func appFileItems() throws -> [DeletionItem] {
        var urls = locations.additionalFiles.filter(Self.exists)
        urls += try contents(of: locations.appDataRoot)
        return urls.filter { !containsGitRepository($0) }.map { url in
            DeletionItem(
                kind: Self.isDirectory(url) ? .directory(url) : .file(url),
                label: String(localized: "App-Datei „\(url.lastPathComponent)“", bundle: .module),
                byteCount: Self.size(of: url), affectsOtherDevices: false
            )
        }
    }

    private func skippedRepositoryNotes(for scope: LocalDeletionScope) -> [String] {
        var folders: [URL] = []
        switch scope {
        case .audioRecordings: folders = [locations.audioDirectory]
        case .apiKeys: return []
        case .localDatabase: folders = locations.cacheDirectories
        case .everythingLocal: folders = [locations.appDataRoot, locations.audioDirectory] + locations.cacheDirectories
        }
        let skipped = folders.flatMap { (try? contents(of: $0)) ?? [] }.filter(containsGitRepository)
        return Array(Set(skipped.map(\.lastPathComponent))).sorted().map {
            String(localized: "„\($0)“ enthält ein Git-Repository und wird nicht gelöscht.", bundle: .module)
        }
    }

    private func contents(of directory: URL) throws -> [URL] {
        guard Self.isDirectory(directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []
        ).sorted { $0.path < $1.path }
    }

    // MARK: Safety

    private var allowedRoots: [URL] {
        ([locations.appDataRoot, locations.audioDirectory, locations.databaseFile.deletingLastPathComponent()]
            + locations.cacheDirectories + locations.additionalFiles.map { $0.deletingLastPathComponent() })
            .map(Self.canonical)
    }

    /// The item is the database (or one of its `-wal`/`-shm`/`-journal` files) or a folder containing it.
    private func touchesDatabase(_ url: URL) -> Bool {
        let item = Self.canonical(url)
        let database = Self.canonical(locations.databaseFile)
        let sibling = item.deletingLastPathComponent() == database.deletingLastPathComponent()
            && item.lastPathComponent.hasPrefix(database.lastPathComponent)
        return sibling || Self.isInside(database, item)
    }

    private func validate(_ item: DeletionItem) throws {
        guard let url = item.url else { return }
        // The parent is resolved (symlinked containers such as /var → /private/var); the item itself is not.
        let path = Self.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
        let home = Self.canonical(URL.homeDirectory)
        guard let root = allowedRoots.filter({ Self.isInside(path, $0) && path != $0 }).max(by: { $0.path.count < $1.path.count }),
              root.path != "/", root != home else {
            throw DeletionError.unsafePath(url.path)
        }
        if url.lastPathComponent == ".git" { throw DeletionError.unsafePath(url.path) }
        for protected in protectedPaths where Self.isInside(path, protected) || Self.isInside(protected, path) {
            throw DeletionError.unsafePath(url.path)
        }
        // No Git work tree around the item: checked up to (excluding) the home folder, so a repository
        // that contains the app folder is detected too (a dotfiles repo in `~` does not block deletion).
        var directory = path.deletingLastPathComponent()
        while directory.path != "/", directory != home, directory.path.count > 1 {
            if Self.exists(directory.appendingPathComponent(".git")) { throw DeletionError.unsafePath(url.path) }
            directory = directory.deletingLastPathComponent()
        }
        if containsGitRepository(url) { throw DeletionError.unsafePath(url.path) }
    }

    /// True if `url` is a Git repository/worktree or contains one at any depth (links are not followed).
    private func containsGitRepository(_ url: URL) -> Bool {
        if url.lastPathComponent == ".git" { return true }
        guard !Self.isSymbolicLink(url), Self.isDirectory(url) else { return false }
        if Self.exists(url.appendingPathComponent(".git")) { return true }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            return false
        }
        for case let child as URL in enumerator where child.lastPathComponent == ".git" { return true }
        return false
    }

    // MARK: File helpers

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func exists(_ url: URL) -> Bool {
        isSymbolicLink(url) || FileManager.default.fileExists(atPath: url.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func size(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard isDirectory(url) else {
            return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
            for case let child as URL in enumerator {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Drops duplicates and items inside a listed directory (the directory removes them).
    private static func deduplicated(_ items: [DeletionItem]) -> [DeletionItem] {
        var seen: Set<String> = []
        let directories = items.compactMap { item -> URL? in
            if case .directory(let url) = item.kind { return canonical(url) } else { return nil }
        }
        return items.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            guard let url = item.url else { return true }
            let path = canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
            return !directories.contains { $0 != path && isInside(path, $0) }
        }
    }

    /// Database files may live in a shared container (macOS App Group): coordinate the deletion.
    private static func coordinatedRemove(_ url: URL, fileManager: FileManager) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var removeError: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { url in
            do { try fileManager.removeItem(at: url) } catch { removeError = error }
        }
        if let error = coordinatorError ?? removeError { throw error }
    }
}
