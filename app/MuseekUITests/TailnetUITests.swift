import XCTest

final class TailnetUITests: XCTestCase {
    @MainActor func testFoundRequiresTapAndUnauthorizedPreservesInvitation() {
        let app = XCUIApplication()
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "unauthorized"
        app.launch()
        XCTAssertTrue(app.staticTexts["Museek found"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tailnet.join"].exists)
        XCTAssertTrue(app.textFields["Server address"].exists)
        XCTAssertTrue(app.textFields["Invitation code"].exists)
        XCTAssertFalse(app.staticTexts["This Tailscale account is not authorized to join Museek."].exists)
        app.buttons["tailnet.join"].tap()
        XCTAssertTrue(app.staticTexts["This Tailscale account is not authorized to join Museek."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Server address"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Museek found and unauthorized join"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    @MainActor func testNotFoundManualPairingStillUsable() {
        let app = XCUIApplication()
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "notFound"
        app.launch()
        XCTAssertTrue(app.buttons["Check again"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["tailnet.join"].exists)
        let server = app.textFields["Server address"]
        XCTAssertTrue(server.exists)
        server.tap()
        server.typeText("https://example.com")
        let code = app.textFields["Invitation code"]
        code.tap()
        code.typeText("ABCD-2345")
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
    }
}
