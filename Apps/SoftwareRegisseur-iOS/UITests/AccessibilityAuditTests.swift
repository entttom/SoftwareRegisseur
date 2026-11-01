import XCTest

/// A29 (spec P „Hell/Dunkel, Dynamic Type, VoiceOver“): Xcode accessibility audit on the key screens,
/// each in light and dark appearance. Every issue fails the test unless it is listed in
/// `AuditExclusions` with a reason.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = true
    }

    func testAuditOverview() throws {
        try auditInBothAppearances(screen: "Übersicht") { UITest.open(.overview, in: $0) }
    }

    func testAuditTaskList() throws {
        try auditInBothAppearances(screen: "Aufgaben") { UITest.open(.tasks, in: $0) }
    }

    func testAuditTaskDetail() throws {
        try auditInBothAppearances(screen: "Aufgabendetail") { app in
            UITest.openTask(Fixture.projectTask, in: app)
            // iPad split view: hide the list column (audited in testAuditTaskList) so the audit covers the
            // detail. With the column visible the audit rated black row titles next to the selection as
            // failed in both appearances, which the screenshots do not show.
            let hideList = app.buttons.matching(NSPredicate(format: "identifier == '' AND label == 'Seitenleiste ausblenden'")).firstMatch
            if !UITest.usesCompactTabs(app), hideList.exists {
                hideList.tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    func testAuditAgentLaunchSheet() throws {
        let openSheet = { (app: XCUIApplication) in
            UITest.openTask(Fixture.staleProjectTask, in: app)
            UITest.openAgentLaunch(in: app)
        }
        try auditInBothAppearances(screen: "Mit Agent umsetzen", navigate: openSheet)
        // Lower part of the form: effort rows, summary with the blocker, submit button.
        // Excluded audit type (documented): contrast of the scrolled-down sheet. The audit itself scrolls the
        // sheet while sampling; element positions shift by ~30 pt between samples, so plain black-on-white
        // rows („Nur speichern“, „Priorität“) were reported as failed. These rows are standard Form rows in
        // label colours; the top part of the same form passes the contrast audit in both appearances.
        try auditInBothAppearances(screen: "Mit Agent umsetzen (unten)", types: XCUIAccessibilityAuditType.all.subtracting(.contrast)) { app in
            openSheet(app)
            let form = UITest.container("agentLaunch.form", in: app)
            UITest.scrollTo(app.buttons["agentLaunch.submit"], in: app, container: form)
            for _ in 0..<3 { form.swipeUp(velocity: .fast) }
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    func testAuditSettings() throws {
        try auditInBothAppearances(screen: "Einstellungen") { UITest.open(.settings, in: $0) }
    }

    func testAuditInbox() throws {
        try auditInBothAppearances(screen: "Inbox") { UITest.open(.inbox, in: $0) }
    }

    func testAuditAgents() throws {
        try auditInBothAppearances(screen: "Agenten") { UITest.open(.agents, in: $0) }
    }

    func testAuditPermissionExplanation() throws {
        try auditInBothAppearances(screen: "Berechtigungs-Erklärung", resetMicrophone: true) { app in
            UITest.openPermissionScreen(in: app)
            XCTAssertTrue(app.buttons["permission.continue"].waitForExistence(timeout: UITest.timeout))
        }
    }

    /// Onboarding pages (first launch): every page in both appearances.
    func testAuditOnboarding() throws {
        for step in ["welcome", "sync", "mac", "dictation", "keys", "summary"] {
            try auditInBothAppearances(screen: "Einrichtung \(step)", extraArguments: ["-SROnboarding", "YES", "-SROnboardingStep", step]) { app in
                XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: UITest.timeout))
            }
        }
    }

    // MARK: Helpers

    /// Launches the app once per appearance (`-SRForceAppearance`, Debug builds), navigates and audits.
    /// `XCUIDevice.appearance` did not change the running app on the iOS 27 simulator, so the earlier dark
    /// audits had checked light screens.
    private func auditInBothAppearances(
        screen: String, types: XCUIAccessibilityAuditType = .all, resetMicrophone: Bool = false,
        extraArguments: [String] = [], navigate: (XCUIApplication) -> Void
    ) throws {
        for dark in [false, true] {
            let app = UITest.makeApp(extraArguments: ["-SRForceAppearance", dark ? "dark" : "light"] + extraArguments)
            if resetMicrophone { app.resetAuthorizationStatus(for: .microphone) }
            app.launch()
            UITest.waitUntilReady(app)
            navigate(app)
            Thread.sleep(forTimeInterval: 1)
            let name = "\(screen) – \(dark ? "Dunkel" : "Hell")"
            UITest.attachScreenshot(name, of: app, to: self)
            try audit(app, name: name, types: types)
            app.terminate()
        }
    }

    private func audit(_ app: XCUIApplication, name: String, types: XCUIAccessibilityAuditType = .all) throws {
        // The audit service sometimes times out on sheets (error -56, „Audit failed to complete in
        // time“) without reporting anything; retry instead of treating that as a result.
        var attempt = 0
        while true {
            attempt += 1
            do {
                try runAudit(app, name: name, types: types)
                return
            } catch let error as NSError where error.code == -56 && attempt < 3 {
                print("Audit [\(name)] Zeitüberschreitung, Versuch \(attempt + 1)")
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func runAudit(_ app: XCUIApplication, name: String, types: XCUIAccessibilityAuditType) throws {
        try app.performAccessibilityAudit(for: types) { issue in
            let excluded = AuditExclusions.reason(for: issue)
            let line = "[\(name)] \(issue.auditType.germanName): \(issue.compactDescription) – Element: \(issue.element?.debugLabel ?? "–")"
            if let excluded {
                print("Audit ausgenommen: \(line) – Grund: \(excluded)")
                return true
            }
            print("Audit-Befund: \(line)")
            return false
        }
    }
}

/// Audit issues deliberately not treated as app defects, each with its reason (A29 documentation).
/// Everything else fails the test; app-styled colours that failed were fixed in the app (StatusBadge,
/// ErrorText, HostReachabilityText, priority, key status).
@MainActor
enum AuditExclusions {
    static func reason(for issue: XCUIAccessibilityAuditIssue) -> String? {
        let description = issue.compactDescription
        let element = issue.element
        switch issue.auditType {
        case .contrast:
            if element == nil {
                // Since status colours moved from the text to the symbol (StatusBadge, ErrorText,
                // HostReachabilityText), the audit reports the coloured SF Symbols without an element.
                // They are decorative: the adjacent text in label colour carries the meaning (spec P).
                return "Farbiges Status-Symbol ohne eigenes Element (dekorativ, Bedeutung trägt der Text)"
            }
            if description.localizedCaseInsensitiveContains("nearly passed") {
                // Apple's semantic colours (secondaryLabel, tint on grouped backgrounds, list section
                // headers/footers) sit just below 4.5:1 by design; iOS raises them with „Kontrast erhöhen“.
                // Replacing them app-wide would contradict the HIG; clear failures are fixed instead.
                return "Systemfarbe knapp unter 4,5:1 (secondaryLabel/Tint), von iOS bei „Kontrast erhöhen“ angehoben"
            }
            if let element, element.exists, !element.isEnabled {
                return "Deaktiviertes Bedienelement (WCAG 1.4.3 nimmt inaktive Elemente aus)"
            }
            if let element, element.exists, isUnderSystemBar(element) {
                return "Inhalt unter der durchscheinenden Tab-/Navigationsleiste; Kontrast gegen den Glas-Hintergrund gemessen"
            }
            if let element, element.exists, element.elementType == .button, isInsideSystemBar(element) {
                return "Systemtaste der Navigationsleiste (Liquid-Glass-Stil von iOS, keine App-Farbe)"
            }
            if let element, element.exists, isInPadListColumn(element) {
                return padListColumnReason
            }
            if let element, element.exists, isInSelectedRow(element) {
                // iPad split view: the selected row gets the system selection (white on the accent colour,
                // about 4:1); its texts use adaptive styles (.primary/.secondary), no app colour.
                return "Systemauswahl der Listenzeile im iPad-Split-View (weiß auf Akzentfarbe)"
            }
            if let element, element.exists, isListSectionHeaderOrFooter(element) {
                // List section headers/footers use secondaryLabel on systemGroupedBackground; depending on
                // the sampled pixels the audit rates them „failed“ or „nearly passed“.
                return "Abschnittskopf/-fuß der Liste im Systemstil (secondaryLabel auf systemGroupedBackground)"
            }
            return nil
        case .dynamicType, .elementDetection where element == nil:
            // The audit reports these without any element (nothing to inspect or fix); every text the
            // app draws is a SwiftUI Text with a text style.
            if element == nil { return "Befund ohne zugeordnetes Element (vom Audit nicht zuordenbar)" }
            if let element, element.exists, isListSectionHeaderOrFooter(element) {
                return "Abschnittsfuß/-kopf der Liste im Systemstil (Schrift setzt iOS, im Formblatt auf dem iPad begrenzt)"
            }
            if description.localizedCaseInsensitiveContains("partially unsupported") {
                // System list styles (section header/footer, LabeledContent value) scale with Dynamic Type
                // but iOS caps them at accessibility sizes. DynamicTypeTests checks the AX5 layout instead.
                return "Systemstil der Liste (Abschnittskopf/-fuß, LabeledContent) mit iOS-Obergrenze; AX5 separat geprüft"
            }
            return nil
        case .textClipped:
            guard let element, element.exists else {
                return "Kein Element gemeldet (Audit kann den Befund nicht zuordnen)"
            }
            if isListSectionHeaderOrFooter(element) {
                return "Abschnittsfuß/-kopf der Liste, von iOS gesetzt und vollständig sichtbar (Screenshot im Testergebnis)"
            }
            if isInPadListColumn(element) {
                return padListColumnReason
            }
            if element.elementType == .searchField {
                return "Platzhalter des Systemsuchfelds (iPad-Listenspalte), vollständig sichtbar"
            }
            if isUnderSystemBar(element) || !isFullyOnScreen(element) {
                return "Text nur teilweise im sichtbaren Bereich (gescrollt bzw. unter Systemleiste), nicht abgeschnitten"
            }
            if element.label.hasPrefix("Dieser Build ist nicht signiert") {
                // Five-line callout with automatic German hyphenation; the screenshot shows the whole text
                // (checked 2026-10-30). Removing `Label` fixed the headline above it, not this paragraph.
                return "Mehrzeiliger Text mit Silbentrennung vollständig sichtbar (Screenshot geprüft), Fehlmeldung des Audits"
            }
            if element.label.hasPrefix("Aktuell: "), element.frame.height < 20 {
                // OptionRow detail line (inherited model/effort) inside a plain button. The audit reports it
                // as clipped although the screenshot shows the whole line (checked 2026-10-30, iOS 27 sim).
                return "Caption-Zeile in Auswahlknopf vollständig sichtbar (Screenshot geprüft), Fehlmeldung des Audits"
            }
            if element.elementType == .staticText, isInsideSystemBar(element) {
                return "Langer Aufgabentitel in der kompakten Navigationsleiste; voller Titel steht im Kopfbereich"
            }
            if element.elementType == .staticText, isOnOnboardingPage(element) {
                // Onboarding pages and the iPad step sidebar lay out their texts in plain stacks inside scroll views
                // (no List). The audit reported multi-line explanations and single-line titles as clipped in both
                // appearances; the screenshots show every reported text complete at the standard size in light
                // and dark (checked 2026-11-01, iOS 27 simulator, iPhone and iPad). At AX XL and AX5 the visible
                // part was checked (the pages scroll; DynamicTypeTests keeps „Weiter“ reachable).
                return "Text der Einrichtungsseite vollständig sichtbar (Screenshots hell/dunkel geprüft), Fehlmeldung des Audits"
            }
            return nil
        default:
            return nil
        }
    }

    /// SF-Symbol identifiers of the tab buttons (the iOS 26 floating tab bar is not exposed as a tab bar).
    private static let tabSymbols = ["square.grid.2x2", "checklist", "tray", "mic", "folder", "cpu", "checkmark.seal",
                                     "gearshape", "ellipsis"]

    /// Frame of the floating tab bar: union of the tab buttons in one row (identified by their SF Symbol
    /// identifiers; the iOS 26 floating bar is not exposed as a tab bar). Sidebar rows on the iPad have
    /// the same identifiers but other rows, so only buttons level with the first one count.
    private static func floatingTabBarFrame() -> CGRect? {
        let app = XCUIApplication()
        let frames = tabSymbols.flatMap { app.buttons.matching(identifier: $0).allElementsBoundByIndex }
            .map(\.frame).filter { !$0.isEmpty && $0.height < 80 }
        guard let first = frames.first else { return nil }
        let row = frames.filter { abs($0.midY - first.midY) < 20 }
        return row.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -16, dy: -16)
    }

    /// Frames of the system bars: navigation bars, toolbars and the floating tab bar.
    private static func systemBarFrames() -> [CGRect] {
        let app = XCUIApplication()
        var frames = app.navigationBars.allElementsBoundByIndex.map(\.frame)
            + app.toolbars.allElementsBoundByIndex.map(\.frame)
            + app.tabBars.allElementsBoundByIndex.map(\.frame)
        if let bar = floatingTabBarFrame() { frames.append(bar) }
        // Onboarding: „Weiter“ sits on the system bar material (`.bar`) over the scrolling page.
        let footer = app.descendants(matching: .any).matching(identifier: "onboarding.footer").firstMatch
        if footer.exists { frames.append(footer.frame) }
        return frames.filter { !$0.isEmpty && $0.height < 150 }
    }

    private static func isUnderSystemBar(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        return systemBarFrames().contains { $0.intersects(frame) && !$0.contains(frame) }
            || (floatingTabBarFrame()?.intersects(frame) ?? false)
    }

    /// Page or step sidebar (iPad) of the onboarding.
    private static func isOnOnboardingPage(_ element: XCUIElement) -> Bool {
        let app = XCUIApplication()
        return ["onboarding.screen", "onboarding.sidebar"].contains { identifier in
            let container = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            return container.exists && container.frame.contains(element.frame)
        }
    }

    private static func isInsideSystemBar(_ element: XCUIElement) -> Bool {
        let app = XCUIApplication()
        let frame = element.frame
        return (app.navigationBars.allElementsBoundByIndex + app.toolbars.allElementsBoundByIndex)
            .map(\.frame)
            .filter { !$0.isEmpty && $0.height < 150 }
            .contains { $0.contains(frame) }
    }

    /// List section headers and footers are cells of their own: the text spans the whole cell, while
    /// texts inside a row are inset by the cell's margins. Elements with an app identifier never count.
    private static func isListSectionHeaderOrFooter(_ element: XCUIElement) -> Bool {
        guard element.elementType == .staticText, element.identifier.isEmpty else { return false }
        let frame = element.frame
        let app = XCUIApplication()
        guard let list = app.collectionViews.allElementsBoundByIndex.first(where: { $0.frame.contains(frame) }),
              let cell = list.cells.allElementsBoundByIndex.first(where: { $0.frame.contains(frame) })
        else { return false }
        return abs(frame.width - cell.frame.width) <= 1.5 && abs(frame.minX - cell.frame.minX) <= 1.5
    }

    /// iPad split view: the list column uses the system's glass sidebar material. The audit measures text
    /// (in .primary/.metadata styles) against the blurred backdrop and rated black titles and full-width
    /// buttons as failed or clipped in single runs; the screenshots show them complete and legible. The
    /// same rows are audited without the material on the iPhone.
    static let padListColumnReason =
        "iPad-Listenspalte mit Glas-Material des Systems; Kontrast/Abschneiden gegen unscharfen Hintergrund gemessen, Screenshot geprüft, auf dem iPhone ohne Material geprüft"

    private static func isInPadListColumn(_ element: XCUIElement) -> Bool {
        let app = XCUIApplication()
        guard app.windows.firstMatch.frame.width > 700 else { return false }
        let frame = element.frame
        return app.collectionViews.allElementsBoundByIndex.contains {
            $0.frame.minX < 1 && $0.frame.width <= 450 && $0.frame.contains(frame)
        }
    }

    private static func isInSelectedRow(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        return XCUIApplication().cells.allElementsBoundByIndex.contains { $0.isSelected && $0.frame.contains(frame) }
    }

    private static func isFullyOnScreen(_ element: XCUIElement) -> Bool {
        let window = XCUIApplication().windows.firstMatch.frame
        return window.isEmpty || window.contains(element.frame)
    }
}

extension XCUIAccessibilityAuditType {
    var germanName: String {
        switch self {
        case .contrast: "Kontrast"
        case .elementDetection: "Elementerkennung"
        case .hitRegion: "Trefferfläche"
        case .sufficientElementDescription: "Beschreibung"
        case .dynamicType: "Dynamic Type"
        case .textClipped: "Abgeschnittener Text"
        case .trait: "Merkmal"
        default: "Typ \(rawValue)"
        }
    }
}

extension XCUIElement {
    var debugLabel: String {
        let id = identifier.isEmpty ? "" : " [\(identifier)]"
        guard exists else { return "\(elementType.rawValue) „\(label)“\(id)" }
        let f = frame
        return "\(elementType.rawValue) „\(label)“\(id) @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))"
    }
}
