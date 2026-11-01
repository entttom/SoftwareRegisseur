import Foundation
import GRDB
import SoftwareRegisseurDomain

// MARK: - ADRs

public protocol ADRRepository: Sendable {
    func insert(_ adr: ADR, at date: Date) async throws
    func update(_ adr: ADR, expectedRevision: Int, at date: Date) async throws -> ADR
    func transition(_ id: ADRID, to status: ADRStatus, expectedRevision: Int, at date: Date) async throws -> ADR
    func fetch(_ id: ADRID) async throws -> ADR?
    func fetch(projectId: ProjectID, number: ADRNumber) async throws -> ADR?
    func list(projectId: ProjectID) async throws -> [ADR]
    func delete(_ id: ADRID, expectedRevision: Int, at date: Date) async throws
}

public struct GRDBADRRepository: ADRRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Registers the number in the ADR range so it is never handed out again (ADR-0018).
    public func insert(_ adr: ADR, at date: Date = .now) async throws {
        try await database.write { db in
            if try ADRStorage.fetch(db, syncID: adr.uuid.rawValue) != nil {
                throw StoreError.alreadyExists(entity: .adr, id: adr.uuid.uuidString)
            }
            try HumanIDCounters.observe(db, projectId: adr.projectId, rangeKey: HumanIDCounters.adrRangeKey,
                                        number: adr.decisionNumber.value, at: date)
            try SyncBookkeeping.save(db, ADRStorage.self, adr, isNew: true, at: date)
        }
    }

    public func update(_ adr: ADR, expectedRevision: Int, at date: Date = .now) async throws -> ADR {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, adr.uuid, expectedRevision: expectedRevision)
            guard adr.projectId == stored.projectId, adr.decisionNumber == stored.decisionNumber, adr.createdAt == stored.createdAt else {
                throw StoreError.identityFieldChanged(entity: .adr, field: "projectId/decisionNumber/createdAt")
            }
            if adr.status != stored.status, !stored.status.canTransition(to: adr.status) {
                throw StoreError.invalidADRTransition(InvalidStateTransition(from: stored.status, to: adr.status))
            }
            guard adr.revision >= expectedRevision else {
                throw StoreError.revisionConflict(entity: .adr, id: adr.uuid.uuidString, expected: expectedRevision, actual: adr.revision)
            }
            // ADR has no public `touch`; an unchanged revision is bumped through the full initializer.
            let updated = adr.revision == expectedRevision ? try Self.bumped(adr, at: date) : adr
            try SyncBookkeeping.save(db, ADRStorage.self, updated, isNew: false, at: date)
            return updated
        }
    }

    public func transition(_ id: ADRID, to status: ADRStatus, expectedRevision: Int, at date: Date = .now) async throws -> ADR {
        try await database.write { db in
            var adr = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            do throws(InvalidStateTransition<ADRStatus>) {
                try adr.transition(to: status, at: date)
            } catch {
                throw StoreError.invalidADRTransition(error)
            }
            try SyncBookkeeping.save(db, ADRStorage.self, adr, isNew: false, at: date)
            return adr
        }
    }

    public func fetch(_ id: ADRID) async throws -> ADR? {
        try await database.read { db in try ADRStorage.fetch(db, syncID: id.rawValue) }
    }

    public func fetch(projectId: ProjectID, number: ADRNumber) async throws -> ADR? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM adrs WHERE project_id = ? AND decision_number = ?",
                             arguments: [projectId.databaseText, number.value]).map(ADRStorage.decode)
        }
    }

    public func list(projectId: ProjectID) async throws -> [ADR] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM adrs WHERE project_id = ? ORDER BY decision_number",
                             arguments: [projectId.databaseText]).map(ADRStorage.decode)
        }
    }

    public func delete(_ id: ADRID, expectedRevision: Int, at date: Date = .now) async throws {
        try await database.write { db in
            _ = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            try SyncBookkeeping.delete(db, ADRStorage.self, syncID: id.rawValue, at: date)
        }
    }

    static func fetchForUpdate(_ db: Database, _ id: ADRID, expectedRevision: Int) throws -> ADR {
        guard let stored = try ADRStorage.fetch(db, syncID: id.rawValue) else {
            throw StoreError.notFound(entity: .adr, id: id.uuidString)
        }
        guard stored.revision == expectedRevision else {
            throw StoreError.revisionConflict(entity: .adr, id: id.uuidString, expected: expectedRevision, actual: stored.revision)
        }
        return stored
    }

    static func bumped(_ adr: ADR, at date: Date) throws -> ADR {
        ADR(
            uuid: adr.uuid, projectId: adr.projectId, decisionNumber: adr.decisionNumber, title: adr.title,
            status: adr.status, date: adr.date, context: adr.context, decision: adr.decision,
            alternatives: adr.alternatives, consequences: adr.consequences, supersedes: adr.supersedes,
            supersededBy: adr.supersededBy, revision: adr.revision + 1, createdAt: adr.createdAt, updatedAt: date
        )
    }
}

