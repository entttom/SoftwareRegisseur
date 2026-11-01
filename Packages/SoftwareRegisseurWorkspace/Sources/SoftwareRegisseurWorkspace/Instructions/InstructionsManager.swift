import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence

/// Agent capabilities relevant for instruction files (spec G rule 5/6). Supplied by the agent detection
/// (installed Claude Code version), never assumed.
public struct InstructionCapabilities: Sendable, Hashable {
    /// The installed Claude Code supports `@path` imports in `CLAUDE.md`.
    public var claudeSupportsImports: Bool
    /// Create `CLAUDE.md` with the import when it does not exist yet (only on explicit wish).
    public var createClaudeFileIfMissing: Bool

    public init(claudeSupportsImports: Bool, createClaudeFileIfMissing: Bool = false) {
        self.claudeSupportsImports = claudeSupportsImports
        self.createClaudeFileIfMissing = createClaudeFileIfMissing
    }
}

public enum InstructionWarning: Sendable, Hashable, CustomStringConvertible {
    /// The file has uncommitted changes in git (spec G rule 3).
    case uncommittedChanges(path: String)
    case claudeImportUnsupported
    /// `CLAUDE.md` exists but no import is added; agents may not see the managed rules.
    case claudeFileWithoutImport
    /// `CLAUDE.md` has its own Software Regisseur block: possible duplicate rule source.
    case claudeFileHasManagedBlock
    case proposeOnlyPolicy

    public var description: String {
        switch self {
        case let .uncommittedChanges(path): String(localized: "\(path) hat nicht eingecheckte Änderungen.", bundle: .module)
        case .claudeImportUnsupported: String(localized: "Die installierte Claude-Code-Version unterstützt keine @-Importe; CLAUDE.md bleibt unverändert.", bundle: .module)
        case .claudeFileWithoutImport: String(localized: "CLAUDE.md verweist nicht auf AGENTS.md.", bundle: .module)
        case .claudeFileHasManagedBlock: String(localized: "CLAUDE.md enthält einen eigenen Software-Regisseur-Block (doppelte Regelquelle).", bundle: .module)
        case .proposeOnlyPolicy: String(localized: "Projekt-Richtlinie: Änderungen nur vorschlagen.", bundle: .module)
        }
    }
}

public struct InstructionFileChange: Sendable, Hashable {
    /// Repository-relative path (`AGENTS.md`, `CLAUDE.md`).
    public let path: String
    public let originalText: String?
    public let proposedText: String
    public let unifiedDiff: String
    /// Hash of the file content when the proposal was computed (`nil` = file did not exist).
    public let originalHash: String?
}

public struct InstructionProposal: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectId: ProjectID
    public let changes: [InstructionFileChange]
    public let warnings: [InstructionWarning]
    public let createdAt: Date

    public var hasChanges: Bool { !changes.isEmpty }
}

public struct InstructionApplyResult: Sendable, Hashable {
    public let proposalId: UUID
    public let writtenFiles: [String]
    public let approvedBy: EventActor
    public let warnings: [InstructionWarning]
}

