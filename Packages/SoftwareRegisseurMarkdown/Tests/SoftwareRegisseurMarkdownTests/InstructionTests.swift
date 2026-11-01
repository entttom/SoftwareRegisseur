import Foundation
import Testing
@testable import SoftwareRegisseurMarkdown

@Suite("AGENTS.md managed block and CLAUDE.md import")
struct InstructionTests {
    /// Current block (v2, ADR-0024) for the default layout.
    static let specExample = """
    <!-- SOFTWARE-REGISSEUR:BEGIN v2 -->
    ## Software Regisseur Workflow
    - ADRs: docs/adr/
    - Open requests: docs/requests/open/
    - In progress: docs/requests/in-progress/
    - Review: docs/requests/review/
    - Done: docs/requests/done/
    - Read relevant accepted ADRs before architectural changes.
    - Request files and ADRs in the folders above are maintained by Software Regisseur.
    - Agents must not create, edit or move request files or ADRs; report status, changes and tests in the final message instead.
    - Never commit, push or merge without explicit user approval.
    - Do not modify secrets.
    <!-- SOFTWARE-REGISSEUR:END -->

    """

    /// Block as written by version 1 (spec G example before ADR-0024).
    static let v1Block = """
    <!-- SOFTWARE-REGISSEUR:BEGIN v1 -->
    ## Software Regisseur Workflow
    - ADRs: docs/adr/
    - Open requests: docs/requests/open/
    - In progress: docs/requests/in-progress/
    - Review: docs/requests/review/
    - Done: docs/requests/done/
    - Read relevant accepted ADRs before architectural changes.
    - Preserve request IDs and frontmatter fields.
    - On start: update task status and move into the active location if configured.
    - On implementation finish: report changes and tests; set review, not done.
    - Never push or merge without explicit user approval.
    - Do not modify unrelated requests or secrets.
    <!-- SOFTWARE-REGISSEUR:END -->

    """

    @Test func defaultBlockMatchesSpecExample() {
        #expect(ManagedBlock(layout: .default).rendered() == Self.specExample)
    }

    @Test func appendToRealAgentsFile() throws {
        let agents = try Fixtures.text("AGENTS.md")
        let block = ManagedBlock(layout: .default)
        let updated = try block.apply(to: agents)
        #expect(updated.hasPrefix(agents))
        #expect(updated.utf8.starts(with: agents.utf8))
        let appended = String(updated.dropFirst(agents.count))
        // AGENTS.md ends with a newline but no blank line: exactly one blank line separates the block.
        #expect(agents.hasSuffix("\n") && !agents.hasSuffix("\n\n"))
        #expect(appended == "\n" + Self.specExample)

        // Idempotent.
        #expect(try block.apply(to: updated).isByteIdentical(to: updated))
        #expect(try !block.proposal(for: updated).hasChanges)

        let proposal = try block.proposal(for: agents)
        #expect(proposal.hasChanges)
        #expect(proposal.diff.deletedLines.isEmpty)
        #expect(proposal.diff.insertedLines.count == 14)
        let unified = proposal.unifiedDiff()
        #expect(unified.hasPrefix("--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ -"))
        #expect(unified.contains("+<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->\n"))
    }

