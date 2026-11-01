import CryptoKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

public enum ExportPhase: String, Hashable, Sendable, Codable {
    case preparing
    case entities
    case deviceLocalEntities
    case syncConflicts
    case audioFiles
    case verifying
    case archiving
    case finished
}

public struct ExportProgress: Hashable, Sendable {
    public var phase: ExportPhase
    /// Entity kind currently being written (phase `entities`/`deviceLocalEntities`).
    public var entityType: SyncEntityType?
    /// Entities written so far (all kinds).
    public var exportedEntities: Int
    /// Database pages read so far.
    public var pagesRead: Int
    /// Coarse 0…1 estimate (entity counts are not known up front; paging avoids a counting pass).
    public var fractionCompleted: Double

    public init(phase: ExportPhase, entityType: SyncEntityType? = nil, exportedEntities: Int, pagesRead: Int, fractionCompleted: Double) {
        self.phase = phase
        self.entityType = entityType
        self.exportedEntities = exportedEntities
        self.pagesRead = pagesRead
        self.fractionCompleted = fractionCompleted
    }

    public var localizedDescription: String {
        switch phase {
        case .preparing: String(localized: "Export wird vorbereitet …", bundle: .module)
        case .entities, .deviceLocalEntities:
            String(localized: "\(exportedEntities) Einträge exportiert …", bundle: .module)
        case .syncConflicts: String(localized: "Synchronisationskonflikte werden exportiert …", bundle: .module)
        case .audioFiles: String(localized: "Audioaufnahmen werden kopiert …", bundle: .module)
        case .verifying: String(localized: "Export wird auf Zugangsdaten geprüft …", bundle: .module)
        case .archiving: String(localized: "ZIP-Archiv wird erstellt …", bundle: .module)
        case .finished: String(localized: "Export abgeschlossen.", bundle: .module)
        }
    }
}

public struct ExportOptions: Sendable {
    /// Stored rows inspected per database read (`storedEntities` page size).
    public var pageSize: Int
    public var includeMarkdown: Bool
    /// Also writes `<folder>.zip` next to the folder.
    public var createZipArchive: Bool
    /// When set, the dictation recordings referenced by audio notes are copied into `audio/`.
    public var audioDirectory: URL?
    public var appVersion: String
    public var device: ExportDeviceInfo
    /// Time zone of Markdown timestamps.
    public var timeZone: TimeZone

    public init(
        pageSize: Int = 250, includeMarkdown: Bool = true, createZipArchive: Bool = true, audioDirectory: URL? = nil,
        appVersion: String = ExportOptions.mainBundleVersion, device: ExportDeviceInfo = .current,
        timeZone: TimeZone = .current
    ) {
        self.pageSize = max(1, pageSize)
        self.includeMarkdown = includeMarkdown
        self.createZipArchive = createZipArchive
        self.audioDirectory = audioDirectory
        self.appVersion = appVersion
        self.device = device
        self.timeZone = timeZone
    }

    public static var mainBundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

public struct ExportResult: Sendable {
    public let folderURL: URL
    /// `nil` unless `ExportOptions.createZipArchive` and the archive was written.
    public let archiveURL: URL?
    /// Set when only the ZIP step failed; the folder export is complete.
    public let archiveError: ExportError?
    public let manifest: ExportManifest
}

public enum ExportError: Error, Hashable, Sendable {
    case destinationNotWritable(String)
    /// Provider/credential data still matched the secret rules (JSON paths); nothing was kept on disk.
    case secretDetected([String])
    case archiveFailed(String)

