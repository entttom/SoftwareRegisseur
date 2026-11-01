import Foundation
import Testing
@testable import SoftwareRegisseurGit

@Suite("GitStatus")
struct GitStatusTests {
    @Test func parsesPorcelainV2Records() throws {
        let records = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb file with spaces.txt",
            "2 R. N... 100644 100644 100644 aaaaaaa aaaaaaa R100 new name.txt",
            "old name.txt",
            "u UU N... 100644 100644 100644 100644 a1 a2 a3 conflict.txt",
            "1 A. SC.. 160000 160000 160000 c1 c2 libs/sub",
            "? untracked dir/file.txt",
            "! ignored.log",
        ]
        let data = Data((records.joined(separator: "\u{0}") + "\u{0}").utf8)
        let status = try GitStatus.parse(data)

        #expect(status.branch.oid == "1234567890abcdef1234567890abcdef12345678")
        #expect(status.branch.head == "feature/x")
        #expect(status.branch.upstream == "origin/feature/x")
        #expect(status.branch.ahead == 2)
        #expect(status.branch.behind == 1)
        #expect(status.entries.count == 6)

        #expect(status.entries[0] == GitStatus.Entry(kind: .changed, indexStatus: ".", workTreeStatus: "M", path: "file with spaces.txt"))
        #expect(status.entries[1] == GitStatus.Entry(kind: .renamedOrCopied, indexStatus: "R", workTreeStatus: ".",
                                                     path: "new name.txt", originalPath: "old name.txt", renameScore: "R100"))
        #expect(status.entries[2].kind == .unmerged)
        #expect(status.entries[2].path == "conflict.txt")
        #expect(status.entries[3].submoduleState == "SC..")
        #expect(status.entries[4] == GitStatus.Entry(kind: .untracked, indexStatus: "?", workTreeStatus: "?", path: "untracked dir/file.txt"))
        #expect(status.entries[5].kind == .ignored)
        #expect(status.hasConflicts)
        #expect(!status.isClean)
        #expect(status.untrackedPaths == ["untracked dir/file.txt"])
    }

    @Test func parsesInitialAndDetachedHeaders() throws {
        let initial = try GitStatus.parse(Data("# branch.oid (initial)\u{0}# branch.head main\u{0}".utf8))
        #expect(initial.branch.oid == nil)
        #expect(initial.branch.head == "main")
        #expect(initial.isClean)

        let detached = try GitStatus.parse(Data("# branch.oid abc\u{0}# branch.head (detached)\u{0}".utf8))
        #expect(detached.branch.isDetached)
    }

    @Test func rejectsMalformedRecords() {
        #expect(throws: GitError.self) { try GitStatus.parse(Data("1 .M N...\u{0}".utf8)) }
        #expect(throws: GitError.self) { try GitStatus.parse(Data("x nonsense\u{0}".utf8)) }
    }

    @Test func statusOfRealRepository() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository("repo")
        try sandbox.write("repo/old name.txt", "content\n")
        try sandbox.write("repo/tracked.txt", "one\n")
        try await sandbox.commitAll(repository, "Add files")

        #expect(try await sandbox.git.status(of: repository).isClean)

        try await sandbox.git.run(["mv", "old name.txt", "new name.txt"], in: repository)
        try sandbox.write("repo/tracked.txt", "two\n")
        try sandbox.write("repo/fresh dir/new file.txt", "x\n")
        let status = try await sandbox.git.status(of: repository)

        #expect(status.branch.head == "main")
        #expect(status.branch.oid?.count == 40)
        #expect(status.entries.contains(GitStatus.Entry(kind: .renamedOrCopied, indexStatus: "R", workTreeStatus: ".",
                                                        path: "new name.txt", originalPath: "old name.txt", renameScore: "R100")))
        #expect(status.entries.contains { $0.kind == .changed && $0.path == "tracked.txt" && $0.workTreeStatus == "M" })
        #expect(status.untrackedPaths == ["fresh dir/new file.txt"])
        #expect(status.hasTrackedChanges)
    }

    @Test func entryRoundTripsThroughCodable() throws {
        let entry = GitStatus.Entry(kind: .renamedOrCopied, indexStatus: "R", workTreeStatus: ".", path: "b", originalPath: "a", renameScore: "R90")
        let decoded = try JSONDecoder().decode(GitStatus.Entry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
    }
}
