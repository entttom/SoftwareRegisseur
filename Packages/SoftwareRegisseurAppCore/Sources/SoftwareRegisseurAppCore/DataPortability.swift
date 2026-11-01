import Foundation
import Observation
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability

// MARK: - Export (A34 „Datenauskunft“)

/// Drives „Daten exportieren“: progress, cancellation and the finished export for the share sheet or
/// „In Dateien sichern“. The export itself is `DataExporter` (paged, secret-free, ZIP + folder).
@MainActor
@Observable
public final class DataExportModel {
    public enum State: Equatable {
        case idle
        case running(ExportProgress)
        case finished(Outcome)
        case failed(Failure)
        case cancelled
    }

    public struct Outcome: Equatable, Sendable {
        public let folderURL: URL
        public let archiveURL: URL?
        /// ZIP archive if it was written, else the folder.
        public var shareURL: URL { archiveURL ?? folderURL }
        public let entityCount: Int
        public let audioFiles: Int
        /// Spots in the user's own texts that look like credentials (exported unchanged; shown as hint).
        public let userContentFindings: Int
        /// Only the ZIP step failed; the folder is complete.
        public let archiveError: ExportError?

        public init(result: ExportResult) {
            folderURL = result.folderURL
            archiveURL = result.archiveURL
            entityCount = result.manifest.totalEntityCount
            audioFiles = result.manifest.audioFiles
            userContentFindings = result.manifest.secretScan.userContentFindings.count
            archiveError = result.archiveError
        }
    }

    public enum Failure: Equatable, Sendable {
        case export(ExportError)
        /// Unexpected error, described for the UI by the app.
        case unexpected(String)
    }

    /// Runs one export into `parent`, reporting progress. `includeAudio` copies the recordings.
    public typealias Operation = @Sendable (
        _ includeAudio: Bool, _ parent: URL, _ progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult

    public private(set) var state: State = .idle
    /// Copy the dictation recordings into the export (they never sync, so only this device has them).
    public var includeAudio = false
    /// Folder that holds this model's exports (e.g. `Caches/Exports`); emptied before each new export.
    public let destination: URL
    private let operation: Operation
    private var task: Task<Void, Never>?

    public init(destination: URL, operation: @escaping Operation) {
        self.destination = destination
        self.operation = operation
    }

    /// Export of `database` with `DataExporter` (ZIP archive and Markdown included).
    public static func live(database: AppDatabase, audioDirectory: URL, destination: URL) -> DataExportModel {
        DataExportModel(destination: destination) { includeAudio, parent, progress in
            let options = ExportOptions(audioDirectory: includeAudio ? audioDirectory : nil)
            return try await DataExporter(database: database, options: options).export(into: parent, progress: progress)
        }
    }

    public var isRunning: Bool { if case .running = state { true } else { false } }

    public var outcome: Outcome? { if case let .finished(outcome) = state { outcome } else { nil } }

    public func start() {
        guard !isRunning else { return }
        removePreviousExports()
        state = .running(ExportProgress(phase: .preparing, exportedEntities: 0, pagesRead: 0, fractionCompleted: 0))
        let operation = operation
        let includeAudio = includeAudio
        let destination = destination
        // The task keeps the model alive only until the export ends.
        task = Task {
            do {
                let result = try await operation(includeAudio, destination) { progress in
                    Task { @MainActor in self.apply(progress) }
                }
                if Task.isCancelled {
                    // Finished just as the user cancelled: honour the cancellation.
                    removePreviousExports()
                    state = .cancelled
                    return
                }
                state = .finished(Outcome(result: result))
            } catch is CancellationError {
                removePreviousExports()
                state = .cancelled
            } catch let error as ExportError {
                state = .failed(.export(error))
            } catch {
                state = .failed(.unexpected(String(describing: error)))
            }
        }
    }

    /// Stops after the current page; `DataExporter` removes the partial folder.
    public func cancel() {
        task?.cancel()
    }

    /// Waits for the running export (tests, previews).
    public func waitUntilFinished() async {
        await task?.value
    }

    /// Removes the exported files from the app's container (after sharing or saving them).
    public func discard() {
        guard !isRunning else { return }
        removePreviousExports()
        state = .idle
    }

    private func apply(_ progress: ExportProgress) {
        guard case let .running(current) = state, progress.fractionCompleted >= current.fractionCompleted else { return }
        state = .running(progress)
    }

    private func removePreviousExports() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("SoftwareRegisseur-Export-") {
            try? fileManager.removeItem(at: entry)
        }
    }
}

// MARK: - Deletion (A27, A34 „kontrolliert löschen“)

/// Carries out a confirmed `CloudDataDeletionRequest`. Implemented by the app with its
/// `SyncCoordinator`; the only way this model touches iCloud data.
public protocol CloudDataDeleting: Sendable {
    /// Throws `CloudDataDeletionFailure` with a German message when the deletion is not (yet) done.
    func deleteCloudData(_ request: CloudDataDeletionRequest) async throws
}

/// German, user-presentable reason why the iCloud data was not (yet) deleted.
public struct CloudDataDeletionFailure: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// The local deletion plans the settings screen offers (spec Q1, A34).
public enum LocalDeletionChoice: String, CaseIterable, Hashable, Sendable {
    case audioRecordings
    case apiKeys
    case localDatabase
    case everythingLocal

    public var scope: LocalDeletionScope {
        switch self {
        case .audioRecordings: .audioRecordings
        case .apiKeys: .apiKeys(.all)
        case .localDatabase: .localDatabase
        case .everythingLocal: .everythingLocal
        }
    }