    public var userMessage: String {
        switch self {
        case .destinationNotWritable:
            String(localized: "Der Exportordner kann nicht angelegt werden. Bitte wählen Sie einen anderen Speicherort.", bundle: .module)
        case .secretDetected:
            String(localized: "Der Export wurde abgebrochen, weil er Zugangsdaten enthalten hätte. Es wurden keine Dateien gespeichert.", bundle: .module)
        case .archiveFailed:
            String(localized: "Das ZIP-Archiv konnte nicht erstellt werden. Der Exportordner ist vollständig vorhanden.", bundle: .module)
        }
    }
}

/// Exports all user data of an `AppDatabase` into a folder (and optionally a ZIP archive).
///
/// - Reads in pages (`GRDBSyncStore.storedEntities` keyset paging, which includes device-local values
///   such as audio notes), writes each entity kind as a streamed JSON array and never holds more than one
///   page. Works on a read-only database (macOS UI process, ADR-0019).
/// - Never reads the keychain: API keys cannot be part of the export. Provider profiles are additionally
///   sanitized and every written payload is scanned (`ExportSecretScanner`).
/// - Cancellation (`Task.cancel()`) stops after the current page and removes the partial folder.
/// - ZIP: `NSFileCoordinator` with `.forUploading` zips a directory on iOS and macOS without third-party
///   code (Apple Archive would produce `.aar`, which other systems cannot open).
public struct DataExporter: Sendable {
    public static let dataDirectory = "data"
    public static let syncConflictsPath = "data/syncConflicts.json"
    static let readmeName = "LIESMICH.md"

    public static func entityFilePath(_ type: SyncEntityType) -> String { "\(dataDirectory)/\(type.rawValue).json" }

    public let database: AppDatabase
    public let options: ExportOptions

    public init(database: AppDatabase, options: ExportOptions = ExportOptions()) {
        self.database = database
        self.options = options
    }

    /// Creates `SoftwareRegisseur-Export-<timestamp>` inside `parentDirectory`.
    public func export(
        into parentDirectory: URL, at date: Date = .now,
        progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportResult {
        let fileManager = FileManager.default
        let folder: URL
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            folder = try Self.makeUniqueFolder(in: parentDirectory, date: date)
        } catch {
            throw ExportError.destinationNotWritable(String(describing: error))
        }
        do {
            let manifest = try await write(into: folder, date: date, progress: progress)
            var archiveURL: URL?
            var archiveError: ExportError?
            if options.createZipArchive {
                try Task.checkCancellation()
                progress(ExportProgress(phase: .archiving, exportedEntities: manifest.totalEntityCount, pagesRead: 0, fractionCompleted: 0.95))
                do {
                    archiveURL = try Self.zip(folder: folder)
                } catch {
                    // The folder is complete and verified; only the archive is missing.
                    try? fileManager.removeItem(at: folder.appendingPathExtension("zip"))
                    archiveError = error as? ExportError ?? .archiveFailed(String(describing: error))
                }
            }
            progress(ExportProgress(phase: .finished, exportedEntities: manifest.totalEntityCount, pagesRead: 0, fractionCompleted: 1))
            return ExportResult(folderURL: folder, archiveURL: archiveURL, archiveError: archiveError, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: folder)
            try? fileManager.removeItem(at: folder.appendingPathExtension("zip"))
            throw error
        }
    }

    // MARK: Writing

    private func write(into folder: URL, date: Date, progress: @Sendable (ExportProgress) -> Void) async throws -> ExportManifest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder.appendingPathComponent(Self.dataDirectory), withIntermediateDirectories: true)
        var state = WriteState(folder: folder)
        progress(ExportProgress(phase: .preparing, exportedEntities: 0, pagesRead: 0, fractionCompleted: 0))

        var writers: [SyncEntityType: EntityArrayWriter] = [:]
        for type in SyncEntityType.allCases {
            writers[type] = try EntityArrayWriter(url: folder.appendingPathComponent(Self.entityFilePath(type)))
        }

