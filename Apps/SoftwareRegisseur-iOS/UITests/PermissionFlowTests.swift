import XCTest

/// Spec Q4 / App Review 5.1.1(iv), A07 (Fehlerfall): own explanation screen before the microphone
/// prompt with exactly one neutral button „Weiter“, no way to skip; „Weiter“ shows the system prompt
/// immediately; after a denial a Settings link and no second request.
@MainActor
final class PermissionFlowTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    func testExplanationOffersOnlyWeiterAndDeniedPathLinksToSettings() {
        let app = UITest.makeApp()
        // Same as `xcrun simctl privacy <udid> reset microphone <bundle id>`; terminates the app if running.
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        UITest.waitUntilReady(app)
        UITest.openPermissionScreen(in: app)

        // Explanation step: one button, neutral title, no skip/later/close.
        let continueButton = app.buttons["permission.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(continueButton.label, "Weiter")
        XCTAssertTrue(app.staticTexts["permission.title"].exists)
        let screen = UITest.container("permission.screen", in: app)
        XCTAssertTrue(screen.exists)
        XCTAssertEqual(screen.buttons.count, 1, "Erklärbildschirm darf nur „Weiter“ anbieten")
        for forbidden in ["Später", "Nicht jetzt", "Überspringen", "Schließen", "Abbrechen", "Erlauben", "Zugriff gewähren"] {
            XCTAssertFalse(app.buttons[forbidden].exists, "Unzulässige Taste „\(forbidden)“")
        }
        // No swipe-to-dismiss: the screen stays after a downward swipe.
        screen.swipeDown(velocity: .fast)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2))
        UITest.attachScreenshot("Erklärbildschirm Mikrofon", of: app, to: self)

        // „Weiter“ → system prompt right away.
        UITest.scrollTo(continueButton, in: app, container: screen)
        continueButton.tap()
        let alert = UITest.springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: UITest.timeout), "Systemabfrage erscheint nicht nach „Weiter“")
        UITest.attachScreenshot("Systemabfrage Mikrofon", of: app, to: self)
        let deny = alert.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Don' OR label BEGINSWITH 'Nicht' OR label CONTAINS[c] 'not allow'"
        )).firstMatch
        XCTAssertTrue(deny.exists, "Ablehnen-Taste der Systemabfrage nicht gefunden: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        deny.tap()

        // Denied: explanation of the consequence, Settings link, closing only now.
        XCTAssertTrue(app.staticTexts["permission.deniedTitle"].waitForExistence(timeout: UITest.timeout))
        XCTAssertTrue(app.buttons["permission.openSettings"].exists, "Link in die Einstellungen fehlt")
        XCTAssertEqual(app.buttons["permission.openSettings"].label, "Einstellungen öffnen")
        XCTAssertTrue(app.buttons["permission.close"].exists)
        XCTAssertFalse(continueButton.exists, "Nach Ablehnung darf nicht erneut gefragt werden")
        UITest.attachScreenshot("Abgelehnt mit Einstellungs-Link", of: app, to: self)

        // Closing returns to „Diktat“; a new attempt shows the denial again, without a second system prompt.
        app.buttons["permission.close"].tap()
        XCTAssertTrue(UITest.navigationBar(Section.dictation.title, in: app).waitForExistence(timeout: UITest.timeout))
        app.buttons["dictation.start"].tap()
        XCTAssertTrue(app.staticTexts["permission.deniedTitle"].waitForExistence(timeout: UITest.timeout))
        XCTAssertFalse(UITest.springboard.alerts.firstMatch.waitForExistence(timeout: 2), "Systemabfrage erneut gezeigt")
        XCTAssertFalse(app.buttons["permission.continue"].exists)
        app.buttons["permission.close"].tap()
    }
}