    /// Whether the app has to reopen its database afterwards.
    public var resetsDatabase: Bool { self == .localDatabase || self == .everythingLocal }
}

/// Drives „Daten löschen“: every deletion goes preview → explicit confirmation → execution.
///
/// - `prepare…` creates the plan and shows exactly what would be removed; nothing is deleted.
/// - `confirm()` is the only path to execution. It needs the current preview and the user's
///   acknowledgement (`isAcknowledged`) and passes the plan's single-use token to `LocalDataEraser`.
/// - The iCloud plan is separate: its confirmation produces a `CloudDataDeletionRequest` that only the
///   injected `CloudDataDeleting` (the sync coordinator) carries out. Local plans never reach iCloud.
@MainActor
@Observable
public final class DataDeletionModel {
    public enum Preview: Equatable {
        case local(LocalDeletionChoice, LocalDeletionPlan)
        case cloud(CloudDeletionPlan)
    }

    public enum Completion: Equatable {
        case local(LocalDeletionChoice, LocalDeletionReport)
        case cloud(CloudDataDeletionRequest)
    }

    public enum Failure: Equatable {
        case deletion(DeletionError)
        case cloud(String)
        /// iCloud sync is not active on this device (unsigned build, no account): nothing to delete here.
        case cloudUnavailable
        case unexpected(String)
    }

    public enum Step: Equatable {
        case idle
        case preparing
        case preview(Preview)
        case executing(Preview)
        case completed(Completion)
        case failed(Failure)
    }

    public private(set) var step: Step = .idle
    /// The user confirmed having checked the preview („Ich habe die Liste geprüft“). Reset with every plan.
    public var isAcknowledged = false

    private let eraser: LocalDataEraser
    private let cloud: (any CloudDataDeleting)?
    private let afterLocalDeletion: @MainActor (LocalDeletionChoice, LocalDeletionReport) async -> Void
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - cloud: nil when iCloud sync is not available (the iCloud plan is then refused).
    ///   - afterLocalDeletion: brings the app back into a consistent state (reopen the database, refresh
    ///     key status, …). Runs after every executed local plan, also a partially failed one.
    public init(
        eraser: LocalDataEraser,
        cloud: (any CloudDataDeleting)?,
        clock: @escaping @Sendable () -> Date = { Date() },
        afterLocalDeletion: @escaping @MainActor (LocalDeletionChoice, LocalDeletionReport) async -> Void = { _, _ in }
    ) {
        self.eraser = eraser
        self.cloud = cloud
        self.clock = clock
        self.afterLocalDeletion = afterLocalDeletion
    }

    public var isCloudDeletionAvailable: Bool { cloud != nil }

    public var preview: Preview? {
        switch step {
        case let .preview(preview), let .executing(preview): preview
        default: nil
        }
    }

    public var isExecuting: Bool { if case .executing = step { true } else { false } }

    /// The preview is expired (the eraser would refuse its token); prepare it again.
    public var isPreviewExpired: Bool {
        switch preview {
        case let .local(_, plan)?: clock() > plan.expiresAt
        case let .cloud(plan)?: clock() > plan.expiresAt
        case nil: false
        }
    }

    /// Execution is possible: a preview with something to delete, acknowledged, not expired.
    public var canConfirm: Bool {
        guard case let .preview(preview) = step, isAcknowledged, !isPreviewExpired else { return false }
        if case let .local(_, plan) = preview { return !plan.isEmpty }
        return true
    }

    /// Lists what `choice` would delete. Deletes nothing.
    public func prepare(_ choice: LocalDeletionChoice) async {
        guard !isExecuting else { return }
        step = .preparing
        isAcknowledged = false
        do {
            let plan = try await eraser.preparePlan(choice.scope)
            step = .preview(.local(choice, plan))
        } catch {
            step = .failed(Self.failure(error))
        }
    }

    /// Shows the separate iCloud plan. Deletes nothing.
    public func prepareCloudDeletion() async {
        guard !isExecuting else { return }
        isAcknowledged = false
        guard cloud != nil else {
            step = .failed(.cloudUnavailable)
            return
        }
        let plan = await eraser.prepareCloudDeletion()
        step = .preview(.cloud(plan))
    }

    /// Executes the previewed plan with its token, after the explicit confirmation. Without a preview or
    /// acknowledgement nothing happens.
    public func confirm() async {
        guard case let .preview(preview) = step, isAcknowledged else { return }
        step = .executing(preview)
        switch preview {
        case let .local(choice, plan):
            do {
                let report = try await eraser.execute(plan, confirmation: plan.confirmationToken)
                await afterLocalDeletion(choice, report)
                step = .completed(.local(choice, report))
            } catch {
                // The database may have been closed before a later step failed: restore the app state.
                if choice.resetsDatabase { await afterLocalDeletion(choice, LocalDeletionReport(planId: plan.id)) }
                step = .failed(Self.failure(error))
            }
        case let .cloud(plan):
            guard let cloud else {
                step = .failed(.cloudUnavailable)
                return
            }
            do {
                let request = try await eraser.confirmCloudDeletion(plan, confirmation: plan.confirmationToken)
                try await cloud.deleteCloudData(request)
                step = .completed(.cloud(request))
            } catch {
                step = .failed(Self.failure(error))
            }
        }
        isAcknowledged = false
    }

    /// Back to the overview without deleting (the issued plan simply expires).
    public func cancel() {
        guard !isExecuting else { return }
        step = .idle
        isAcknowledged = false
    }

    private static func failure(_ error: any Error) -> Failure {
        switch error {
        case let error as DeletionError: .deletion(error)
        case let error as CloudDataDeletionFailure: .cloud(error.message)
        default: .unexpected(String(describing: error))
        }
    }
}
