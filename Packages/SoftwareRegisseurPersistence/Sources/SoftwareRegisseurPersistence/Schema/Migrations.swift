import Foundation
import GRDB

/// Explicit, numbered schema migrations (spec C.3, ADR-0019). Registered migrations must never be
/// edited once shipped; schema changes add a new `vN_…` migration. `eraseDatabaseOnSchemaChange` is
/// deliberately never used.
///
/// Schema conventions:
/// - UUIDs: uppercase TEXT. Open provider/model/effort IDs: verbatim TEXT (ADR-0006).
/// - Dates: REAL seconds since 2001-01-01 (exact `Date` round trip).
/// - Structured values: JSON TEXT; CloudKit payloads and engine state: BLOB.
/// - Foreign keys only inside one aggregate (e.g. `work_item_texts` → `work_items`). References
///   between independently synced entities are not FK-enforced, because CloudKit delivers records in
///   no guaranteed order (spec N3); repositories enforce those invariants.
/// - Spec O: user-editable text (`work_item_texts`) is stored apart from execution metadata
///   (`work_items`, `agent_jobs`).
public enum AppSchema {
    public static let migrationIdentifiers = [
        "v1_initial", "v2_sync_three_way_merge", "v3_workspace_host_index", "v4_cross_device_contracts",
    ]

    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial", migrate: v1Initial)
        migrator.registerMigration("v2_sync_three_way_merge", migrate: v2SyncThreeWayMerge)
        migrator.registerMigration("v3_workspace_host_index", migrate: v3WorkspaceHostIndex)
        migrator.registerMigration("v4_cross_device_contracts", migrate: v4CrossDeviceContracts)
    }

    /// Cross-device contracts (spec E2, H3, J2, J6, K1, M1/M2, N1). Additive only:
    /// - `work_items.archived_at`: archiving is not a status (ADR-0012).
    /// - `agent_jobs.retry_of_job_id`: retry link (K1 „Wiederholung“, M2).
    /// - `reviews`: synced review content (summary, commits, per-file stats, conflict, test summary).
    /// - `pending_approvals` / `approval_decisions`: approvals relayed by the Mac (J6 V1 fallback, L3).
    /// - `draft_versions`: original/transcript/AI draft versions (H3), synced.
    /// - `global_settings`: synced user-wide defaults (F2, J2).
    /// The v3 tables `project_setup_commands`, `indexed_folders` and `file_conflicts` now sync; rows that
    /// already exist are queued once for upload so the iPhone sees them after the upgrade.
    private static func v4CrossDeviceContracts(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE work_items ADD COLUMN archived_at REAL;
            CREATE INDEX work_items_by_archived ON work_items(archived_at);

            ALTER TABLE agent_jobs ADD COLUMN retry_of_job_id TEXT;
            CREATE INDEX agent_jobs_by_retry_of ON agent_jobs(retry_of_job_id) WHERE retry_of_job_id IS NOT NULL;

            ALTER TABLE reviews ADD COLUMN summary TEXT;
            ALTER TABLE reviews ADD COLUMN commits TEXT NOT NULL DEFAULT '[]';
            ALTER TABLE reviews ADD COLUMN file_changes TEXT NOT NULL DEFAULT '[]';
            ALTER TABLE reviews ADD COLUMN conflict TEXT;
            ALTER TABLE reviews ADD COLUMN test_summary TEXT;
            ALTER TABLE reviews ADD COLUMN head_commit TEXT;
            ALTER TABLE reviews ADD COLUMN notes TEXT NOT NULL DEFAULT '[]';

            CREATE TABLE pending_approvals (
                id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT NOT NULL,
                work_item_id TEXT NOT NULL,
                host_id TEXT NOT NULL,
                request_id TEXT NOT NULL,
                state TEXT NOT NULL,
                requested_at REAL NOT NULL,
                expires_at REAL,
                payload TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX pending_approvals_by_job ON pending_approvals(job_id, requested_at);
            CREATE INDEX pending_approvals_open ON pending_approvals(host_id, requested_at) WHERE state = 'pending';

            -- Immutable user decisions (append-only like task events).
            CREATE TABLE approval_decisions (
                id TEXT PRIMARY KEY NOT NULL,
                approval_id TEXT NOT NULL,
                job_id TEXT NOT NULL,
                decision TEXT NOT NULL,
                decided_by TEXT NOT NULL,
                decided_at REAL NOT NULL,
                payload TEXT NOT NULL
            ) STRICT;
            CREATE INDEX approval_decisions_by_approval ON approval_decisions(approval_id, decided_at);

            CREATE TABLE draft_versions (
                id TEXT PRIMARY KEY NOT NULL,
                work_item_id TEXT NOT NULL,
                version INTEGER NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL,
                accepted_at REAL,
                payload TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX draft_versions_by_work_item ON draft_versions(work_item_id, version, created_at);

            CREATE TABLE global_settings (
                id TEXT PRIMARY KEY NOT NULL,
                payload TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            """)
        let now = Date()
        for (type, table) in [(SyncEntityType.projectSetupCommand, "project_setup_commands"),
                              (.indexedFolder, "indexed_folders"), (.fileConflict, "file_conflicts")] {
            for text in try String.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY id") {
                guard let id = UUID(uuidString: text), try SyncBookkeeping.entityVersion(db, type, id) == nil else { continue }
                try SyncBookkeeping.enqueue(db, type, id, kind: .create, at: now)
            }
        }
    }

    /// Workspace layer of the Mac host (spec E1–E3, F3, M3). Additive only:
    /// - `projects.status_reason`: German explanation for `needsAttention`/`unavailable` (E2).
    /// - `project_setup_commands`: `CreateProject`/`LinkProject` commands (E2, A03). Full entity as JSON.
    /// - `indexed_folders`: folder index per host (E1/E2), selectable folders for new projects.
    /// - `document_files`: last reconciled version of every request/ADR file (hash, text, entity revision),
    ///   the common ancestor for detecting concurrent file + database edits (A04/A24).
    /// - `file_conflicts`: conflicts between database and request files / GitHub issues (N2, ADR-0016).
    /// - `host_state`: small host-local key/value store (scan cache, GitHub snapshots).
    /// These tables were host-local in v3; v4 syncs `project_setup_commands`, `indexed_folders` and
    /// `file_conflicts` (`document_files` and `host_state` stay host-local).
    private static func v3WorkspaceHostIndex(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE projects ADD COLUMN status_reason TEXT;

            CREATE TABLE project_setup_commands (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                host_id TEXT,
                state TEXT NOT NULL,
                payload TEXT NOT NULL,
                revision INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX project_setup_commands_by_state ON project_setup_commands(state, created_at);

            CREATE TABLE indexed_folders (
                id TEXT PRIMARY KEY NOT NULL,
                host_id TEXT NOT NULL,
                canonical_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                project_id TEXT,
                repository_identity TEXT,
                is_selectable INTEGER NOT NULL,
                is_available INTEGER NOT NULL,
                payload TEXT NOT NULL,
                last_seen_at REAL NOT NULL,
                UNIQUE (host_id, canonical_path)
            ) STRICT;
            CREATE INDEX indexed_folders_by_project ON indexed_folders(project_id);
            CREATE INDEX indexed_folders_by_identity ON indexed_folders(repository_identity);

            CREATE TABLE document_files (
                project_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                entity_id TEXT,
                content_hash TEXT NOT NULL,
                content TEXT NOT NULL,
                entity_revision INTEGER,
                entity_snapshot BLOB,
                compatibility TEXT NOT NULL,
                issue TEXT,
                updated_at REAL NOT NULL,
                PRIMARY KEY (project_id, relative_path)
            ) STRICT;
            CREATE INDEX document_files_by_entity ON document_files(entity_id);

            CREATE TABLE file_conflicts (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                work_item_id TEXT,
                adr_id TEXT,
                kind TEXT NOT NULL,
                payload TEXT NOT NULL,
                detected_at REAL NOT NULL,
                resolved_at REAL
            ) STRICT;
            CREATE INDEX file_conflicts_open ON file_conflicts(project_id, work_item_id) WHERE resolved_at IS NULL;

            CREATE TABLE host_state (
                scope TEXT NOT NULL,
                key TEXT NOT NULL,
                value BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (scope, key)
            ) STRICT;
            """)
    }

    /// Spec N2 (3-way merge instead of last-writer-wins): the last synced payload per entity (the common
    /// ancestor of later local and remote edits), a snapshot of it in each conflict, and who resolved a
    /// conflict (user or an automatic rule), so automatic resolutions stay traceable.
    /// Existing rows get NULL ancestors (unknown); such conflicts are never merged automatically.
    private static func v2SyncThreeWayMerge(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE sync_entity_state ADD COLUMN ancestor_payload BLOB;
            ALTER TABLE sync_entity_state ADD COLUMN ancestor_version INTEGER;
            ALTER TABLE sync_conflicts ADD COLUMN ancestor_payload BLOB;
            ALTER TABLE sync_conflicts ADD COLUMN ancestor_version INTEGER;
            ALTER TABLE sync_conflicts ADD COLUMN resolved_by TEXT;
            CREATE INDEX sync_conflicts_resolved ON sync_conflicts(resolved_at) WHERE resolved_at IS NOT NULL;
            """)
    }

    private static func v1Initial(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE project_settings (
                id TEXT PRIMARY KEY NOT NULL,
                adr_path TEXT NOT NULL,
                requests_root TEXT NOT NULL,
                open_path TEXT NOT NULL,
                active_path TEXT NOT NULL,
                review_path TEXT NOT NULL,
                done_path TEXT NOT NULL,
                default_agent_id TEXT,
                allow_parallel INTEGER NOT NULL,
                project_wide_lock INTEGER NOT NULL,
                max_parallel_jobs INTEGER,
                review_policy TEXT NOT NULL,
                integration_strategy TEXT NOT NULL,
                agent_instructions_policy TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;

            CREATE TABLE projects (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                repository_identity TEXT,
                repository_kind TEXT NOT NULL,
                remote TEXT,
                host_id TEXT,
                status TEXT NOT NULL,
                settings_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX projects_by_repository_identity ON projects(repository_identity);
            CREATE INDEX projects_by_host ON projects(host_id);

            CREATE TABLE repository_locations (
                project_id TEXT NOT NULL,
                host_id TEXT NOT NULL,
                sync_id TEXT NOT NULL UNIQUE,
                canonical_path TEXT NOT NULL,
                bookmark_reference TEXT,
                scan_state TEXT NOT NULL,
                last_scan_at REAL,
                PRIMARY KEY (project_id, host_id)
            ) STRICT;
            CREATE INDEX repository_locations_by_host ON repository_locations(host_id);

            CREATE TABLE work_items (
                uuid TEXT PRIMARY KEY NOT NULL,
                project_id TEXT,
                type TEXT NOT NULL,
                human_id TEXT,
                human_id_number INTEGER,
                status TEXT NOT NULL,
                priority TEXT NOT NULL,
                priority_rank INTEGER NOT NULL,
                complexity TEXT,
                labels TEXT NOT NULL,
                dependencies TEXT NOT NULL,
                agent_job_ids TEXT NOT NULL,
                review_state TEXT NOT NULL,
                revision INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE UNIQUE INDEX work_items_unique_human_id ON work_items(project_id, human_id)
                WHERE human_id IS NOT NULL;
            CREATE INDEX work_items_by_project_status ON work_items(project_id, status);
            CREATE INDEX work_items_by_project_type ON work_items(project_id, type);
            CREATE INDEX work_items_by_status ON work_items(status);
            CREATE INDEX work_items_by_priority ON work_items(priority_rank, updated_at);

            CREATE TABLE work_item_texts (
                work_item_id TEXT PRIMARY KEY NOT NULL
                    REFERENCES work_items(uuid) ON DELETE CASCADE,
                title TEXT NOT NULL,
                original_note TEXT NOT NULL,
                transcript TEXT,
                structured_body TEXT NOT NULL
            );
            """)

        // Full-text search over user-editable text; diacritics folded for German input.
        try db.create(virtualTable: "work_item_search", using: FTS5()) { t in
            t.synchronize(withTable: "work_item_texts")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("title")
            t.column("original_note")
            t.column("transcript")
            t.column("structured_body")
        }

        try db.execute(sql: """
            CREATE TABLE adrs (
                uuid TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                decision_number INTEGER NOT NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL,
                date REAL,
                context TEXT NOT NULL,
                decision TEXT NOT NULL,
                alternatives TEXT NOT NULL,
                consequences TEXT NOT NULL,
                supersedes TEXT NOT NULL,
                superseded_by INTEGER,
                revision INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE (project_id, decision_number)
            ) STRICT;

            CREATE TABLE audio_notes (
                id TEXT PRIMARY KEY NOT NULL,
                work_item_id TEXT,
                local_asset_ref TEXT NOT NULL,
                provider TEXT NOT NULL,
                consent TEXT NOT NULL,
                transcription_state TEXT NOT NULL,
                retention_policy TEXT NOT NULL,
                created_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX audio_notes_by_work_item ON audio_notes(work_item_id);

            CREATE TABLE ai_requests (
                id TEXT PRIMARY KEY NOT NULL,
                item_id TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                mode TEXT NOT NULL,
                input_version INTEGER NOT NULL,
                draft_version INTEGER,
                usage TEXT,
                cost_estimate TEXT,
                state TEXT NOT NULL,
                created_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX ai_requests_by_item ON ai_requests(item_id, created_at);

            CREATE TABLE ai_conversations (
                id TEXT PRIMARY KEY NOT NULL,
                item_id TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                messages TEXT NOT NULL,
                context_scope TEXT NOT NULL,
                proposed_draft_version INTEGER,
                usage TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX ai_conversations_by_item ON ai_conversations(item_id, updated_at);

            CREATE TABLE agent_hosts (
                host_id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                last_seen REAL NOT NULL,
                ready INTEGER NOT NULL,
                service_version TEXT NOT NULL
            ) STRICT;

            -- Decision: the model catalog is a child table (one row per model, ordered by `position`),
            -- per-model effort IDs are a JSON array (ordered, lossless open strings).
            CREATE TABLE agent_capabilities (
                host_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                sync_id TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                executable_path TEXT,
                app_bundle_id TEXT,
                version TEXT NOT NULL,
                installed INTEGER NOT NULL,
                authenticated INTEGER NOT NULL,
                runnable INTEGER NOT NULL,
                supports_remote INTEGER NOT NULL,
                supports_automatic_start INTEGER NOT NULL,
                supports_resume INTEGER NOT NULL,
                supports_approvals INTEGER NOT NULL,
                supports_model_selection INTEGER NOT NULL,
                supports_effort_selection INTEGER NOT NULL,
                default_model_id TEXT,
                capability_source TEXT NOT NULL,
                capability_revision INTEGER NOT NULL,
                last_checked REAL NOT NULL,
                detection_timestamp REAL NOT NULL,
                session_link_format TEXT,
                diagnostic TEXT,
                PRIMARY KEY (host_id, provider_id)
            ) STRICT;

            CREATE TABLE agent_model_capabilities (
                host_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                model_provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                supported_effort_ids TEXT NOT NULL,
                default_effort_id TEXT,
                availability TEXT NOT NULL,
                source TEXT NOT NULL,
                last_validated_at REAL NOT NULL,
                PRIMARY KEY (host_id, provider_id, position),
                FOREIGN KEY (host_id, provider_id)
                    REFERENCES agent_capabilities(host_id, provider_id) ON DELETE CASCADE
            ) STRICT;
            CREATE INDEX agent_model_capabilities_by_model ON agent_model_capabilities(provider_id, model_id);

            CREATE TABLE agent_model_preferences (
                scope_key TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                sync_id TEXT NOT NULL UNIQUE,
                project_id TEXT,
                model_selection TEXT,
                model_id TEXT,
                effort TEXT,
                inherits_default INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (scope_key, provider_id),
                CHECK ((scope_key = 'global') = (project_id IS NULL)),
                CHECK (model_selection IS NULL OR model_selection IN ('providerDefault', 'model')),
                CHECK ((model_selection = 'model') = (model_id IS NOT NULL))
            ) STRICT;
            CREATE INDEX agent_model_preferences_by_project ON agent_model_preferences(project_id);

            CREATE TABLE agent_jobs (
                job_id TEXT PRIMARY KEY NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE,
                project_id TEXT NOT NULL,
                work_item_id TEXT NOT NULL,
                host_id TEXT,
                provider_id TEXT NOT NULL,
                -- Immutable model/effort snapshot (spec J2a, A39); see trigger below.
                config_snapshot TEXT NOT NULL,
                requested_model_id TEXT,
                requested_effort TEXT,
                resolved_model_id TEXT,
                resolved_effort TEXT NOT NULL,
                capability_revision INTEGER NOT NULL,
                effective_model_id TEXT,
                effective_effort TEXT,
                effective_confirmed_at REAL,
                schedule TEXT NOT NULL,
                scheduled_at REAL,
                priority TEXT NOT NULL,
                priority_rank INTEGER NOT NULL,
                state TEXT NOT NULL,
                work_item_status_before_job TEXT NOT NULL,
                retry_count INTEGER NOT NULL,
                session_id TEXT,
                branch TEXT,
                worktree_path TEXT,
                started_at REAL,
                finished_at REAL,
                last_error TEXT,
                revision INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX agent_jobs_by_state_schedule ON agent_jobs(state, scheduled_at);
            CREATE INDEX agent_jobs_by_work_item ON agent_jobs(work_item_id, created_at);
            CREATE INDEX agent_jobs_by_project_state ON agent_jobs(project_id, state);
            CREATE INDEX agent_jobs_by_host_state ON agent_jobs(host_id, state);
            -- A15: at most one non-terminal job per work item.
            CREATE UNIQUE INDEX agent_jobs_one_active_per_work_item ON agent_jobs(work_item_id)
                WHERE state NOT IN ('finished', 'failed', 'cancelled');

            -- The snapshot may only be replaced explicitly before the job started (AgentJob.replaceConfiguration).
            CREATE TRIGGER agent_jobs_config_snapshot_immutable
            BEFORE UPDATE OF config_snapshot ON agent_jobs
            WHEN OLD.config_snapshot IS NOT NEW.config_snapshot
                AND (OLD.started_at IS NOT NULL
                     OR OLD.state NOT IN ('requested', 'pendingMac', 'scheduled', 'needs_configuration', 'waiting_quota', 'paused'))
            BEGIN
                SELECT RAISE(ABORT, 'agent_jobs.config_snapshot is immutable after start');
            END;

            CREATE TABLE task_locks (
                lock_id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                job_id TEXT NOT NULL,
                host_id TEXT NOT NULL,
                owner TEXT NOT NULL,
                scope TEXT NOT NULL,
                acquired_at REAL NOT NULL,
                last_heartbeat REAL NOT NULL,
                lease_until REAL NOT NULL,
                recovery_state TEXT NOT NULL,
                released_at REAL,
                release_reason TEXT
            ) STRICT;
            -- Spec L1: one unreleased lock per task, one unreleased project-scope lock per project.
            CREATE UNIQUE INDEX task_locks_one_per_task ON task_locks(task_id)
                WHERE recovery_state <> 'released';
            CREATE UNIQUE INDEX task_locks_one_project_lock ON task_locks(project_id)
                WHERE scope = 'project' AND recovery_state <> 'released';
            CREATE INDEX task_locks_by_project_state ON task_locks(project_id, recovery_state);
            CREATE INDEX task_locks_by_host_state ON task_locks(host_id, recovery_state);

            -- Append-only history (spec M2).
            CREATE TABLE task_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                work_item_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                actor TEXT NOT NULL,
                timestamp REAL NOT NULL,
                payload TEXT NOT NULL,
                source_revision INTEGER NOT NULL
            ) STRICT;
            CREATE INDEX task_events_by_work_item ON task_events(work_item_id, timestamp);
            CREATE INDEX task_events_by_time ON task_events(timestamp);
            CREATE TRIGGER task_events_no_update BEFORE UPDATE ON task_events
            BEGIN SELECT RAISE(ABORT, 'task_events is append-only'); END;
            CREATE TRIGGER task_events_no_delete BEFORE DELETE ON task_events
            BEGIN SELECT RAISE(ABORT, 'task_events is append-only'); END;

            CREATE TABLE reviews (
                review_id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT NOT NULL,
                diff_summary TEXT NOT NULL,
                test_results TEXT NOT NULL,
                decision TEXT NOT NULL,
                approved_at REAL,
                integration_commit TEXT,
                integration_strategy TEXT
            ) STRICT;
            CREATE INDEX reviews_by_job ON reviews(job_id);

            CREATE TABLE github_issue_links (
                work_item_id TEXT PRIMARY KEY NOT NULL,
                repo TEXT NOT NULL,
                issue_number INTEGER NOT NULL,
                url TEXT NOT NULL,
                last_synced_revision INTEGER NOT NULL
            ) STRICT;
            CREATE INDEX github_issue_links_by_issue ON github_issue_links(repo, issue_number);

            -- BYOK profiles hold only keychain coordinates, never secret material (spec I, ADR-0008).
            CREATE TABLE provider_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                provider_id TEXT NOT NULL,
                purpose TEXT NOT NULL,
                model TEXT,
                keychain_service TEXT,
                keychain_account TEXT,
                device_scope TEXT NOT NULL,
                settings TEXT NOT NULL,
                CHECK ((keychain_service IS NULL) = (keychain_account IS NULL))
            ) STRICT;

            -- ADR-0018: monotonic number range per prefix (FR, BUG, …, ADR) and project; never decremented.
            CREATE TABLE human_id_counters (
                project_id TEXT NOT NULL,
                range_key TEXT NOT NULL,
                highest_number INTEGER NOT NULL CHECK (highest_number >= 0),
                updated_at REAL NOT NULL,
                PRIMARY KEY (project_id, range_key)
            ) STRICT;
            CREATE TRIGGER human_id_counters_monotonic BEFORE UPDATE ON human_id_counters
            WHEN NEW.highest_number < OLD.highest_number
            BEGIN SELECT RAISE(ABORT, 'human_id_counters must never decrease'); END;

            -- Sync bookkeeping (spec N3, ADR-0019). Consumed by the CKSyncEngine layer.
            CREATE TABLE sync_outbox (
                operation_id TEXT PRIMARY KEY NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                change_kind TEXT NOT NULL,
                version INTEGER NOT NULL,
                state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX sync_outbox_by_state ON sync_outbox(state, created_at);
            CREATE INDEX sync_outbox_by_entity ON sync_outbox(entity_type, entity_id);

            -- Replay protection: every remote operation ID is applied at most once.
            CREATE TABLE sync_inbox (
                operation_id TEXT PRIMARY KEY NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                change_kind TEXT NOT NULL,
                version INTEGER NOT NULL,
                base_version INTEGER,
                outcome TEXT NOT NULL,
                received_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX sync_inbox_by_entity ON sync_inbox(entity_type, entity_id);

            CREATE TABLE sync_tombstones (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                version INTEGER NOT NULL,
                origin TEXT NOT NULL,
                deleted_at REAL NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            ) STRICT;

            -- Per-entity versions and CKRecord encoded system fields.
            CREATE TABLE sync_entity_state (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                local_version INTEGER NOT NULL,
                synced_version INTEGER NOT NULL,
                system_fields BLOB,
                updated_at REAL NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            ) STRICT;

            -- CKSyncEngine.State.Serialization, saved with the fetched changes it covers.
            CREATE TABLE sync_engine_state (
                scope TEXT PRIMARY KEY NOT NULL,
                serialization BLOB NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT;

            -- Spec N2/A24: both versions are kept; no silent last-writer-wins.
            CREATE TABLE sync_conflicts (
                conflict_id TEXT PRIMARY KEY NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                base_version INTEGER,
                local_version INTEGER NOT NULL,
                remote_version INTEGER NOT NULL,
                local_payload BLOB,
                remote_payload BLOB,
                remote_change_kind TEXT NOT NULL,
                remote_operation_id TEXT NOT NULL,
                remote_system_fields BLOB,
                detected_at REAL NOT NULL,
                resolved_at REAL,
                resolution TEXT
            ) STRICT;
            CREATE INDEX sync_conflicts_open ON sync_conflicts(entity_type, entity_id)
                WHERE resolved_at IS NULL;
            """)
    }
}
