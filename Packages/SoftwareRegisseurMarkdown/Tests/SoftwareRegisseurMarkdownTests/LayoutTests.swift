import Foundation
import Testing
@testable import SoftwareRegisseurMarkdown

@Suite("File naming and folder layout")
struct LayoutTests {
    @Test("Slugs", arguments: [
        ("Senderliste auf dem iPad vergrößern", "senderliste-auf-dem-ipad-vergroessern"),
        ("Äpfel, Öl & Übergrößen – Straße", "aepfel-oel-uebergroessen-strasse"),
        ("  --Crème brûlée!!  ", "creme-brulee"),
        ("Bug #12: Crash beim Start", "bug-12-crash-beim-start"),
        ("ÄÖÜ", "aeoeue"),
        ("🎬🎬", ""),
        ("a___b...c", "a-b-c"),
    ])
    func slug(input: String, expected: String) {
        #expect(Slug.make(from: input) == expected)
    }

    @Test func slugLengthLimit() {
        let title = "Eine sehr lange Überschrift die deutlich mehr als sechzig Zeichen enthält und abgeschnitten wird"
        let slug = Slug.make(from: title)
        #expect(slug.count <= 60)
        #expect(!slug.hasSuffix("-"))
        #expect(slug == "eine-sehr-lange-ueberschrift-die-deutlich-mehr-als-sechzig")
        let noSpaces = String(repeating: "x", count: 80)
        #expect(Slug.make(from: noSpaces).count == 60)
        #expect(Slug.make(from: String(repeating: "ab-", count: 40)).count <= 60)
        #expect(!Slug.make(from: String(repeating: "ab-", count: 40)).hasSuffix("-"))
    }

    @Test func requestFileNames() throws {
        let id = HumanID(prefix: .fr, number: 1)
        #expect(RequestFileName.make(id: id, title: "Senderliste auf dem iPad vergrößern")
            == "FR-0001-senderliste-auf-dem-ipad-vergroessern.md")
        #expect(RequestFileName.make(id: id, title: "🎬") == "FR-0001.md")
        let parsed = try #require(RequestFileName.parse("BUG-0002-issue.md"))
        #expect(parsed.id == HumanID(prefix: .bug, number: 2))
        #expect(parsed.slug == "issue")
        #expect(RequestFileName.parse("FR-0001.md")?.slug == "")
        #expect(RequestFileName.parse("0001-database.md") == nil)
        #expect(RequestFileName.parse("FR-0001-x.txt") == nil)
    }

    @Test func relativePathValidation() throws {
        #expect(try RelativePath("docs/adr").string == "docs/adr")
        #expect(try RelativePath("docs/adr/").components == ["docs", "adr"])
        #expect(try RelativePath("docs/adr").directoryString == "docs/adr/")
        #expect(try RelativePath(".").isRoot)
        #expect(throws: RelativePathError.empty) { try RelativePath("") }
        #expect(throws: RelativePathError.absolute) { try RelativePath("/etc/passwd") }
        #expect(throws: RelativePathError.homeDirectory) { try RelativePath("~/x") }
        #expect(throws: RelativePathError.parentTraversal) { try RelativePath("docs/../../x") }
        #expect(throws: RelativePathError.parentTraversal) { try RelativePath("..") }
        #expect(throws: RelativePathError.currentDirectoryComponent) { try RelativePath("docs/./adr") }
        #expect(throws: RelativePathError.emptyComponent) { try RelativePath("docs//adr") }
        #expect(throws: RelativePathError.emptyComponent) { try RelativePath("docs/adr//") }
        #expect(throws: RelativePathError.invalidCharacter("\\")) { try RelativePath("docs\\adr") }
        #expect(throws: RelativePathError.self) { try RelativePath("docs/a\nb") }
        let base = try RelativePath("docs/requests/open")
        #expect(throws: RelativePathError.self) { try base.appending(component: "../x.md") }
        #expect(throws: RelativePathError.self) { try base.appending(component: "a/b.md") }
        #expect(try base.appending(component: "FR-0001-x.md").string == "docs/requests/open/FR-0001-x.md")

        let json = try JSONEncoder().encode(base)
        #expect(String(decoding: json, as: UTF8.self) == "\"docs\\/requests\\/open\"")
        #expect(try JSONDecoder().decode(RelativePath.self, from: json) == base)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RelativePath.self, from: Data("\"../x\"".utf8)) }
    }

    @Test func defaultFolderMapping() throws {
        let layout = FolderLayout.default
        let expected: [WorkItemStatus: String?] = [
            .inbox: "docs/requests/open", .open: "docs/requests/open", .queued: "docs/requests/open",
            .scheduled: "docs/requests/open", .inProgress: "docs/requests/in-progress",
            .waitingApproval: "docs/requests/in-progress", .implementationFinished: "docs/requests/review",
            .review: "docs/requests/review", .integrated: "docs/requests/done", .done: "docs/requests/done",
            .blocked: nil, .failed: nil, .cancelled: nil, .paused: nil,
        ]
        for status in WorkItemStatus.allCases {
            #expect(layout.folder(for: status)?.string == expected[status]!, "\(status)")
        }
        let current = try RelativePath("docs/requests/in-progress")
        #expect(try layout.destination(for: .blocked, fileName: "FR-0001-a.md", currentFolder: current).string
            == "docs/requests/in-progress/FR-0001-a.md")
        #expect(try layout.destination(for: .done, fileName: "FR-0001-a.md", currentFolder: current).string
            == "docs/requests/done/FR-0001-a.md")
        #expect(layout.statuses(inFolder: try RelativePath("docs/requests/done")) == [.integrated, .done])
        #expect(layout.requestFolders.map(\.string)
            == ["docs/requests/open", "docs/requests/in-progress", "docs/requests/review", "docs/requests/done"])
        #expect(layout.validate().isEmpty)
    }

    @Test func customGermanFolders() throws {
        var layout = FolderLayout(
            adrPath: try RelativePath("dokumentation/entscheidungen"),
            requestsRoot: try RelativePath("aufgaben"),
            statusFolders: [
                .open: try RelativePath("ideen/offen"),
                .inProgress: try RelativePath("in-arbeit"),
                .review: try RelativePath("prüfung"),
                .done: try RelativePath("features/erledigt"),
                .blocked: try RelativePath("blockiert"),
            ]
        )
        #expect(layout.folder(for: .open)?.string == "aufgaben/ideen/offen")
        #expect(layout.folder(for: .done)?.string == "aufgaben/features/erledigt")
        #expect(layout.folder(for: .blocked)?.string == "aufgaben/blockiert")
        #expect(layout.folder(for: .queued) == nil)
        #expect(try layout.destination(for: .done, fileName: "FR-0003-x.md",
                                       currentFolder: try RelativePath("aufgaben/prüfung")).string
            == "aufgaben/features/erledigt/FR-0003-x.md")

        let decoded = try JSONDecoder().decode(FolderLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)

        layout.adrPath = try RelativePath("aufgaben/ideen/offen")
        #expect(layout.validate() == [.adrFolderOverlapsRequests(try RelativePath("aufgaben/ideen/offen"))])
    }
}
