import Foundation
import SoftwareRegisseurDomain

/// Ergebnis eines Befehls (``ServiceResponse/result(_:)``). Fehler kommen als ``ServiceResponse/failure(_:)``.
public enum ServiceResult: Codable, Sendable, Hashable {
    /// Befehl ausgeführt; optionale deutsche Meldung für die UI.
    case done(String?)
    /// Befehl angenommen, läuft im Hintergrund weiter; Fortschritt über Datenbank/Statusübersicht.
    case accepted(String?)
    case serviceSettings(ServiceSettings)
    case syncFinished(SyncRunInfo)
    case scanFinished(ScanInfo)
    case rootFolders(RootFolderState)
    /// Pfadliste, z. B. Re-Link-Kandidaten.
    case paths([String])
    case instructionProposals([InstructionProposalInfo])
    case folderMigrationPlan(FolderMigrationPlanInfo)
    case agents([AgentProviderSummary])
    case job(JobInfo)
    case jobStatus(JobStatusInfo)
    case reviewDetails(ReviewDetailsInfo)
    case integration(IntegrationInfo)
    case gitHubAvailability(GitHubAvailabilityInfo)
    case gitHubIssues([GitHubIssueInfo])
    case workItem(WorkItemID)
    case macAIElaboration(MacAIElaborationInfo)

    // Seit Protokoll 3
    /// Aufgabe angelegt oder geändert.
    case workItemSaved(WorkItemSavedInfo)
    case adrCreated(ADRCreatedInfo)
    case gitHubProjectState(GitHubProjectStateInfo)
    case localDeletionPreview(LocalDeletionPreviewInfo)
    case localDeletionReport(LocalDeletionReportInfo)
    case cloudDeletionPreview(CloudDeletionPreviewInfo)

    // Seit Protokoll 4
    /// Gespräch aus „Mit KI besprechen“ gespeichert.
    case conversationSaved(ConversationSavedInfo)
    /// Vorschlag als Entwurfsversion angelegt (und ggf. übernommen).
    case conversationDraft(ConversationDraftInfo)
    /// Vollständiger Text einer gekürzten Freigabevorschau (SR-SEC-08).
    case approvalPreview(ApprovalPreviewInfo)
}

public struct SyncRunInfo: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable, Hashable {
        case completed, deferred, paused, failed, coalesced
    }

    public var outcome: Outcome
    public var applied: Int
    public var sent: Int
    public var conflicts: Int
    /// Deutsche Erklärung bei `deferred`, `paused`, `failed`.
    public var message: String?

    public init(outcome: Outcome, applied: Int = 0, sent: Int = 0, conflicts: Int = 0, message: String? = nil) {
        self.outcome = outcome
        self.applied = applied
        self.sent = sent
        self.conflicts = conflicts
        self.message = message
    }
}

public struct ScanInfo: Codable, Sendable, Hashable {
    public var createdProjects: Int
    public var updatedProjects: Int
    public var movedProjects: Int
    public var unavailableProjects: Int
    public var relinkCandidates: Int
    public var indexedFolders: Int
    /// Bereits redigierte Meldungen des Scanners.
    public var issues: [String]
    public var finishedAt: Date

    public init(createdProjects: Int, updatedProjects: Int, movedProjects: Int, unavailableProjects: Int,
                relinkCandidates: Int, indexedFolders: Int, issues: [String], finishedAt: Date) {
        self.createdProjects = createdProjects
        self.updatedProjects = updatedProjects
        self.movedProjects = movedProjects
        self.unavailableProjects = unavailableProjects
        self.relinkCandidates = relinkCandidates
        self.indexedFolders = indexedFolders
        self.issues = issues
        self.finishedAt = finishedAt
    }
}

