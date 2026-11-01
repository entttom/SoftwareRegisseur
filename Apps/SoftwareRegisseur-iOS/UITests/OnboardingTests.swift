import XCTest

/// Onboarding on the first launch (spec B, H2, I, P; Q4): six pages with „Weiter“, „Zurück“ from the
/// second page, „Ändern“ in the summary, „Los geht’s“ opens the app. No page triggers a system prompt;
/// microphone and speech recognition are asked for only when a dictation starts (PermissionFlowTests).
@MainActor
final class OnboardingTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    private let titles = [
        "Willkommen bei Software Regisseur", "iCloud-Synchronisierung", "Mac verbinden",
        "Diktat", "Eigene KI-Schlüssel",
    ]

    func testWalkThroughEveryPageWithoutSystemPrompt() {
        let app = UITest.makeApp(extraArguments: ["-SROnboarding", "YES"])
        app.launch()
        UITest.waitUntilReady(app)

        let continueButton = app.buttons["onboarding.continue"]
        let title = app.staticTexts["onboarding.title"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: UITest.timeout), "Einrichtung erscheint nicht beim ersten Start")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Tabs sind während der Einrichtung sichtbar")
        XCTAssertFalse(app.buttons["onboarding.back"].isHittable, "„Zurück“ auf der ersten Seite")

        for (index, expected) in titles.enumerated() {
            XCTAssertTrue(title.waitForExistence(timeout: UITest.timeout))
            XCTAssertEqual(title.label, expected, "Seite \(index + 1)")
            XCTAssertEqual(continueButton.label, "Weiter")
            UITest.attachScreenshot("Einrichtung \(index + 1) – \(expected)", of: app, to: self)
            continueButton.tap()
            XCTAssertFalse(UITest.springboard.alerts.firstMatch.waitForExistence(timeout: 1),
                           "Systemabfrage während der Einrichtung")
        }

        // Summary: fixtures report a Mac host.
        XCTAssertTrue(UITest.container("onboarding.summary", in: app).waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(continueButton.label, "Los geht’s")
        XCTAssertTrue(UITest.element(containing: "Studio-Mac", in: app).exists, "Verbundener Mac fehlt in der Zusammenfassung")
        UITest.attachScreenshot("Einrichtung 6 – Zusammenfassung", of: app, to: self)

        // „Ändern“ jumps back to the page; „Zurück“ goes one page back.
        app.buttons["onboarding.summary.change.dictation"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(title.label, "Diktat")
        app.buttons["onboarding.dictation.openAI"].tap()
        XCTAssertTrue(app.buttons["onboarding.dictation.openAI"].isSelected)
        app.buttons["onboarding.back"].tap()
        XCTAssertEqual(title.label, "Mac verbinden")
        continueButton.tap()
        continueButton.tap()
        continueButton.tap()
        XCTAssertTrue(UITest.element(containing: "OpenAI Speech-to-Text", in: app).waitForExistence(timeout: UITest.timeout),
                      "Gewählte Spracherkennung fehlt in der Zusammenfassung")

        continueButton.tap()
        XCTAssertTrue(UITest.navigationBar(Section.overview.title, in: app).waitForExistence(timeout: UITest.timeout),
                      "„Los geht’s“ öffnet nicht die Übersicht")
        XCTAssertFalse(continueButton.exists)
    }

    func testReopenFromSettings() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        XCTAssertFalse(app.buttons["onboarding.continue"].waitForExistence(timeout: 2),
                       "Mit Testdaten startet die App ohne Einrichtung")
        UITest.open(.settings, in: app)
        let reopen = app.buttons["settings.reopenOnboarding"]
        XCTAssertTrue(UITest.scrollTo(reopen, in: app), "„Einrichtung erneut ansehen“ nicht erreichbar")
        reopen.tap()
        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: UITest.timeout))
        XCTAssertEqual(app.staticTexts["onboarding.title"].label, titles[0])
    }
}
