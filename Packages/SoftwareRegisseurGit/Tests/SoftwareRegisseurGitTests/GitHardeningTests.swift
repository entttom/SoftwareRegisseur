import Foundation
import Testing
@testable import SoftwareRegisseurGit

/// SR-SEC-02, SR-SEC-04, SR-SEC-06, SR-SEC-10: repository-controlled programs never run in the
/// unsandboxed service, worktrees are verified, integration is bound to the reviewed commit.
@Suite("Git hardening (security audit 2026-10-30)")
struct GitHardeningTests {
    /// Executable script that appends its first argument to `marker` and passes stdin through.
    private func makeMarkerScript(_ sandbox: GitSandbox, name: String) throws -> (script: URL, marker: URL) {
        let marker = sandbox.root.appending(path: "\(name).marker")
        let script = sandbox.root.appending(path: "\(name).sh")
        let text = "#!/bin/sh\necho \"ran $1\" >> '\(marker.path(percentEncoded: false))'\ncat\n"
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        return (script, marker)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func worktreeAddDoesNotRunRepositoryHooks() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        let (script, marker) = try makeMarkerScript(sandbox, name: "hook")
        // Hook in the shared .git directory (as an agent or a copied repository could place it).
        let hooks = repository.appending(path: ".git/hooks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for hook in ["post-checkout", "pre-commit", "post-commit", "reference-transaction"] {
            try FileManager.default.copyItem(at: script, to: hooks.appending(path: hook))
        }
        let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"), scanRoots: [sandbox.url("scan")])
        let created = try await manager.createWorktree(repository: repository, taskID: "FR-0001", jobShortID: "h00k", baseRef: "main")
        try sandbox.write("scan/Repo/x.txt", "x\n")
        try await sandbox.commitAll(repository, "Commit with hooks present")
        #expect(exists(created.url.appending(path: "README.md")))
        #expect(!exists(marker), "a repository hook was executed by the service")
    }

    @Test func localFilterAndMergeDriversAreNeutralised() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        let (script, marker) = try makeMarkerScript(sandbox, name: "driver")
        let path = script.path(percentEncoded: false)
        try sandbox.write("scan/Repo/.gitattributes", "*.txt filter=evil merge=evil\n")
        try await sandbox.git.run(["config", "--local", "filter.evil.clean", "\(path) clean"], in: repository)
        try await sandbox.git.run(["config", "--local", "filter.evil.smudge", "\(path) smudge"], in: repository)
        try await sandbox.git.run(["config", "--local", "filter.evil.required", "true"], in: repository)
        try await sandbox.git.run(["config", "--local", "merge.evil.driver", "\(path) merge %A"], in: repository)
        try sandbox.write("scan/Repo/a.txt", "base\n")
        try await sandbox.commitAll(repository, "Add a.txt with filter attribute")
        try sandbox.write("scan/Repo/a.txt", "changed\n")
        _ = try await sandbox.git.status(of: repository)
        try await sandbox.git.run(["diff", "HEAD"], in: repository)