// MARK: - Audio notes, AI requests, AI conversations

/// Dictation and text-AI records (spec H2–H4). Audio notes are device-local and never enter the outbox.
public protocol AIRecordRepository: Sendable {
    func saveAudioNote(_ note: AudioNote, at date: Date) async throws
    func audioNote(_ id: AudioNoteID) async throws -> AudioNote?
    func audioNotes(workItemId: WorkItemID) async throws -> [AudioNote]
    func deleteAudioNote(_ id: AudioNoteID, at date: Date) async throws
    func saveRequest(_ request: AIRequest, at date: Date) async throws
    func request(_ id: AIRequestID) async throws -> AIRequest?
    func requests(itemId: WorkItemID) async throws -> [AIRequest]
    func saveConversation(_ conversation: AIConversation, at date: Date) async throws
    func conversation(_ id: AIConversationID) async throws -> AIConversation?
    func conversations(itemId: WorkItemID) async throws -> [AIConversation]
}

public struct GRDBAIRecordRepository: AIRecordRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func saveAudioNote(_ note: AudioNote, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, AudioNoteStorage.self, note, at: date) }
    }

    public func audioNote(_ id: AudioNoteID) async throws -> AudioNote? {
        try await database.read { db in try AudioNoteStorage.fetch(db, syncID: id.rawValue) }
    }

    public func audioNotes(workItemId: WorkItemID) async throws -> [AudioNote] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM audio_notes WHERE work_item_id = ? ORDER BY created_at, rowid",
                             arguments: [workItemId.databaseText]).map(AudioNoteStorage.decode)
        }
    }

    public func deleteAudioNote(_ id: AudioNoteID, at date: Date = .now) async throws {
        try await database.write { db in try SyncBookkeeping.delete(db, AudioNoteStorage.self, syncID: id.rawValue, at: date) }
    }

    public func saveRequest(_ request: AIRequest, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, AIRequestStorage.self, request, at: date) }
    }

    public func request(_ id: AIRequestID) async throws -> AIRequest? {
        try await database.read { db in try AIRequestStorage.fetch(db, syncID: id.rawValue) }
    }

    public func requests(itemId: WorkItemID) async throws -> [AIRequest] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_requests WHERE item_id = ? ORDER BY created_at, rowid",
                             arguments: [itemId.databaseText]).map(AIRequestStorage.decode)
        }
    }

    public func saveConversation(_ conversation: AIConversation, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, AIConversationStorage.self, conversation, at: date) }
    }

    public func conversation(_ id: AIConversationID) async throws -> AIConversation? {
        try await database.read { db in try AIConversationStorage.fetch(db, syncID: id.rawValue) }
    }

    public func conversations(itemId: WorkItemID) async throws -> [AIConversation] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_conversations WHERE item_id = ? ORDER BY updated_at, rowid",
                             arguments: [itemId.databaseText]).map(AIConversationStorage.decode)
        }
    }
}

// MARK: - Reviews and GitHub issue links

