import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence

/// What one synchronization pass did (spec F3/F5, E3, U4).
public struct RequestSyncReport: Sendable, Hashable {
    public var createdFiles: [String] = []
    public var updatedFiles: [String] = []
    /// (from, to) repository-relative paths.
    public var movedFiles: [Move] = []
    /// Work items updated from external file edits.
    public var updatedItems: [WorkItemID] = []
    /// Work items created from request files that were not in the database.
    public var importedItems: [WorkItemID] = []
    public var conflicts: [FileConflict] = []
    /// Status edits by an agent during its own run, recorded but not applied (ADR-0012).
    public var agentReportedStatuses: [WorkItemID: DomainWorkItemStatus] = [:]
    public var incompatibleFiles: [String: String] = [:]
    public var skippedForOpenConflict: [WorkItemID] = []
    public var errors: [String] = []

    public struct Move: Sendable, Hashable {
        public let from: String
        public let to: String
    }

    public var isEmpty: Bool {
        createdFiles.isEmpty && updatedFiles.isEmpty && movedFiles.isEmpty && updatedItems.isEmpty && importedItems.isEmpty
            && conflicts.isEmpty && agentReportedStatuses.isEmpty && incompatibleFiles.isEmpty && errors.isEmpty
    }

    mutating func merge(_ other: RequestSyncReport) {
        createdFiles += other.createdFiles
        updatedFiles += other.updatedFiles
        movedFiles += other.movedFiles
        updatedItems += other.updatedItems
        importedItems += other.importedItems
        conflicts += other.conflicts
        agentReportedStatuses.merge(other.agentReportedStatuses) { $1 }
        incompatibleFiles.merge(other.incompatibleFiles) { $1 }
        skippedForOpenConflict += other.skippedForOpenConflict
        errors += other.errors
    }
}

