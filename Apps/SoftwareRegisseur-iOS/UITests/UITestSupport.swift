import XCTest

// UI tests of the iOS app (spec P, Q4, R: A07–A10, A26, A29; ADR-0025).
//
// Run (one simulator at a time, never in parallel):
//   xcodegen generate
//   xcrun simctl create SR-UITest-iPhone "iPhone 17 Pro"      # once
//   xcodebuild test -scheme SoftwareRegisseur-iOS \
//     -destination 'platform=iOS Simulator,name=SR-UITest-iPhone' \
//     -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
//   (same with SR-UITest-iPad, e.g. "iPad Pro 11-inch (M5)")
//
// The app runs as a Debug build with `-SRScreenshotFixtures YES`: projects, tasks, a Mac host with Codex
// and Claude Code capabilities are written through the normal repositories into an empty database
// (AppModel.insertScreenshotFixtures). For a reproducible run start from a fresh install
// (`xcrun simctl uninstall <udid> <bundle id>`); the tests themselves only add uniquely named notes.
//
// Microphone permission: `PermissionFlowTests` resets it with `resetAuthorizationStatus(for: .microphone)`
// before launching (same effect as `xcrun simctl privacy <udid> reset microphone <bundle id>`).
// Speech recognition has no reset API; the flow asks for the microphone first, so the tests never
// reach the speech prompt.

/// Sections of the app (spec P, iPhone views 1–8) with their German titles.
enum Section: String, CaseIterable {
    case overview, tasks, inbox, dictation, projects, agents, review, settings

    var title: String {
        switch self {
        case .overview: "Übersicht"
        case .tasks: "Aufgaben"
        case .inbox: "Inbox"
        case .dictation: "Diktat"
        case .projects: "Projekte"
        case .agents: "Agenten"
        case .review: "Review"
        case .settings: "Einstellungen"
        }
    }

    /// SF Symbol of the tab; tab buttons and sidebar cells carry it as accessibility identifier.
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tasks: "checklist"
        case .inbox: "tray"
        case .dictation: "mic"
        case .projects: "folder"
        case .agents: "cpu"
        case .review: "checkmark.seal"
        case .settings: "gearshape"
        }
    }

    /// Sections with their own tab in the compact layout; the others open from „Mehr“.
    var isCompactPrimary: Bool { [.overview, .tasks, .inbox, .dictation].contains(self) }
}

/// Fixture values (AppModel.insertScreenshotFixtures).
enum Fixture {
    static let projectTask = "Login-Fehler bei abgelaufener Sitzung beheben"
    /// Task of the project with the stale Codex preference (effort „max“ not supported → blocked).
    static let staleProjectTask = "Startseite für Tablets überarbeiten"
    static let project = "Software Regisseur"
}

@MainActor
enum UITest {
    static let timeout: TimeInterval = 10

