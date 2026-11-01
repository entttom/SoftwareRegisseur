import Foundation
import Testing
@testable import SoftwareRegisseurGit

@Suite("RepositoryInfo")
struct RepositoryInfoTests {
    @Test func inspectsRepositoryWithCommitsAndRemote() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("repo")
        try await sandbox.git.run(["remote", "add", "origin", "https://user:s3cret@example.com/org/repo.git"], in: repository)
        try await sandbox.git.run(["remote", "add", "backup", "/srv/backup.git"], in: repository)

        let configBefore = try Data(contentsOf: repository.appending(path: ".git/config"))
        let indexAttributesBefore = try FileManager.default.attributesOfItem(atPath: repository.appending(path: ".git/index").plainPathForTests)

        let inspector = RepositoryInspector(git: sandbox.git)
        let info = try await inspector.inspect(repository)
        #expect(info.rootURL.plainPathForTests == repository.plainPathForTests)
        #expect(!info.isBare)
        #expect(info.currentBranch == "main")
        #expect(!info.isDetachedHead)
        #expect(info.headCommit == (try await sandbox.head(repository)))
        #expect(info.defaultBranch == "main")
        #expect(info.defaultBranchSource == .initDefaultBranch)
        #expect(info.remotes == [
            GitRemote(name: "backup", fetchURL: "/srv/backup.git", pushURL: "/srv/backup.git"),
            GitRemote(name: "origin", fetchURL: "https://user@example.com/org/repo.git", pushURL: "https://user@example.com/org/repo.git"),
        ])
        let roots = try await sandbox.output(["rev-list", "--max-parents=0", "HEAD"], in: repository)
        #expect(info.identity == RepositoryIdentity(value: "git-roots:\(roots)", rootCommits: [roots], isProvisional: false))

        // Read-only: neither config nor index were rewritten.
        #expect(try Data(contentsOf: repository.appending(path: ".git/config")) == configBefore)
        let indexAttributesAfter = try FileManager.default.attributesOfItem(atPath: repository.appending(path: ".git/index").plainPathForTests)
        #expect(indexAttributesAfter[.modificationDate] as? Date == indexAttributesBefore[.modificationDate] as? Date)
    }

    @Test func originHeadWinsAndIdentitySurvivesMove() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("repo")
        try await sandbox.git.run(["update-ref", "refs/remotes/origin/trunk", "HEAD"], in: repository)
        try await sandbox.git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: repository)
        try await sandbox.git.run(["checkout", "--quiet", "-b", "topic"], in: repository)

        let inspector = RepositoryInspector(git: sandbox.git)
        let info = try await inspector.inspect(repository)
        #expect(info.defaultBranch == "trunk")
        #expect(info.defaultBranchSource == .originHead)
        #expect(info.currentBranch == "topic")

        let moved = sandbox.url("renamed-repo")
        try FileManager.default.moveItem(at: repository, to: moved)
        #expect(try await inspector.identity(of: moved) == info.identity)
    }

    @Test func repositoryWithoutCommitsHasProvisionalIdentity() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("fresh", commit: false)
        let inspector = RepositoryInspector(git: sandbox.git)
        let info = try await inspector.inspect(repository)
        #expect(info.identity.isProvisional)
        #expect(info.identity.rootCommits.isEmpty)
        #expect(info.identity.value.hasPrefix("provisional:"))
        #expect(info.headCommit == nil)
        #expect(info.defaultBranch == "main")
        #expect(info.defaultBranchSource == .unbornHead)
        #expect(try await inspector.identity(of: repository) == info.identity)

        // After the first commit the identity becomes final.
        try sandbox.write("fresh/a.txt", "a\n")
        try await sandbox.commitAll(repository, "First")
        let final = try await inspector.identity(of: repository)
        #expect(!final.isProvisional)
        #expect(final.rootCommits.count == 1)
    }

    @Test func multipleRootCommitsAreSorted() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("repo")
        try await sandbox.git.run(["checkout", "--quiet", "--orphan", "other"], in: repository)
        try sandbox.write("repo/other.txt", "x\n")
        try await sandbox.commitAll(repository, "Other root")
        try await sandbox.git.run(["checkout", "--quiet", "main"], in: repository)
        try await sandbox.git.run(["merge", "--quiet", "--allow-unrelated-histories", "--no-edit", "other"], in: repository)

        let identity = try await RepositoryInspector(git: sandbox.git).identity(of: repository)
        #expect(identity.rootCommits.count == 2)
        #expect(identity.rootCommits == identity.rootCommits.sorted())
        #expect(identity.value == "git-roots:" + identity.rootCommits.joined(separator: ","))
    }

    @Test func inspectsBareRepositoryAndRejectsPlainFolder() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let bare = sandbox.url("bare.git")
        try await sandbox.git.run(["init", "--quiet", "--bare", bare.plainPathForTests], in: nil)
        let info = try await RepositoryInspector(git: sandbox.git).inspect(bare)
        #expect(info.isBare)
        #expect(info.identity.isProvisional)

        let plain = try sandbox.makeDirectory("plain")
        await #expect(throws: GitError.notARepository(plain.path(percentEncoded: false))) {
            try await RepositoryInspector(git: sandbox.git).inspect(plain)
        }
    }
}