/// Stammordner dieses Macs (E1). Ohne bestätigten Ordner scannt der Dienst nichts.
public struct RootFolderState: Codable, Sendable, Hashable {
    public struct Folder: Codable, Sendable, Hashable {
        /// Kanonischer absoluter Pfad.
        public var path: String
        public var exists: Bool
        public var addedAt: Date

        public init(path: String, exists: Bool, addedAt: Date) {
            self.path = path
            self.exists = exists
            self.addedAt = addedAt
        }
    }

    public var folders: [Folder]
    /// Vorschlag für die Ersteinrichtung (`~/Developer`, falls vorhanden); wird nie automatisch übernommen.
    public var suggestion: String?

    public init(folders: [Folder], suggestion: String?) {
        self.folders = folders
        self.suggestion = suggestion
    }
}

public struct InstructionProposalInfo: Codable, Sendable, Hashable, Identifiable {
    public struct FileChange: Codable, Sendable, Hashable {
        public var path: String
        public var isNewFile: Bool
        public var proposedText: String
        public var unifiedDiff: String

        public init(path: String, isNewFile: Bool, proposedText: String, unifiedDiff: String) {
            self.path = path
            self.isNewFile = isNewFile
            self.proposedText = proposedText
            self.unifiedDiff = unifiedDiff
        }
    }

    public var id: UUID
    public var projectId: ProjectID
    public var projectName: String
    public var changes: [FileChange]
    /// Deutsche Hinweise (nicht eingecheckte Änderungen, CLAUDE.md-Import nicht unterstützt …).
    public var warnings: [String]
    public var createdAt: Date

    public init(id: UUID, projectId: ProjectID, projectName: String, changes: [FileChange], warnings: [String], createdAt: Date) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.changes = changes
        self.warnings = warnings
        self.createdAt = createdAt
    }
}

public struct FolderMigrationPlanInfo: Codable, Sendable, Hashable {
    public struct Move: Codable, Sendable, Hashable {
        /// "request" oder "adr".
        public var kind: String
        public var source: String
        public var destination: String

        public init(kind: String, source: String, destination: String) {
            self.kind = kind
            self.source = source
            self.destination = destination
        }
    }

    public struct Collision: Codable, Sendable, Hashable {
        public var destination: String
        public var sources: [String]
        public var reason: String

        public init(destination: String, sources: [String], reason: String) {
            self.destination = destination
            self.sources = sources
            self.reason = reason
        }
    }

    public var planId: UUID
    public var projectId: ProjectID
    public var layout: FolderLayoutPaths
    public var moves: [Move]
    public var collisions: [Collision]
    /// Diff des AGENTS.md-Blocks, falls sich die Pfade darin ändern.
    public var instructionsDiff: String?
    public var isApplicable: Bool

    public init(planId: UUID, projectId: ProjectID, layout: FolderLayoutPaths, moves: [Move], collisions: [Collision],
                instructionsDiff: String?, isApplicable: Bool) {
        self.planId = planId
        self.projectId = projectId
        self.layout = layout
        self.moves = moves
        self.collisions = collisions
        self.instructionsDiff = instructionsDiff
        self.isApplicable = isApplicable
    }
}

/// Kurzfassung eines Jobs nach einer Steueraktion.
public struct JobInfo: Codable, Sendable, Hashable {
    public var jobId: JobID
    public var workItemId: WorkItemID
    public var providerId: ProviderID
    public var state: AgentJobState
    public var priority: Priority
    public var lastError: String?
    /// `false`, wenn ein Jobwunsch mit demselben Idempotenzschlüssel schon existierte.
    public var wasCreated: Bool

    public init(jobId: JobID, workItemId: WorkItemID, providerId: ProviderID, state: AgentJobState, priority: Priority,
                lastError: String?, wasCreated: Bool = false) {
        self.jobId = jobId
        self.workItemId = workItemId
        self.providerId = providerId
        self.state = state
        self.priority = priority
        self.lastError = lastError
        self.wasCreated = wasCreated
    }
}

