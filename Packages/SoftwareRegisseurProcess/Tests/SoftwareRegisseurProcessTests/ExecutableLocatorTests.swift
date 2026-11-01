import Darwin
import Foundation
import Testing
@testable import SoftwareRegisseurProcess

@Suite("ExecutableLocator")
struct ExecutableLocatorTests {
    @Test func reportsAllCandidatesInOrderAndPrefersFirstUsable() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let fm = FileManager.default
        func dir(_ name: String) throws -> URL {
            let url = temp.url.appending(path: name, directoryHint: .isDirectory)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let real = try dir("real"), linked = try dir("linked"), plain = try dir("plain")
        let broken = try dir("broken"), folder = try dir("folder"), empty = try dir("empty")

        let realTool = real.appending(path: "tool")
        try Data("#!/bin/sh\necho real\n".utf8).write(to: realTool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realTool.path)
        try fm.createSymbolicLink(at: linked.appending(path: "tool"), withDestinationURL: realTool)
        try Data("not executable".utf8).write(to: plain.appending(path: "tool"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.appending(path: "tool").path)
        try fm.createSymbolicLink(at: broken.appending(path: "tool"), withDestinationURL: temp.url.appending(path: "missing"))
        try fm.createDirectory(at: folder.appending(path: "tool"), withIntermediateDirectories: true)

        let locator = ExecutableLocator(userDirectories: [empty, plain, broken, folder, linked, real, linked],
                                        includeDefaultDirectories: false)
        #expect(locator.searchDirectories.count == 6) // duplicate `linked` removed

        let lookup = try locator.locate("tool")
        #expect(lookup.candidates.map(\.status) == [.notExecutable, .brokenSymbolicLink, .notRegularFile, .usable, .usable])
        let preferred = try #require(lookup.preferred)
        #expect(preferred.isSymbolicLink)
        #expect(preferred.url.deletingLastPathComponent().lastPathComponent == "linked")
        let expectedTarget = String(cString: realpath(realTool.path, nil)!)
        #expect(preferred.resolvedURL?.path(percentEncoded: false) == expectedTarget)

        #expect(try locator.locate("absent").candidates.isEmpty)
        #expect(try locator.locate("absent").preferred == nil)
    }

    @Test func rejectsNamesWithPathComponents() {
        let locator = ExecutableLocator(includeDefaultDirectories: false)
        for name in ["", ".", "..", "../tool", "bin/tool", "/bin/sh"] {
            #expect(throws: ExecutableLocatorError.invalidName(name)) { try locator.locate(name) }
        }
    }

    @Test func defaultOrderSuitsLaunchAgents() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let custom = URL(filePath: "/custom/bin", directoryHint: .isDirectory)
        let locator = ExecutableLocator(userDirectories: [custom], homeDirectory: home)
        #expect(locator.searchDirectories.map { $0.path(percentEncoded: false) }.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } == [
            "/custom/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Users/example/.local/bin", "/usr/bin", "/bin",
        ])
    }

    @Test func findsSystemShell() throws {
        let lookup = try ExecutableLocator(includeDefaultDirectories: true).locate("sh")
        #expect(lookup.preferred != nil)
    }
}
