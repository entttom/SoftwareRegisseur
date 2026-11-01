import Foundation
import Testing
@testable import SoftwareRegisseurGit

/// ADR-0024: uncommitted request/ADR files in the main working tree do not block the integration, but
/// are never overwritten by it.
@Suite("IntegrationService – uncommitted document paths (ADR-0024)")
struct IntegrationDocumentPathsTests {
    static let documentPaths = ["docs/adr", "docs/requests"]

    struct Fixture {
        let sandbox: GitSandbox
        let repository: URL
        let job: CreatedWorktree
        let baseCommit: String
        let jobTip: String

        /// `main` with a.txt, an ADR and an open request; the job branch changes a.txt and, optionally,
        /// document files (`jobDocumentChanges`: relative path → content, nil = delete).
        static func make(jobDocumentChanges: [String: String?] = [:]) async throws -> Fixture {
            let sandbox = try GitSandbox()
            let repository = try await sandbox.makeRepository("scan/Repo")
            try sandbox.write("scan/Repo/a.txt", "line 1\n")
            try sandbox.write("scan/Repo/docs/adr/0001-first.md", "# ADR 1\n")
            try sandbox.write("scan/Repo/docs/requests/open/FR-0001-first.md", "status: open\n")
            let base = try await sandbox.commitAll(repository, "Base with docs")
            let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"),
                                              scanRoots: [sandbox.url("scan")])
            let job = try await manager.createWorktree(repository: repository, taskID: "FR-0007", jobShortID: "d0c5", baseRef: "main")
            try Data("line 1 changed by agent\n".utf8).write(to: job.url.appending(path: "a.txt"))
            for (path, content) in jobDocumentChanges {
                let url = job.url.appending(path: path)
                if let content {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(content.utf8).write(to: url)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            }
            let tip = try await sandbox.commitAll(job.url, "Agent work")
            return Fixture(sandbox: sandbox, repository: repository, job: job, baseCommit: base, jobTip: tip)
        }

        func request(_ strategy: IntegrationStrategy, ignored: [String] = IntegrationDocumentPathsTests.documentPaths) -> IntegrationRequest {
            IntegrationRequest(
                repository: repository, defaultBranch: "main", jobBranch: job.branchName, strategy: strategy,
                commitMessage: "FR-0007: Integrate", temporaryWorktreeParent: sandbox.url("worktrees/.integration"),
                ignoredUncommittedPaths: ignored)
        }

        func statusLines() async throws -> String {
            try await sandbox.output(["status", "--porcelain=v1", "--untracked-files=all"], in: repository)
        }

        func integrationLeftovers() throws -> [String] {
            let path = sandbox.url("worktrees/.integration").plainPathForTests
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    }

    @Test(arguments: IntegrationStrategy.allCases)
    func succeedsWithUncommittedRequestAndADRFiles(strategy: IntegrationStrategy) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        // New request (untracked), edited ADR (modified), request moved open → review (staged rename),
        // and a staged new ADR.
        try fixture.sandbox.write("scan/Repo/docs/requests/open/FR-0008-new.md", "status: open\n")
        try fixture.sandbox.write("scan/Repo/docs/adr/0001-first.md", "# ADR 1 edited\n")
        // Status move as done by the Mac service (`git mv`: staged rename, never committed).
        try FileManager.default.createDirectory(at: fixture.repository.appending(path: "docs/requests/review"), withIntermediateDirectories: true)
        try await fixture.sandbox.git.run(["mv", "--", "docs/requests/open/FR-0001-first.md", "docs/requests/review/FR-0001-first.md"],
                                          in: fixture.repository)
        try fixture.sandbox.write("scan/Repo/docs/adr/0002-second.md", "# ADR 2\n")
        try await fixture.sandbox.git.run(["add", "--", "docs/adr/0002-second.md"], in: fixture.repository)
        let statusBefore = try await fixture.statusLines()

        let result = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(strategy))

