import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence
import Testing
@testable import SoftwareRegisseurWorkspace

@Suite("Cross-device workspace contracts (E2, F2, N2)")
struct CrossDeviceWorkspaceTests {
    @Test("N2: a resolution chosen on the iPhone is applied to the request file by the Mac")
    func requestedResolutionIsAppliedByTheMac() async throws {
        let h = try Harness()
        let (project, _) = try await h.project("app")
        let item = try await h.item(project.id)
        let materializer = RequestMaterializer(environment: h.environment)
        try await materializer.materialize(item.uuid)
        let path = "app/docs/requests/open/FR-0001-senderliste-vergroessern.md"
        let current = try #require(try await h.database.workItems.fetch(item.uuid))
        _ = try await h.database.workItems.update(item.uuid, expectedRevision: current.revision, actor: .user(DeviceID()), at: h.clock.now) {
            $0.title = "Titel vom iPhone"
        }
        try h.sandbox.write(path, try h.sandbox.read(path).replacingOccurrences(of: "title: \"Senderliste vergrößern\"", with: "title: \"Titel aus dem Editor\""))
        let conflict = try #require(try await materializer.reconcile(projectId: project.id).conflicts.first)

        // Nothing happens before the user decides.
        #expect(try await materializer.applyRequestedResolutions().updatedItems.isEmpty)
        let phone = DeviceID()
        _ = try await h.database.fileConflicts.requestResolution(conflict.id, resolution: .acceptedExternal, by: phone, at: h.clock.now)
        let report = try await materializer.applyRequestedResolutions()
        #expect(report.updatedItems == [item.uuid])
        #expect(try await h.database.workItems.fetch(item.uuid)?.title == "Titel aus dem Editor")
        let resolved = try #require(try await h.database.fileConflicts.fetch(conflict.id))
        #expect(resolved.resolution == .acceptedExternal && resolved.requestedBy == phone)
        #expect(try await h.database.fileConflicts.pendingRequests().isEmpty)
    }

    @Test("F2: projects created by the Mac use the synced global folder layout")
    func newProjectsUseGlobalDefaults() async throws {
        let h = try Harness()
        let dev = try h.sandbox.mkdir("Developer")
        var global = try await h.database.globalSettings.fetch()
        global.folderLayout.adrPath = "architecture/decisions"
        global.workspace.integrationStrategy = .mergeCommit
        _ = try await h.database.globalSettings.save(global, expectedRevision: 0, at: h.clock.now)

        let catalog = ProjectCatalog(environment: h.environment, configuration: CatalogConfiguration(roots: [dev]))
        let setup = ProjectSetupService(environment: h.environment, catalog: catalog)
        try await catalog.scan()
        let command = ProjectSetupCommand(kind: .createProject, projectName: "Neu",
                                          target: .newSubfolder(parentPath: dev.path(percentEncoded: false), folderName: "Neu"),
                                          requestedBy: DeviceID(), createdAt: h.clock.now)
        // Created on the iPhone: only the synced command exists on the Mac, no project yet.
        try await h.database.projectSetupCommands.insert(command, at: h.clock.now)
        let result = try await setup.processPending()
        #expect(result.map(\.state) == [.completed])
        let settings = try #require(try await h.database.projects.settings(forProject: command.projectId))
        #expect(settings.adrPath == "architecture/decisions" && settings.integrationStrategy == .mergeCommit)
        #expect(try await h.database.projects.fetch(command.projectId)?.status == .ready)
    }
}
