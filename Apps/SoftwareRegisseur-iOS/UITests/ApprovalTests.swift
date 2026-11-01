import XCTest

/// SR-SEC-08 (docs/security/audit-2026-10-30.md), spec J6/L3: a shortened approval preview is marked as
/// such, „Erlauben“ is disabled with the reason („Vollständige Anfrage nur am Mac prüfbar“) and only
/// „Ablehnen“ can be sent from the iPhone/iPad. Fixture approvals: `fixture-short` (complete preview)
/// and `fixture-truncated` (preview shortened, host review required).
@MainActor
final class ApprovalTests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    func testTruncatedPreviewOffersOnlyDenyWithExplanation() {
        let app = UITest.makeApp()
        app.launch()
        UITest.waitUntilReady(app)
        UITest.open(.agents, in: app)
        let list = UITest.container("agents.list", in: app)

        let notice = app.descendants(matching: .any)["approval.truncationNotice.fixture-truncated"]
        XCTAssertTrue(UITest.scrollTo(notice, in: app, container: list), "Kürzungshinweis fehlt")
        XCTAssertTrue(notice.label.contains("Vorschau gekürzt"), notice.label)

        let allow = app.buttons["approval.allow.fixture-truncated"]
        let deny = app.buttons["approval.deny.fixture-truncated"]
        XCTAssertTrue(UITest.scrollTo(deny, in: app, container: list))
        XCTAssertTrue(allow.exists, "„Erlauben“ soll sichtbar, aber deaktiviert sein")
        XCTAssertFalse(allow.isEnabled, "„Erlauben“ darf bei gekürzter Vorschau nicht möglich sein")
        XCTAssertTrue(deny.isEnabled)
        let reason = app.staticTexts["approval.allowUnavailable.fixture-truncated"]
        XCTAssertTrue(reason.exists)
        XCTAssertTrue(reason.label.hasPrefix("Vollständige Anfrage nur am Mac prüfbar"), reason.label)
        UITest.attachScreenshot("Gekürzte Freigabe", of: app, to: self)

        // Complete preview: both decisions possible, no notice.
        XCTAssertFalse(app.descendants(matching: .any)["approval.truncationNotice.fixture-short"].exists)
        let allowShort = app.buttons["approval.allow.fixture-short"]
        XCTAssertTrue(allowShort.exists)
        XCTAssertTrue(allowShort.isEnabled)
        XCTAssertFalse(app.staticTexts["approval.allowUnavailable.fixture-short"].exists)
    }
}
