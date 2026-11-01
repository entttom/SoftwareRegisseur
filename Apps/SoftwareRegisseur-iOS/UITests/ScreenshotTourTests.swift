import XCTest

/// Visual check, not an assertion test: photographs every screen, detail and sheet in light, dark and a large
/// accessibility text size, so layout faults (squeezed buttons, clipped labels) show up on review.
/// Runs only on request: `TEST_RUNNER_SR_SCREENSHOT_DIR=<folder> xcodebuild test -only-testing:…/ScreenshotTourTests`.
/// The PNGs land in that folder; without the variable the test is skipped.
@MainActor
final class ScreenshotTourTests: XCTestCase {
    private var directory: URL!
    private var variant = ""
    private var appearance = "light"

    nonisolated override func setUp() {
        continueAfterFailure = true
    }

    func testTour() throws {
        guard let path = ProcessInfo.processInfo.environment["SR_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Nur mit SR_SCREENSHOT_DIR (Bildschirmfoto-Rundgang).")
        }
        directory = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, contentSize) in [
            ("hell", "light", String?.none),
            ("dunkel", "dark", nil),
            ("gross", "light", "UICTContentSizeCategoryAccessibilityXL"),
        ] {
            variant = name
            self.appearance = appearance
            tour(contentSize: contentSize)
        }
    }

    private func tour(contentSize: String?) {
        for section in Section.allCases {
            let app = launch(contentSize)
            UITest.open(section, in: app)
            shootScrolling(section.rawValue, app)
        }

        var app = launch(contentSize)
        UITest.openTask(Fixture.projectTask, in: app)
        shootScrolling("aufgabe-detail", app, container: UITest.container("task.detail", in: app))

        app = launch(contentSize)
        UITest.openTask(Fixture.staleProjectTask, in: app)
        UITest.openAgentLaunch(in: app)
        shootScrolling("agent-start", app, container: UITest.container("agentLaunch.form", in: app))

        app = launch(contentSize)
        UITest.open(.tasks, in: app)
        tapIfPresent(app.buttons["Neue Aufgabe"], then: "neue-aufgabe", app)

        app = launch(contentSize)
        UITest.open(.overview, in: app)
        tapIfPresent(app.buttons["Schnell erfassen"], then: "schnell-erfassen", app)

        app = launch(contentSize)
        UITest.open(.projects, in: app)
        tapIfPresent(app.buttons["Neues Projekt"], then: "neues-projekt", app)

        app = launch(contentSize)
        UITest.open(.projects, in: app)
        tapIfPresent(app.cells.firstMatch, then: "projekt-detail", app)

        app = launch(contentSize)
        UITest.open(.review, in: app)
        tapIfPresent(app.cells.firstMatch, then: "review-detail", app)

        for (index, label) in ["Konflikte", "OpenAI – Transkription", "OpenAI – KI-Ausarbeitung"].enumerated() {
            app = launch(contentSize)
            UITest.open(.settings, in: app)
            let row = UITest.row(containing: label, in: app)
            if UITest.scrollTo(row, in: app) { tapIfPresent(row, then: "einstellungen-\(index + 1)", app) }
        }

        app = launch(contentSize)
        UITest.openPermissionScreen(in: app)
        shoot("berechtigung", app)
    }

    private func launch(_ contentSize: String?) -> XCUIApplication {
        let app = UITest.makeApp(contentSize: contentSize, extraArguments: ["-SRForceAppearance", appearance])
        app.launch()
        UITest.waitUntilReady(app)
        return app
    }

    private func tapIfPresent(_ element: XCUIElement, then name: String, _ app: XCUIApplication) {
        guard element.waitForExistence(timeout: UITest.timeout), element.isHittable else {
            XCTFail("\(variant)/\(name): Element nicht erreichbar")
            return
        }
        element.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shootScrolling(name, app)
    }

    /// Top of the screen plus up to two scrolled pages.
    private func shootScrolling(_ name: String, _ app: XCUIApplication, container: XCUIElement? = nil) {
        Thread.sleep(forTimeInterval: 1)
        shoot("\(name)-1", app)
        let target = container ?? app.windows.firstMatch
        for page in 2...3 {
            target.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 1)
            shoot("\(name)-\(page)", app)
        }
    }

    private func shoot(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(variant)-\(name).png"))
    }
}
