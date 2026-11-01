import XCTest

/// Spec P (iPhone views 1–8), ADR-0025: every section is reachable on iPhone (tabs + „Mehr“) and iPad
/// (sidebar-adaptable tabs); a pushed screen has exactly one back button (no nested stacks).
@MainActor
final class NavigationTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    func testAllEightSectionsAreReachable() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        let compact = UITest.usesCompactTabs(app)

        for section in Section.allCases {
            UITest.open(section, in: app)
            let expectedBackButtons = compact && !section.isCompactPrimary ? 1 : 0
            XCTAssertEqual(UITest.backButtons(in: app).count, expectedBackButtons,
                           "Falsche Zahl an Zurück-Tasten in „\(section.title)“")
        }
        UITest.attachScreenshot("Letzter Bereich", of: app, to: self)
    }

    func testInitialTabLaunchArgumentOpensSection() {
        let app = UITest.makeApp(initialTab: .settings)
        app.launch()
        UITest.waitUntilReady(app)
        XCTAssertTrue(UITest.navigationBar(Section.settings.title, in: app).waitForExistence(timeout: UITest.timeout))
    }

    /// Übersicht → Projekt: pushed on the overview's own stack on iPhone and iPad.
    func testPushedProjectDetailHasExactlyOneBackButton() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.open(.overview, in: app)

        let projectRow = UITest.row(containing: Fixture.project, in: app)
        XCTAssertTrue(UITest.scrollTo(projectRow, in: app, container: UITest.container("overview.list", in: app)))
        projectRow.tap()
        XCTAssertTrue(UITest.navigationBar(Fixture.project, in: app).waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(UITest.backButtons(in: app).count, 1)

        UITest.backButtons(in: app).firstMatch.tap()
        XCTAssertTrue(UITest.navigationBar(Section.overview.title, in: app).waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(UITest.backButtons(in: app).count, 0)
    }

    /// Aufgaben → Aufgabe: pushed on the iPhone (one back button), detail column on the iPad (none).
    func testTaskDetailNavigation() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.openTask(Fixture.projectTask, in: app)
        let expected = UITest.usesCompactTabs(app) ? 1 : 0
        XCTAssertEqual(UITest.backButtons(in: app).count, expected)
    }

    /// Compact layout only: „Mehr“ → Projekte → Projekt keeps one stack (no second navigation bar).
    func testMoreSectionPushHasExactlyOneBackButton() throws {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        try XCTSkipUnless(UITest.usesCompactTabs(app), "Nur im kompakten Layout (iPhone)")

        UITest.open(.projects, in: app)
        XCTAssertEqual(UITest.backButtons(in: app).count, 1)
        let projectRow = UITest.row(containing: Fixture.project, in: app)
        XCTAssertTrue(projectRow.waitForExistence(timeout: UITest.timeout))
        projectRow.tap()
        XCTAssertTrue(UITest.navigationBar(Fixture.project, in: app).waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(UITest.backButtons(in: app).count, 1)
        XCTAssertEqual(app.navigationBars.count, 1, "Zweite Navigationsleiste (verschachtelter Stack)")
    }
}
