import Foundation
import Testing
@testable import SoftwareRegisseurMarkdown

@Suite("ADRs")
struct ADRTests {
    static var repoADRFiles: [String] {
        Fixtures.adrFileNames.filter { ADRNumbering.number(fromFileName: $0) != nil }
    }

    @Test("Repository ADRs parse as frontmatter ADRs", arguments: repoADRFiles)
    func parseRepositoryADR(fileName: String) throws {
        let text = try Fixtures.text("adr/" + fileName)
        let record = try #require(ADRParser.parse(fileName: fileName, text: text).record)
        #expect(record.number == ADRNumbering.number(fromFileName: fileName))
        #expect(record.format == .frontmatter)
        #expect(record.date == "2026-10-30")
        #expect(record.warnings.isEmpty)
        #expect(!record.title.isEmpty)
        let expectedStatus: ADRStatus = fileName.hasPrefix("0010-") ? .proposed : .accepted
        #expect(record.status == expectedStatus)
    }

    @Test func specificRepositoryADRs() throws {
        let record = try #require(ADRParser.parse(
            fileName: "0012-getrennte-status-zustandsmaschinen.md",
            text: try Fixtures.text("adr/0012-getrennte-status-zustandsmaschinen.md")
        ).record)
        #expect(record.number == 12)
        #expect(record.title == "Getrennte Zustandsmaschinen für Projekt, Aufgabe und Agentenjob")
        #expect(record.supersedes == [])
    }

    @Test func readmeAndTemplateAreNotNumberedADRs() throws {
        #expect(ADRParser.parse(fileName: "README.md", text: try Fixtures.text("adr/README.md"))
            == .incompatible(.missingNumber))
        // TEMPLATE.md has frontmatter `adr: NNNN` – a placeholder, not a number.
        #expect(ADRParser.parse(fileName: "TEMPLATE.md", text: try Fixtures.text("adr/TEMPLATE.md"))
            == .incompatible(.invalidNumber("NNNN")))
    }

    @Test func madrWithoutFrontmatter() throws {
        let madr = """
        # 7. Use PostgreSQL for persistence

        * Status: Superseded by [ADR-0009](0009-sqlite.md)
        * Date: 2024-02-01

        ## Context and Problem Statement

        Status: this line is ignored because a status was already found.
        """
        let record = try #require(ADRParser.parse(fileName: "0007-use-postgresql.md", text: madr).record)
        #expect(record.number == 7)
        #expect(record.title == "Use PostgreSQL for persistence")
        #expect(record.status == .superseded)
        #expect(record.supersededBy == 9)
        #expect(record.date == "2024-02-01")
        #expect(record.format == .madr)

        let sectionStyle = """
        # ADR-0003: Datenbank wählen

        ## Status

        Akzeptiert

        ## Datum

        2025-01-05

        ## Kontext

        ```markdown
        ## Status
        rejected
        ```
        """
        let second = try #require(ADRParser.parse(fileName: "0003-datenbank.md", text: sectionStyle).record)
        #expect(second.status == .accepted)
        #expect(second.title == "Datenbank wählen")
        #expect(second.date == "2025-01-05")

        let boldStyle = "# Titel\r\n\r\n**Status:** Proposed  \r\n"
        #expect(ADRParser.parse(fileName: "12-titel.md", text: boldStyle).record?.status == .proposed)
    }

    @Test func incompatibleADRs() {
        #expect(ADRParser.parse(fileName: "0005-x.md", text: "# Nur ein Titel\n\nText ohne Status.\n")
            == .incompatible(.missingStatus))
        #expect(ADRParser.parse(fileName: "0005-x.md", text: "# T\n\nStatus: vielleicht\n")
            == .incompatible(.unknownStatus("vielleicht")))
        #expect(ADRParser.parse(fileName: "notes.md", text: "# T\n\nStatus: accepted\n")
            == .incompatible(.missingNumber))
        if case .incompatible(.malformedFrontmatter) = ADRParser.parse(
            fileName: "0005-x.md", text: "---\nadr: [0005\nstatus: accepted\n---\n") {
        } else {
            Issue.record("expected malformed frontmatter")
        }
        if case .incompatible(.malformedFrontmatter) = ADRParser.parse(fileName: "0005-x.md", text: "---\nadr: 5\n") {
        } else {
            Issue.record("expected unterminated frontmatter")
        }
        let mismatch = ADRParser.parse(fileName: "0005-x.md", text: "---\nadr: 6\nstatus: accepted\ntitle: T\n---\n")
        #expect(mismatch.record?.number == 6)
        #expect(mismatch.record?.warnings.count == 1)
    }

    @Test func nextNumberAndFileName() {
        #expect(ADRNumbering.nextNumber(fileNames: Fixtures.adrFileNames) == 19)
        #expect(ADRNumbering.nextNumber(fileNames: ["README.md"]) == 1)
        #expect(ADRNumbering.fileName(number: 19, title: "Markdown-Paket: verlustfreie Bearbeitung")
            == "0019-markdown-paket-verlustfreie-bearbeitung.md")
        #expect(ADRNumbering.parseNumber("ADR-0004") == 4)
        #expect(ADRNumbering.parseNumber("NNNN") == nil)
    }

    @Test func newADRFromRepositoryTemplate() throws {
        let template = try Fixtures.text("adr/TEMPLATE.md")
        #expect(template.isByteIdentical(to: ADRTemplate.defaultTemplate))
        let text = try ADRTemplate.render(template: template, number: 19, title: "Verlustfreie Markdown-Bearbeitung",
                                          date: ADRTemplate.dateString(Fixtures.fixedDate, timeZone: Fixtures.vienna))
        let diff = LineDiff(old: template, new: text)
        #expect(diff.deletedLines.map(\.text) == [
            "adr: NNNN", "title: \"Kurzer Entscheidungstitel\"", "date: YYYY-MM-DD",
            "# ADR-NNNN: Kurzer Entscheidungstitel",
        ])
        #expect(diff.insertedLines.map(\.text) == [
            "adr: 0019", "title: \"Verlustfreie Markdown-Bearbeitung\"", "date: 2026-10-30",
            "# ADR-0019: Verlustfreie Markdown-Bearbeitung",
        ])
        let record = try #require(ADRParser.parse(fileName: "0019-verlustfreie-markdown-bearbeitung.md", text: text).record)
        #expect(record.number == 19)
        #expect(record.status == .proposed)
        #expect(record.title == "Verlustfreie Markdown-Bearbeitung")

        let superseding = try ADRTemplate.render(template: template, number: 20, title: "Ersatz", date: "2026-11-01",
                                                 supersedes: [4])
        #expect(superseding.contains("\nsupersedes: 0004\n"))
        #expect(!superseding.contains("# supersedes"))
        #expect(ADRParser.parse(fileName: "0020-ersatz.md", text: superseding).record?.supersedes == [4])

        let multiple = try ADRTemplate.render(number: 21, title: "Zwei", date: "2026-11-01", supersedes: [4, 12])
        #expect(ADRParser.parse(fileName: "0021-zwei.md", text: multiple).record?.supersedes == [4, 12])
    }

    @Test func madrTemplateWithoutFrontmatterGetsFrontmatter() throws {
        let text = try ADRTemplate.render(template: "## Context\n\nTBD\n", number: 3, title: "X: Y", date: "2026-01-01")
        let record = try #require(ADRParser.parse(fileName: "0003-x-y.md", text: text).record)
        #expect(record.title == "X: Y")
        #expect(text.hasSuffix("## Context\n\nTBD\n"))
    }
}

@Suite("ADR frontmatter edits")
struct ADRFrontmatterEditTests {
    @Test func acceptingProposedADRTouchesOnlyStatusLine() throws {
        let original = try Fixtures.text("adr/0010-offizielle-mobile-agenten-sitzungen.md")
        var document = FrontmatterDocument(text: original)
        try document.setScalar(key: "status", value: ADRStatus.accepted.rawValue)
        let diff = LineDiff(old: original, new: document.text)
        #expect(diff.deletedLines.map(\.text) == ["status: proposed"])
        #expect(diff.insertedLines.map(\.text) == ["status: accepted"])
        #expect(ADRParser.parse(fileName: "0010-x.md", text: document.text).record?.status == .accepted)
    }
}
