import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence

public struct LayoutMove: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case request, adr }
    public let kind: Kind
    public let source: String
    public let destination: String
    let sourceHash: String
}

public struct LayoutCollision: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        /// A file that is not part of the migration already exists at the destination.
        case destinationExists
        /// Two files would end up at the same destination.
        case duplicateDestination
    }

    public let destination: String
    public let sources: [String]
    public let reason: Reason
}

/// Preview of a folder layout change (spec F2: "sichere Migration mit Vorschau, Kollisionsprüfung …").
public struct LayoutMigrationPlan: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectId: ProjectID
    public let newSettings: ProjectSettings
    public let moves: [LayoutMove]
    public let collisions: [LayoutCollision]
    /// Updated managed block for `AGENTS.md`, if the file already has one (diff shown with the plan).
    public let instructionsDiff: String?
    let agentsOriginalHash: String?
    let agentsProposedText: String?

    public var isApplicable: Bool { collisions.isEmpty }
}

public struct LayoutMigrationResult: Sendable, Hashable {
    public let movedFiles: [LayoutMove]
    public let settings: ProjectSettings
    public let updatedInstructions: Bool
    public let approvedBy: EventActor
}

/// Moves request and ADR files to a new configurable layout (spec F2, A05). Only files of the plan are
/// moved (`git mv` when tracked); nothing is overwritten; unrelated files stay untouched.
public actor FolderLayoutMigrator {
    let environment: WorkspaceEnvironment
    private let mover: RepositoryFileMover
    private var plans: [UUID: LayoutMigrationPlan] = [:]

    public init(environment: WorkspaceEnvironment) {
        self.environment = environment
        mover = RepositoryFileMover(git: environment.git)
    }

    public func preview(projectId: ProjectID, newSettings: ProjectSettings) async throws -> LayoutMigrationPlan {
        let root = try await environment.projectRoot(projectId)
        let oldLayout = try await environment.layout(projectId)
        let newLayout: FolderLayout
        do {
            newLayout = try MarkdownDomainBridge.folderLayout(newSettings)
        } catch {
            throw WorkspaceError.invalidLayout("\(error)")
        }
        if let issue = newLayout.validate().first { throw WorkspaceError.invalidLayout("\(issue)") }

        var moves: [LayoutMove] = []
        for entry in RequestFileScanner.scan(root: root, layout: oldLayout) where entry.uuid != nil {
            let fileName = entry.fileName
            let destination: String
            if let status = entry.document.metadata.status, let folder = newLayout.folder(for: status) {
                destination = folder.string + "/" + fileName
            } else {
                // Statuses without folder keep their position relative to the requests root.
                let oldRoot = oldLayout.requestsRoot.string
                let suffix = oldRoot == "." ? entry.relativePath : String(entry.relativePath.dropFirst(oldRoot.count + 1))
                destination = newLayout.requestsRoot.isRoot ? suffix : newLayout.requestsRoot.string + "/" + suffix
            }
            if destination != entry.relativePath {
                moves.append(LayoutMove(kind: .request, source: entry.relativePath, destination: destination, sourceHash: entry.hash))
            }
        }
        if oldLayout.adrPath != newLayout.adrPath {
            let folder = root.appendingRelative(oldLayout.adrPath.string)
            for relative in FileSystem.markdownFiles(in: folder, relativeTo: root, recursive: false) {
                let fileName = (relative as NSString).lastPathComponent
                guard let data = FileSystem.read(relative, in: root) else { continue }
                let destination = newLayout.adrPath.isRoot ? fileName : newLayout.adrPath.string + "/" + fileName
                moves.append(LayoutMove(kind: .adr, source: relative, destination: destination, sourceHash: DocumentFileRecord.hash(data)))
            }
        }

        var collisions: [LayoutCollision] = []
        let sources = Set(moves.map(\.source))
        for (destination, group) in Dictionary(grouping: moves, by: \.destination) {
            if group.count > 1 {
                collisions.append(LayoutCollision(destination: destination, sources: group.map(\.source).sorted(), reason: .duplicateDestination))
            } else if FileSystem.exists(root.appendingRelative(destination)), !sources.contains(destination) {
                collisions.append(LayoutCollision(destination: destination, sources: group.map(\.source), reason: .destinationExists))
            }
        }

        // Managed block update only where the block already exists (no new AGENTS.md content unasked).
        var diff: String?
        var originalHash: String?
        var proposedText: String?
        if let data = FileSystem.read("AGENTS.md", in: root) {
            let text = String(decoding: data, as: UTF8.self)
            if case .present? = try? ManagedBlock.locate(in: text),
               let proposal = try? ManagedBlock(layout: newLayout).proposal(for: text), proposal.hasChanges {
                diff = proposal.unifiedDiff()
                originalHash = DocumentFileRecord.hash(data)
                proposedText = proposal.proposedText
            }
        }

        let plan = LayoutMigrationPlan(
            id: UUID(), projectId: projectId, newSettings: newSettings,
            moves: moves.sorted { $0.source < $1.source },
            collisions: collisions.sorted { $0.destination < $1.destination },
            instructionsDiff: diff, agentsOriginalHash: originalHash, agentsProposedText: proposedText
        )
        plans[plan.id] = plan
        return plan
    }

    /// Applies a previewed plan after explicit approval (`approved` must be true).
    public func apply(_ planId: UUID, approved: Bool, approvedBy: EventActor) async throws -> LayoutMigrationResult {
        guard approved else { throw WorkspaceError.notApproved }
        guard let plan = plans[planId] else { throw WorkspaceError.proposalNotFound(planId) }
        guard plan.isApplicable else { throw WorkspaceError.planHasCollisions }
        let root = try await environment.projectRoot(plan.projectId)
        let database = environment.database

        // Re-validate everything before the first move.
        for move in plan.moves {
            guard let data = FileSystem.read(move.source, in: root) else {
                plans[planId] = nil
                throw WorkspaceError.staleProposal(path: move.source)
            }
            guard DocumentFileRecord.hash(data) == move.sourceHash else {
                plans[planId] = nil
                throw WorkspaceError.staleProposal(path: move.source)
            }
            if FileSystem.exists(root.appendingRelative(move.destination)) { throw WorkspaceError.collision(path: move.destination) }
        }
        if let originalHash = plan.agentsOriginalHash {
            guard FileSystem.read("AGENTS.md", in: root).map(DocumentFileRecord.hash) == originalHash else {
                plans[planId] = nil
                throw WorkspaceError.staleProposal(path: "AGENTS.md")
            }
        }

        var done: [LayoutMove] = []
        for move in plan.moves {
            try await mover.move(from: move.source, to: move.destination, in: root)
            done.append(move)
            if try await database.documentFiles.fetch(projectId: plan.projectId, relativePath: move.source) != nil {
                try await database.documentFiles.move(projectId: plan.projectId, from: move.source, to: move.destination, at: environment.now())
            }
        }

        let current = try await environment.settings(plan.projectId)
        var updated = current
        updated.adrPath = plan.newSettings.adrPath
        updated.requestsRoot = plan.newSettings.requestsRoot
        updated.openPath = plan.newSettings.openPath
        updated.activePath = plan.newSettings.activePath
        updated.reviewPath = plan.newSettings.reviewPath
        updated.donePath = plan.newSettings.donePath
        let saved = try await database.projects.saveSettings(updated, expectedRevision: current.revision, at: environment.now())

        var updatedInstructions = false
        if let text = plan.agentsProposedText, let hash = plan.agentsOriginalHash {
            try AtomicFileWriter.write(Data(text.utf8), to: root.appendingRelative("AGENTS.md"), mode: .replace(expectedHash: hash), confinedTo: root)
            updatedInstructions = true
        }
        plans[planId] = nil
        return LayoutMigrationResult(movedFiles: done, settings: saved, updatedInstructions: updatedInstructions, approvedBy: approvedBy)
    }
}
