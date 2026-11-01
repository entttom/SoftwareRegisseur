import XCTest

/// A10 (lokaler Teil): a note captured without Mac and without iCloud is stored locally, shows up in the
/// Inbox and survives a relaunch. A26: the sync status is visible; an unsigned build explains that
/// iCloud sync is not available instead of pretending to sync.
@MainActor
final class QuickCaptureAndSyncTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    func testInboxCaptureAppearsAndSurvivesRelaunch() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.open(.inbox, in: app)

        let note = "UI-Test-Notiz \(UUID().uuidString.prefix(8))"
        let field = app.textFields["inbox.newNote"].exists ? app.textFields["inbox.newNote"] : app.textViews["inbox.newNote"]
        XCTAssertTrue(field.waitForExistence(timeout: UITest.timeout))
        let capture = app.buttons["inbox.capture"]
        XCTAssertFalse(capture.isEnabled, "Leere Notiz darf nicht ablegbar sein")
        field.tap()
        field.typeText(note)
        XCTAssertTrue(capture.isEnabled)
        capture.tap()
        UITest.attachScreenshot("Nach „In Inbox ablegen“", of: app, to: self)
        // Saving clears the field; the button is disabled again.
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: capture)],
                                       timeout: UITest.timeout) == .completed, "Notiz wurde nicht abgelegt")

        let row = UITest.row(containing: note, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: UITest.timeout), "Notiz erscheint nicht in der Inbox")

        app.terminate()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.open(.inbox, in: app)
        XCTAssertTrue(UITest.row(containing: note, in: app).waitForExistence(timeout: UITest.timeout),
                      "Notiz nach Neustart verloren")
    }

    func testQuickCaptureFromOverviewLandsInInbox() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.open(.overview, in: app)

        app.buttons["overview.quickCapture"].tap()
        let field = app.textFields["quickCapture.text"].exists ? app.textFields["quickCapture.text"] : app.textViews["quickCapture.text"]
        XCTAssertTrue(field.waitForExistence(timeout: UITest.timeout))
        let note = "Schnellerfassung \(UUID().uuidString.prefix(8))"
        field.tap()
        field.typeText(note)
        app.buttons["quickCapture.save"].tap()
        XCTAssertFalse(app.buttons["quickCapture.save"].waitForExistence(timeout: 2), "Blatt bleibt offen")

        UITest.open(.inbox, in: app)
        XCTAssertTrue(UITest.row(containing: note, in: app).waitForExistence(timeout: UITest.timeout))
    }

    func testSyncStatusIsVisibleOnOverviewAndSettings() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)

        for section in [Section.overview, .settings] {
            UITest.open(section, in: app)
            let unavailable = app.descendants(matching: .any)["sync.unavailable"]
            let lastSync = app.descendants(matching: .any)["sync.lastSync"]
            XCTAssertTrue(unavailable.waitForExistence(timeout: UITest.timeout) || lastSync.exists,
                          "Kein Synchronisierungsstatus in „\(section.title)“")
            if unavailable.exists {
                // Unsigned/placeholder build: honest explanation, no sync button.
                XCTAssertTrue(unavailable.label.contains("iCloud-Synchronisierung nicht verfügbar"), unavailable.label)
                XCTAssertFalse(app.buttons["sync.now"].exists)
            } else {
                XCTAssertTrue(app.buttons["sync.now"].exists, "„Jetzt synchronisieren“ fehlt")
            }
        }
    }
}
