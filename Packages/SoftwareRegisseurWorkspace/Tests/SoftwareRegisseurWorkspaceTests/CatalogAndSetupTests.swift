import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence
import Testing
@testable import SoftwareRegisseurWorkspace

@Suite("Project catalog (E1–E3)")
struct ProjectCatalogTests {
    @Test func scanCreatesProjectsAttachesWorktreesAndOffersFolders() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        let app = try await h.sandbox.repository("Developer/App")
        try h.sandbox.write("Developer/App/AGENTS.md", "# Regeln\n")
        try h.sandbox.write("Developer/App/docs/adr/0001-start.md", "---\nadr: 0001\ntitle: Start\nstatus: accepted\n---\n")
        try h.sandbox.mkdir("Developer/App/Sources/Feature")
        try await h.sandbox.git.run(["worktree", "add", "--quiet", "-b", "feature", dev.appending(path: "App-feature").path(percentEncoded: false)], in: app)
        try h.sandbox.mkdir("Developer/Idee")
        try h.sandbox.mkdir("Developer/node_modules/pkg")
        // A second clone of the same repository is a separate project (same identity, other path).
        try await h.sandbox.git.run(["clone", "--quiet", app.path(percentEncoded: false), dev.appending(path: "App-Klon").path(percentEncoded: false)], in: nil)

        let catalog = ProjectCatalog(environment: h.environment, configuration: CatalogConfiguration(roots: [dev]))
        let report = try await catalog.scan()
        #expect(report.createdProjects.count == 2)
        let projects = try await h.database.projects.list(statuses: [])
        #expect(Set(projects.map(\.name)) == ["App", "App-Klon"])
        #expect(projects.allSatisfy { $0.status == .ready && $0.repositoryKind == .gitRepository })
        #expect(projects[0].repositoryIdentity == projects[1].repositoryIdentity)
        #expect(projects.first { $0.name == "App-Klon" }?.remote != nil)

        let folders = try await h.database.indexedFolders.list(hostId: h.hostId)
        let byName = Dictionary(folders.map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["App-feature"]?.kind == .linkedWorktree)
        #expect(byName["App-feature"]?.projectId == nil && byName["App-feature"]?.isSelectable == false)
        #expect(byName["Idee"]?.kind == .plainFolder && byName["Idee"]?.isSelectable == true)
        #expect(byName["Sources"]?.kind == .repositorySubfolder && byName["Sources"]?.isSelectable == true)
        #expect(byName["pkg"] == nil)
        let documents = try #require(byName["App"]?.documents)
        #expect(documents.hasAgentsFile && !documents.hasClaudeFile && documents.adrFolder == "docs/adr" && documents.adrFileCount == 1)
        #expect(documents.readmeFiles == ["README.md"])
        let selectable = try await catalog.selectableFolders().map(\.displayName)
        #expect(selectable.contains("Idee") && !selectable.contains("App-feature"))

