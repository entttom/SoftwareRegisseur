import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import Testing

@Suite("Markdown-Vorschau, Diffs, ADR-Entwurf, Ordnerstruktur, git-Argumente")
struct TextAndDocumentTests {
    @Test func markdownBlocksRecognizeStructure() {
        let text = """
        ---
        id: FR-0001
        status: open
        ---
        # Titel
        Absatz eins
        geht weiter.

        - Punkt
          - Unterpunkt
        - [ ] offen
        - [x] erledigt
        1. Erstens
        > Zitat
        ```swift
        let x = 1
        ```
        ---
        """
        let blocks = MarkdownBlock.parse(text)
        #expect(blocks.first == .frontmatter("id: FR-0001\nstatus: open"))
        #expect(blocks.contains(.heading(level: 1, text: "Titel")))
        #expect(blocks.contains(.paragraph("Absatz eins geht weiter.")))
        #expect(blocks.contains(.bullet("Punkt", depth: 0)))
        #expect(blocks.contains(.bullet("Unterpunkt", depth: 1)))
        #expect(blocks.contains(.task("offen", checked: false)))
        #expect(blocks.contains(.task("erledigt", checked: true)))
        #expect(blocks.contains(.numbered("Erstens", number: 1)))
        #expect(blocks.contains(.quote("Zitat")))
        #expect(blocks.contains(.code("let x = 1", language: "swift")))
        #expect(blocks.last == .rule)
        #expect(MarkdownBlock.parse("").isEmpty)
    }

    @Test func unifiedDiffClassification() {
        let lines = UnifiedDiff.lines("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n kontext\n-alt\n+neu")
        #expect(lines.map(\.kind) == [.header, .header, .header, .hunk, .context, .removed, .added])
        #expect(UnifiedDiff.stats(lines) == (added: 1, removed: 1))
    }

    @Test func sideBySideAlignsChangesAndInsertions() {
        let rows = SideBySideDiff.rows(left: "a\nb\nc", right: "a\nB\nc\nd")
        #expect(rows.map(\.change) == [.same, .changed, .same, .onlyRight])
        #expect(rows[1].left == "b")
        #expect(rows[1].right == "B")
        #expect(rows[3].left == nil)
        #expect(SideBySideDiff.rows(left: "x", right: "x").allSatisfy { $0.change == .same })
    }

    @Test func prettyJSONFormatsAndHandlesDeletion() {
        #expect(PrettyJSON.format(Data(#"{"b":1,"a":2}"#.utf8)).contains("\"a\" : 2"))
        #expect(PrettyJSON.format(nil) == "(gelöscht)")
    }

    @Test func adrDraftRendersProposedADRFromTemplate() throws {
        var input = ADRDraftInput(number: 24, title: "Mac-UI liest nur")
        input.context = "Der Dienst ist einziger Schreiber."
        input.decision = "Die UI öffnet die Datenbank nur lesend."
        input.supersedes = [19]
        let text = try input.render(template: nil, date: Fixture.now, timeZone: TimeZone(identifier: "Europe/Vienna")!)
        #expect(text.contains("status: proposed"))
        #expect(text.contains("adr: 0024"))
        #expect(text.contains("# ADR-0024: Mac-UI liest nur"))
        #expect(text.contains("## Kontext\n\nDer Dienst ist einziger Schreiber.\n"))
        #expect(text.contains("Die UI öffnet die Datenbank nur lesend."))
        #expect(text.contains("supersedes: 0019"))
        // Leere Abschnitte behalten den Vorlagentext.
        #expect(text.contains("## Konsequenzen"))
        #expect(input.fileName.hasPrefix("0024-"))
        #expect(input.fileName.hasSuffix(".md"))
    }

    @Test func adrSectionReplacementStopsAtNextHeading() {
        let text = "# T\n\n## Kontext\n\nalt\n\n## Entscheidung\n\nbleibt"
        let replaced = ADRDraftInput.replaceSection("Kontext", with: "neu", in: text)
        #expect(replaced == "# T\n\n## Kontext\n\nneu\n\n## Entscheidung\n\nbleibt")
        #expect(ADRDraftInput.replaceSection("Kontext", with: "  ", in: text) == text)
    }

    @Test func nextADRNumberConsidersDatabaseAndFiles() {
        #expect(ADRDraftInput.nextNumber(knownNumbers: [1, 2], fileNames: ["0007-x.md", "README.md"]) == 8)
        #expect(ADRDraftInput.nextNumber(knownNumbers: [12], fileNames: []) == 13)
        #expect(ADRDraftInput.nextNumber(knownNumbers: [], fileNames: []) == 1)
    }

