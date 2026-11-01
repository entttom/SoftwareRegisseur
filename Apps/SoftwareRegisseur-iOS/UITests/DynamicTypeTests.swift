import XCTest

/// A29 Dynamic Type: at the largest accessibility size (AX5 / „AccessibilityXXXL“) the key screens keep
/// their critical information and the permission „Weiter“ button stays reachable (spec Q4).
@MainActor
final class DynamicTypeTests: XCTestCase {
    static let largest = "UICTContentSizeCategoryAccessibilityXXXL"

    nonisolated override func setUp() {
        continueAfterFailure = true
    }

    func testOverviewShowsCountsAndSyncStatus() throws {
        let app = launch()
        UITest.open(.overview, in: app)
        let list = UITest.container("overview.list", in: app)
        let sync = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'sync.unavailable' OR identifier == 'sync.lastSync'")).firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: UITest.timeout), "Synchronisierungsstatus fehlt")
        for tab in ["inbox", "tasks", "review"] {
            let tile = app.buttons["overview.count.\(tab)"]
            XCTAssertTrue(UITest.scrollTo(tile, in: app, container: list), "Zähler „\(tab)“ nicht erreichbar")
            XCTAssertFalse(tile.label.isEmpty)
            XCTAssertFalse((tile.value as? String ?? "").isEmpty, "Zahl fehlt bei „\(tile.label)“")
        }
        UITest.attachScreenshot("Übersicht AX5", of: app, to: self)
        try auditText(app, name: "Übersicht AX5")
    }

    func testTaskListAndDetailShowTitleAndStatus() throws {
        let app = launch()
        UITest.open(.tasks, in: app)
        let row = UITest.row(containing: Fixture.projectTask, in: app)
        XCTAssertTrue(UITest.scrollTo(row, in: app), "Aufgabe nicht erreichbar")
        // Title, status and priority stay in the row (stacked, not truncated away).
        XCTAssertTrue(row.label.contains("Offen"), row.label)
        XCTAssertTrue(row.label.contains("Hoch"), row.label)
        UITest.attachScreenshot("Aufgaben AX5", of: app, to: self)
        try auditText(app, name: "Aufgaben AX5")

        row.tap()
        XCTAssertTrue(UITest.container("task.detail", in: app).waitForExistence(timeout: UITest.timeout))
        let start = app.buttons["task.startAgent"]
        XCTAssertTrue(UITest.scrollTo(start, in: app, container: UITest.container("task.detail", in: app)),
                      "„Mit Agent umsetzen“ bei größter Schrift nicht erreichbar")
        UITest.attachScreenshot("Aufgabendetail AX5", of: app, to: self)
    }

    func testAgentLaunchSubmitReachable() {
        let app = launch()
        UITest.openTask(Fixture.projectTask, in: app)
        UITest.openAgentLaunch(in: app)
        let submit = app.buttons["agentLaunch.submit"]
        XCTAssertTrue(UITest.scrollTo(submit, in: app, container: UITest.container("agentLaunch.form", in: app), maxSwipes: 30),
                      "Startknopf bei größter Schrift nicht erreichbar")
        UITest.attachScreenshot("Mit Agent umsetzen AX5", of: app, to: self)
        app.buttons["agentLaunch.close"].tap()
    }

    func testPermissionWeiterIsHittable() throws {
        let app = UITest.makeApp(contentSize: Self.largest)
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        UITest.waitUntilReady(app)
        UITest.openPermissionScreen(in: app)
        let continueButton = app.buttons["permission.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: UITest.timeout))
        XCTAssertTrue(UITest.scrollTo(continueButton, in: app, container: UITest.container("permission.screen", in: app)),
                      "„Weiter“ bei größter Schrift nicht erreichbar")
        XCTAssertTrue(continueButton.isHittable)
        XCTAssertEqual(continueButton.label, "Weiter")
        UITest.attachScreenshot("Erklärbildschirm AX5", of: app, to: self)
        try auditText(app, name: "Erklärbildschirm AX5")
    }

    /// Onboarding at AX5: every page scrolls, „Weiter“ stays reachable under the page.
    func testOnboardingPagesStayUsable() throws {
        let app = UITest.makeApp(contentSize: Self.largest, extraArguments: ["-SROnboarding", "YES"])
        app.launch()
        UITest.waitUntilReady(app)
        let continueButton = app.buttons["onboarding.continue"]
        for page in 1...6 {
            XCTAssertTrue(continueButton.waitForExistence(timeout: UITest.timeout), "„Weiter“ fehlt auf Seite \(page)")
            XCTAssertTrue(continueButton.isHittable, "„Weiter“ auf Seite \(page) nicht erreichbar")
            XCTAssertTrue(app.staticTexts["onboarding.title"].exists, "Seitentitel fehlt auf Seite \(page)")
            UITest.attachScreenshot("Einrichtung \(page) AX5", of: app, to: self)
            if page == 1 || page == 6 { try auditText(app, name: "Einrichtung \(page) AX5") }
            if page < 6 { continueButton.tap() }
        }
        XCTAssertEqual(continueButton.label, "Los geht’s")
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = UITest.makeApp(contentSize: Self.largest)
        app.launch()
        UITest.waitUntilReady(app)
        return app
    }

    /// Dynamic Type and clipped-text audit at the largest size.
    private func auditText(_ app: XCUIApplication, name: String) throws {
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped]) { issue in
            let line = "[\(name)] \(issue.auditType.germanName): \(issue.compactDescription) – Element: \(issue.element?.debugLabel ?? "–")"
            if let reason = AuditExclusions.reason(for: issue) {
                print("Audit ausgenommen: \(line) – Grund: \(reason)")
                return true
            }
            print("Audit-Befund: \(line)")
            return false
        }
    }
}
