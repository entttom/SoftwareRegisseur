import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import Testing
@testable import SoftwareRegisseurWorkspace

@Suite("Agent instructions (G, A05/A06)")
struct InstructionsManagerTests {
    let userText = "# Eigene Regeln\n\n- Immer Tests schreiben.\n"

    @Test func proposalNeedsExplicitApplyAndKeepsUserContent() async throws {
        let h = try Harness()
        let (project, repo) = try await h.project("app")
        try h.sandbox.write("app/AGENTS.md", userText)
        try h.sandbox.write("app/CLAUDE.md", "# Claude\n\nBitte freundlich bleiben.\n")
        try await h.sandbox.commitAll(repo)
        let manager = InstructionsManager(environment: h.environment)

        let proposal = try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: true))
        #expect(proposal.changes.map(\.path) == ["AGENTS.md", "CLAUDE.md"])
        let agentsDiff = try #require(proposal.changes.first?.unifiedDiff)
        #expect(agentsDiff.contains("+<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->"))
        #expect(agentsDiff.contains("+- Never commit, push or merge without explicit user approval."))
        #expect(agentsDiff.contains("+- Open requests: docs/requests/open/"))
        #expect(proposal.warnings.isEmpty)
        // Nothing written before approval.
        #expect(try h.sandbox.read("app/AGENTS.md") == userText)

        let result = try await manager.apply(proposal.id, approvedBy: .user(DeviceID()))
        #expect(result.writtenFiles == ["AGENTS.md", "CLAUDE.md"])
        let agents = try h.sandbox.read("app/AGENTS.md")
        #expect(agents.hasPrefix(userText))
        #expect(agents.contains("<!-- SOFTWARE-REGISSEUR:END -->"))
        let claude = try h.sandbox.read("app/CLAUDE.md")
        #expect(claude.hasPrefix("# Claude\n\nBitte freundlich bleiben.\n") && claude.hasSuffix("@AGENTS.md\n"))
        // Applying twice is impossible; a new proposal is empty (idempotent).
        await #expect(throws: WorkspaceError.self) { _ = try await manager.apply(proposal.id, approvedBy: .user(DeviceID())) }
        #expect(try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: true)).changes.isEmpty)
    }

    @Test func staleProposalIsRejectedAndUncommittedChangesWarn() async throws {
        let h = try Harness()
        let (project, repo) = try await h.project("app")
        try h.sandbox.write("app/AGENTS.md", userText)
        try await h.sandbox.commitAll(repo)
        try h.sandbox.write("app/AGENTS.md", userText + "- Uncommitted.\n")
        let manager = InstructionsManager(environment: h.environment)

        let proposal = try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: false))
        #expect(proposal.warnings.contains(.uncommittedChanges(path: "AGENTS.md")))
        #expect(proposal.changes.map(\.path) == ["AGENTS.md"]) // no CLAUDE.md (absent, not requested)

        try h.sandbox.write("app/AGENTS.md", userText + "- Noch eine Änderung.\n")
        await #expect(throws: WorkspaceError.staleProposal(path: "AGENTS.md")) {
            _ = try await manager.apply(proposal.id, approvedBy: .user(DeviceID()))
        }
        #expect(try h.sandbox.read("app/AGENTS.md") == userText + "- Noch eine Änderung.\n")
    }

    @Test func claudeImportOnlyWithCapabilityAndPolicyRespected() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app", git: false)
        try h.sandbox.write("app/CLAUDE.md", "# Claude\n")
        let manager = InstructionsManager(environment: h.environment)
        let proposal = try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: false))
        #expect(!proposal.changes.contains { $0.path == "CLAUDE.md" })
        #expect(proposal.warnings.contains(.claudeImportUnsupported))
        #expect(proposal.changes.first?.originalText == nil) // AGENTS.md would be created

        var settings = try #require(try await h.database.projects.settings(forProject: project.id))
        settings.agentInstructionsPolicy = .disabled
        _ = try await h.database.projects.saveSettings(settings, expectedRevision: settings.revision, at: h.clock.now)
        await #expect(throws: WorkspaceError.instructionsDisabled) {
            _ = try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: true))
        }
    }

    /// ADR-0024: an installed v1 block is migrated to v2 only as a proposal that needs explicit approval.
    @Test func v1BlockIsMigratedOnlyThroughApprovedProposal() async throws {
        let h = try Harness()
        let (project, repo) = try await h.project("app")
        let v1 = """
        <!-- SOFTWARE-REGISSEUR:BEGIN v1 -->
        ## Software Regisseur Workflow
        - On start: update task status and move into the active location if configured.
        - Never push or merge without explicit user approval.
        <!-- SOFTWARE-REGISSEUR:END -->

        """
        let original = userText + "\n" + v1 + "\n## Nachher\n"
        try h.sandbox.write("app/AGENTS.md", original)
        try await h.sandbox.commitAll(repo)
        let manager = InstructionsManager(environment: h.environment)

        let proposal = try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: false))
        let change = try #require(proposal.changes.first { $0.path == "AGENTS.md" })
        #expect(change.unifiedDiff.contains("-<!-- SOFTWARE-REGISSEUR:BEGIN v1 -->"))
        #expect(change.unifiedDiff.contains("+<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->"))
        #expect(change.unifiedDiff.contains("-- On start: update task status and move into the active location if configured."))
        // Not auto-applied.
        #expect(try h.sandbox.read("app/AGENTS.md") == original)

        _ = try await manager.apply(proposal.id, approvedBy: .user(DeviceID()))
        let migrated = try h.sandbox.read("app/AGENTS.md")
        #expect(migrated.hasPrefix(userText + "\n<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->\n"))
        #expect(migrated.hasSuffix("<!-- SOFTWARE-REGISSEUR:END -->\n\n## Nachher\n"))
        #expect(!migrated.contains("BEGIN v1"))
        #expect(try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: false))
            .changes.isEmpty)
    }
}

