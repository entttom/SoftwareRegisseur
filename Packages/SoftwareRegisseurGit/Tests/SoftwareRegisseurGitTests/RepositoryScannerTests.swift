import Foundation
import Testing
@testable import SoftwareRegisseurGit

@Suite("RepositoryScanner")
struct RepositoryScannerTests {
    /// Builds a representative tree under `<sandbox>/scan`.
    private func makeTree(_ sandbox: GitSandbox) async throws -> URL {
        let scan = try sandbox.makeDirectory("scan")
        let projA = try await sandbox.makeRepository("scan/ProjA")
        try sandbox.makeDirectory("scan/ProjA/src/feature")
        try sandbox.write("scan/ProjA/src/feature/main.swift", "print(1)\n")
        try await sandbox.makeRepository("scan/ProjA/node_modules/pkg")        // must not be found
        try sandbox.makeDirectory("scan/ProjA/.build/debug")
        try await sandbox.makeRepository("scan/ProjA/vendor/Nested")           // nested repo
        try await sandbox.git.run(["worktree", "add", "--quiet", "-b", "feature", sandbox.url("scan/ProjA-wt").plainPathForTests], in: projA)

        try sandbox.makeDirectory("scan/PlainProject/docs")
        try await sandbox.git.run(["init", "--quiet", "--bare", sandbox.url("scan/Bare.git").plainPathForTests], in: nil)
        try await sandbox.makeRepository("scan/Fresh", commit: false)
        try await sandbox.makeRepository("scan/.hidden-repo")
        try sandbox.makeDirectory("scan/.hidden-plain/inner")

        let source = try await sandbox.makeRepository("scan/SubSource")
        let superproject = try await sandbox.makeRepository("scan/Super")
        try await sandbox.git.run(["submodule", "--quiet", "add", source.path(percentEncoded: false), "libs/Sub"], in: superproject)
        try await sandbox.commitAll(superproject, "Add submodule")

        try sandbox.makeDirectory("scan/LoopDir")
        try FileManager.default.createSymbolicLink(atPath: sandbox.url("scan/LoopDir/loop").plainPathForTests,
                                                   withDestinationPath: "..")
        try FileManager.default.createSymbolicLink(atPath: sandbox.url("scan/LoopDir/self").plainPathForTests,
                                                   withDestinationPath: sandbox.url("scan").plainPathForTests)
        try sandbox.makeDirectory("scan/deep/a/b/c")
        return scan
    }

    @Test func classifiesRepositoriesWorktreesSubmodulesAndFolders() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let scan = try await makeTree(sandbox)
        func path(_ relative: String) -> String { sandbox.url("scan/\(relative)").plainPathForTests }

        let scanner = RepositoryScanner(options: ScanOptions(maxDepth: 3))
        let result = try await scanner.scan(roots: [scan])

        let repositoryPaths = Set(result.repositories.map(\.rootURL.plainPathForTests))
        #expect(repositoryPaths == Set(["ProjA", "ProjA/vendor/Nested", "Bare.git", "Fresh", ".hidden-repo", "SubSource", "Super"].map(path)))

        let projA = try #require(result.repository(at: sandbox.url("scan/ProjA")))
        #expect(projA.linkedWorktrees.map(\.plainPathForTests) == [path("ProjA-wt")])
        #expect(projA.enclosingRepositoryURL == nil)
        #expect(result.directory(at: sandbox.url("scan/ProjA-wt"))?.kind == .linkedWorktree)
        #expect(result.directory(at: sandbox.url("scan/ProjA-wt"))?.owningRepositoryURL?.plainPathForTests == path("ProjA"))

        let nested = try #require(result.repository(at: sandbox.url("scan/ProjA/vendor/Nested")))
        #expect(nested.enclosingRepositoryURL?.plainPathForTests == path("ProjA"))

        let superproject = try #require(result.repository(at: sandbox.url("scan/Super")))
        #expect(superproject.submodules.map(\.plainPathForTests) == [path("Super/libs/Sub")])
        #expect(result.directory(at: sandbox.url("scan/Super/libs/Sub"))?.kind == .submodule)

        let bare = try #require(result.repository(at: sandbox.url("scan/Bare.git")))
        #expect(bare.isBare)
        #expect(result.directory(at: sandbox.url("scan/Bare.git/objects")) == nil)
        #expect(result.directory(at: sandbox.url("scan/Fresh"))?.kind == .repositoryRoot)

        #expect(result.directory(at: sandbox.url("scan/ProjA/src"))?.kind == .repositorySubfolder)
        #expect(result.directory(at: sandbox.url("scan/ProjA/src"))?.owningRepositoryURL?.plainPathForTests == path("ProjA"))
        #expect(result.directory(at: sandbox.url("scan/PlainProject"))?.kind == .plainFolder)
        #expect(result.directory(at: sandbox.url("scan/PlainProject/docs"))?.kind == .plainFolder)

        // Excludes, internals, hidden folders.
        #expect(result.excludedDirectories.map(\.plainPathForTests).contains(path("ProjA/node_modules")))
        #expect(result.excludedDirectories.map(\.plainPathForTests).contains(path("ProjA/.build")))
        #expect(!result.directories.contains { $0.url.plainPathForTests.contains("/node_modules/") })
        #expect(!result.directories.contains { $0.url.plainPathForTests.contains("/.git") })
        #expect(result.directory(at: sandbox.url("scan/.hidden-plain")) == nil)

