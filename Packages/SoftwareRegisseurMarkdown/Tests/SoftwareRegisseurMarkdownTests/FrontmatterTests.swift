import Foundation
import Testing
@testable import SoftwareRegisseurMarkdown

@Suite("Frontmatter document")
struct FrontmatterTests {
    @Test("All repository fixtures re-serialise byte-identically", arguments: Fixtures.allMarkdownPaths)
    func roundTripFixtures(path: String) throws {
        let data = try Fixtures.data(path)
        let document = try FrontmatterDocument(data: data)
        #expect(document.data == data)
        let request = RequestDocument(text: try Fixtures.text(path))
        #expect(request.text.bytes == data.map { $0 })
        #expect(MarkdownSections(parsing: document.body).text.isByteIdentical(to: document.body))
    }

    @Test func fixturesCoverRepository() {
        #expect(Fixtures.adrFileNames.count >= 20)
    }

    @Test func roundTripSampleRequestAndVariants() {
        let variants = [
            Fixtures.sampleRequest,
            Fixtures.sampleRequest.replacingOccurrences(of: "\n", with: "\r\n"),
            "\u{FEFF}" + Fixtures.sampleRequest,
            "no frontmatter at all\n",
            "",
            "---\n",
            "---\nunterminated: true\n",
            "---\n---\n",
            "---\nkey: value\n---",
            "---\n: : broken [\n---\nbody",
            "--- \ntrailing: space\n---  \nbody",
            "---\nk: v\n...\nbody",
            "\r\n",
        ]
        for text in variants {
            #expect(FrontmatterDocument(text: text).text.isByteIdentical(to: text), "\(text.debugDescription)")
        }
    }

    @Test func readsValues() throws {
        let document = FrontmatterDocument(text: Fixtures.sampleRequest)
        #expect(document.state == .present)
        #expect(document.diagnostics.isEmpty)
        #expect(document["id"] == .scalar("FR-0001"))
        #expect(document["title"] == .scalar("Senderliste auf dem iPad vergrößern"))
        #expect(document["status"] == .scalar("open"))
        #expect(document["labels"]?.stringList == ["ios", "ux"])
        #expect(document["dependsOn"]?.stringList == [])
        #expect(document["agentJobIds"]?.stringList == ["job-1", "job-2"])
        #expect(document.keys.first == "id")
        #expect(document.keys.contains("customField"))
        #expect(document.keys.last == "x-team")
    }