@Suite("Folder layout migration (F2, A05)")
struct FolderLayoutMigrationTests {
    @Test func previewShowsCollisionsAndApplyMovesOnlyPlannedFiles() async throws {
        let h = try Harness()
        let (project, repo) = try await h.project("app")
        let materializer = RequestMaterializer(environment: h.environment)
        let open = try await h.item(project.id, title: "Offen")
        let active = try await h.item(project.id, title: "Aktiv", status: .inProgress)
        try await materializer.materialize(open.uuid)
        try await materializer.materialize(active.uuid)
        try h.sandbox.write("app/docs/adr/0001-start.md", "---\nadr: 0001\ntitle: Start\nstatus: accepted\n---\n")
        try h.sandbox.write("app/docs/requests/open/notizen.txt", "privat\n")
        try h.sandbox.write("app/AGENTS.md", "# Regeln\n")
        let manager = InstructionsManager(environment: h.environment)
        let instructions = try await manager.propose(projectId: project.id, capabilities: InstructionCapabilities(claudeSupportsImports: false))
        _ = try await manager.apply(instructions.id, approvedBy: .user(DeviceID()))
        try await h.sandbox.commitAll(repo)

        var newSettings = try #require(try await h.database.projects.settings(forProject: project.id))
        newSettings.requestsRoot = "aufgaben"
        newSettings.openPath = "offen"
        newSettings.activePath = "in-arbeit"
        newSettings.reviewPath = "pruefung"
        newSettings.donePath = "erledigt"
        newSettings.adrPath = "architektur/adr"
        try h.sandbox.write("app/aufgaben/offen/FR-0001-offen.md", "fremd\n")

        let migrator = FolderLayoutMigrator(environment: h.environment)
        let blocked = try await migrator.preview(projectId: project.id, newSettings: newSettings)
        #expect(blocked.collisions.map(\.destination) == ["aufgaben/offen/FR-0001-offen.md"])
        #expect(!blocked.isApplicable)
        await #expect(throws: WorkspaceError.planHasCollisions) { _ = try await migrator.apply(blocked.id, approved: true, approvedBy: .user(DeviceID())) }

        try FileManager.default.removeItem(at: h.sandbox.url("app/aufgaben"))
        let plan = try await migrator.preview(projectId: project.id, newSettings: newSettings)
        #expect(plan.isApplicable)
        #expect(Set(plan.moves.map(\.destination)) == [
            "aufgaben/offen/FR-0001-offen.md", "aufgaben/in-arbeit/FR-0002-aktiv.md", "architektur/adr/0001-start.md",
        ])
        #expect(plan.instructionsDiff?.contains("+- Open requests: aufgaben/offen/") == true)
        await #expect(throws: WorkspaceError.notApproved) { _ = try await migrator.apply(plan.id, approved: false, approvedBy: .user(DeviceID())) }

        let result = try await migrator.apply(plan.id, approved: true, approvedBy: .user(DeviceID()))
        #expect(result.movedFiles.count == 3 && result.updatedInstructions)
        #expect(result.settings.requestsRoot == "aufgaben" && result.settings.adrPath == "architektur/adr")
        #expect(h.sandbox.exists("app/aufgaben/offen/FR-0001-offen.md"))
        #expect(h.sandbox.exists("app/architektur/adr/0001-start.md"))
        #expect(try h.sandbox.read("app/docs/requests/open/notizen.txt") == "privat\n") // unrelated file untouched
        let agents = try h.sandbox.read("app/AGENTS.md")
        #expect(agents.hasPrefix("# Regeln\n") && agents.contains("- ADRs: architektur/adr/"))
        #expect(try await h.database.documentFiles.fetch(entityId: open.uuid.rawValue)?.relativePath == "aufgaben/offen/FR-0001-offen.md")
        #expect(try await h.database.documentFiles.fetch(entityId: active.uuid.rawValue)?.relativePath == "aufgaben/in-arbeit/FR-0002-aktiv.md")
        // Tracked files were moved with git (renames staged).
        let status = try await h.sandbox.gitOutput(["status", "--porcelain"], in: repo)
        #expect(status.contains("R  docs/requests/open/FR-0001-offen.md -> aufgaben/offen/FR-0001-offen.md"))
        // The next reconciliation is quiet.
        let after = try await materializer.reconcile(projectId: project.id)
        #expect(after.conflicts.isEmpty && after.movedFiles.isEmpty && after.createdFiles.isEmpty && after.importedItems.isEmpty)
    }
}

