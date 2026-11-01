import Foundation
import Testing
@testable import SoftwareRegisseurGit

@Suite("WorktreeManager")
struct WorktreeManagerTests {
    @Test func branchNamesAreValidated() throws {
        #expect(try WorktreeManager.branchName(taskID: "FR-0001", jobShortID: "a1b2c3") == "software-regisseur/FR-0001/a1b2c3")
        #expect(try WorktreeManager.branchName(taskID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", jobShortID: "job_1.2")
                == "software-regisseur/3F2504E0-4F89-11D3-9A0C-0305E82C3301/job_1.2")
        for bad in ["", "../x", "a/b", ".hidden", "x.lock", "a..b", "trailing.", "space here", "-flag", "ä", String(repeating: "x", count: 65)] {
            #expect(throws: WorktreeError.invalidIdentifier(bad)) { try WorktreeManager.branchName(taskID: bad, jobShortID: "j1") }
            #expect(throws: WorktreeError.invalidIdentifier(bad)) { try WorktreeManager.branchName(taskID: "FR-1", jobShortID: bad) }
        }
    }

    @Test func baseDirectoryMustBeOutsideScanRoots() throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        try sandbox.makeDirectory("scan")
        #expect(throws: WorktreeError.self) {
            try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("scan/.worktrees"), scanRoots: [sandbox.url("scan")])
        }
        #expect(throws: Never.self) {
            try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"), scanRoots: [sandbox.url("scan")])
        }
    }

    @Test func createListAndRemove() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"), scanRoots: [sandbox.url("scan")])

        let created = try await manager.createWorktree(repository: repository, taskID: "FR-0001", jobShortID: "a1b2c3", baseRef: "main")
        #expect(created.branchName == "software-regisseur/FR-0001/a1b2c3")
        #expect(created.baseCommit == (try await sandbox.head(repository)))
        #expect(created.url.plainPathForTests.hasPrefix(sandbox.url("worktrees").plainPathForTests + "/Repo-"))
        #expect(FileManager.default.fileExists(atPath: created.url.appending(path: "README.md").plainPathForTests))
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"], in: created.url) == created.branchName)

        let worktrees = try await manager.list(repository: repository)
        #expect(worktrees.count == 2)
        #expect(worktrees[0].isMain)
        #expect(worktrees[0].branchName == "main")
        #expect(worktrees[1].url.plainPathForTests == created.url.plainPathForTests)
        #expect(worktrees[1].branchRef == "refs/heads/software-regisseur/FR-0001/a1b2c3")
        #expect(!worktrees[1].isMain)

        // Refuses when the target already exists.
        await #expect(throws: WorktreeError.targetExists(created.url.plainPathForTests)) {
            try await manager.createWorktree(repository: repository, taskID: "FR-0001", jobShortID: "a1b2c3", baseRef: "main")
        }
        await #expect(throws: WorktreeError.unknownBaseRef("no-such-branch")) {
            try await manager.createWorktree(repository: repository, taskID: "FR-0001", jobShortID: "zz", baseRef: "no-such-branch")
        }

        // Dirty worktree is protected unless force is explicit.
        try Data("work in progress\n".utf8).write(to: created.url.appending(path: "notes.txt"))
        do {
            try await manager.removeWorktree(at: created.url, repository: repository)
            Issue.record("Expected dirty refusal")
        } catch WorktreeError.dirty(let path, let status) {
            #expect(path == created.url.plainPathForTests)
            #expect(status.untrackedPaths == ["notes.txt"])
        }
        #expect(FileManager.default.fileExists(atPath: created.url.plainPathForTests))

        try await manager.removeWorktree(at: created.url, repository: repository, force: true)
        #expect(!FileManager.default.fileExists(atPath: created.url.plainPathForTests))
        #expect(try await manager.list(repository: repository).count == 1)
        // The branch is never deleted implicitly.
        #expect(try await sandbox.output(["branch", "--list", created.branchName], in: repository).contains(created.branchName))

        // Same IDs again: the branch still exists, so creation is refused.
        await #expect(throws: WorktreeError.branchExists(created.branchName)) {
            try await manager.createWorktree(repository: repository, taskID: "FR-0001", jobShortID: "a1b2c3", baseRef: "main")
        }
    }

    @Test func cleanWorktreeRemovalAndMainProtection() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"), scanRoots: [sandbox.url("scan")])
        let created = try await manager.createWorktree(repository: repository, taskID: "BUG-0002", jobShortID: "j1", baseRef: "HEAD")

        try sandbox.write("scan/Repo/README.md", "modified\n")
        try await manager.removeWorktree(at: created.url, repository: repository)
        #expect(!FileManager.default.fileExists(atPath: created.url.plainPathForTests))

        await #expect(throws: WorktreeError.cannotRemoveMainWorktree(repository.plainPathForTests)) {
            try await manager.removeWorktree(at: repository, repository: repository, force: true)
        }
        await #expect(throws: WorktreeError.notAWorktree(sandbox.url("worktrees").plainPathForTests)) {
            try await manager.removeWorktree(at: sandbox.url("worktrees"), repository: repository)
        }
        #expect(try sandbox.read("scan/Repo/README.md") == "modified\n")
    }
}