        // 1. Every stored entity, page by page, in Persistence's stable order: what syncs first, then
        //    device-local values (audio notes; provider profiles kept on this device are part of their kind).
        let order = GRDBSyncStore.storedEntityOrder
        var audioNotes: [AudioNote] = []
        var cursor: SyncEntityCursor?
        repeat {
            try Task.checkCancellation()
            let page = try await database.sync.storedEntities(after: cursor, limit: options.pageSize)
            state.pagesRead += 1
            for entity in page.entities {
                try await append(entity.payload, type: entity.entityType, id: entity.entityId, to: writers, state: &state)
                if entity.entityType == .audioNote, options.audioDirectory != nil {
                    audioNotes.append(try SyncPayloadCodec.decode(AudioNote.self, from: entity.payload))
                }
            }
            cursor = page.next
            let current = cursor?.entityType ?? page.entities.last?.entityType
            let index = current.flatMap { order.firstIndex(of: $0) }.map(Double.init) ?? Double(order.count)
            progress(ExportProgress(phase: current?.isDeviceLocal == true ? .deviceLocalEntities : .entities,
                                    entityType: current, exportedEntities: state.exported, pagesRead: state.pagesRead,
                                    fractionCompleted: 0.05 + 0.75 * index / Double(order.count)))
        } while cursor != nil

        var entityFiles: [ExportManifest.EntityFile] = []
        for type in SyncEntityType.allCases {
            let writer = writers[type]!
            let checksum = try writer.finish(relativePath: Self.entityFilePath(type))
            state.files.append(checksum)
            entityFiles.append(ExportManifest.EntityFile(entityType: type, path: Self.entityFilePath(type), count: writer.count))
        }

        // 3. Sync conflicts (open and resolved).
        try Task.checkCancellation()
        progress(ExportProgress(phase: .syncConflicts, exportedEntities: state.exported, pagesRead: state.pagesRead, fractionCompleted: 0.85))
        let conflicts = try await exportedConflicts(state: &state)
        let conflictData = try SyncPayloadCodec.encode(conflicts)
        state.recordUserFindings(in: conflictData, path: Self.syncConflictsPath)
        state.files.append(try Self.writeFile(conflictData, relativePath: Self.syncConflictsPath, in: folder))

        // 4. Optional copies of dictation recordings.
        if let audioDirectory = options.audioDirectory, !audioNotes.isEmpty {
            progress(ExportProgress(phase: .audioFiles, exportedEntities: state.exported, pagesRead: state.pagesRead, fractionCompleted: 0.88))
            try copyAudio(audioNotes, from: audioDirectory, state: &state)
        }

        // 5. Verification: provider data must be clean (defence in depth after sanitizing).
        try Task.checkCancellation()
        progress(ExportProgress(phase: .verifying, exportedEntities: state.exported, pagesRead: state.pagesRead, fractionCompleted: 0.9))
        let profileFile = try Data(contentsOf: folder.appendingPathComponent(Self.entityFilePath(.providerProfile)))
        let profileFindings = ExportSecretScanner.findings(inJSON: profileFile)
        guard profileFindings.isEmpty else { throw ExportError.secretDetected(profileFindings) }

        let readme = Data(Self.readme(createdAt: date, timeZone: options.timeZone).utf8)
        state.files.append(try Self.writeFile(readme, relativePath: Self.readmeName, in: folder))