    @Test func statusChangeTouchesOnlyStatusAndUpdatedAt() throws {
        var request = RequestDocument(text: Fixtures.sampleRequest)
        try request.setStatus(.inProgress, updatedAt: Fixtures.fixedDate, timeZone: Fixtures.vienna)
        let diff = LineDiff(old: Fixtures.sampleRequest, new: request.text)
        #expect(diff.deletedLines.map(\.text) == [
            "status: open   # inline comment survives",
            "updatedAt: \"2026-10-29T20:00:00+01:00\"",
        ])
        #expect(diff.insertedLines.map(\.text) == [
            "status: in_progress   # inline comment survives",
            "updatedAt: \"2026-10-30T20:00:00+01:00\"",
        ])
        #expect(request.metadata.status == .inProgress)
        #expect(request.diagnostics.isEmpty)
        // Comments, unknown fields and body unchanged.
        #expect(request.text.contains("# Kommentar: vom Benutzer eingefügt\n"))
        #expect(request.text.contains("customField: { nested: true, other: 'x' }\n"))
        #expect(request.frontmatter.body.isByteIdentical(to: FrontmatterDocument(text: Fixtures.sampleRequest).body))
    }

    @Test func crlfAndBOMArePreservedOnEdit() throws {
        let crlf = "\u{FEFF}" + Fixtures.sampleRequest.replacingOccurrences(of: "\n", with: "\r\n")
        var data = Data(crlf.utf8)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        var document = try FrontmatterDocument(data: data)
        #expect(document.hasByteOrderMark)
        #expect(document.lineEnding == .crlf)
        #expect(document.data == data)
        try document.setScalar(key: "status", value: "review")
        try document.setScalar(key: "newKey", value: "Wert: mit Doppelpunkt")
        try document.setList(key: "labels", values: ["ios", "ux", "ipad"])
        data = document.data
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = document.text
        #expect(text.contains("status: review   # inline comment survives\r\n"))
        #expect(text.contains("newKey: \"Wert: mit Doppelpunkt\"\r\n---\r\n"))
        #expect(text.contains("labels: [ios, ux, ipad]\r\n"))
        // No bare LF introduced.
        let bytes = Array(data)
        for index in bytes.indices where bytes[index] == 0x0A {
            #expect(index > 0 && bytes[index - 1] == 0x0D)
        }
        #expect(FrontmatterDocument(text: text)["newKey"] == .scalar("Wert: mit Doppelpunkt"))
    }

    @Test func invalidUTF8IsTypedError() {
        #expect(throws: FrontmatterError.invalidUTF8) {
            _ = try FrontmatterDocument(data: Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE]))
        }
    }

    @Test func missingAndMalformedFrontmatterDiagnostics() throws {
        let missing = FrontmatterDocument(text: "# Nur Text\n")
        #expect(missing.state == .absent)
        #expect(missing.diagnostics == [.missingFrontmatter])

        let unterminated = FrontmatterDocument(text: "---\nid: FR-1\n# never closed\n")
        #expect(unterminated.state == .unterminated)
        #expect(unterminated.diagnostics == [.unterminatedFrontmatter])
        var copy = unterminated
        #expect(throws: FrontmatterError.frontmatterUnterminated) { try copy.setScalar(key: "a", value: "b") }

        var malformed = FrontmatterDocument(text: "---\ntitle: \"unclosed\nstatus: [open\n---\nbody\n")
        #expect(malformed.diagnostics.contains { if case .malformedYAML = $0 { true } else { false } })
        #expect(throws: FrontmatterError.self) { try malformed.setScalar(key: "status", value: "done") }

        var duplicate = FrontmatterDocument(text: "---\nstatus: open\nstatus: done\n---\n")
        #expect(duplicate.diagnostics.contains(.duplicateKey("status")))
        #expect(throws: FrontmatterError.duplicateKey("status")) { try duplicate.setScalar(key: "status", value: "x") }

        let list = FrontmatterDocument(text: "---\n- a\n- b\n---\n")
        #expect(list.diagnostics == [.frontmatterNotAMapping])
    }

    @Test func addingKeyToDocumentWithoutFrontmatterKeepsBody() throws {
        let body = "# Titel\r\n\r\nText\r\n"
        var document = FrontmatterDocument(text: body)
        try document.setScalar(key: "status", value: "open")
        #expect(document.text == "---\r\nstatus: open\r\n---\r\n" + body)
        #expect(document.body.isByteIdentical(to: body))
    }

    @Test func removeKeyRemovesContinuationLinesOnly() throws {
        var document = FrontmatterDocument(text: Fixtures.sampleRequest)
        #expect(try document.remove(key: "agentJobIds"))
        #expect(try !document.remove(key: "doesNotExist"))
        let diff = LineDiff(old: Fixtures.sampleRequest, new: document.text)
        #expect(diff.insertedLines.isEmpty)
        #expect(diff.deletedLines.map(\.text) == ["agentJobIds:", "  - job-1", "  - 'job-2'"])
        #expect(document["agentJobIds"] == nil)
        #expect(document["reviewState"] == .scalar("pending"))
    }

    @Test func blockListKeepsIndentationAndFlowListStaysFlow() throws {
        var document = FrontmatterDocument(text: Fixtures.sampleRequest)
        try document.setList(key: "agentJobIds", values: ["job-1", "job: 3", "#4"])
        try document.setList(key: "dependsOn", values: ["FR-0002"])
        let diff = LineDiff(old: Fixtures.sampleRequest, new: document.text)
        #expect(diff.deletedLines.map(\.text) == ["dependsOn: []", "  - 'job-2'"])
        #expect(diff.insertedLines.map(\.text) == ["dependsOn: [FR-0002]", "  - \"job: 3\"", "  - \"#4\""])
        #expect(document["agentJobIds"]?.stringList == ["job-1", "job: 3", "#4"])
        try document.setList(key: "agentJobIds", values: [])
        #expect(document.text.contains("agentJobIds: []\n"))
        #expect(document["agentJobIds"]?.stringList == [])
        try document.setList(key: "flowItems", values: ["a,b", "c"])
        #expect(document.text.contains("flowItems: [\"a,b\", c]\n"))
        #expect(document["flowItems"]?.stringList == ["a,b", "c"])
    }

    @Test func unchangedValueReserialisesIdentically() throws {
        var document = FrontmatterDocument(text: Fixtures.sampleRequest)
        try document.setScalar(key: "title", value: "Senderliste auf dem iPad vergrößern")
        try document.setScalar(key: "priority", value: "medium")
        #expect(document.text.isByteIdentical(to: Fixtures.sampleRequest))
    }

    @Test("Quoting round-trips through YAML", arguments: [
        "plain",
        "Wert: mit Doppelpunkt",
        "trailing colon:",
        "\"quoted\"",
        "it's",
        "'single'",
        "- leading dash",
        "#hash",
        "a # comment-like",
        "Größe ändern – Überblick ß",
        "yes", "No", "null", "~", "true",
        "0004", "1.5", "0x1F", "1:20",
        "2026-10-30",
        "@mention", "`code`", "*bold*", "&anchor", "!tag", "%percent", "{brace}", "[bracket]", "|pipe", ">folded",
        " leading space", "trailing space ",
        "line1\nline2", "tab\there", "back\\slash",
        "",
        "---",
        "emoji 🎬",
    ])
    func quoting(value: String) throws {
        var document = FrontmatterDocument(text: "---\nexisting: x\n---\nbody\n")
        try document.setScalar(key: "value", value: value)
        #expect(document.diagnostics.isEmpty, "\(document.text)")
        #expect(document["value"] == .scalar(value), "\(document.text)")
        try document.setList(key: "list", values: [value, "b"])
        #expect(document["list"]?.stringList == [value, "b"], "\(document.text)")
        #expect(document.body == "body\n")
    }

    @Test func existingQuotingStyleIsPreserved() throws {
        var document = FrontmatterDocument(text: "---\na: 'single'\nb: \"double\"\nc: plain\nd: 2026-10-30\n---\n")
        try document.setScalar(key: "a", value: "neu")
        try document.setScalar(key: "b", value: "neu")
        try document.setScalar(key: "c", value: "neu: wert")
        try document.setScalar(key: "d", value: "2026-11-01")
        #expect(document.text == "---\na: 'neu'\nb: \"neu\"\nc: \"neu: wert\"\nd: 2026-11-01\n---\n")
        try document.setScalar(key: "a", value: "it's")
        #expect(document.text.contains("a: 'it''s'\n"))
        #expect(document["a"] == .scalar("it's"))
    }

    @Test func emptyValueAndCommentOnlyValue() throws {
        var document = FrontmatterDocument(text: "---\nempty:\ncommented:   # note\n---\n")
        #expect(document["empty"] == .null)
        try document.setScalar(key: "empty", value: "x")
        try document.setScalar(key: "commented", value: "wert")
        #expect(document.text == "---\nempty: x\ncommented: wert   # note\n---\n")
    }
}