/// Hostlokale Jobdetails (Laufzeitdatei des Dienstes, nicht synchronisiert).
public struct JobStatusInfo: Codable, Sendable, Hashable {
    public var job: JobInfo
    /// Deutsche Zeitplan-/Statuszeile, z. B. „für 22:00 geplant, Mac zuletzt online 21:30“.
    public var scheduleText: String
    public var plannedStart: Date?
    /// Warum der Job gerade nicht startet (deutsch), falls bekannt.
    public var admissionBlock: String?
    public var awaitingMissedRunDecision: Bool
    public var nextQuotaAttempt: Date?
    public var isLive: Bool
    public var orphanedProcess: Bool
    public var processIdentifier: Int32?
    public var worktreePath: String?
    public var branch: String?
    public var repositoryPath: String?
    public var openApprovals: [PendingApprovalID]

    public init(job: JobInfo, scheduleText: String, plannedStart: Date?, admissionBlock: String?, awaitingMissedRunDecision: Bool,
                nextQuotaAttempt: Date?, isLive: Bool, orphanedProcess: Bool, processIdentifier: Int32?, worktreePath: String?,
                branch: String?, repositoryPath: String?, openApprovals: [PendingApprovalID]) {
        self.job = job
        self.scheduleText = scheduleText
        self.plannedStart = plannedStart
        self.admissionBlock = admissionBlock
        self.awaitingMissedRunDecision = awaitingMissedRunDecision
        self.nextQuotaAttempt = nextQuotaAttempt
        self.isLive = isLive
        self.orphanedProcess = orphanedProcess
        self.processIdentifier = processIdentifier
        self.worktreePath = worktreePath
        self.branch = branch
        self.repositoryPath = repositoryPath
        self.openApprovals = openApprovals
    }
}

/// Review mit hostlokalen Pfaden (M1). Diff-Inhalte liest die UI selbst per `git` im Worktree.
public struct ReviewDetailsInfo: Codable, Sendable, Hashable {
    public var reviewId: ReviewID
    public var jobId: JobID
    public var workItemId: WorkItemID
    public var repositoryPath: String
    public var defaultBranch: String
    public var branch: String
    public var worktreePath: String?
    public var baseCommit: String?
    public var headCommit: String
    public var commits: [ReviewCommit]
    public var files: [ReviewFileChange]
    public var agentSummary: String?
    public var autoCommittedPaths: [String]
    /// Seit Protokoll 4 (SR-SEC-09, ADR-0026): Agentenausgaben, die wie Geheimnisse aussahen und deshalb nicht
    /// committet wurden; sie liegen noch im Worktree und blockieren die Integration. `nil` bei älteren Diensten.
    public var excludedSecretPaths: [String]?
    public var permissionDenials: [String]
    public var capturedAt: Date
    public var integrationConflictFiles: [String]?
    public var integrationProblem: String?
    public var integratedCommit: String?
    public var integratedAt: Date?

    public init(reviewId: ReviewID, jobId: JobID, workItemId: WorkItemID, repositoryPath: String, defaultBranch: String, branch: String,
                worktreePath: String?, baseCommit: String?, headCommit: String, commits: [ReviewCommit], files: [ReviewFileChange],
                agentSummary: String?, autoCommittedPaths: [String], permissionDenials: [String], capturedAt: Date,
                integrationConflictFiles: [String]?, integrationProblem: String?, integratedCommit: String?, integratedAt: Date?,
                excludedSecretPaths: [String]? = nil) {
        self.excludedSecretPaths = excludedSecretPaths
        self.reviewId = reviewId
        self.jobId = jobId
        self.workItemId = workItemId
        self.repositoryPath = repositoryPath
        self.defaultBranch = defaultBranch
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseCommit = baseCommit
        self.headCommit = headCommit
        self.commits = commits
        self.files = files
        self.agentSummary = agentSummary
        self.autoCommittedPaths = autoCommittedPaths
        self.permissionDenials = permissionDenials
        self.capturedAt = capturedAt
        self.integrationConflictFiles = integrationConflictFiles
        self.integrationProblem = integrationProblem
        self.integratedCommit = integratedCommit
        self.integratedAt = integratedAt
    }
}