        #expect(try await fixture.sandbox.head(fixture.repository, "main") == result.commitSHA)
        #expect(result.updatedWorktree?.plainPathForTests == fixture.repository.plainPathForTests)
        #expect(try fixture.sandbox.read("scan/Repo/a.txt") == "line 1 changed by agent\n")
        // Document changes are untouched and still uncommitted.
        #expect(try await fixture.statusLines() == statusBefore)
        #expect(try fixture.sandbox.read("scan/Repo/docs/adr/0001-first.md") == "# ADR 1 edited\n")
        #expect(try fixture.sandbox.read("scan/Repo/docs/requests/review/FR-0001-first.md") == "status: open\n")
        #expect(try await fixture.sandbox.output(["diff", "--name-only", fixture.baseCommit, "main"], in: fixture.repository) == "a.txt")
        #expect(try fixture.integrationLeftovers().isEmpty)
    }

    @Test(arguments: IntegrationStrategy.allCases)
    func collisionWithUncommittedDocumentsAbortsWithoutPartialState(strategy: IntegrationStrategy) async throws {
        let fixture = try await Fixture.make(jobDocumentChanges: [
            "docs/requests/open/FR-0001-first.md": "status: done (agent)\n", // modified on main, uncommitted
            "docs/adr/0002-second.md": "# ADR 2 by agent\n", // untracked on main
            "docs/adr/0001-first.md": nil, // deleted by the job, modified on main
        ])
        defer { fixture.sandbox.remove() }
        try fixture.sandbox.write("scan/Repo/docs/requests/open/FR-0001-first.md", "status: review\n")
        try fixture.sandbox.write("scan/Repo/docs/adr/0002-second.md", "# ADR 2 by user\n")
        try fixture.sandbox.write("scan/Repo/docs/adr/0001-first.md", "# ADR 1 edited\n")
        try fixture.sandbox.write("scan/Repo/docs/requests/open/FR-0009-unrelated.md", "status: open\n")
        let statusBefore = try await fixture.statusLines()

        do {
            _ = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(strategy))
            Issue.record("Expected the document collision to abort")
        } catch IntegrationError.uncommittedDocumentsWouldBeOverwritten(let path, let files) {
            #expect(path == fixture.repository.plainPathForTests)
            #expect(files == ["docs/adr/0001-first.md", "docs/adr/0002-second.md", "docs/requests/open/FR-0001-first.md"])
        }
        // Main tree and branch unchanged.
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == fixture.baseCommit)
        #expect(try await fixture.statusLines() == statusBefore)
        #expect(try fixture.sandbox.read("scan/Repo/a.txt") == "line 1\n")
        #expect(try fixture.sandbox.read("scan/Repo/docs/requests/open/FR-0001-first.md") == "status: review\n")
        #expect(try fixture.sandbox.read("scan/Repo/docs/adr/0002-second.md") == "# ADR 2 by user\n")
        // Job tree and branch unchanged; temporary worktree gone.
        #expect(try await fixture.sandbox.head(fixture.repository, fixture.job.branchName) == fixture.jobTip)
        #expect(try await fixture.sandbox.git.status(of: fixture.job.url).isClean)
        #expect(try await WorktreeManager.listWorktrees(git: fixture.sandbox.git, repository: fixture.repository).count == 2)
        #expect(try fixture.integrationLeftovers().isEmpty)
    }

    @Test func nonDocumentChangesStillBlock() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        let service = IntegrationService(git: fixture.sandbox.git)
        try fixture.sandbox.write("scan/Repo/docs/requests/open/FR-0008-new.md", "status: open\n")

        // Sibling folder sharing the prefix text is not a document path.
        try fixture.sandbox.write("scan/Repo/docs/requests-archive/old.md", "x\n")
        await #expect(throws: IntegrationError.self) { try await service.integrate(fixture.request(.squash)) }
        try FileManager.default.removeItem(at: fixture.repository.appending(path: "docs/requests-archive"))

        try fixture.sandbox.write("scan/Repo/README.md", "user edit\n")
        do {
            _ = try await service.integrate(fixture.request(.squash))
            Issue.record("Expected dirty refusal")
        } catch IntegrationError.defaultBranchWorktreeDirty(let path, let status) {
            #expect(path == fixture.repository.plainPathForTests)
            #expect(status.hasTrackedChanges)
        }
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == fixture.baseCommit)
        #expect(try fixture.sandbox.read("scan/Repo/README.md") == "user edit\n")

        // Without ignored paths, document changes block as before.
        try await fixture.sandbox.git.run(["checkout", "--quiet", "--", "README.md"], in: fixture.repository)
        await #expect(throws: IntegrationError.self) { try await service.integrate(fixture.request(.squash, ignored: [])) }
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == fixture.baseCommit)
        // With them, the same state integrates.
        _ = try await service.integrate(fixture.request(.squash))
        #expect(try await fixture.sandbox.head(fixture.repository, "main") != fixture.baseCommit)
    }

    @Test func prefixNormalisationNeverWidensTheExemption() {
        #expect(IntegrationService.normalizedPathPrefixes(["", ".", "./", "/abs", "~/x", "../out", "a/../b", "a//b"]).isEmpty)
        #expect(IntegrationService.normalizedPathPrefixes(["./docs/adr/", "docs/adr", "ideen"]) == ["docs/adr", "ideen"])
        #expect(IntegrationService.isPath("docs/adr/0001.md", under: ["docs/adr"]))
        #expect(!IntegrationService.isPath("docs/adrs/0001.md", under: ["docs/adr"]))
        #expect(IntegrationService.pathsOverlap("docs/adr/x", "docs/adr/x/y.md"))
        #expect(IntegrationService.pathsOverlap("Docs/ADR/X.md", "docs/adr/x.md"))
        #expect(!IntegrationService.pathsOverlap("docs/adr/x.md", "docs/adr/x.md.bak"))
    }
}
