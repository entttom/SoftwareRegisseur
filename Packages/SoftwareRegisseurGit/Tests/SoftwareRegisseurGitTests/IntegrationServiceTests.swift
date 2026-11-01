import Foundation
import Testing
@testable import SoftwareRegisseurGit

@Suite("IntegrationService")
struct IntegrationServiceTests {
    struct Fixture {
        let sandbox: GitSandbox
        let repository: URL
        let job: CreatedWorktree
        let baseCommit: String

        /// Repository on `main` with `a.txt`; job branch with two commits (modify a.txt, add b.txt).
        static func make() async throws -> Fixture {
            let sandbox = try GitSandbox()
            let repository = try await sandbox.makeRepository("scan/Repo")
            try sandbox.write("scan/Repo/a.txt", "line 1\nline 2\nline 3\n")
            let base = try await sandbox.commitAll(repository, "Add a.txt")
            let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"),
                                              scanRoots: [sandbox.url("scan")])
            let job = try await manager.createWorktree(repository: repository, taskID: "FR-0007", jobShortID: "c0ffee", baseRef: "main")
            try Data("line 1\nline 2 changed by agent\nline 3\n".utf8).write(to: job.url.appending(path: "a.txt"))
            try await sandbox.commitAll(job.url, "Agent: change a.txt")
            try Data("new file\n".utf8).write(to: job.url.appending(path: "b.txt"))
            try await sandbox.commitAll(job.url, "Agent: add b.txt")
            return Fixture(sandbox: sandbox, repository: repository, job: job, baseCommit: base)
        }

        func request(_ strategy: IntegrationStrategy) -> IntegrationRequest {
            IntegrationRequest(
                repository: repository,
                defaultBranch: "main",
                jobBranch: job.branchName,
                strategy: strategy,
                commitMessage: "FR-0007: Integrate agent work",
                temporaryWorktreeParent: sandbox.url("worktrees/.integration")
            )
        }