public protocol ReviewRepository: Sendable {
    func save(_ review: Review, at date: Date) async throws
    func fetch(_ id: ReviewID) async throws -> Review?
    func reviews(jobId: JobID) async throws -> [Review]
    func saveIssueLink(_ link: GitHubIssueLink, at date: Date) async throws
    func issueLink(workItemId: WorkItemID) async throws -> GitHubIssueLink?
    func issueLinks(repo: String) async throws -> [GitHubIssueLink]
    func deleteIssueLink(workItemId: WorkItemID, at date: Date) async throws
}

public struct GRDBReviewRepository: ReviewRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// A recorded integration commit is permanent (ADR-0015).
    public func save(_ review: Review, at date: Date = .now) async throws {
        try await database.write { db in
            if let stored = try ReviewStorage.fetch(db, syncID: review.reviewId.rawValue) {
                guard stored.jobId == review.jobId else { throw StoreError.identityFieldChanged(entity: .review, field: "jobId") }
                if let commit = stored.integrationCommit, review.integrationCommit != commit {
                    throw StoreError.identityFieldChanged(entity: .review, field: "integrationCommit")
                }
            }
            try SyncBookkeeping.upsert(db, ReviewStorage.self, review, at: date)
        }
    }

    public func fetch(_ id: ReviewID) async throws -> Review? {
        try await database.read { db in try ReviewStorage.fetch(db, syncID: id.rawValue) }
    }

    public func reviews(jobId: JobID) async throws -> [Review] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM reviews WHERE job_id = ? ORDER BY rowid",
                             arguments: [jobId.databaseText]).map(ReviewStorage.decode)
        }
    }

    public func saveIssueLink(_ link: GitHubIssueLink, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, GitHubIssueLinkStorage.self, link, at: date) }
    }

    public func issueLink(workItemId: WorkItemID) async throws -> GitHubIssueLink? {
        try await database.read { db in try GitHubIssueLinkStorage.fetch(db, syncID: workItemId.rawValue) }
    }

    public func issueLinks(repo: String) async throws -> [GitHubIssueLink] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM github_issue_links WHERE repo = ? ORDER BY issue_number",
                             arguments: [repo]).map(GitHubIssueLinkStorage.decode)
        }
    }

    public func deleteIssueLink(workItemId: WorkItemID, at date: Date = .now) async throws {
        try await database.write { db in
            try SyncBookkeeping.delete(db, GitHubIssueLinkStorage.self, syncID: workItemId.rawValue, at: date)
        }
    }
}

// MARK: - Provider profiles

/// BYOK profiles (spec I). Only keychain coordinates are stored; key material stays in the Keychain.
public protocol ProviderProfileRepository: Sendable {
    func save(_ profile: ProviderProfile, at date: Date) async throws
    func fetch(_ id: ProviderProfileID) async throws -> ProviderProfile?
    func list(purpose: ProviderPurpose?) async throws -> [ProviderProfile]
    func delete(_ id: ProviderProfileID, at date: Date) async throws
}

public struct GRDBProviderProfileRepository: ProviderProfileRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ profile: ProviderProfile, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, ProviderProfileStorage.self, profile, at: date) }
    }

    public func fetch(_ id: ProviderProfileID) async throws -> ProviderProfile? {
        try await database.read { db in try ProviderProfileStorage.fetch(db, syncID: id.rawValue) }
    }

    public func list(purpose: ProviderPurpose? = nil) async throws -> [ProviderProfile] {
        try await database.read { db in
            if let purpose {
                return try Row.fetchAll(db, sql: "SELECT * FROM provider_profiles WHERE purpose = ? ORDER BY provider_id, id",
                                        arguments: [purpose.rawValue]).map(ProviderProfileStorage.decode)
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM provider_profiles ORDER BY provider_id, id").map(ProviderProfileStorage.decode)
        }
    }

    public func delete(_ id: ProviderProfileID, at date: Date = .now) async throws {
        try await database.write { db in try SyncBookkeeping.delete(db, ProviderProfileStorage.self, syncID: id.rawValue, at: date) }
    }
}
