import XCTest

/// Spec J2a / ADR-0006, A37, A40, A42: the start sheet uses the capabilities reported by the Mac
/// (fixture host „Studio-Mac“). A blocked model/effort combination cannot be submitted, and an agent
/// without effort support shows „Anbieterstandard – nicht einstellbar“ instead of a pseudo option.
@MainActor
final class AgentLaunchTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    /// Project „Website Relaunch“ keeps a Codex preference with effort „max“, which GPT-5-Codex does not
    /// support: the sheet must block it until a supported effort is chosen for this job.
    func testBlockedCombinationCannotBeSubmitted() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.openTask(Fixture.staleProjectTask, in: app)
        UITest.openAgentLaunch(in: app)
        let form = UITest.container("agentLaunch.form", in: app)

        let codex = app.buttons["agentLaunch.provider.codex"]
        XCTAssertTrue(codex.waitForExistence(timeout: UITest.timeout), "Codex aus den Mac-Fähigkeiten fehlt")
        codex.tap()
        XCTAssertTrue(codex.isSelected)

        let submit = app.buttons["agentLaunch.submit"]
        XCTAssertTrue(UITest.scrollTo(submit, in: app, container: form))
        XCTAssertFalse(submit.isEnabled, "Blockierte Kombination darf nicht absendbar sein")
        XCTAssertTrue(app.descendants(matching: .any)["agentLaunch.blocker"].exists, "Begründung der Blockade fehlt")
        UITest.attachScreenshot("Blockierte Kombination", of: app, to: self)

        // Tapping the disabled button does nothing (sheet stays, no confirmation).
        submit.tap()
        XCTAssertFalse(app.staticTexts["Auftrag angelegt"].waitForExistence(timeout: 1))

        // A supported effort for this job resolves the block.
        form.swipeDown(velocity: .slow)
        let high = app.buttons["agentLaunch.effort.high"]
        XCTAssertTrue(scrollToward(high, app: app, form: form), "Stufe „Hoch“ nicht erreichbar")
        high.tap()
        XCTAssertTrue(UITest.scrollTo(submit, in: app, container: form))
        XCTAssertTrue(submit.isEnabled, "Unterstützte Kombination muss absendbar sein")
        XCTAssertFalse(app.descendants(matching: .any)["agentLaunch.blocker"].exists)

        app.buttons["agentLaunch.close"].tap()
    }

    func testAgentWithoutEffortSupportShowsProviderDefault() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.openTask(Fixture.projectTask, in: app)
        UITest.openAgentLaunch(in: app)
        let form = UITest.container("agentLaunch.form", in: app)

        let claude = app.buttons["agentLaunch.provider.claude-code"]
        XCTAssertTrue(claude.waitForExistence(timeout: UITest.timeout), "Claude Code aus den Mac-Fähigkeiten fehlt")
        claude.tap()
        XCTAssertTrue(claude.isSelected)

        let hint = app.staticTexts["agentLaunch.effortNotAdjustable"]
        XCTAssertTrue(UITest.scrollTo(hint, in: app, container: form))
        XCTAssertEqual(hint.label, "Anbieterstandard – nicht einstellbar")
        XCTAssertFalse(app.buttons["agentLaunch.effort.high"].exists, "Keine Pseudo-Stufen ohne Effort-Unterstützung")
        XCTAssertFalse(app.buttons["agentLaunch.effort.auto"].exists)

        let submit = app.buttons["agentLaunch.submit"]
        XCTAssertTrue(UITest.scrollTo(submit, in: app, container: form))
        XCTAssertTrue(submit.isEnabled)
        UITest.attachScreenshot("Claude Code – Anbieterstandard", of: app, to: self)
        app.buttons["agentLaunch.close"].tap()
    }

    /// Scrolls down from the top until `element` is hittable (it may be above or below the fold).
    private func scrollToward(_ element: XCUIElement, app: XCUIApplication, form: XCUIElement) -> Bool {
        for _ in 0..<3 where !(element.exists && element.isHittable) { form.swipeDown(velocity: .fast) }
        return UITest.scrollTo(element, in: app, container: form)
    }
}