public struct IntegrationInfo: Codable, Sendable, Hashable {
    /// "squash", "mergeCommit" oder "cherryPick" (ADR-0015).
    public var strategy: String
    public var commitSHA: String
    public var previousDefaultBranchCommit: String
    public var integratedCommits: [String]

    public init(strategy: String, commitSHA: String, previousDefaultBranchCommit: String, integratedCommits: [String]) {
        self.strategy = strategy
        self.commitSHA = commitSHA
        self.previousDefaultBranchCommit = previousDefaultBranchCommit
        self.integratedCommits = integratedCommits
    }
}

public struct GitHubAvailabilityInfo: Codable, Sendable, Hashable {
    public var isAvailable: Bool
    /// `gh --version` bei Verfügbarkeit, sonst deutsche Erklärung zur Einrichtung.
    public var detail: String

    public init(isAvailable: Bool, detail: String) {
        self.isAvailable = isAvailable
        self.detail = detail
    }
}

public struct GitHubIssueInfo: Codable, Sendable, Hashable {
    public var number: Int
    public var title: String
    public var state: String
    public var url: String
    public var updatedAt: String
    public var labels: [String]
    /// Bereits mit einer lokalen Aufgabe verknüpft.
    public var linkedWorkItemId: WorkItemID?

    public init(number: Int, title: String, state: String, url: String, updatedAt: String, labels: [String], linkedWorkItemId: WorkItemID?) {
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.updatedAt = updatedAt
        self.labels = labels
        self.linkedWorkItemId = linkedWorkItemId
    }
}

/// Stand einer KI-Ausarbeitung am Mac inklusive Kontext-Manifest (H4: nachvollziehbare Übermittlung).
public struct MacAIElaborationInfo: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        case pending, running, completed, failed
    }

    public struct ManifestEntry: Codable, Sendable, Hashable {
        public var kind: String
        public var title: String
        public var path: String?
        public var characterCount: Int
        public var redactionCount: Int
        public var truncated: Bool

        public init(kind: String, title: String, path: String?, characterCount: Int, redactionCount: Int, truncated: Bool) {
            self.kind = kind
            self.title = title
            self.path = path
            self.characterCount = characterCount
            self.redactionCount = redactionCount
            self.truncated = truncated
        }
    }

    public struct ExcludedEntry: Codable, Sendable, Hashable {
        public var title: String
        public var path: String?
        /// Deutscher Ausschlussgrund (Geheimnis, Budget, Binärdatei …).
        public var reason: String

        public init(title: String, path: String?, reason: String) {
            self.title = title
            self.path = path
            self.reason = reason
        }
    }

    public var requestId: AIRequestID
    public var workItemId: WorkItemID
    public var state: State
    public var providerId: String
    public var modelId: String
    public var included: [ManifestEntry]
    public var excluded: [ExcludedEntry]
    public var estimatedTokens: Int
    public var draftVersion: Int?
    /// Deutsche Fehlermeldung ohne Geheimnisse.
    public var errorMessage: String?
    public var updatedAt: Date

    public init(requestId: AIRequestID, workItemId: WorkItemID, state: State, providerId: String, modelId: String,
                included: [ManifestEntry] = [], excluded: [ExcludedEntry] = [], estimatedTokens: Int = 0, draftVersion: Int? = nil,
                errorMessage: String? = nil, updatedAt: Date) {
        self.requestId = requestId
        self.workItemId = workItemId
        self.state = state
        self.providerId = providerId
        self.modelId = modelId
        self.included = included
        self.excluded = excluded
        self.estimatedTokens = estimatedTokens
        self.draftVersion = draftVersion
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}