        // Incremental: the persisted cache is used on the next scan; nothing is duplicated.
        let second = try await catalog.scan()
        #expect(second.createdProjects.isEmpty)
        #expect((second.statistics?.cacheHits ?? 0) > 0)
        #expect(try await h.database.hostState.value(scope: "catalog", key: "scanCache") != nil)
        #expect(try await h.database.projects.list(statuses: []).count == 2)
    }

    @Test func movedAndMissingFoldersAreRelinkedNeverDeleted() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        try await h.sandbox.repository("Developer/App")
        let catalog = ProjectCatalog(environment: h.environment, configuration: CatalogConfiguration(roots: [dev]))
        try await catalog.scan()
        let project = try #require(try await h.database.projects.list(statuses: []).first)
        let item = try await h.item(project.id)

        // Same volume move → recognised by git dir device/inode.
        try FileManager.default.moveItem(at: h.sandbox.url("Developer/App"), to: h.sandbox.url("Developer/App-neu"))
        let moved = try await catalog.scan()
        #expect(moved.movedProjects[project.id]?.hasSuffix("Developer/App-neu") == true)
        #expect(moved.createdProjects.isEmpty)
        #expect(try await h.database.projects.locations(projectId: project.id).first?.canonicalPath.hasSuffix("App-neu") == true)

        // Folder removed → unavailable with reason, data kept.
        let backup = try h.sandbox.mkdir("Backup")
        try FileManager.default.moveItem(at: h.sandbox.url("Developer/App-neu"), to: backup.appending(path: "App"))
        let missing = try await catalog.scan()
        #expect(missing.unavailableProjects == [project.id])
        let unavailable = try #require(try await h.database.projects.fetch(project.id))
        #expect(unavailable.status == .unavailable && unavailable.statusReason?.contains("Ordner nicht gefunden") == true)
        #expect(try await h.database.workItems.fetch(item.uuid) != nil)

        // Relink outside the roots is rejected; a different repository needs explicit confirmation.
        await #expect(throws: WorkspaceError.self) { try await catalog.relink(projectId: project.id, to: backup.appending(path: "App")) }
        let other = try await h.sandbox.repository("Developer/Anderes")
        await #expect(throws: WorkspaceError.self) { try await catalog.relink(projectId: project.id, to: other) }

        // Moving it back into the root (as a copy elsewhere would be): relink candidates + relink.
        try FileManager.default.moveItem(at: backup.appending(path: "App"), to: h.sandbox.url("Developer/Zurueck"))
        try FileManager.default.removeItem(at: other)
        _ = try await catalog.scan()
        let relinked = try await catalog.relink(projectId: project.id, to: h.sandbox.url("Developer/Zurueck"))
        #expect(relinked.status == .ready && relinked.statusReason == nil)
    }
}

@Suite("Project setup commands (E2, A03)")
struct ProjectSetupTests {
    func makeServices(_ h: Harness, root: URL) -> (ProjectCatalog, ProjectSetupService) {
        let catalog = ProjectCatalog(environment: h.environment, configuration: CatalogConfiguration(roots: [root]))
        return (catalog, ProjectSetupService(environment: h.environment, catalog: catalog))
    }

    @Test func createProjectFromIndexedPlainFolderAndNewSubfolderWithConsent() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        try h.sandbox.mkdir("Developer/Idee")
        let (catalog, setup) = makeServices(h, root: dev)
        try await catalog.scan()

        let plain = ProjectSetupCommand(kind: .createProject, projectName: "Idee",
                                        target: .indexedFolder(path: h.sandbox.url("Developer/Idee").path(percentEncoded: false)),
                                        createdAt: h.clock.now)
        try await setup.submit(plain)
        #expect(try await h.database.projects.fetch(plain.projectId)?.status == .pendingMacSetup)
        let consent = GitInitConsent(grantedBy: DeviceID(), grantedAt: h.clock.now)
        let fresh = ProjectSetupCommand(kind: .createProject, projectName: "Neu",
                                        target: .newSubfolder(parentPath: dev.path(percentEncoded: false), folderName: "Neu"),
                                        initializeGitRepository: true, gitInitConsent: consent, createdAt: h.clock.now)
        try await setup.submit(fresh)
        let results = try await setup.processPending()
        #expect(results.map(\.state) == [.completed, .completed])