/// Managed instructions in `AGENTS.md` and an optional `@AGENTS.md` import in `CLAUDE.md` (spec G, A05/A06).
/// Proposals show a diff; files are written only via `apply(_:approvedBy:)`, atomically, and only when the
/// file is still byte-identical to what the proposal was computed from. User text outside the managed
/// block is never touched.
public actor InstructionsManager {
    let environment: WorkspaceEnvironment
    private let mover: RepositoryFileMover
    private var proposals: [UUID: InstructionProposal] = [:]

    public init(environment: WorkspaceEnvironment) {
        self.environment = environment
        mover = RepositoryFileMover(git: environment.git)
    }

    /// Computes the proposal for the project's current layout (or `layoutOverride`, e.g. during migration).
    public func propose(
        projectId: ProjectID, capabilities: InstructionCapabilities, layoutOverride: FolderLayout? = nil
    ) async throws -> InstructionProposal {
        let settings = try await environment.settings(projectId)
        guard settings.agentInstructionsPolicy != .disabled else { throw WorkspaceError.instructionsDisabled }
        let root = try await environment.projectRoot(projectId)
        let layout: FolderLayout
        if let layoutOverride {
            layout = layoutOverride
        } else {
            layout = try await environment.layout(projectId)
        }
        var warnings: [InstructionWarning] = []
        if settings.agentInstructionsPolicy == .proposeOnly { warnings.append(.proposeOnlyPolicy) }
        var changes: [InstructionFileChange] = []

        // AGENTS.md: only the managed block is (re)generated.
        let agentsPath = "AGENTS.md"
        let agentsData = FileSystem.read(agentsPath, in: root)
        let agentsText = agentsData.map { String(decoding: $0, as: UTF8.self) }
        let block = ManagedBlock(layout: layout)
        let proposal: InstructionFileProposal
        do {
            proposal = try block.proposal(for: agentsText, path: agentsPath)
        } catch {
            throw WorkspaceError.invalidRequestFile(path: agentsPath, detail: String(localized: "Markierungen des verwalteten Blocks: \(String(describing: error))", bundle: .module))
        }
        if proposal.hasChanges {
            changes.append(InstructionFileChange(
                path: agentsPath, originalText: agentsText, proposedText: proposal.proposedText,
                unifiedDiff: proposal.unifiedDiff(), originalHash: agentsData.map(DocumentFileRecord.hash)
            ))
            if agentsData != nil, await mover.hasUncommittedChanges(agentsPath, in: root) == true {
                warnings.append(.uncommittedChanges(path: agentsPath))
            }
        }

        // CLAUDE.md: never rewritten; at most the import line is appended (spec G rule 5).
        let claudePath = "CLAUDE.md"
        let claudeData = FileSystem.read(claudePath, in: root)
        let claudeText = claudeData.map { String(decoding: $0, as: UTF8.self) }
        if let claudeText, (try? ManagedBlock.locate(in: claudeText)) != .absent {
            warnings.append(.claudeFileHasManagedBlock)
        }
        if claudeData != nil || capabilities.createClaudeFileIfMissing {
            if !capabilities.claudeSupportsImports {
                warnings.append(.claudeImportUnsupported)
                if let claudeText, !ClaudeMemoryImport.containsAgentsImport(claudeText) { warnings.append(.claudeFileWithoutImport) }
            } else {
                let claudeProposal = ClaudeMemoryImport.proposal(for: claudeText, path: claudePath)
                if claudeProposal.hasChanges {
                    changes.append(InstructionFileChange(
                        path: claudePath, originalText: claudeText, proposedText: claudeProposal.proposedText,
                        unifiedDiff: claudeProposal.unifiedDiff(), originalHash: claudeData.map(DocumentFileRecord.hash)
                    ))
                    if claudeData != nil, await mover.hasUncommittedChanges(claudePath, in: root) == true {
                        warnings.append(.uncommittedChanges(path: claudePath))
                    }
                }
            }
        }

        let result = InstructionProposal(id: UUID(), projectId: projectId, changes: changes, warnings: warnings, createdAt: environment.now())
        if result.hasChanges { proposals[result.id] = result }
        return result
    }

    public func pendingProposal(_ id: UUID) -> InstructionProposal? { proposals[id] }

    /// Writes an approved proposal. Fails with `staleProposal` if any file changed since the proposal.
    public func apply(_ proposalId: UUID, approvedBy: EventActor) async throws -> InstructionApplyResult {
        guard let proposal = proposals[proposalId] else { throw WorkspaceError.proposalNotFound(proposalId) }
        let root = try await environment.projectRoot(proposal.projectId)
        // Re-check every file before writing anything.
        for change in proposal.changes {
            let current = FileSystem.read(change.path, in: root).map(DocumentFileRecord.hash)
            guard current == change.originalHash else {
                proposals[proposalId] = nil
                throw WorkspaceError.staleProposal(path: change.path)
            }
        }
        var written: [String] = []
        var warnings: [InstructionWarning] = []
        for change in proposal.changes {
            if change.originalHash != nil, await mover.hasUncommittedChanges(change.path, in: root) == true {
                warnings.append(.uncommittedChanges(path: change.path))
            }
            try AtomicFileWriter.write(Data(change.proposedText.utf8), to: root.appendingRelative(change.path),
                                       mode: .replace(expectedHash: change.originalHash), confinedTo: root)
            written.append(change.path)
            try await environment.database.documentFiles.upsert(DocumentFileRecord(
                projectId: proposal.projectId, relativePath: change.path, kind: .instructions, entityId: nil,
                content: change.proposedText, entityRevision: nil, updatedAt: environment.now()
            ))
        }
        proposals[proposalId] = nil
        return InstructionApplyResult(proposalId: proposalId, writtenFiles: written, approvedBy: approvedBy, warnings: warnings)
    }

    public func discard(_ proposalId: UUID) {
        proposals[proposalId] = nil
    }
}