    static func makeApp(
        initialTab: Section? = nil,
        contentSize: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-SRScreenshotFixtures", "YES", "-AppleLanguages", "(de-AT)", "-AppleLocale", "de_AT"]
        if let initialTab { arguments += ["-SRInitialTab", initialTab.rawValue] }
        if let contentSize { arguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchArguments = arguments + extraArguments
        return app
    }

    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// The app finished loading the database (root view replaced the loading indicator).
    static func waitUntilReady(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let loading = app.staticTexts["Daten werden geladen …"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "App bleibt im Ladezustand", file: file, line: line)
    }

    /// Opens a section like a user: tab bar (iPhone: four tabs plus „Mehr“), iPad: the visible tabs of the
    /// floating tab bar or the sidebar („Seitenleiste ein-/ausblenden“) for the others.
    static func open(_ section: Section, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if usesCompactTabs(app) {
            if section.isCompactPrimary {
                tapTab(section.symbol, title: section.title, in: app, file: file, line: line)
            } else {
                tapTab("ellipsis", title: "Mehr", in: app, file: file, line: line)
                // Back to the „Mehr“ list if a section is still open there.
                let moreRow = app.buttons["more.\(section.rawValue)"].firstMatch
                var attempts = 0
                while !moreRow.waitForExistence(timeout: 1), attempts < 4 {
                    backButtons(in: app).firstMatch.tap()
                    attempts += 1
                }
                XCTAssertTrue(moreRow.waitForExistence(timeout: timeout), "„\(section.title)“ fehlt unter „Mehr“", file: file, line: line)
                moreRow.tap()
            }
        } else if let tab = visibleTab(section, in: app) {
            // iPad: the floating tab bar shows as many tabs as fit, paged with chevrons.
            XCTAssertEqual(tab.label, section.title, "Tab-Beschriftung", file: file, line: line)
            tab.tap()
        } else {
            // iPad: the tab view's sidebar („Seitenleiste ein-/ausblenden“ in the tab bar) lists all sections;
            // a split view's own column toggle has no identifier and is not used.
            let cell = app.cells.matching(identifier: section.symbol).firstMatch
            if !(cell.exists && cell.isHittable) {
                let toggle = app.buttons.matching(NSPredicate(
                    format: "identifier ==[c] 'ToggleSidebar' AND label CONTAINS 'ein'")).firstMatch
                XCTAssertTrue(toggle.waitForExistence(timeout: timeout), "Seitenleisten-Taste fehlt", file: file, line: line)
                toggle.tap()
            }
            XCTAssertTrue(cell.waitForExistence(timeout: timeout), "„\(section.title)“ fehlt in der Seitenleiste", file: file, line: line)
            XCTAssertEqual(cell.label, section.title, file: file, line: line)
            cell.tap()
            // The sidebar normally closes itself after a selection; close it if it stayed open.
            let hide = app.buttons.matching(NSPredicate(
                format: "identifier ==[c] 'ToggleSidebar' AND label == 'Seitenleiste ausblenden'")).firstMatch
            if hide.waitForExistence(timeout: 1.5) { hide.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(navigationBar(section.title, in: app).waitForExistence(timeout: timeout),
                      "Bereich „\(section.title)“ nicht geöffnet", file: file, line: line)
    }

    /// Compact layout: the app's own „Mehr“ tab exists (iPhone, compact iPad windows).
    static func usesCompactTabs(_ app: XCUIApplication) -> Bool {
        // iPhone always; iPad only in narrow windows (Split View, Slide Over), where the app's own
        // „Mehr“ tab appears.
        guard isPad else { return true }
        return app.buttons.matching(identifier: "ellipsis").firstMatch.waitForExistence(timeout: 2)
    }

    /// Tab button of `section` in the floating tab bar if fully usable (not under a page chevron).
    private static func visibleTab(_ section: Section, in app: XCUIApplication) -> XCUIElement? {
        let tab = app.buttons.matching(identifier: section.symbol).firstMatch
        guard tab.waitForExistence(timeout: 1), tab.isHittable else { return nil }
        let chevrons = app.buttons.matching(NSPredicate(format: "label == 'Nächste Seite' OR label == 'Vorherige Seite'"))
            .allElementsBoundByIndex.map(\.frame)
        return chevrons.contains { $0.intersects(tab.frame) } ? nil : tab
    }

    private static func tapTab(_ symbol: String, title: String, in app: XCUIApplication, file: StaticString, line: UInt) {
        // Tab buttons usually carry their SF Symbol as identifier; some tab bar states expose only the
        // label (e.g. at accessibility text sizes). Count tiles and „Mehr“ rows have own identifiers.
        let byIdentifier = app.buttons.matching(identifier: symbol).firstMatch
        let byLabel = app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH 'overview.') AND NOT (identifier BEGINSWITH 'more.')", title)).firstMatch
        let inTabBar = app.tabBars.buttons[title]
        var button = byIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if byIdentifier.exists { button = byIdentifier; break }
            if inTabBar.exists { button = inTabBar; break }
            if byLabel.exists { button = byLabel; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !button.exists {
            print("Tab „\(title)“ fehlt – Hierarchie:\n\(app.debugDescription.prefix(6000))")
            print("Springboard:\n\(springboard.debugDescription.prefix(3000))")
        }
        XCTAssertTrue(button.exists, "Tab „\(title)“ fehlt", file: file, line: line)
        XCTAssertEqual(button.label, title, "Tab-Beschriftung", file: file, line: line)
        button.tap()
    }

    static func navigationBar(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.matching(identifier: title).firstMatch
    }

    /// Back buttons of all navigation bars currently on screen.
    static func backButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.navigationBars.buttons.matching(identifier: "BackButton")
    }

    /// First element whose accessibility label contains `text` (rows combine their texts).
    static func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Row (cell or button) whose label contains `text`.
    static func row(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.matching(predicate).firstMatch
        return button.exists ? button : app.cells.matching(predicate).firstMatch
    }

    /// Scrolls `container` (default: the first list) until `element` exists and is hittable.
    @discardableResult
    static func scrollTo(_ element: XCUIElement, in app: XCUIApplication, container: XCUIElement? = nil, maxSwipes: Int = 15) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            let scrollable = container ?? (app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch
                : (app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.windows.firstMatch))
            scrollable.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    /// Container of a screen marked with an accessibility identifier (list, form or scroll view).
    static func container(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens a fixture task from „Aufgaben“ (pushes on the iPhone, selects into the detail column on the iPad).
    static func openTask(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        open(.tasks, in: app, file: file, line: line)
        var row = row(containing: title, in: app)
        // Large text sizes or more data push the row below the visible part of the lazy list.
        var swipes = 0
        while !row.waitForExistence(timeout: swipes == 0 ? timeout : 1) || !row.isHittable, swipes < 15 {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            row = self.row(containing: title, in: app)
            swipes += 1
        }
        XCTAssertTrue(row.exists, "Aufgabe „\(title)“ fehlt", file: file, line: line)
        row.tap()
        XCTAssertTrue(container("task.detail", in: app).waitForExistence(timeout: timeout),
                      "Aufgabendetail „\(title)“ nicht geöffnet", file: file, line: line)
    }

    /// Task detail → „Mit Agent umsetzen“: waits for the start sheet and its agent rows.
    static func openAgentLaunch(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let start = app.buttons["task.startAgent"]
        XCTAssertTrue(scrollTo(start, in: app, container: container("task.detail", in: app)),
                      "„Mit Agent umsetzen“ nicht erreichbar", file: file, line: line)
        start.tap()
        XCTAssertTrue(container("agentLaunch.form", in: app).waitForExistence(timeout: timeout),
                      "Startblatt „Mit Agent umsetzen“ nicht geöffnet", file: file, line: line)
    }

    /// Opens the permission explanation screen: Diktat → „Aufnahme starten“.
    static func openPermissionScreen(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        open(.dictation, in: app, file: file, line: line)
        let start = app.buttons["dictation.start"]
        let form = container("dictation.form", in: app)
        _ = form.waitForExistence(timeout: timeout)
        XCTAssertTrue(scrollTo(start, in: app, container: form), "„Aufnahme starten“ nicht erreichbar", file: file, line: line)
        start.tap()
    }

    static func attachScreenshot(_ name: String, of app: XCUIApplication, to testCase: XCTestCase) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