    @Test func replaceOnlyBetweenMarkers() throws {
        let agents = try Fixtures.text("AGENTS.md")
        let installed = try ManagedBlock(layout: .default).apply(to: agents) + "\n## Eigene Regeln danach\n\n- bleibt\n"
        var layout = FolderLayout.default
        layout.adrPath = try RelativePath("architektur/entscheidungen")
        layout.requestsRoot = try RelativePath("aufgaben")
        layout.statusFolders[.open] = try RelativePath("ideen/offen")
        layout.statusFolders[.done] = try RelativePath("features/erledigt")
        let replaced = try ManagedBlock(layout: layout).apply(to: installed)

        let diff = LineDiff(old: installed, new: replaced)
        #expect(diff.deletedLines.map(\.text) == [
            "- ADRs: docs/adr/", "- Open requests: docs/requests/open/", "- In progress: docs/requests/in-progress/",
            "- Review: docs/requests/review/", "- Done: docs/requests/done/",
        ])
        #expect(diff.insertedLines.map(\.text) == [
            "- ADRs: architektur/entscheidungen/", "- Open requests: aufgaben/ideen/offen/",
            "- In progress: aufgaben/in-progress/", "- Review: aufgaben/review/",
            "- Done: aufgaben/features/erledigt/",
        ])
        #expect(replaced.hasPrefix(agents))
        #expect(replaced.hasSuffix("<!-- SOFTWARE-REGISSEUR:END -->\n\n## Eigene Regeln danach\n\n- bleibt\n"))
    }

    @Test func crlfFileAndMissingTrailingNewline() throws {
        let block = ManagedBlock(layout: .default)
        let crlf = "# Regeln\r\n\r\n- eins"
        let appended = try block.apply(to: crlf)
        #expect(appended == "# Regeln\r\n\r\n- eins\r\n\r\n" + Self.specExample.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(try block.apply(to: appended).isByteIdentical(to: appended))

        let lfWithBlank = "# Regeln\n\n"
        #expect(try block.apply(to: lfWithBlank) == lfWithBlank + Self.specExample)
        #expect(try block.apply(to: nil) == Self.specExample)
        #expect(try block.apply(to: "") == Self.specExample)

        // Indented markers with trailing whitespace are recognised; marker lines stay byte-identical.
        let indented = "x\n  <!-- SOFTWARE-REGISSEUR:BEGIN v2 -->  \nold\n<!-- SOFTWARE-REGISSEUR:END -->\ny"
        let replaced = try block.apply(to: indented)
        #expect(replaced.hasPrefix("x\n  <!-- SOFTWARE-REGISSEUR:BEGIN v2 -->  \n## Software Regisseur Workflow\n"))
        #expect(replaced.hasSuffix("\n<!-- SOFTWARE-REGISSEUR:END -->\ny"))
    }

    @Test func brokenMarkersAreRejected() throws {
        let block = ManagedBlock(layout: .default)
        let begin = ManagedBlock.beginMarker
        let end = ManagedBlock.endMarker
        let cases: [(String, ManagedBlockError)] = [
            ("a\n\(begin)\nx\n\(end)\n\(begin)\ny\n\(end)\n", .duplicateBeginMarker(lines: [2, 5])),
            ("\(begin)\n\(begin)\n\(end)\n\(end)\n", .nestedMarkers(lines: [1, 2, 3, 4])),
            ("\(begin)\nx\n\(end)\n\(end)\n", .duplicateEndMarker(lines: [3, 4])),
            ("\(end)\nx\n\(begin)\n", .endBeforeBegin(endLine: 1)),
            ("a\n\(begin)\nx\n", .missingEndMarker(beginLine: 2)),
            ("a\nx\n\(end)\n", .missingBeginMarker(endLine: 3)),
            ("<!-- SOFTWARE-REGISSEUR:BEGIN v3 -->\nx\n\(end)\n", .unsupportedVersion("v3", line: 1)),
            ("<!-- SOFTWARE-REGISSEUR:BEGIN v1 -->\nx\n\(begin)\ny\n\(end)\n\(end)\n", .nestedMarkers(lines: [1, 3, 5, 6])),
            ("<!-- SOFTWARE-REGISSEUR:BEGIN -->\nx\n\(end)\n", .malformedMarker("<!-- SOFTWARE-REGISSEUR:BEGIN -->", line: 1)),
        ]
        for (text, expected) in cases {
            #expect(throws: expected) { try block.apply(to: text) }
            #expect(throws: expected) { try block.proposal(for: text) }
        }
    }

    /// ADR-0024: an installed v1 block is recognised and replaced by v2 as a normal proposal; user text,
    /// indentation and line endings around it stay byte-identical.
    @Test func v1BlockMigratesToV2ViaProposal() throws {
        let before = "# Eigene Regeln\n\n- bleibt\n\n"
        let after = "\n## Danach\n- bleibt auch\n"
        let installed = before + Self.v1Block + after
        #expect(try ManagedBlock.installedVersion(in: installed) == 1)
        #expect(try ManagedBlock.locate(in: installed) == .present(beginLine: 4, endLine: 17))

        let block = ManagedBlock(layout: .default)
        let proposal = try block.proposal(for: installed)
        #expect(proposal.hasChanges)
        #expect(proposal.originalText == installed) // proposal only; nothing is written here
        #expect(proposal.proposedText == before + Self.specExample + after)
        #expect(try ManagedBlock.installedVersion(in: proposal.proposedText) == ManagedBlock.version)
        let diff = proposal.diff
        #expect(diff.deletedLines.map(\.text).contains("<!-- SOFTWARE-REGISSEUR:BEGIN v1 -->"))
        #expect(diff.deletedLines.map(\.text).contains("- On start: update task status and move into the active location if configured."))
        #expect(diff.insertedLines.map(\.text).contains("<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->"))
        #expect(diff.insertedLines.map(\.text).contains("- Never commit, push or merge without explicit user approval."))
        let unified = proposal.unifiedDiff()
        #expect(unified.contains("\n-<!-- SOFTWARE-REGISSEUR:BEGIN v1 -->\n") && unified.contains("\n+<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->\n"))
        // Migrated text is stable.
        #expect(try !block.proposal(for: proposal.proposedText).hasChanges)

        // CRLF and indented v1 marker: only the marker token changes.
        let crlf = "x\r\n  <!-- SOFTWARE-REGISSEUR:BEGIN v1 -->  \r\nold\r\n<!-- SOFTWARE-REGISSEUR:END -->\r\ny"
        let migrated = try block.apply(to: crlf)
        #expect(migrated.hasPrefix("x\r\n  <!-- SOFTWARE-REGISSEUR:BEGIN v2 -->  \r\n## Software Regisseur Workflow\r\n"))
        #expect(migrated.hasSuffix("\r\n<!-- SOFTWARE-REGISSEUR:END -->\r\ny"))
        #expect(try ManagedBlock.installedVersion(in: "kein Block\n") == nil)
    }

    /// ADR-0024 wording: no status updates or file moves by agents, no commits without approval.
    @Test func blockForbidsAgentsTouchingDocumentsAndCommitting() {
        let text = ManagedBlock(layout: .default).contentLines.joined(separator: "\n")
        #expect(text.contains("Request files and ADRs in the folders above are maintained by Software Regisseur."))
        #expect(text.contains("Agents must not create, edit or move request files or ADRs"))
        #expect(text.contains("Never commit, push or merge without explicit user approval."))
        #expect(!text.contains("update task status"))
        #expect(!text.contains("move into the active location"))
        #expect(!text.contains("set review"))
    }

    @Test func markersInsideCodeFencesAreIgnored() throws {
        // Documentation of the block format (like spec section G) must not be treated as the block.
        let text = "# Doku\n\n```markdown\n\(Self.specExample)```\n"
        #expect(try ManagedBlock.locate(in: text) == .absent)
        let updated = try ManagedBlock(layout: .default).apply(to: text)
        #expect(updated == text + "\n" + Self.specExample)
        #expect(try ManagedBlock.locate(in: updated) == .present(beginLine: 18, endLine: 30))
    }

    @Test func claudeImportDetection() throws {
        let claude = try Fixtures.text("CLAUDE.md")
        #expect(ClaudeMemoryImport.containsAgentsImport(claude))
        #expect(!ClaudeMemoryImport.proposal(for: claude).hasChanges)
        #expect(ClaudeMemoryImport.containsAgentsImport("# X\n   @AGENTS.md\t\n"))
        #expect(ClaudeMemoryImport.containsAgentsImport("\u{FEFF}@AGENTS.md"))
        #expect(!ClaudeMemoryImport.containsAgentsImport("Siehe @AGENTS.md für Details\n"))
        #expect(!ClaudeMemoryImport.containsAgentsImport("@AGENTS.md.bak\n"))
        #expect(!ClaudeMemoryImport.containsAgentsImport("```\n@AGENTS.md\n```\n"))
    }

    @Test func claudeImportProposalOnlyAppends() {
        let withoutImport = "# Hinweise für Claude Code\n\n- Eigene Regel\n"
        let proposal = ClaudeMemoryImport.proposal(for: withoutImport)
        #expect(proposal.hasChanges)
        #expect(proposal.proposedText == withoutImport + "\n@AGENTS.md\n")
        #expect(proposal.diff.deletedLines.isEmpty)
        #expect(proposal.diff.insertedLines.map(\.text) == ["", "@AGENTS.md"])

        let crlfNoNewline = "Regel\r\nZweite"
        #expect(ClaudeMemoryImport.proposal(for: crlfNoNewline).proposedText == "Regel\r\nZweite\r\n\r\n@AGENTS.md\r\n")
        #expect(ClaudeMemoryImport.proposal(for: nil).proposedText == "@AGENTS.md\n")
        #expect(ClaudeMemoryImport.proposal(for: nil).unifiedDiff().hasPrefix("--- /dev/null\n+++ b/CLAUDE.md\n"))
    }

    @Test func unifiedDiffFormat() {
        let diff = LineDiff(old: "a\nb\nc\n", new: "a\nB\nc\nd")
        #expect(diff.unified() == """
        --- a
        +++ b
        @@ -1,3 +1,4 @@
         a
        -b
        +B
         c
        +d
        \\ No newline at end of file

        """)
        #expect(LineDiff(old: "x\n", new: "x\n").unified().isEmpty)
    }
}