@Suite("ADR import (F4, E3)")
struct ADRImportTests {
    @Test func importsCompatibleADRsPreservingNumbersAndMarksIncompatible() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app", git: false)
        try h.sandbox.write("app/docs/adr/0001-datenbank.md", """
            ---
            adr: 0001
            title: "Datenbank"
            status: accepted
            date: 2026-10-30
            ---

            # ADR-0001: Datenbank

            ## Kontext

            SQLite oder Cloud.

            ## Entscheidung

            GRDB.
            """)
        try h.sandbox.write("app/docs/adr/0004-alt.md", "# 4. Alter Ansatz\n\n## Status\n\nRejected\n")
        try h.sandbox.write("app/docs/adr/0007-ohne-status.md", "# Ohne Status\n")
        try h.sandbox.write("app/docs/adr/0001-doppelt.md", "---\nadr: 1\ntitle: Doppelt\nstatus: proposed\n---\n")
        try h.sandbox.write("app/docs/adr/README.md", "# Index\n")
        let importer = ADRImporter(environment: h.environment)

        let report = try await importer.importADRs(projectId: project.id)
        #expect(Set(report.imported.map(\.value)) == [1, 4])
        #expect(report.incompatible.keys.sorted() == ["docs/adr/0001-doppelt.md", "docs/adr/0007-ohne-status.md"])
        let adrs = try await h.database.adrs.list(projectId: project.id)
        let first = try #require(adrs.first { $0.decisionNumber.value == 1 })
        let rejected = try #require(adrs.first { $0.decisionNumber.value == 4 })
        #expect(rejected.status == .deprecated)
        #expect(report.warnings["docs/adr/0004-alt.md"]?.isEmpty == false)
        #expect(first.title == "Datenbank" && first.status == .accepted)
        #expect(first.context == "SQLite oder Cloud." && first.decision == "GRDB.")
        let records = try await h.database.documentFiles.list(projectId: project.id, kind: .adr)
        #expect(records.filter { $0.compatibility == .incompatible }.count == 2)

        // Idempotent; numbers are never reused (ADR-0018).
        let again = try await importer.importADRs(projectId: project.id)
        #expect(again.imported.isEmpty && again.updated.isEmpty)
        #expect(try await h.database.humanIDs.allocateADRNumber(projectId: project.id, existing: [], at: h.clock.now).value == 5)

        // Status edit in the file is taken over when it is a valid transition.
        try h.sandbox.write("app/docs/adr/0004-alt.md", "# 4. Alter Ansatz\n\n## Status\n\nproposed\n")
        let invalid = try await importer.importADRs(projectId: project.id)
        #expect(invalid.warnings["docs/adr/0004-alt.md"]?.contains { $0.contains("nicht zulässig") } == true)
    }
}
