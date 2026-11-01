import Foundation
import Testing
@testable import SoftwareRegisseurGit

@Suite("PathGuard")
struct PathGuardTests {
    @Test func acceptsPathsInsideRootsIncludingNotYetExisting() throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let allowed = try sandbox.makeDirectory("allowed")
        try sandbox.makeDirectory("allowed/project")
        let guardian = try PathGuard(allowedRoots: [allowed])

        #expect(try guardian.validate(sandbox.url("allowed/project")).plainPathForTests == sandbox.url("allowed/project").plainPathForTests)
        #expect(try guardian.validate(sandbox.url("allowed/project/./new/deeper")).plainPathForTests
                == sandbox.url("allowed/project/new/deeper").plainPathForTests)
        #expect(try guardian.validate(allowed).plainPathForTests == allowed.plainPathForTests)
        // `/private/var` vs `/var`: the non-canonical temp path still validates.
        let nonCanonical = FileManager.default.temporaryDirectory.appending(path: sandbox.root.lastPathComponent)
            .appending(path: "allowed/project")
        #expect(guardian.isAllowed(nonCanonical))
    }

    @Test func rejectsTraversal() throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let allowed = try sandbox.makeDirectory("allowed")
        try sandbox.makeDirectory("outside")
        try sandbox.makeDirectory("allowed-sibling")
        let guardian = try PathGuard(allowedRoots: [allowed])

        #expect(throws: PathGuardError.self) { try guardian.validate(URL(filePath: allowed.plainPathForTests + "/../outside")) }
        #expect(throws: PathGuardError.self) { try guardian.validate(URL(filePath: allowed.plainPathForTests + "/missing/../../outside/x")) }
        #expect(throws: PathGuardError.self) { try guardian.validate(sandbox.url("allowed-sibling")) } // prefix trick
        #expect(throws: PathGuardError.relativePath("relative/path")) { try guardian.validate(URL(filePath: "relative/path", relativeTo: nil)) }
    }

    @Test func rejectsSymlinkEscapes() throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let allowed = try sandbox.makeDirectory("allowed")
        let outside = try sandbox.makeDirectory("outside")
        try sandbox.makeDirectory("allowed/inner")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: allowed.plainPathForTests + "/escape", withDestinationPath: outside.plainPathForTests)
        try fm.createSymbolicLink(atPath: allowed.plainPathForTests + "/relative-escape", withDestinationPath: "../outside")
        try fm.createSymbolicLink(atPath: allowed.plainPathForTests + "/internal", withDestinationPath: "inner")
        try fm.createSymbolicLink(atPath: allowed.plainPathForTests + "/dangling", withDestinationPath: "/nonexistent/target")
        let guardian = try PathGuard(allowedRoots: [allowed])

        #expect(throws: PathGuardError.self) { try guardian.validate(sandbox.url("allowed/escape")) }
        #expect(throws: PathGuardError.self) { try guardian.validate(sandbox.url("allowed/escape/new-folder")) }
        #expect(throws: PathGuardError.self) { try guardian.validate(sandbox.url("allowed/relative-escape/file")) }
        #expect(throws: PathGuardError.danglingSymlink(allowed.plainPathForTests + "/dangling")) {
            try guardian.validate(sandbox.url("allowed/dangling/child"))
        }
        #expect(try guardian.validate(sandbox.url("allowed/internal")).plainPathForTests == sandbox.url("allowed/inner").plainPathForTests)
    }

    @Test func validatesNewSubfolderNames() throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let allowed = try sandbox.makeDirectory("allowed")
        try sandbox.makeDirectory("allowed/Existing")
        let guardian = try PathGuard(allowedRoots: [allowed])

        let created = try guardian.validateNewSubfolder(named: "New Project", in: allowed)
        #expect(created.plainPathForTests == allowed.plainPathForTests + "/New Project")

        let cases: [(String, PathGuardError.FolderNameProblem)] = [
            ("", .empty), ("..", .traversal), (".", .traversal), ("a/b", .separator), ("../x", .separator),
            ("a:b", .separator), (".hidden", .leadingDot), (" padded", .surroundingWhitespace),
            ("tab\tname", .controlCharacter), (String(repeating: "x", count: 256), .tooLong),
        ]
        for (name, problem) in cases {
            #expect(throws: PathGuardError.invalidFolderName(name, reason: problem)) {
                try guardian.validateNewSubfolder(named: name, in: allowed)
            }
        }
        #expect(throws: Never.self) {
            try guardian.validateNewSubfolder(named: ".config", in: allowed, rules: FolderNameRules(allowLeadingDot: true))
        }
        #expect(throws: PathGuardError.alreadyExists(allowed.plainPathForTests + "/Existing")) {
            try guardian.validateNewSubfolder(named: "Existing", in: allowed)
        }
        #expect(throws: PathGuardError.self) {
            try guardian.validateNewSubfolder(named: "x", in: sandbox.url("elsewhere"))
        }
    }
}