        // Symlinks recorded, not followed; loop terminates.
        #expect(Set(result.symlinkedDirectories.map(\.url.plainPathForTests)) == [path("LoopDir/loop"), path("LoopDir/self")])
        #expect(!result.directories.contains { $0.url.plainPathForTests.hasPrefix(path("LoopDir/loop")) })

        // Depth limit: deep(1)/a(2)/b(3)/c(4).
        #expect(result.directory(at: sandbox.url("scan/deep/a/b")) != nil)
        #expect(result.directory(at: sandbox.url("scan/deep/a/b/c")) == nil)
        #expect(result.depthLimitedDirectories.map(\.plainPathForTests).contains(path("deep/a/b/c")))
        #expect(result.unattachedDirectories.isEmpty)
    }

    @Test func worktreeOutsideScanIsAttachedAndNotDuplicated() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("scan/Repo")
        try await sandbox.git.run(["worktree", "add", "--quiet", "-b", "wt", sandbox.url("outside/Repo-wt").plainPathForTests], in: repository)

        let onlyWorktree = try await RepositoryScanner().scan(roots: [sandbox.url("outside")])
        #expect(onlyWorktree.repositories.isEmpty)
        #expect(onlyWorktree.unattachedDirectories.map(\.kind) == [.linkedWorktree])
        #expect(onlyWorktree.unattachedDirectories.first?.owningRepositoryURL?.plainPathForTests == repository.plainPathForTests)

        let both = try await RepositoryScanner().scan(roots: [sandbox.url("scan"), sandbox.url("outside"), sandbox.url("scan")])
        #expect(both.repositories.count == 1)
        #expect(both.repositories.first?.linkedWorktrees.map(\.plainPathForTests) == [sandbox.url("outside/Repo-wt").plainPathForTests])
    }

    @Test func rootInsideRepositoryYieldsSubfolders() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        try await sandbox.makeRepository("Repo")
        try sandbox.makeDirectory("Repo/Sources/App")
        let result = try await RepositoryScanner().scan(roots: [sandbox.url("Repo/Sources")])
        #expect(result.directories.map(\.kind) == [.repositorySubfolder, .repositorySubfolder])
        #expect(result.directories.first?.owningRepositoryURL?.plainPathForTests == sandbox.url("Repo").plainPathForTests)
    }

    @Test func rescanOfUnchangedTreeUsesCache() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let scan = try await makeTree(sandbox)
        let scanner = RepositoryScanner()
        let first = try await scanner.scan(roots: [scan])
        #expect(first.statistics.directoriesListed == first.statistics.directoriesVisited)

        let second = try await scanner.scan(roots: [scan])
        #expect(second.statistics.directoriesListed == 0)
        #expect(second.statistics.cacheHits == second.statistics.directoriesVisited)
        #expect(second.directories == first.directories)
        #expect(second.repositories == first.repositories)

        try sandbox.makeDirectory("scan/PlainProject/NewIdea")
        let third = try await scanner.scan(roots: [scan])
        #expect(third.statistics.directoriesListed == 2) // PlainProject (mtime changed) + NewIdea
        #expect(third.directory(at: sandbox.url("scan/PlainProject/NewIdea"))?.kind == .plainFolder)

        // `git init` in a known folder is detected on the next scan.
        try await sandbox.git.run(["init", "--quiet"], in: sandbox.url("scan/PlainProject/NewIdea"))
        let fourth = try await scanner.scan(roots: [scan])
        #expect(fourth.directory(at: sandbox.url("scan/PlainProject/NewIdea"))?.kind == .repositoryRoot)

        // Cache survives persistence.
        let data = try JSONEncoder().encode(await scanner.cache)
        let restored = RepositoryScanner(cache: try JSONDecoder().decode(ScanCache.self, from: data))
        let fifth = try await restored.scan(roots: [scan])
        #expect(fifth.statistics.directoriesListed == 0)
    }

    @Test func configurableExcludesAndExcludedPaths() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        try sandbox.makeDirectory("scan/keep/node_modules/x")
        try sandbox.makeDirectory("scan/skip-me/inner")
        try sandbox.makeDirectory("scan/worktrees/job")
        let options = ScanOptions(excludedDirectoryNames: ["skip-me"], excludedPaths: [sandbox.url("scan/worktrees")])
        let result = try await RepositoryScanner(options: options).scan(roots: [sandbox.url("scan")])
        let paths = Set(result.directories.map { $0.url.plainPathForTests })
        #expect(paths.contains(sandbox.url("scan/keep/node_modules/x").plainPathForTests))
        #expect(!paths.contains(sandbox.url("scan/skip-me").plainPathForTests))
        #expect(!paths.contains(sandbox.url("scan/worktrees").plainPathForTests))
    }

    @Test func scanIsCancellable() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        for index in 0..<50 { try sandbox.makeDirectory("scan/d\(index)/e") }
        let scanner = RepositoryScanner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan(roots: [sandbox.url("scan")])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

extension URL {
    var plainPathForTests: String {
        var path = path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