    @Test func folderLayoutValidation() {
        let valid = FolderLayoutForm(adrPath: "docs/adr", requestsRoot: "docs/requests", openPath: "offen", activePath: "in-arbeit",
                                     reviewPath: "review", donePath: "erledigt")
        #expect(valid.isValid)
        var invalid = valid
        invalid.donePath = "offen"
        invalid.adrPath = "../außerhalb"
        invalid.requestsRoot = "/absolut"
        #expect(invalid.problems.count == 3)
        invalid = valid
        invalid.reviewPath = " "
        #expect(!invalid.isValid)
    }

    @Test func gitDiffArgumentsAreExplicitAndRejectOptionInjection() throws {
        let withBase = try GitDiffLoader.arguments(base: "abc123", defaultBranch: "main", head: "def456", path: "a b.swift")
        #expect(withBase == ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "abc123..def456", "--", "a b.swift"])
        let withoutBase = try GitDiffLoader.arguments(base: nil, defaultBranch: "main", head: "def456", path: nil)
        #expect(withoutBase.last == "main...def456")
        #expect(throws: GitDiffLoader.Failure.invalidReference) {
            try GitDiffLoader.arguments(base: "--output=/tmp/x", defaultBranch: "main", head: "h", path: nil)
        }
        #expect(throws: GitDiffLoader.Failure.invalidReference) {
            try GitDiffLoader.arguments(base: nil, defaultBranch: "main", head: "a b", path: nil)
        }
    }

    /// SR-SEC-10/13: Eine repo-lokale Konfiguration (kopiertes Repository) darf beim Diff-Anzeigen kein Programm starten.
    @Test func gitDiffNeverRunsProgramsFromTheRepositoryConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SRDiff-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let marker = root.appending(path: "marker")
        let script = root.appending(path: "evil.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path(percentEncoded: false))'\ncat \"$1\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let located = try GitClient.locate()
        let git = GitClient(executableURL: located.executableURL,
                            environment: located.environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]),
                            configOverrides: [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false")])
        try await git.run(["init", "--quiet", "--initial-branch=main"], in: repo)
        let scriptPath = script.path(percentEncoded: false)
        for (key, value) in [("diff.evil.textconv", scriptPath), ("diff.external", scriptPath), ("core.fsmonitor", scriptPath)] {
            try await git.run(["config", "--local", key, value], in: repo)
        }
        try Data("*.txt diff=evil\n".utf8).write(to: repo.appending(path: ".gitattributes"))
        try Data("eins\n".utf8).write(to: repo.appending(path: "a.txt"))
        try await git.run(["add", "-A"], in: repo)
        try await git.run(["commit", "--quiet", "-m", "eins"], in: repo)
        let base = try await git.run(["rev-parse", "HEAD"], in: repo).trimmedOutput
        try Data("zwei\n".utf8).write(to: repo.appending(path: "a.txt"))
        try await git.run(["commit", "--quiet", "-am", "zwei"], in: repo)
        let head = try await git.run(["rev-parse", "HEAD"], in: repo).trimmedOutput
        try? FileManager.default.removeItem(at: marker)

        let result = await GitDiffLoader.diff(repository: repo.path(percentEncoded: false), base: base, defaultBranch: "main",
                                              head: head, path: "a.txt", git: git)
        let diff = try result.get()
        #expect(diff.contains("-eins"))
        #expect(diff.contains("+zwei"))
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)), "kein Programm aus der Repo-Konfiguration")
    }

    @Test func historyPayloadIsShownInGerman() {
        let job = EventPayloadText.summary(kind: .jobStateChanged, payload: [
            "from": "running", "to": "failed", "jobId": "74626BE8-7582-45FA-9533-99FF99F78E8C", "workItemStatus": "failed",
        ])
        #expect(job == "Status: Läuft → Fehlgeschlagen · Aufgabe: Fehlgeschlagen · Job: 74626BE8")
        let requested = EventPayloadText.summary(kind: .jobRequested, payload: [
            "providerId": "codex", "resolvedModel": "providerDefault", "resolvedEffort": "xhigh", "custom": "x",
        ])
        #expect(requested == "Agent: Codex · Modell: Anbieterstandard · Stufe: \(EffortLevel.xhigh.germanDisplayName) · custom: x")
        #expect(!requested.contains("providerId"))
    }
}