        let plainProject = try #require(try await h.database.projects.fetch(plain.projectId))
        #expect(plainProject.status == .ready && plainProject.repositoryKind == .notARepository)
        #expect(!h.sandbox.exists("Developer/Idee/.git")) // no git init without request
        let freshProject = try #require(try await h.database.projects.fetch(fresh.projectId))
        #expect(freshProject.status == .ready && freshProject.repositoryKind == .gitRepository)
        #expect(h.sandbox.exists("Developer/Neu/.git"))
        #expect(try await h.database.projects.locations(projectId: fresh.projectId).first?.canonicalPath
            == h.sandbox.url("Developer/Neu").path(percentEncoded: false))
    }

    @Test func gitInitWithoutConsentIsRejected() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        let (_, setup) = makeServices(h, root: dev)
        let command = ProjectSetupCommand(kind: .createProject, projectName: "Neu",
                                          target: .newSubfolder(parentPath: dev.path(percentEncoded: false), folderName: "Neu"),
                                          initializeGitRepository: true, createdAt: h.clock.now)
        await #expect(throws: ProjectSetupFailure.self) { try await setup.submit(command) }
        #expect(!h.sandbox.exists("Developer/Neu"))
    }

    @Test func traversalSymlinksAndForeignPathsAreRejected() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        let outside = try h.sandbox.mkdir("Privat")
        try h.sandbox.mkdir("Developer/Echt")
        try FileManager.default.createSymbolicLink(at: h.sandbox.url("Developer/Link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: h.sandbox.url("Developer/LinkIntern"), withDestinationURL: h.sandbox.url("Developer/Echt"))
        let (catalog, setup) = makeServices(h, root: dev)
        try await catalog.scan()
        let devPath = dev.path(percentEncoded: false)

        let cases: [(ProjectSetupTarget, ProjectSetupFailureCode)] = [
            (.indexedFolder(path: devPath + "/../Privat"), .pathTraversal),
            (.indexedFolder(path: devPath + "/Link"), .pathOutsideAllowedRoots),
            (.indexedFolder(path: devPath + "/LinkIntern"), .symlinkNotAllowed),
            (.indexedFolder(path: outside.path(percentEncoded: false)), .pathOutsideAllowedRoots),
            (.newSubfolder(parentPath: devPath + "/Link", folderName: "x"), .pathOutsideAllowedRoots),
            (.newSubfolder(parentPath: devPath, folderName: "Echt"), .folderAlreadyExists),
            (.newSubfolder(parentPath: devPath, folderName: ".versteckt"), .invalidFolderName),
            (.indexedFolder(path: devPath + "/Gibtsnicht"), .folderNotFound),
        ]
        for (target, expected) in cases {
            let command = ProjectSetupCommand(kind: .createProject, projectName: "X", target: target, createdAt: h.clock.now)
            try await setup.submit(command)
            let result = try await setup.execute(command.id)
            #expect(result.state == .failed, "\(target)")
            #expect(result.failure?.code == expected, "\(target): \(String(describing: result.failure))")
            let project = try #require(try await h.database.projects.fetch(command.projectId))
            #expect(project.status == .needsAttention && project.statusReason == result.failure?.message)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
    }

    @Test func repositorySubfolderRequiresScopeChoiceAndDraftCanBeLinkedLater() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        try await h.sandbox.repository("Developer/Mono")
        try h.sandbox.mkdir("Developer/Mono/apps/web")
        let (catalog, setup) = makeServices(h, root: dev)
        try await catalog.scan()
        let subfolder = h.sandbox.url("Developer/Mono/apps").path(percentEncoded: false)

        let unscoped = ProjectSetupCommand(kind: .createProject, projectName: "Apps", target: .indexedFolder(path: subfolder), createdAt: h.clock.now)
        try await setup.submit(unscoped)
        #expect(try await setup.execute(unscoped.id).failure?.code == .scopeChoiceRequired)

        let scoped = ProjectSetupCommand(kind: .createProject, projectName: "Apps", target: .indexedFolder(path: subfolder),
                                         repositoryScope: .subfolderOnly, createdAt: h.clock.now)
        try await setup.submit(scoped)
        #expect(try await setup.execute(scoped.id).state == .completed)
        let project = try #require(try await h.database.projects.fetch(scoped.projectId))
        #expect(project.repositoryKind == .subfolderOfRepository && project.status == .ready)
        #expect(project.repositoryIdentity?.rawValue.hasSuffix("#" + subfolder) == true)

        // Draft first, link to an indexed folder later.
        let draft = ProjectSetupCommand(kind: .createProject, projectName: "Entwurf", target: .draftWithoutRepository, createdAt: h.clock.now)
        try await setup.submit(draft)
        #expect(try await setup.execute(draft.id).state == .completed)
        #expect(try await h.database.projects.fetch(draft.projectId)?.status == .pendingMacSetup)
        try h.sandbox.mkdir("Developer/Spaeter")
        try await catalog.scan()
        let link = ProjectSetupCommand(kind: .linkProject, projectId: draft.projectId, projectName: "Entwurf",
                                       target: .indexedFolder(path: h.sandbox.url("Developer/Spaeter").path(percentEncoded: false)),
                                       createdAt: h.clock.now)
        try await setup.submit(link)
        #expect(try await setup.execute(link.id).state == .completed)
        #expect(try await h.database.projects.fetch(draft.projectId)?.status == .ready)
    }
}
