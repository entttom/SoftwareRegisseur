import Foundation
import Testing
@testable import SoftwareRegisseurDomain

@Suite("Workspace entities (E2/E3)")
struct WorkspaceEntityTests {
    @Test func projectStatusReasonIsOptionalAndBackwardCompatible() throws {
        var project = Project(name: "Demo", repositoryKind: .gitRepository, settingsId: ProjectSettingsID(), createdAt: referenceDate)
        let encoded = try JSONEncoder().encode(project)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("statusReason"))
        try project.transition(to: .needsAttention, reason: "Ordner fehlt", at: referenceDate)
        #expect(project.status == .needsAttention && project.statusReason == "Ordner fehlt" && project.revision == 2)
        try project.transition(to: .needsAttention, reason: "Ordner fehlt", at: referenceDate)
        #expect(project.revision == 2)
        try project.transition(to: .ready, reason: nil, at: referenceDate)
        #expect(project.statusReason == nil)
        #expect(throws: InvalidStateTransition<ProjectStatus>.self) {
            try project.transition(to: .pendingMacSetup, reason: "x", at: referenceDate)
        }
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        #expect(decoded.statusReason == nil)
    }

    @Test func setupCommandStructureValidation() throws {
        let ok = ProjectSetupCommand(kind: .createProject, projectName: "App", target: .indexedFolder(path: "/tmp/x"), createdAt: referenceDate)
        try ok.validateStructure()
        let noConsent = ProjectSetupCommand(kind: .createProject, projectName: "App",
                                            target: .newSubfolder(parentPath: "/tmp", folderName: "neu"),
                                            initializeGitRepository: true, createdAt: referenceDate)
        #expect(throws: ProjectSetupFailure.self) { try noConsent.validateStructure() }
        let traversal = ProjectSetupCommand(kind: .createProject, projectName: "App",
                                            target: .newSubfolder(parentPath: "/tmp", folderName: ".."), createdAt: referenceDate)
        #expect { try traversal.validateStructure() } throws: { ($0 as? ProjectSetupFailure)?.code == .invalidFolderName }
        let linkDraft = ProjectSetupCommand(kind: .linkProject, projectName: "App", target: .draftWithoutRepository, createdAt: referenceDate)
        #expect(throws: ProjectSetupFailure.self) { try linkDraft.validateStructure() }

        var command = ok
        command.fail(ProjectSetupFailure(.folderNotFound, "fehlt"), at: referenceDate)
        #expect(command.state == .failed && command.revision == 2)
        let roundTrip = try JSONDecoder().decode(ProjectSetupCommand.self, from: JSONEncoder().encode(command))
        #expect(roundTrip == command)
    }

    @Test func indexedFolderKindMapsToRepositoryKind() {
        #expect(IndexedFolderKind.plainFolder.repositoryKind == .notARepository)
        #expect(IndexedFolderKind.repositorySubfolder.repositoryKind == .subfolderOfRepository)
        #expect(IndexedFolderKind.linkedWorktree.repositoryKind == nil)
    }

    @Test func fileConflictResolution() {
        var conflict = FileConflict(projectId: ProjectID(), location: "docs/requests/open/FR-0001.md", kind: .concurrentEdit,
                                    databaseRevision: 3, detectedAt: referenceDate)
        #expect(!conflict.isResolved)
        conflict.resolve(.acceptedExternal, at: referenceDate)
        #expect(conflict.isResolved && conflict.resolution == .acceptedExternal)
    }
}
