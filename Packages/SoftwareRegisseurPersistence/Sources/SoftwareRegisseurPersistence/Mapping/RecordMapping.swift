import Foundation
import GRDB
import SoftwareRegisseurDomain

enum AudioNoteStorage: EntityStorage {
    typealias Entity = AudioNote
    static let entityType = SyncEntityType.audioNote

    static func syncID(of entity: AudioNote) -> UUID { entity.id.rawValue }

    static func decode(_ row: Row) throws -> AudioNote {
        AudioNote(
            id: try row.id("id"),
            workItemId: try row.optionalID("work_item_id"),
            localAssetRef: try row.string("local_asset_ref"),
            provider: try row.open("provider"),
            consent: try row.json("consent"),
            transcriptionState: try row.enumValue("transcription_state"),
            retentionPolicy: try row.json("retention_policy"),
            createdAt: try row.date("created_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> AudioNote? {
        try Row.fetchOne(db, sql: "SELECT * FROM audio_notes WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ a: AudioNote) throws {
        try db.upsert(into: "audio_notes", [
            "id": a.id.databaseText,
            "work_item_id": a.workItemId?.databaseText,
            "local_asset_ref": a.localAssetRef,
            "provider": a.provider.rawValue,
            "consent": try JSONColumn.encode(a.consent),
            "transcription_state": a.transcriptionState.rawValue,
            "retention_policy": try JSONColumn.encode(a.retentionPolicy),
            "created_at": StoredDate.value(a.createdAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM audio_notes WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum AIRequestStorage: EntityStorage {
    typealias Entity = AIRequest
    static let entityType = SyncEntityType.aiRequest

    static func syncID(of entity: AIRequest) -> UUID { entity.id.rawValue }

    static func decode(_ row: Row) throws -> AIRequest {
        AIRequest(
            id: try row.id("id"),
            itemId: try row.id("item_id"),
            provider: try row.open("provider"),
            model: try row.open("model"),
            mode: try row.enumValue("mode"),
            inputVersion: try row.int("input_version"),
            draftVersion: row.optionalInt("draft_version"),
            usage: try row.optionalJSON("usage"),
            costEstimate: try row.optionalJSON("cost_estimate"),
            state: try row.enumValue("state"),
            createdAt: try row.date("created_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> AIRequest? {
        try Row.fetchOne(db, sql: "SELECT * FROM ai_requests WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ r: AIRequest) throws {
        try db.upsert(into: "ai_requests", [
            "id": r.id.databaseText,
            "item_id": r.itemId.databaseText,
            "provider": r.provider.rawValue,
            "model": r.model.rawValue,
            "mode": r.mode.rawValue,
            "input_version": r.inputVersion,
            "draft_version": r.draftVersion,
            "usage": try r.usage.map(JSONColumn.encode),
            "cost_estimate": try r.costEstimate.map(JSONColumn.encode),
            "state": r.state.rawValue,
            "created_at": StoredDate.value(r.createdAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM ai_requests WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum AIConversationStorage: EntityStorage {
    typealias Entity = AIConversation
    static let entityType = SyncEntityType.aiConversation

    static func syncID(of entity: AIConversation) -> UUID { entity.id.rawValue }

    static func decode(_ row: Row) throws -> AIConversation {
        let fields: [String: (any Encodable)?] = [
            "id": try row.uuid("id"),
            "itemId": try row.uuid("item_id"),
            "provider": try row.string("provider"),
            "model": try row.string("model"),
            "messages": try row.json("messages", as: [AIMessage].self),
            "contextScope": try row.json("context_scope", as: AIContextScope.self),
            "proposedDraftVersion": row.optionalInt("proposed_draft_version"),
            "usage": try row.json("usage", as: TokenUsage.self),
            "createdAt": try row.date("created_at"),
            "updatedAt": try row.date("updated_at"),
        ]
        do {
            return try DomainBridge.make(AIConversation.self, fields)
        } catch {
            throw StoreError.corruptValue(column: "ai_conversations", detail: "\(error)")
        }
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> AIConversation? {
        try Row.fetchOne(db, sql: "SELECT * FROM ai_conversations WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ c: AIConversation) throws {
        try db.upsert(into: "ai_conversations", [
            "id": c.id.databaseText,
            "item_id": c.itemId.databaseText,
            "provider": c.provider.rawValue,
            "model": c.model.rawValue,
            "messages": try JSONColumn.encode(c.messages),
            "context_scope": try JSONColumn.encode(c.contextScope),
            "proposed_draft_version": c.proposedDraftVersion,
            "usage": try JSONColumn.encode(c.usage),
            "created_at": StoredDate.value(c.createdAt),
            "updated_at": StoredDate.value(c.updatedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM ai_conversations WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum ReviewStorage: EntityStorage {
    typealias Entity = Review
    static let entityType = SyncEntityType.review

    static func syncID(of entity: Review) -> UUID { entity.reviewId.rawValue }

    static func decode(_ row: Row) throws -> Review {
        var fields: [String: (any Encodable)?] = [
            "reviewId": try row.uuid("review_id"),
            "jobId": try row.uuid("job_id"),
            "diffSummary": try row.json("diff_summary", as: DiffSummary.self),
            "testResults": try row.json("test_results", as: [TestResult].self),
            "decision": try row.string("decision"),
            "approvedAt": row.optionalDate("approved_at"),
            "integrationCommit": row["integration_commit"] as String?,
            "integrationStrategy": row["integration_strategy"] as String?,
        ]
        // v4 content columns; absent on databases migrated only to v1–v3.
        if row.hasColumn("commits") {
            fields["summary"] = row["summary"] as String?
            fields["commits"] = try row.json("commits", as: [ReviewCommit].self)
            fields["fileChanges"] = try row.json("file_changes", as: [ReviewFileChange].self)
            fields["conflict"] = try row.optionalJSON("conflict", as: ReviewConflictInfo.self)
            fields["testSummary"] = try row.optionalJSON("test_summary", as: TestRunSummary.self)
            fields["headCommit"] = row["head_commit"] as String?
            fields["notes"] = try row.json("notes", as: [String].self)
        }
        do {
            return try DomainBridge.make(Review.self, fields)
        } catch {
            throw StoreError.corruptValue(column: "reviews", detail: "\(error)")
        }
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> Review? {
        try Row.fetchOne(db, sql: "SELECT * FROM reviews WHERE review_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ r: Review) throws {
        try db.upsert(into: "reviews", [
            "review_id": r.reviewId.databaseText,
            "job_id": r.jobId.databaseText,
            "diff_summary": try JSONColumn.encode(r.diffSummary),
            "test_results": try JSONColumn.encode(r.testResults),
            "decision": r.decision.rawValue,
            "approved_at": StoredDate.value(r.approvedAt),
            "integration_commit": r.integrationCommit,
            "integration_strategy": r.integrationStrategy?.rawValue,
        ], conflictKeys: ["review_id"])
        if try db.hasColumn("commits", in: "reviews") {
            try db.execute(sql: """
                UPDATE reviews SET summary = ?, commits = ?, file_changes = ?, conflict = ?, test_summary = ?,
                    head_commit = ?, notes = ? WHERE review_id = ?
                """, arguments: [r.summary, try JSONColumn.encode(r.commits), try JSONColumn.encode(r.fileChanges),
                                 try r.conflict.map(JSONColumn.encode), try r.testSummary.map(JSONColumn.encode),
                                 r.headCommit, try JSONColumn.encode(r.notes), r.reviewId.databaseText])
        }
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM reviews WHERE review_id = ?", arguments: [syncID.uuidString])
    }
}

enum GitHubIssueLinkStorage: EntityStorage {
    typealias Entity = GitHubIssueLink
    static let entityType = SyncEntityType.gitHubIssueLink

    /// One link per work item; the work item UUID is the link identity.
    static func syncID(of entity: GitHubIssueLink) -> UUID { entity.workItemId.rawValue }

    static func decode(_ row: Row) throws -> GitHubIssueLink {
        GitHubIssueLink(
            workItemId: try row.id("work_item_id"),
            repo: try row.string("repo"),
            issueNumber: try row.int("issue_number"),
            url: try row.string("url"),
            lastSyncedRevision: try row.int("last_synced_revision")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> GitHubIssueLink? {
        try Row.fetchOne(db, sql: "SELECT * FROM github_issue_links WHERE work_item_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ l: GitHubIssueLink) throws {
        try db.upsert(into: "github_issue_links", [
            "work_item_id": l.workItemId.databaseText,
            "repo": l.repo,
            "issue_number": l.issueNumber,
            "url": l.url,
            "last_synced_revision": l.lastSyncedRevision,
        ], conflictKeys: ["work_item_id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM github_issue_links WHERE work_item_id = ?", arguments: [syncID.uuidString])
    }
}

enum ProviderProfileStorage: EntityStorage {
    typealias Entity = ProviderProfile
    static let entityType = SyncEntityType.providerProfile

    static func syncID(of entity: ProviderProfile) -> UUID { entity.id.rawValue }

    /// Only profiles whose key reference points into the iCloud Keychain are meaningful on other
    /// devices; the record never contains key material (spec I, N1).
    static func shouldSync(_ entity: ProviderProfile) -> Bool { entity.deviceScope == .iCloudKeychain }

    static func decode(_ row: Row) throws -> ProviderProfile {
        let reference: KeychainReference? =
            if let service: String = row["keychain_service"], let account: String = row["keychain_account"] {
                KeychainReference(service: service, account: account)
            } else { nil }
        return ProviderProfile(
            id: try row.id("id"),
            providerId: try row.open("provider_id"),
            purpose: try row.enumValue("purpose"),
            model: try row.optionalOpen("model"),
            keychainReference: reference,
            deviceScope: try row.enumValue("device_scope"),
            settings: try row.json("settings")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> ProviderProfile? {
        try Row.fetchOne(db, sql: "SELECT * FROM provider_profiles WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ p: ProviderProfile) throws {
        try db.upsert(into: "provider_profiles", [
            "id": p.id.databaseText,
            "provider_id": p.providerId.rawValue,
            "purpose": p.purpose.rawValue,
            "model": p.model?.rawValue,
            "keychain_service": p.keychainReference?.service,
            "keychain_account": p.keychainReference?.account,
            "device_scope": p.deviceScope.rawValue,
            "settings": try JSONColumn.encode(p.settings),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM provider_profiles WHERE id = ?", arguments: [syncID.uuidString])
    }
}
