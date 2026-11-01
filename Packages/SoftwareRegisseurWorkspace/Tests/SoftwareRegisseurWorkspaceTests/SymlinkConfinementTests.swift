import Darwin
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import Testing
@testable import SoftwareRegisseurWorkspace

/// SR-SEC-07 (B04, B14): a symbolic link in an intermediate component of a document path never makes the
/// service read, write or move files outside the repository.
@Suite("Symlink confinement of document paths (security audit 2026-10-30)")
struct SymlinkConfinementTests {
    @Test func symlinkedDocsFolderIsNeitherImportedNorWritten() async throws {
        let h = try Harness()
        let (project, repo) = try await h.project("app")
        // Foreign folder outside the repository with a request file in the expected layout.
        try h.sandbox.write("outside/requests/open/FR-0009-fremd.md",
                            requestFile(id: "FR-0009", type: "feature", status: "open", title: "Fremd"))
        try FileManager.default.createSymbolicLink(at: repo.appending(path: "docs"), withDestinationURL: h.sandbox.url("outside"))

        let materializer = RequestMaterializer(environment: h.environment)
        let report = try await materializer.reconcile(projectId: project.id)
        #expect(report.importedItems.isEmpty)
        #expect(try await h.database.workItems.list(WorkItemFilter(project: .project(project.id))).isEmpty)

        let item = try await h.item(project.id)
        await #expect(throws: WorkspaceError.self) { _ = try await materializer.materialize(item.uuid) }
        let written = try FileManager.default.subpathsOfDirectory(atPath: h.sandbox.url("outside").path(percentEncoded: false))
        #expect(written.sorted() == ["requests", "requests/open", "requests/open/FR-0009-fremd.md"])
    }

    @Test func confinementHelpersRejectEveryLinkedComponent() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.mkdir("repo")
        try sandbox.mkdir("elsewhere/sub")
        try sandbox.write("elsewhere/sub/secret.md", "geheim")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: sandbox.url("elsewhere"))

        #expect(FileSystem.symlinkComponent(of: root.appending(path: "link/sub/secret.md"), below: root) != nil)
        #expect(FileSystem.read("link/sub/secret.md", in: root) == nil)
        #expect(FileSystem.markdownFiles(in: root.appending(path: "link/sub"), relativeTo: root).isEmpty)
        #expect(throws: WorkspaceError.self) {
            try AtomicFileWriter.write(Data("x".utf8), to: root.appending(path: "link/sub/new.md"), mode: .createNew, confinedTo: root)
        }
        #expect(!sandbox.exists("elsewhere/sub/new.md"))
        #expect(FileSystem.symlinkComponent(of: root.appending(path: "../elsewhere"), below: root) != nil)

        // Regular nested folders are created without following links.
        try AtomicFileWriter.write(Data("ok".utf8), to: root.appending(path: "docs/requests/open/a.md"), mode: .createNew, confinedTo: root)
        #expect(try sandbox.read("repo/docs/requests/open/a.md") == "ok")
        #expect(FileSystem.read("docs/requests/open/a.md", in: root) == Data("ok".utf8))
    }

    @Test func moverRefusesSymlinkedDestination() async throws {
        let h = try Harness()
        let (_, repo) = try await h.project("app")
        try h.sandbox.write("app/docs/requests/open/FR-0001-a.md", "a")
        try h.sandbox.mkdir("outside")
        try FileManager.default.createSymbolicLink(at: repo.appending(path: "docs/requests/done"), withDestinationURL: h.sandbox.url("outside"))
        let mover = RepositoryFileMover(git: nil)
        await #expect(throws: WorkspaceError.self) {
            try await mover.move(from: "docs/requests/open/FR-0001-a.md", to: "docs/requests/done/FR-0001-a.md", in: repo)
        }
        #expect(h.sandbox.exists("app/docs/requests/open/FR-0001-a.md"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.sandbox.url("outside").path(percentEncoded: false)).isEmpty)
    }
}