/// Database ↔ request file synchronization on the Mac host (spec F3, F5, E3, N2, U4; ADR-0012, ADR-0018).
///
/// - New work items with a project get a human ID (ADR-0018, considering existing files) and a request file
///   rendered by `RequestRenderer`, written atomically without overwriting anything.
/// - Database changes reach the file surgically (status change: only `status` and `updatedAt` lines) and the
///   file moves to the status folder of the project's layout (`git mv` when tracked).
/// - External file edits reach the database through the repositories (actor `.external`).
/// - Both sides changed the same field since the last reconciliation → `FileConflict`, nothing overwritten.
/// - Status edits during an active job/lock are validated: statuses an agent may report are recorded, others
///   become a conflict (ADR-0012).
public actor RequestMaterializer {
    /// Statuses an agent may write into its request file during its run (spec F5, ADR-0012).
    public static let agentReportableStatuses: Set<DomainWorkItemStatus> = [
        .inProgress, .waitingApproval, .implementationFinished, .review,
    ]

    /// Marker for records of files the user decided to keep deleted.
    static let detachedIssue = "detached: Datei gelöscht, Löschung übernommen"

    let environment: WorkspaceEnvironment
    let mover: RepositoryFileMover
    var database: AppDatabase { environment.database }
    var hostActor: EventActor { .host(environment.hostId) }

    public init(environment: WorkspaceEnvironment) {
        self.environment = environment
        mover = RepositoryFileMover(git: environment.git)
    }

    // MARK: Public API

    /// Materializes or updates the request file of one work item.
    @discardableResult
    public func materialize(_ workItemId: WorkItemID) async throws -> RequestSyncReport {
        guard let item = try await database.workItems.fetch(workItemId) else { throw WorkspaceError.workItemNotFound(workItemId) }
        guard let projectId = item.projectId else { throw WorkspaceError.workItemWithoutProject(workItemId) }
        let context = try await ProjectContext.load(environment, projectId)
        var report = RequestSyncReport()
        try await synchronize(item, context: context, report: &report)
        return report
    }

    /// Full reconciliation of one project: external edits → database, database changes → files, new items →
    /// files, unknown request files → database. Usable with or without file system events (spec U4).
    @discardableResult
    public func reconcile(projectId: ProjectID) async throws -> RequestSyncReport {
        let context = try await ProjectContext.load(environment, projectId)
        var report = RequestSyncReport()
        let items = try await database.workItems.list(WorkItemFilter(project: .project(projectId)))
        let knownIds = Set(items.map(\.uuid.rawValue))

        // Unknown request files → import (spec E3: keep existing IDs).
        var seenUUIDs: [UUID: String] = [:]
        for entry in context.entries {
            guard let uuid = entry.uuid else {
                if entry.document.hasErrors || entry.document.metadata.uuid == nil {
                    report.incompatibleFiles[entry.relativePath] = String(localized: "UUID fehlt oder ungültig", bundle: .module)
                    try await recordIncompatible(entry, projectId: projectId, issue: String(localized: "UUID fehlt oder ungültig", bundle: .module))
                }
                continue
            }
            if let first = seenUUIDs[uuid] {
                report.incompatibleFiles[entry.relativePath] = "UUID doppelt (auch in \(first))"
                continue
            }
            seenUUIDs[uuid] = entry.relativePath
            if !knownIds.contains(uuid) {
                if let foreign = try await database.workItems.fetch(WorkItemID(uuid)), foreign.projectId != projectId {
                    report.incompatibleFiles[entry.relativePath] = String(localized: "UUID gehört zu einem anderen Projekt", bundle: .module)
                    continue
                }
                do {
                    if let imported = try await importFile(entry, context: context) {
                        report.importedItems.append(imported)
                    } else {
                        report.incompatibleFiles[entry.relativePath] = String(localized: "Pflichtfelder fehlen oder ungültig", bundle: .module)
                    }
                } catch {
                    report.errors.append("\(entry.relativePath): \(error)")
                }
            }
        }

        for item in items {
            do {
                try await synchronize(item, context: context, report: &report)
            } catch {
                report.errors.append("\(item.uuid): \(error)")
            }
        }
        return report
    }

    /// Applies resolutions the user chose on a device without file access (iPhone, synced
    /// `FileConflict.requestedResolution`, spec N2). GitHub divergences are left to `GitHubIssueService`.
    /// A request that cannot be applied (e.g. the file vanished) stays open and is reported.
    @discardableResult
    public func applyRequestedResolutions() async throws -> RequestSyncReport {
        var report = RequestSyncReport()
        for conflict in try await database.fileConflicts.pendingRequests() where conflict.kind != .gitHubDivergence {
            guard let resolution = conflict.requestedResolution else { continue }
            do {
                let result = try await resolveConflict(conflict.id, resolution: resolution)
                report.createdFiles += result.createdFiles
                report.updatedFiles += result.updatedFiles
                report.movedFiles += result.movedFiles
                report.updatedItems += result.updatedItems
                report.errors += result.errors
            } catch {
                report.errors.append("\(conflict.id): \(error)")
            }
        }
        return report
    }

    /// Resolves a request file conflict (spec N2: user decision).
    @discardableResult
    public func resolveConflict(_ id: FileConflictID, resolution: FileConflictResolution) async throws -> RequestSyncReport {
        guard let conflict = try await database.fileConflicts.fetch(id) else { throw WorkspaceError.conflictNotFound(id) }
        guard let workItemId = conflict.workItemId else { throw WorkspaceError.conflictNotFound(id) }
        guard var item = try await database.workItems.fetch(workItemId) else { throw WorkspaceError.workItemNotFound(workItemId) }
        let context = try await ProjectContext.load(environment, conflict.projectId)
        let record = try await database.documentFiles.fetch(entityId: workItemId.rawValue)
        var report = RequestSyncReport()

        switch (conflict.kind, resolution) {
        case (.fileDeleted, .acceptedExternal):
            // Keep the data, never recreate the file automatically.
            if var record {
                record.compatibility = .incompatible
                record.issue = Self.detachedIssue
                record.updatedAt = environment.now()
                try await database.documentFiles.upsert(record)
            }
        case (.fileDeleted, .keptDatabase):
            if let record { try await database.documentFiles.delete(projectId: record.projectId, relativePath: record.relativePath) }
            _ = try await database.fileConflicts.resolve(id, resolution: resolution, at: environment.now())
            try await synchronize(item, context: context, report: &report)
            return report
        case (_, .acceptedExternal):
            guard let entry = context.entry(for: workItemId.rawValue), let fileFields = RequestFields(document: entry.document) else {
                throw WorkspaceError.fileNotFound(path: conflict.location)
            }
            if try await isActive(item.uuid), fileFields.status != item.status {
                throw WorkspaceError.activeJob(item.uuid)
            }
            item = try await apply(fileFields, fields: Set(RequestFields.Field.allCases), to: item, path: entry.relativePath)
            try await saveRecord(item: item, path: entry.relativePath, text: entry.text, projectId: context.projectId)
            report.updatedItems.append(item.uuid)
        case (_, .keptDatabase):
            if let entry = context.entry(for: workItemId.rawValue) {
                // Write the database version over the file version the user has seen (hash checked).
                let fields = RequestFields(item: item)
                var document = entry.document
                try writeFields(fields, changed: Set(RequestFields.Field.allCases), into: &document, item: item)
                if document.text != entry.text {
                    try AtomicFileWriter.write(document.data, to: context.root.appendingRelative(entry.relativePath),
                                               mode: .replace(expectedHash: entry.hash), confinedTo: context.root)
                    report.updatedFiles.append(entry.relativePath)
                }
                let path = try await moveIfNeeded(entry.relativePath, status: item.status, context: context, report: &report)
                try await saveRecord(item: item, path: path, text: document.text, projectId: context.projectId)
            }
        case (_, .dismissed):
            break
        }
        _ = try await database.fileConflicts.resolve(id, resolution: resolution, at: environment.now())
        return report
    }

    // MARK: Per-item synchronization

    func synchronize(_ item: WorkItem, context: ProjectContext, report: inout RequestSyncReport) async throws {
        if !(try await database.fileConflicts.open(workItemId: item.uuid)).isEmpty {
            report.skippedForOpenConflict.append(item.uuid)
            return
        }
        guard let record = try await database.documentFiles.fetch(entityId: item.uuid.rawValue) else {
            if let entry = context.entry(for: item.uuid.rawValue) {
                // File exists without record (e.g. index rebuilt): the file is authoritative (spec N2).
                try await reconcileExisting(item, record: nil, entry: entry, context: context, report: &report)
            } else {
                try await createFile(for: item, context: context, report: &report)
            }
            return
        }
        if record.issue == Self.detachedIssue { return }

        let entry: RequestFileEntry
        if let atPath = context.entries.first(where: { $0.relativePath == record.relativePath && $0.uuid == item.uuid.rawValue }) {
            entry = atPath
        } else if let moved = context.entry(for: item.uuid.rawValue) {
            entry = moved // moved/renamed externally (e.g. `git mv` by an agent)
        } else {
            try await raiseConflict(FileConflict(
                projectId: context.projectId, workItemId: item.uuid, location: record.relativePath, kind: .fileDeleted,
                databaseRevision: item.revision, databaseText: record.content, externalText: nil,
                detail: String(localized: "Die Request-Datei wurde außerhalb der App gelöscht.", bundle: .module), detectedAt: environment.now()
            ), report: &report)
            return
        }
        try await reconcileExisting(item, record: record, entry: entry, context: context, report: &report)
    }

    private func reconcileExisting(
        _ item: WorkItem, record: DocumentFileRecord?, entry: RequestFileEntry, context: ProjectContext,
        report: inout RequestSyncReport
    ) async throws {
        guard let fileFields = RequestFields(document: entry.document), !entry.document.hasErrors else {
            if record?.contentHash == entry.hash { return }
            try await raiseConflict(FileConflict(
                projectId: context.projectId, workItemId: item.uuid, location: entry.relativePath, kind: .invalidFile,
                databaseRevision: item.revision, databaseText: record?.content, externalText: entry.text,
                detail: String(localized: "Frontmatter ungültig: \(entry.document.diagnostics.map { "\($0.code)" }.joined(separator: ", "))", bundle: .module),
                detectedAt: environment.now()
            ), report: &report)
            return
        }

        let currentFields = RequestFields(item: item)
        let recordedFields = record.flatMap { RequestFields(document: RequestDocument(text: $0.content)) }
        let snapshotFields = record?.entitySnapshot.flatMap { try? JSONDecoder().decode(WorkItem.self, from: $0) }.map(RequestFields.init(item:))
            ?? currentFields

        let fileChanged = fileFields.changedFields(comparedTo: recordedFields ?? currentFields)
        let databaseChanged = record == nil || record?.entityRevision == item.revision
            ? Set<RequestFields.Field>()
            : currentFields.changedFields(comparedTo: snapshotFields)
        let overlap = fileChanged.intersection(databaseChanged).filter { fileFields.value($0) != currentFields.value($0) }
        if !overlap.isEmpty {
            try await raiseConflict(FileConflict(
                projectId: context.projectId, workItemId: item.uuid, location: entry.relativePath, kind: .concurrentEdit,
                databaseRevision: item.revision, databaseText: renderPreview(item, humanId: entry.humanId?.description),
                externalText: entry.text,
                detail: String(localized: "Gleichzeitig geändert: \(overlap.map(\.rawValue).sorted().joined(separator: ", "))", bundle: .module),
                detectedAt: environment.now()
            ), report: &report)
            return
        }

        var updated = item
        var fileStatusKeptForAgent = false
        // File → database.
        var toDatabase = fileChanged.filter { fileFields.value($0) != currentFields.value($0) }
        if toDatabase.contains(.status) {
            if try await isActive(item.uuid) {
                guard Self.agentReportableStatuses.contains(fileFields.status) else {
                    try await raiseConflict(FileConflict(
                        projectId: context.projectId, workItemId: item.uuid, location: entry.relativePath,
                        kind: .statusChangeDuringActiveJob, databaseRevision: item.revision,
                        databaseText: renderPreview(item, humanId: entry.humanId?.description), externalText: entry.text,
                        detail: String(localized: "Status „\(fileFields.status.rawValue)“ während eines aktiven Agentenlaufs gesetzt.", bundle: .module),
                        detectedAt: environment.now()
                    ), report: &report)
                    return
                }
                // Expected agent behaviour: recorded, the host derives the task status from the job (ADR-0012).
                toDatabase.remove(.status)
                fileStatusKeptForAgent = true
                report.agentReportedStatuses[item.uuid] = fileFields.status
                try await database.events.append(TaskEvent(
                    workItemId: item.uuid, kind: .externalChangeDetected, actor: .external, timestamp: environment.now(),
                    payload: ["path": entry.relativePath, "reportedStatus": fileFields.status.rawValue], sourceRevision: item.revision
                ))
            } else {
                do {
                    try item.status.validateManualChange(to: fileFields.status, hasActiveJob: false)
                } catch {
                    try await raiseConflict(FileConflict(
                        projectId: context.projectId, workItemId: item.uuid, location: entry.relativePath, kind: .invalidFile,
                        databaseRevision: item.revision, databaseText: renderPreview(item, humanId: entry.humanId?.description),
                        externalText: entry.text,
                        detail: String(localized: "Unzulässiger Statuswechsel \(item.status.rawValue) → \(fileFields.status.rawValue).", bundle: .module),
                        detectedAt: environment.now()
                    ), report: &report)
                    return
                }
            }
        }
        if !toDatabase.isEmpty {
            updated = try await apply(fileFields, fields: toDatabase, to: item, path: entry.relativePath)
            report.updatedItems.append(item.uuid)
        }
        if let humanId = entry.humanId, updated.humanId == nil, let domainId = try? MarkdownDomainBridge.domain(humanId),
           domainId.type == updated.type {
            updated = try await database.humanIDs.adopt(domainId, for: updated.uuid, actor: .external, at: environment.now())
        }

        // Database → file.
        var document = entry.document
        var toFile = databaseChanged.filter { currentFields.value($0) != fileFields.value($0) }
        if fileStatusKeptForAgent { toFile.remove(.status) }
        if !toFile.isEmpty {
            try writeFields(RequestFields(item: updated), changed: toFile, into: &document, item: updated)
        }
        if document.text != entry.text {
            try AtomicFileWriter.write(document.data, to: context.root.appendingRelative(entry.relativePath),
                                       mode: .replace(expectedHash: entry.hash), confinedTo: context.root)
            report.updatedFiles.append(entry.relativePath)
        }
        let fileStatus = document.metadata.status.map(MarkdownDomainBridge.domain) ?? updated.status
        let path = try await moveIfNeeded(entry.relativePath, status: fileStatus, context: context, report: &report)
        try await saveRecord(item: updated, path: path, text: document.text, projectId: context.projectId)
    }

    // MARK: Creating files

    private func createFile(for item: WorkItem, context: ProjectContext, report: inout RequestSyncReport) async throws {
        var item = item
        if item.humanId == nil {
            item = try await database.humanIDs.assign(
                to: item.uuid, existingFileIDs: RequestFileScanner.usedHumanIDs(context.entries), actor: hostActor, at: environment.now()
            )
        }
        guard let humanId = item.humanId else { return }
        let text = try render(item, humanId: humanId)
        let fileName = RequestFileName.make(id: MarkdownDomainBridge.markdown(humanId), title: item.title)
        let status = MarkdownDomainBridge.markdown(item.status)
        let folder = context.layout.folder(for: status) ?? context.layout.folder(for: .open) ?? context.layout.requestsRoot
        let relative: String
        do {
            relative = try folder.appending(component: fileName).string
        } catch {
            throw WorkspaceError.invalidRequestFile(path: fileName, detail: "\(error)")
        }
        // Never overwrite: an existing file (any content) is a collision (spec F2/F3).
        try AtomicFileWriter.write(Data(text.utf8), to: context.root.appendingRelative(relative), mode: .createNew,
                                   confinedTo: context.root)
        report.createdFiles.append(relative)
        try await saveRecord(item: item, path: relative, text: text, projectId: context.projectId)
    }

    func render(_ item: WorkItem, humanId: DomainHumanID) throws -> String {
        let id = MarkdownDomainBridge.markdown(humanId)
        let body = RequestBody.normalize(item.structuredBody)
        let draft = RequestDraft(
            uuid: item.uuid.rawValue, type: MarkdownDomainBridge.markdown(item.type), title: item.title,
            status: MarkdownDomainBridge.markdown(item.status), priority: MarkdownDomainBridge.markdown(item.priority),
            labels: item.labels, dependsOn: item.dependencies.map { $0.uuidString.lowercased() },
            agentJobIds: item.agentJobIds.map { $0.uuidString.lowercased() }, reviewState: item.reviewState.rawValue,
            createdAt: item.createdAt, description: body.isEmpty ? item.originalNote : ""
        )
        let text: String
        do {
            text = try RequestRenderer.render(draft, id: id, timeZone: environment.timeZone)
        } catch {
            throw WorkspaceError.invalidRequestFile(path: id.description, detail: "\(error)")
        }
        guard !body.isEmpty else { return text }
        var document = RequestDocument(text: text)
        RequestBody.replace(in: &document, body: body, heading: "# \(id): \(item.title)")
        return document.text
    }

    private func renderPreview(_ item: WorkItem, humanId: String?) -> String? {
        guard let id = item.humanId else { return nil }
        return try? render(item, humanId: id)
    }

    // MARK: Importing files (spec E3)

    private func importFile(_ entry: RequestFileEntry, context: ProjectContext) async throws -> WorkItemID? {
        let metadata = entry.document.metadata
        guard let uuid = metadata.uuid, let type = metadata.type, let fields = RequestFields(document: entry.document),
              !entry.document.hasErrors else {
            try await recordIncompatible(entry, projectId: context.projectId, issue: String(localized: "Pflichtfelder fehlen oder ungültig", bundle: .module))
            return nil
        }
        let domainType = MarkdownDomainBridge.domain(type)
        var humanId: DomainHumanID?
        if let id = entry.humanId, let converted = try? MarkdownDomainBridge.domain(id), converted.type == domainType {
            humanId = converted
        }
        let now = environment.now()
        var item = WorkItem(
            uuid: WorkItemID(uuid), humanId: nil, projectId: context.projectId, type: domainType, title: fields.title,
            originalNote: "", structuredBody: fields.body, status: fields.status, priority: fields.priority,
            labels: fields.labels, dependencies: metadata.dependsOn.compactMap { WorkItemID(uuidString: $0) },
            reviewState: fields.reviewState, createdAt: metadata.createdAt ?? now, updatedAt: metadata.updatedAt ?? now
        )
        try await database.workItems.insert(item, actor: .external, at: now)
        if let humanId {
            do {
                item = try await database.humanIDs.adopt(humanId, for: item.uuid, actor: .external, at: now)
            } catch {
                // Duplicate number: keep the item, flag the file for manual mapping (spec E3).
                try await recordIncompatible(entry, projectId: context.projectId, issue: "Nummer \(humanId) bereits vergeben")
                return item.uuid
            }
        }
        try await saveRecord(item: item, path: entry.relativePath, text: entry.text, projectId: context.projectId)
        return item.uuid
    }

    // MARK: Helpers

    func isActive(_ id: WorkItemID) async throws -> Bool {
        if try await database.workItems.hasActiveJob(id) { return true }
        return try await database.locks.activeLock(forTask: id) != nil
    }

    private func apply(_ fields: RequestFields, fields changed: Set<RequestFields.Field>, to item: WorkItem, path: String) async throws -> WorkItem {
        let now = environment.now()
        let updated = try await database.workItems.update(item.uuid, expectedRevision: item.revision, actor: .external, at: now) { value in
            if changed.contains(.title) { value.title = fields.title }
            if changed.contains(.priority) { value.priority = fields.priority }
            if changed.contains(.labels) { value.labels = fields.labels }
            if changed.contains(.body) { value.structuredBody = fields.body }
            if changed.contains(.reviewState) { value.reviewState = fields.reviewState }
            if changed.contains(.status), value.status != fields.status {
                try value.changeStatusManually(to: fields.status, hasActiveJob: false, at: now)
            }
        }
        try await database.events.append(TaskEvent(
            workItemId: item.uuid, kind: .externalChangeDetected, actor: .external, timestamp: now,
            payload: ["path": path, "fields": changed.map(\.rawValue).sorted().joined(separator: ",")],
            sourceRevision: updated.revision
        ))
        return updated
    }

    /// Surgical frontmatter/body edits; a pure status change touches only `status` and `updatedAt`.
    func writeFields(_ fields: RequestFields, changed: Set<RequestFields.Field>, into document: inout RequestDocument, item: WorkItem) throws {
        let now = environment.now()
        let timeZone = environment.timeZone
        let old = RequestFields(document: document)
        do {
            if changed.contains(.status), old?.status != fields.status {
                try document.setStatus(MarkdownDomainBridge.markdown(fields.status), updatedAt: now, timeZone: timeZone)
            }
            if changed.contains(.title), old?.title != fields.title {
                let oldTitle = document.metadata.title ?? ""
                try document.setTitle(fields.title, updatedAt: now, timeZone: timeZone)
                if let id = document.metadata.rawID {
                    RequestBody.updateHeading(in: &document, id: id, oldTitle: oldTitle, newTitle: fields.title)
                }
            }
            if changed.contains(.priority), old?.priority != fields.priority {
                try document.frontmatter.setScalar(key: RequestField.priority, value: fields.priority.rawValue)
                try document.touch(updatedAt: now, timeZone: timeZone)
            }
            if changed.contains(.labels), old?.labels != fields.labels {
                try document.frontmatter.setList(key: RequestField.labels, values: fields.labels)
                try document.touch(updatedAt: now, timeZone: timeZone)
            }
            if changed.contains(.reviewState), old?.reviewState != fields.reviewState {
                try document.frontmatter.setScalar(key: RequestField.reviewState, value: fields.reviewState.rawValue)
                try document.touch(updatedAt: now, timeZone: timeZone)
            }
        } catch {
            throw WorkspaceError.invalidRequestFile(path: document.metadata.rawID ?? "", detail: "\(error)")
        }
        if changed.contains(.body), old?.body != fields.body {
            let id = document.metadata.rawID ?? item.humanId?.formatted ?? ""
            RequestBody.replace(in: &document, body: fields.body, heading: "# \(id): \(fields.title)")
            do { try document.touch(updatedAt: now, timeZone: timeZone) } catch {}
        }
    }

    private func moveIfNeeded(_ path: String, status: DomainWorkItemStatus, context: ProjectContext, report: inout RequestSyncReport) async throws -> String {
        let fileName = (path as NSString).lastPathComponent
        let folderString = (path as NSString).deletingLastPathComponent
        let destination: String
        do {
            let currentFolder = folderString.isEmpty ? RelativePath.root : try RelativePath(folderString)
            destination = try context.layout.destination(for: MarkdownDomainBridge.markdown(status), fileName: fileName,
                                                         currentFolder: currentFolder).string
        } catch {
            throw WorkspaceError.invalidLayout("\(error)")
        }
        guard destination != path else { return path }
        try await mover.move(from: path, to: destination, in: context.root)
        report.movedFiles.append(.init(from: path, to: destination))
        return destination
    }

    private func saveRecord(item: WorkItem, path: String, text: String, projectId: ProjectID) async throws {
        try await database.documentFiles.upsert(DocumentFileRecord(
            projectId: projectId, relativePath: path, kind: .request, entityId: item.uuid.rawValue, content: text,
            entityRevision: item.revision, entitySnapshot: try JSONEncoder().encode(item), updatedAt: environment.now()
        ))
    }

    private func recordIncompatible(_ entry: RequestFileEntry, projectId: ProjectID, issue: String) async throws {
        if let existing = try await database.documentFiles.fetch(projectId: projectId, relativePath: entry.relativePath),
           existing.contentHash == entry.hash, existing.compatibility == .incompatible { return }
        try await database.documentFiles.upsert(DocumentFileRecord(
            projectId: projectId, relativePath: entry.relativePath, kind: .request, entityId: nil, content: entry.text,
            entityRevision: nil, compatibility: .incompatible, issue: issue, updatedAt: environment.now()
        ))
    }

    private func raiseConflict(_ conflict: FileConflict, report: inout RequestSyncReport) async throws {
        try await database.fileConflicts.insert(conflict)
        if let workItemId = conflict.workItemId {
            try await database.events.append(TaskEvent(
                workItemId: workItemId, kind: .conflictDetected, actor: hostActor, timestamp: conflict.detectedAt,
                payload: ["conflictId": conflict.id.uuidString, "kind": conflict.kind.rawValue, "path": conflict.location],
                sourceRevision: conflict.databaseRevision
            ))
        }
        report.conflicts.append(conflict)
    }
}

/// Per-pass snapshot of one project's files.
struct ProjectContext: Sendable {
    let projectId: ProjectID
    let root: URL
    let layout: FolderLayout
    let entries: [RequestFileEntry]

    static func load(_ environment: WorkspaceEnvironment, _ projectId: ProjectID) async throws -> ProjectContext {
        let root = try await environment.projectRoot(projectId)
        let layout = try await environment.layout(projectId)
        return ProjectContext(projectId: projectId, root: root, layout: layout, entries: RequestFileScanner.scan(root: root, layout: layout))
    }

    func entry(for uuid: UUID) -> RequestFileEntry? {
        entries.first { $0.uuid == uuid }
    }
}