        let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"), scanRoots: [sandbox.url("scan")])
        let created = try await manager.createWorktree(repository: repository, taskID: "FR-0002", jobShortID: "f1lt3r", baseRef: "main")
        try Data("job\n".utf8).write(to: created.url.appending(path: "a.txt"))
        try await sandbox.commitAll(created.url, "Job change")
        try await sandbox.commitAll(repository, "Main change")
        // A conflicting merge would invoke the merge driver: it must not run (conflict instead).
        let merge = try await sandbox.git.run(["merge", "--no-edit", created.branchName], in: repository, acceptedExitCodes: [0, 1])
        #expect(merge.exitCode == 1)
        #expect(!exists(marker), "a repository filter or merge driver was executed by the service")
    }

    @Test func driverOverridesOnlyCoverLocalScopeAndRefuseUnsafeNames() throws {
        let output = "global\tfilter.lfs.clean\nlocal\tfilter.x.clean\nworktree\tmerge.m.driver\nlocal\tfilter.x.smudge\n"
        let overrides = try GitClient.driverOverrides(fromScopedNames: output).map { "\($0.name)=\($0.value)" }
        #expect(overrides == ["filter.x.clean=", "filter.x.smudge=", "filter.x.process=", "filter.x.required=false", "merge.m.driver="])
        #expect(throws: GitError.unsafeRepositoryConfiguration("filter.a=b.clean")) {
            try GitClient.driverOverrides(fromScopedNames: "local\tfilter.a=b.clean\n")
        }
    }

    @Test func diffCommandsNeverRunExternalDiffOrTextconv() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        let (script, marker) = try makeMarkerScript(sandbox, name: "extdiff")
        try await sandbox.git.run(["config", "--local", "diff.external", script.path(percentEncoded: false)], in: repository)
        try sandbox.write("scan/Repo/README.md", "changed\n")
        _ = try await sandbox.git.run(["diff", "HEAD"], in: repository, input: Data())
        _ = try await sandbox.git.run(["log", "-p", "-1"], in: repository, input: Data())
        #expect(!exists(marker))
    }

    @Test func verifyManagedWorktreeRefusesMainTreeAndForeignPaths() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        let manager = try WorktreeManager(git: sandbox.git, worktreesBaseDirectory: sandbox.url("worktrees"), scanRoots: [sandbox.url("scan")])
        let created = try await manager.createWorktree(repository: repository, taskID: "FR-0003", jobShortID: "v3r1fy", baseRef: "main")
        let entry = try await manager.verifyManagedWorktree(created.url, repository: repository, expectedBranch: created.branchName)
        #expect(!entry.isMain)

        // Main working tree with its branch (the SR-SEC-02 attack): refused.
        await #expect(throws: WorktreeError.self) {
            try await manager.verifyManagedWorktree(repository, repository: repository, expectedBranch: "main")
        }
        await #expect(throws: WorktreeError.self) {
            try await manager.verifyManagedWorktree(repository, repository: repository, expectedBranch: created.branchName)
        }
        // Right path, wrong branch.
        await #expect(throws: WorktreeError.self) {
            try await manager.verifyManagedWorktree(created.url, repository: repository, expectedBranch: "software-regisseur/FR-0003/other")
        }
        // A user worktree outside the base directory.
        let userTree = sandbox.url("scan/user-tree")
        try await sandbox.git.run(["worktree", "add", "-q", "-b", "software-regisseur/FR-9/x", "--", userTree.path(percentEncoded: false)],
                                  in: repository)
        await #expect(throws: WorktreeError.self) {
            try await manager.verifyManagedWorktree(userTree, repository: repository, expectedBranch: "software-regisseur/FR-9/x")
        }
    }

    @Test func integrationRefusesWhenJobBranchMovedAfterReview() async throws {
        let fixture = try await IntegrationServiceTests.Fixture.make()
        defer { fixture.sandbox.remove() }
        let git = fixture.sandbox.git
        let reviewed = try await fixture.sandbox.head(fixture.job.url)
        let mainBefore = try await fixture.sandbox.head(fixture.repository, "main")
        try Data("unreviewed\n".utf8).write(to: fixture.job.url.appending(path: "c.txt"))
        let moved = try await fixture.sandbox.commitAll(fixture.job.url, "Added after review")

        var request = fixture.request(.squash)
        request.expectedJobTip = reviewed
        await #expect(throws: IntegrationError.jobBranchMoved(expected: reviewed, actual: moved)) {
            try await IntegrationService(git: git).integrate(request)
        }
        #expect(try await fixture.sandbox.head(fixture.repository, "main") == mainBefore)
        #expect(try await fixture.worktreeCount() == 2)

        request.expectedJobTip = moved
        let result = try await IntegrationService(git: git).integrate(request)
        #expect(result.previousDefaultBranchCommit == mainBefore)
    }
}