        func worktreeCount() async throws -> Int {
            try await WorktreeManager.listWorktrees(git: sandbox.git, repository: repository).count
        }
    }

    @Test func squashCreatesSingleCommitAndFastForwardsCleanMainTree() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        let git = fixture.sandbox.git
        let result = try await IntegrationService(git: git).integrate(fixture.request(.squash))

        #expect(result.previousDefaultBranchCommit == fixture.baseCommit)
        #expect(result.integratedCommits.count == 2)
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == result.commitSHA)
        #expect(try await fixture.sandbox.output(["rev-list", "--count", "\(fixture.baseCommit)..main"], in: fixture.repository) == "1")
        #expect(try await fixture.sandbox.output(["log", "-1", "--format=%s", "main"], in: fixture.repository) == "FR-0007: Integrate agent work")
        #expect(try await fixture.sandbox.output(["rev-list", "--parents", "-n", "1", "main"], in: fixture.repository)
                == "\(result.commitSHA) \(fixture.baseCommit)")
        // The clean main working tree followed the branch.
        #expect(try fixture.sandbox.read("scan/Repo/b.txt") == "new file\n")
        #expect(try await git.status(of: fixture.repository).isClean)
        #expect(result.updatedWorktree?.plainPathForTests == fixture.repository.plainPathForTests)
        // Temporary worktree gone, job branch and worktree kept.
        #expect(try await fixture.worktreeCount() == 2)
        #expect(try await fixture.sandbox.output(["branch", "--list", fixture.job.branchName], in: fixture.repository).contains(fixture.job.branchName))
    }

    @Test func mergeCommitHasTwoParents() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        let result = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(.mergeCommit))
        let jobTip = try await fixture.sandbox.head(fixture.repository, fixture.job.branchName)
        #expect(try await fixture.sandbox.output(["rev-list", "--parents", "-n", "1", result.commitSHA], in: fixture.repository)
                == "\(result.commitSHA) \(fixture.baseCommit) \(jobTip)")
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == result.commitSHA)
        #expect(try await fixture.sandbox.output(["log", "-1", "--format=%s", "main"], in: fixture.repository) == "FR-0007: Integrate agent work")
        #expect(try await fixture.worktreeCount() == 2)
    }

    @Test func cherryPickReplaysEachCommit() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        let result = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(.cherryPick))
        let subjects = try await fixture.sandbox.output(["log", "--format=%s", "\(fixture.baseCommit)..main"], in: fixture.repository)
        #expect(subjects == "Agent: add b.txt\nAgent: change a.txt")
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == result.commitSHA)
        #expect(try fixture.sandbox.read("scan/Repo/a.txt") == "line 1\nline 2 changed by agent\nline 3\n")
        #expect(try await fixture.worktreeCount() == 2)
    }

    @Test(arguments: IntegrationStrategy.allCases)
    func conflictsAbortCleanly(strategy: IntegrationStrategy) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        try fixture.sandbox.write("scan/Repo/a.txt", "line 1\nline 2 changed on main\nline 3\n")
        let mainTip = try await fixture.sandbox.commitAll(fixture.repository, "Main: change a.txt")

        do {
            _ = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(strategy))
            Issue.record("Expected a conflict")
        } catch IntegrationError.conflicts(let files) {
            #expect(files == ["a.txt"])
        }
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == mainTip)
        #expect(try await fixture.sandbox.git.status(of: fixture.repository).isClean)
        #expect(try fixture.sandbox.read("scan/Repo/a.txt") == "line 1\nline 2 changed on main\nline 3\n")
        #expect(try await fixture.worktreeCount() == 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.sandbox.url("worktrees/.integration").plainPathForTests)
        #expect(leftovers.isEmpty)
    }

    @Test func dirtyMainTreeIsRefusedAndUntouched() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        try fixture.sandbox.write("scan/Repo/a.txt", "uncommitted user edit\n")

        do {
            _ = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(.squash))
            Issue.record("Expected dirty refusal")
        } catch IntegrationError.defaultBranchWorktreeDirty(let path, let status) {
            #expect(path == fixture.repository.plainPathForTests)
            #expect(status.hasTrackedChanges)
        }
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == fixture.baseCommit)
        #expect(try fixture.sandbox.read("scan/Repo/a.txt") == "uncommitted user edit\n")
        #expect(try await fixture.worktreeCount() == 2)
    }

    @Test func defaultBranchNotCheckedOutIsUpdatedByRef() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        try await fixture.sandbox.git.run(["checkout", "--quiet", "-b", "user-topic"], in: fixture.repository)
        try fixture.sandbox.write("scan/Repo/a.txt", "dirty work on another branch\n")

        let result = try await IntegrationService(git: fixture.sandbox.git).integrate(fixture.request(.squash))
        #expect(result.updatedWorktree == nil)
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == result.commitSHA)
        #expect(try await fixture.sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"], in: fixture.repository) == "user-topic")
        #expect(try fixture.sandbox.read("scan/Repo/a.txt") == "dirty work on another branch\n")
        #expect(try await fixture.sandbox.output(["show", "main:b.txt"], in: fixture.repository) == "new file")
    }

    @Test func refusesNothingToIntegrateAndDirtyJobWorktree() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        let service = IntegrationService(git: fixture.sandbox.git)

        try Data("uncommitted agent change\n".utf8).write(to: fixture.job.url.appending(path: "b.txt"))
        do {
            _ = try await service.integrate(fixture.request(.squash))
            Issue.record("Expected job worktree refusal")
        } catch IntegrationError.jobWorktreeDirty(let path, _) {
            #expect(path == fixture.job.url.plainPathForTests)
        }
        try await fixture.sandbox.git.run(["checkout", "--quiet", "--", "b.txt"], in: fixture.job.url)

        _ = try await service.integrate(fixture.request(.squash))
        let mainAfterSquash = try await fixture.sandbox.head(fixture.repository, "main")
        for strategy in IntegrationStrategy.allCases {
            await #expect(throws: IntegrationError.nothingToIntegrate) {
                try await service.integrate(fixture.request(strategy))
            }
        }
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == mainAfterSquash)
        #expect(try await fixture.worktreeCount() == 2)
        await #expect(throws: IntegrationError.branchNotFound("missing")) {
            var request = fixture.request(.squash)
            request.jobBranch = "missing"
            return try await service.integrate(request)
        }
    }

    @Test func diffSummaryListsChangedFiles() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.sandbox.remove() }
        try await fixture.sandbox.git.run(["mv", "README.md", "README-renamed.md"], in: fixture.job.url)
        try Data([0, 1, 2, 3, 0, 255]).write(to: fixture.job.url.appending(path: "blob.bin"))
        try await fixture.sandbox.commitAll(fixture.job.url, "Agent: rename and binary")

        let summary = try await IntegrationService(git: fixture.sandbox.git)
            .diffSummary(repository: fixture.repository, base: "main", head: fixture.job.branchName)
        let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == ["a.txt", "b.txt", "README-renamed.md", "blob.bin"])
        #expect(byPath["a.txt"]?.status == "M")
        #expect(byPath["a.txt"]?.additions == 1)
        #expect(byPath["a.txt"]?.deletions == 1)
        #expect(byPath["b.txt"]?.status == "A")
        #expect(byPath["README-renamed.md"]?.status == "R")
        #expect(byPath["README-renamed.md"]?.originalPath == "README.md")
        #expect(byPath["blob.bin"]?.isBinary == true)
        #expect(summary.totalAdditions == 2)
        #expect(try await IntegrationService(git: fixture.sandbox.git)
            .changedFiles(repository: fixture.repository, base: "main", head: fixture.job.branchName).count == 4)
    }

    @Test func initRepositoryIsExplicitAndRefusesExisting() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("NewProject")
        let initializer = RepositoryInitializer(git: sandbox.git)
        try await initializer.initRepository(at: folder)
        #expect(try await sandbox.output(["symbolic-ref", "--short", "HEAD"], in: folder) == "main")
        await #expect(throws: IntegrationError.repositoryAlreadyExists(folder.plainPathForTests)) {
            try await initializer.initRepository(at: folder)
        }
    }
}