        let manifest = ExportManifest(
            format: ExportManifest.formatIdentifier,
            formatVersion: ExportManifest.currentFormatVersion,
            createdAt: date,
            device: options.device,
            appVersion: options.appVersion,
            databaseSchema: try database.appliedMigrations(),
            payloadEncoding: "SyncPayloadCodec: JSON, sortierte Schlüssel, Datum als Sekunden seit 2001-01-01 (deferredToDate)",
            entities: entityFiles,
            syncConflicts: conflicts.count,
            markdown: ExportManifest.MarkdownSummary(requests: state.markdownRequests, adrs: state.markdownADRs),
            audioFiles: state.audioFiles,
            files: state.files.sorted { $0.path < $1.path },
            secretScan: ExportManifest.SecretScan(
                rulesVersion: ExportSecretScanner.rulesVersion,
                removedProviderSettings: state.removedProviderSettings,
                userContentFindings: state.userFindings
            ),
            excluded: Self.exclusions
        )
        let manifestData = try ExportManifest.makeEncoder().encode(manifest)
        let manifestFindings = ExportSecretScanner.findings(inJSON: manifestData)
        guard manifestFindings.isEmpty else { throw ExportError.secretDetected(manifestFindings.map { "manifest.json " + $0 }) }
        _ = try Self.writeFile(manifestData, relativePath: ExportManifest.fileName, in: folder)
        return manifest
    }

    private func append(
        _ payload: Data, type: SyncEntityType, id: UUID, to writers: [SyncEntityType: EntityArrayWriter], state: inout WriteState
    ) async throws {
        let writer = writers[type]!
        let path = Self.entityFilePath(type)
        var data = payload
        if type == .providerProfile {
            data = try sanitizeProviderProfile(payload, state: &state)
            let findings = ExportSecretScanner.findings(inJSON: data, rootPath: "$[\(writer.count)]")
            guard findings.isEmpty else { throw ExportError.secretDetected(findings.map { "\(path) \($0)" }) }
        } else {
            state.recordUserFindings(in: data, path: path, rootPath: "$[\(writer.count)]")
        }
        try writer.append(data)
        state.exported += 1

        guard options.includeMarkdown else { return }
        switch type {
        case .project:
            let project = try SyncPayloadCodec.decode(Project.self, from: data)
            state.projectNames[project.id] = project.name
        case .workItem:
            let item = try SyncPayloadCodec.decode(WorkItem.self, from: data)
            let drafts = try await database.draftVersions.versions(workItemId: item.uuid)
            let name = item.projectId.flatMap { state.projectNames[$0] }
            let text = ExportMarkdown.request(item, projectName: name, drafts: drafts, timeZone: options.timeZone)
            let file = (item.humanId?.description ?? item.uuid.shortString) + "-" + ExportMarkdown.slug(item.title) + ".md"
            let relative = "markdown/requests/\(state.projectFolder(item.projectId))/\(file)"
            try state.writeMarkdown(text, relativePath: relative)
            state.markdownRequests += 1
        case .adr:
            let adr = try SyncPayloadCodec.decode(ADR.self, from: data)
            let text = ExportMarkdown.adr(adr, projectName: state.projectNames[adr.projectId], timeZone: options.timeZone)
            let file = "\(adr.decisionNumber.displayID)-\(ExportMarkdown.slug(adr.title))-\(adr.uuid.shortString).md"
            let relative = "markdown/adrs/\(state.projectFolder(adr.projectId))/\(file)"
            try state.writeMarkdown(text, relativePath: relative)
            state.markdownADRs += 1
        default:
            break
        }
    }

    /// Provider profiles hold only keychain coordinates; settings entries that look like credentials
    /// (name or value) are dropped so a key pasted into a settings field never leaves the device.
    private func sanitizeProviderProfile(_ payload: Data, state: inout WriteState) throws -> Data {
        var profile = try SyncPayloadCodec.decode(ProviderProfile.self, from: payload)
        let removed = profile.settings.filter { ExportSecretScanner.isForbiddenKeyName($0.key) || ExportSecretScanner.looksLikeSecret($0.value) }
        guard !removed.isEmpty else { return payload }
        for key in removed.keys.sorted() {
            profile.settings[key] = nil
            let name = ExportSecretScanner.looksLikeSecret(key) ? "<Name entfernt>" : key
            state.removedProviderSettings.append("\(profile.id.uuidString.lowercased()).settings.\(name)")
        }
        return try SyncPayloadCodec.encode(profile)
    }

    private func exportedConflicts(state: inout WriteState) async throws -> [ExportedSyncConflict] {
        var all = try await database.sync.openConflicts()
        all += try await database.sync.resolvedConflicts(limit: Int(Int32.max))
        return try all.map { conflict in
            func embed(_ data: Data?) throws -> JSONValue? {
                guard var data else { return nil }
                if conflict.entityType == .providerProfile { data = try sanitizeProviderProfile(data, state: &state) }
                return try JSONValue(jsonData: data)
            }
            return ExportedSyncConflict(
                id: conflict.id, entityType: conflict.entityType, entityId: conflict.entityId,
                baseVersion: conflict.baseVersion, localVersion: conflict.localVersion, remoteVersion: conflict.remoteVersion,
                localPayload: try embed(conflict.localPayload), remotePayload: try embed(conflict.remotePayload),
                ancestorPayload: try embed(conflict.ancestorPayload), remoteChangeKind: conflict.remoteChangeKind.rawValue,
                detectedAt: conflict.detectedAt, resolvedAt: conflict.resolvedAt, resolution: conflict.resolution,
                resolvedBy: conflict.resolvedBy?.rawValue
            )
        }
    }

    private func copyAudio(_ notes: [AudioNote], from audioDirectory: URL, state: inout WriteState) throws {
        let fileManager = FileManager.default
        let root = audioDirectory.standardizedFileURL.resolvingSymlinksInPath()
        for note in notes {
            try Task.checkCancellation()
            // Only the file name is trusted; the reference can never escape the audio directory.
            let name = URL(fileURLWithPath: note.localAssetRef).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let source = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let relative = "audio/\(note.id.uuidString.lowercased())-\(name)"
            let destination = state.folder.appendingPathComponent(relative)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            state.files.append(try Self.checksum(of: destination, relativePath: relative))
            state.audioFiles += 1
        }
    }

    // MARK: Helpers

    static func makeUniqueFolder(in parent: URL, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "SoftwareRegisseur-Export-\(formatter.string(from: date))"
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: candidate.path) || fileManager.fileExists(atPath: candidate.path + ".zip") {
            candidate = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    static func writeFile(_ data: Data, relativePath: String, in folder: URL) throws -> ExportManifest.FileChecksum {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
        return ExportManifest.FileChecksum(path: relativePath, bytes: Int64(data.count), sha256: SHA256.hash(data: data).hexString)
    }

    /// Streams the file through SHA-256 (audio files can be large).
    public static func checksum(of url: URL, relativePath: String) throws -> ExportManifest.FileChecksum {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        return ExportManifest.FileChecksum(path: relativePath, bytes: bytes, sha256: hasher.finalize().hexString)
    }

    /// Zips `folder` into `<folder>.zip` via `NSFileCoordinator` (`.forUploading`).
    static func zip(folder: URL) throws -> URL {
        let destination = folder.appendingPathExtension("zip")
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var copyError: (any Error)?
        coordinator.coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipURL in
            // The temporary archive only exists inside this block.
            do { try FileManager.default.copyItem(at: zipURL, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw ExportError.archiveFailed(String(describing: error)) }
        return destination
    }

    static let exclusions: [String] = [
        String(localized: "API-Schlüssel und andere Zugangsdaten: Sie liegen ausschließlich im Schlüsselbund und werden nie exportiert.", bundle: .module),
        String(localized: "Git-Repositories, Worktrees und Dateien in Ihren Projektordnern: Diese bleiben unverändert in Git.", bundle: .module),
        String(localized: "Lokaler Dateiindex und Hoststatus des Mac: Zwischenspeicher, der aus Git neu aufgebaut wird.", bundle: .module),
        String(localized: "Synchronisations-Warteschlange und CloudKit-Verwaltungsdaten.", bundle: .module),
    ]

    static func readme(createdAt: Date, timeZone: TimeZone) -> String {
        let created = ExportMarkdown.timestamp(createdAt, timeZone)
        return [
            "# " + String(localized: "Software Regisseur – Datenexport", bundle: .module),
            "",
            String(localized: "Erstellt am \(created).", bundle: .module),
            "",
            String(localized: "Dieser Ordner enthält alle Daten, die Software Regisseur auf diesem Gerät gespeichert hat.", bundle: .module),
            "",
            "- `manifest.json` – " + String(localized: "Inhaltsverzeichnis mit Anzahl, Größe und SHA-256-Prüfsumme jeder Datei.", bundle: .module),
            "- `data/` – " + String(localized: "Maschinenlesbare JSON-Dateien, eine pro Datentyp (Projekte, Aufgaben, ADRs, Ereignisse, Aufträge, Reviews, Freigaben, KI-Anfragen, Einstellungen, Konflikte).", bundle: .module),
            "- `markdown/` – " + String(localized: "Lesbare Fassungen Ihrer Aufgaben (mit Originalnotiz, Transkript und Entwürfen) und ADRs.", bundle: .module),
            "- `audio/` – " + String(localized: "Ihre Diktataufnahmen, sofern Sie diese beim Export ausgewählt haben.", bundle: .module),
            "",
            String(localized: "API-Schlüssel sind nicht enthalten. Ihre eigenen Texte werden unverändert exportiert; prüfen Sie den Export vor der Weitergabe, falls Sie Zugangsdaten in Notizen eingegeben haben.", bundle: .module),
            "",
        ].joined(separator: "\n")
    }
}

// MARK: - Write state

private struct WriteState {
    let folder: URL
    var exported = 0
    var pagesRead = 0
    var files: [ExportManifest.FileChecksum] = []
    var userFindings: [ExportManifest.UserContentFinding] = []
    var removedProviderSettings: [String] = []
    var projectNames: [ProjectID: String] = [:]
    var projectFolders: [ProjectID: String] = [:]
    var markdownRequests = 0
    var markdownADRs = 0
    var audioFiles = 0
    var usedMarkdownPaths: Set<String> = []

    init(folder: URL) { self.folder = folder }

    mutating func recordUserFindings(in data: Data, path: String, rootPath: String = "$") {
        for location in ExportSecretScanner.findings(inJSON: data, rootPath: rootPath) {
            userFindings.append(ExportManifest.UserContentFinding(path: path, location: location))
        }
    }

    mutating func projectFolder(_ id: ProjectID?) -> String {
        guard let id else { return String(localized: "Eingang", bundle: .module) }
        if let folder = projectFolders[id] { return folder }
        let name = projectNames[id].map { ExportMarkdown.slug($0) } ?? String(localized: "Unbekanntes-Projekt", bundle: .module)
        let folder = "\(name)-\(id.shortString)"
        projectFolders[id] = folder
        return folder
    }

    mutating func writeMarkdown(_ text: String, relativePath: String) throws {
        var path = relativePath
        var counter = 2
        while usedMarkdownPaths.contains(path) {
            path = relativePath.replacingOccurrences(of: ".md", with: "-\(counter).md")
            counter += 1
        }
        usedMarkdownPaths.insert(path)
        for line in ExportSecretScanner.findings(inText: text) {
            userFindings.append(ExportManifest.UserContentFinding(path: path, location: "line \(line)"))
        }
        files.append(try DataExporter.writeFile(Data(text.utf8), relativePath: path, in: folder))
    }
}

/// Streams one JSON array (`[\n<payload>,\n<payload>\n]\n`) and hashes it while writing.
private final class EntityArrayWriter {
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var count = 0
    private var bytes: Int64 = 0

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try write(Data("[".utf8))
    }

    func append(_ payload: Data) throws {
        try write(Data((count == 0 ? "\n" : ",\n").utf8))
        try write(payload)
        count += 1
    }

    func finish(relativePath: String) throws -> ExportManifest.FileChecksum {
        try write(Data((count == 0 ? "]\n" : "\n]\n").utf8))
        try handle.close()
        return ExportManifest.FileChecksum(path: relativePath, bytes: bytes, sha256: hasher.finalize().hexString)
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        bytes += Int64(data.count)
    }
}

extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
