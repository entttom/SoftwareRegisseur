import Foundation
import Testing
@testable import SoftwareRegisseurMarkdown

@Suite("Request model")
struct RequestTests {
    @Test func typedRead() throws {
        let request = RequestDocument(text: Fixtures.sampleRequest)
        let metadata = request.metadata
        #expect(metadata.id == HumanID(prefix: .fr, number: 1))
        #expect(metadata.uuid == UUID(uuidString: "4f9b2c1e-8a3d-4e6f-9b2a-1c3d5e7f9a0b"))
        #expect(metadata.type == .feature)
        #expect(metadata.status == .open)
        #expect(metadata.title == "Senderliste auf dem iPad vergrößern")
        #expect(metadata.createdAt.map { RequestTimestamp.format($0, timeZone: Fixtures.vienna) }
            == "2026-10-29T20:00:00+01:00")
        #expect(metadata.priority == .medium)
        #expect(metadata.labels == ["ios", "ux"])
        #expect(metadata.dependsOn == [])
        #expect(metadata.agentJobIds == ["job-1", "job-2"])
        #expect(metadata.reviewState == "pending")
        #expect(metadata.unknownFields.map(\.key) == ["customField", "x-team"])
        #expect(metadata.unknownFields.last?.value == .scalar("Plattform"))
        #expect(request.diagnostics.isEmpty)
    }

    @Test func allWorkItemStatusesAreAccepted() {
        let expected = [
            "inbox", "open", "queued", "scheduled", "in_progress", "waiting_approval", "implementation_finished",
            "review", "integrated", "done", "blocked", "failed", "cancelled", "paused",
        ]
        #expect(WorkItemStatus.allCases.map(\.rawValue) == expected)
        for raw in expected {
            let text = Fixtures.sampleRequest.replacingOccurrences(of: "status: open", with: "status: \(raw)")
            #expect(RequestDocument(text: text).metadata.status?.rawValue == raw)
        }
        // Job-only states (ADR-0012) are not WorkItem statuses.
        for jobState in ["pendingMac", "waiting_quota", "needs_configuration", "running"] {
            #expect(WorkItemStatus(rawValue: jobState) == nil)
        }
    }

    @Test func validationDiagnostics() {
        let text = """
        ---
        id: XX-12
        uuid: not-a-uuid
        type: epic
        status: pendingMac
        createdAt: gestern
        priority: critical
        labels: ios
        ---
        """
        let request = RequestDocument(text: text)
        let codes = request.diagnostics.map(\.code)
        #expect(codes.contains(.invalidValue(field: "id", value: "XX-12")))
        #expect(codes.contains(.invalidValue(field: "uuid", value: "not-a-uuid")))
        #expect(codes.contains(.invalidValue(field: "type", value: "epic")))
        #expect(codes.contains(.invalidValue(field: "status", value: "pendingMac")))
        #expect(codes.contains(.invalidValue(field: "createdAt", value: "gestern")))
        #expect(codes.contains(.missingField("title")))
        #expect(codes.contains(.missingField("updatedAt")))
        #expect(codes.contains(.wrongValueKind(field: "labels")))
        #expect(request.diagnostics.contains(RequestDiagnostic(.warning, .invalidValue(field: "priority", value: "critical"))))
        #expect(request.hasErrors)

        let mismatch = Fixtures.sampleRequest.replacingOccurrences(of: "type: feature", with: "type: bug")
        #expect(RequestDocument(text: mismatch).diagnostics
            == [RequestDiagnostic(.warning, .idPrefixMismatch(id: "FR-0001", type: "bug"))])

        let noFrontmatter = RequestDocument(text: "# Nur eine Notiz\n")
        #expect(noFrontmatter.diagnostics.first == RequestDiagnostic(.error, .frontmatter(.missingFrontmatter)))
    }

    @Test func humanIDs() {
        #expect(HumanID("FR-0001")?.description == "FR-0001")
        #expect(HumanID("BUG-12")?.description == "BUG-0012")
        #expect(HumanID("IMP-12345")?.description == "IMP-12345")
        #expect(HumanID("TODO-0003")?.prefix.requestType == .todo)
        #expect(HumanID("NOTE-0001")?.prefix == .note)
        #expect(HumanID("fr-0001") == nil)
        #expect(HumanID("ADR-0001") == nil)
        #expect(HumanID("FR-") == nil)
        let existing = ["FR-0001-a.md", "FR-0007-b.md", "BUG-0010-c.md", "README.md", "FR-0003"]
        #expect(HumanID.next(prefix: .fr, existing: existing).description == "FR-0008")
        #expect(HumanID.next(prefix: .bug, existing: existing).description == "BUG-0011")
        #expect(HumanID.next(prefix: .imp, existing: existing).description == "IMP-0001")
        #expect(HumanID.next(prefix: .fr, existing: existing, highWaterMark: 20).description == "FR-0021")
        #expect(RequestType.allCases.map(\.idPrefix.rawValue) == ["FR", "BUG", "TODO", "IMP", "NOTE"])
    }

    @Test func renderNewRequest() throws {
        let draft = RequestDraft(
            uuid: UUID(uuidString: "4F9B2C1E-8A3D-4E6F-9B2A-1C3D5E7F9A0B")!,
            type: .feature,
            title: "Senderliste: \"groß\" auf dem iPad",
            labels: ["ios", "ux"],
            createdAt: Fixtures.fixedDate,
            description: "Die Liste ist zu klein.",
            problem: "Schwer lesbar.",
            goal: "",
            acceptanceCriteria: ["Volle Breite", "  ", "Dynamic Type"],
            testNotes: "Auf iPad Pro testen.",
            references: []
        )
        let text = try RequestRenderer.render(draft, id: HumanID(prefix: .fr, number: 42), timeZone: Fixtures.vienna)
        let expected = """
        ---
        id: FR-0042
        uuid: "4f9b2c1e-8a3d-4e6f-9b2a-1c3d5e7f9a0b"
        type: feature
        status: open
        title: "Senderliste: \\"groß\\" auf dem iPad"
        createdAt: "2026-10-30T20:00:00+01:00"
        updatedAt: "2026-10-30T20:00:00+01:00"
        priority: medium
        labels: [ios, ux]
        dependsOn: []
        agentJobIds: []
        reviewState: pending
        ---

        # FR-0042: Senderliste: "groß" auf dem iPad

        ## Beschreibung

        Die Liste ist zu klein.

        ## Problem

        Schwer lesbar.

        ## Ziel

        ## Akzeptanzkriterien

        - Volle Breite
        - Dynamic Type

        ## Testhinweise

        Auf iPad Pro testen.

        """
        #expect(text == expected)
        let parsed = RequestDocument(text: text)
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.metadata.title == "Senderliste: \"groß\" auf dem iPad")
        #expect(parsed.sections.titles == ["Beschreibung", "Problem", "Ziel", "Akzeptanzkriterien", "Testhinweise"])
        #expect(parsed.sectionContent(.acceptanceCriteria) == "- Volle Breite\n- Dynamic Type")

        let crlf = try RequestRenderer.render(draft, id: HumanID(prefix: .fr, number: 42), timeZone: Fixtures.vienna,
                                              lineEnding: .crlf)
        #expect(crlf == expected.replacingOccurrences(of: "\n", with: "\r\n"))

        #expect(throws: RequestRenderError.idPrefixMismatch(id: HumanID(prefix: .bug, number: 1), type: .feature)) {
            _ = try RequestRenderer.render(draft, id: HumanID(prefix: .bug, number: 1), timeZone: Fixtures.vienna)
        }
    }

    @Test func sectionReplacementPreservesUserSections() {
        var request = RequestDocument(text: Fixtures.sampleRequest)
        let before = request.sections
        #expect(before.titles == ["Beschreibung", "Eigene Notizen", "Akzeptanzkriterien"])
        request.setSectionContent("Neue Beschreibung.\nZweite Zeile.", for: "beschreibung")
        request.setSectionContent("- Erstes Kriterium", for: RequestSection.acceptanceCriteria.rawValue)
        request.setSectionContent("Ergänzt.", for: RequestSection.references.rawValue)
        let after = request.sections
        #expect(after.titles == ["Beschreibung", "Eigene Notizen", "Akzeptanzkriterien", "Referenzen"])
        #expect(after.content(of: "Beschreibung") == "Neue Beschreibung.\nZweite Zeile.")
        #expect(after.section(titled: "Eigene Notizen") == before.section(titled: "Eigene Notizen"))
        #expect(after.preamble == before.preamble)
        #expect(request.sectionContent(.references) == "Ergänzt.")
        let diff = LineDiff(old: Fixtures.sampleRequest, new: request.text)
        #expect(diff.deletedLines.map(\.text) == [
            "Die Senderliste ist auf großen Displays zu klein.", "- Liste nutzt die volle Breite",
        ])
        #expect(diff.insertedLines.map(\.text) == [
            "Neue Beschreibung.", "Zweite Zeile.", "- Erstes Kriterium", "", "## Referenzen", "", "Ergänzt.",
        ])
    }

    @Test func changeDetection() throws {
        let old = RequestDocument(text: Fixtures.sampleRequest)
        var new = old
        #expect(!RequestChangeReport.compare(old, new).hasChanges)

        // Requoting and CRLF conversion are not semantic changes.
        let requoted = RequestDocument(text: Fixtures.sampleRequest
            .replacingOccurrences(of: "priority: medium", with: "priority: \"medium\"")
            .replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(!RequestChangeReport.compare(old, requoted).hasChanges)

        try new.setStatus(.review, updatedAt: Fixtures.fixedDate, timeZone: Fixtures.vienna)
        try new.frontmatter.setScalar(key: "title", value: "Neuer Titel")
        new.setSectionContent("Geändert.", for: "Beschreibung")
        new.setSectionContent("Neu.", for: "Testhinweise")
        var sections = new.sections
        sections.removeSection(titled: "Eigene Notizen")
        new.sections = sections

        let report = RequestChangeReport.compare(old, new)
        #expect(report.changedKeys == ["status", "title", "updatedAt"])
        #expect(report.statusChange?.old == .scalar("open"))
        #expect(report.statusChange?.new == .scalar("review"))
        #expect(report.titleChange?.new == .scalar("Neuer Titel"))
        #expect(!report.isDifferentRequest)
        #expect(Set(report.sectionChanges) == [
            .init(title: "Beschreibung", kind: .modified),
            .init(title: "Eigene Notizen", kind: .removed),
            .init(title: "Testhinweise", kind: .added),
        ])

        var other = old
        try other.frontmatter.setScalar(key: "uuid", value: UUID().uuidString)
        #expect(RequestChangeReport.compare(old, other).isDifferentRequest)
    }
}
