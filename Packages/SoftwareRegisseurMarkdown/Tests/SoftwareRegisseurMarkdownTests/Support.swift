import Foundation
@testable import SoftwareRegisseurMarkdown

enum Fixtures {
    static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/repo")
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    static var adrFileNames: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("adr").path))?
            .filter { $0.hasSuffix(".md") }.sorted() ?? []
    }

    static var allMarkdownPaths: [String] {
        adrFileNames.map { "adr/" + $0 } + ["AGENTS.md", "CLAUDE.md"]
    }

    static let sampleRequest = """
    ---
    id: FR-0001
    uuid: "4f9b2c1e-8a3d-4e6f-9b2a-1c3d5e7f9a0b"
    type: feature
    # Kommentar: vom Benutzer eingefügt
    status: open   # inline comment survives
    title: "Senderliste auf dem iPad vergrößern"
    createdAt: "2026-10-29T20:00:00+01:00"
    updatedAt: "2026-10-29T20:00:00+01:00"
    priority: medium
    labels: [ios, ux]
    dependsOn: []
    agentJobIds:
      - job-1
      - 'job-2'
    reviewState: pending
    customField: { nested: true, other: 'x' }
    x-team: Plattform
    ---

    # FR-0001: Senderliste auf dem iPad vergrößern

    ## Beschreibung

    Die Senderliste ist auf großen Displays zu klein.

    ## Eigene Notizen

    Diese Benutzersektion muss erhalten bleiben.

    ```markdown
    ## Kein Abschnitt (im Codeblock)
    ```

    ## Akzeptanzkriterien

    - Liste nutzt die volle Breite

    """

    static let fixedDate = Date(timeIntervalSince1970: 1_793_386_800) // 2026-10-30T20:00:00+01:00
    static let vienna = TimeZone(identifier: "Europe/Vienna")!
}

extension String {
    var bytes: [UInt8] { Array(utf8) }
}
