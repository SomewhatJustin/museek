import XCTest

final class TailnetUITests: XCTestCase {
    @MainActor func testSuccessfulJoinPersistsSessionAndRestoresLibraryAfterRelaunch() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["MUSEEK_UI_TEST_RESET_SESSION"] = "1"
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "success"
        app.launch()
        XCTAssertTrue(app.staticTexts["Museek found"].waitForExistence(timeout: 8))
        // Give an accidental automatic join time to finish before checking consent.
        let library = app.buttons["Settings"]
        XCTAssertFalse(library.waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["Invitation code"].exists)
        XCTAssertTrue(app.buttons["tailnet.join"].isEnabled)
        app.buttons["tailnet.join"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Joined fixture collection")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["tailnet.join"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Listener")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "https://elitedesk-1.tail6900fe.ts.net:10002")).firstMatch.exists)
        app.terminate()

        // No reset or join response on this launch: only the real saved bearer works.
        app.launchEnvironment.removeValue(forKey: "MUSEEK_UI_TEST_RESET_SESSION")
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "restore"
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Restored fixture collection")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["tailnet.join"].exists)
        XCTAssertFalse(app.textFields["Invitation code"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Listener")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "https://elitedesk-1.tail6900fe.ts.net:10002")).firstMatch.exists)
        // Exercise real sign-out so this persisted session cannot leak into other tests.
        app.buttons["Sign Out"].tap()
        app.sheets.buttons["Sign Out"].tap()
        XCTAssertTrue(app.textFields["Invitation code"].waitForExistence(timeout: 5))
    }
    @MainActor func testFoundRequiresTapAndUnauthorizedPreservesInvitation() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["MUSEEK_UI_TEST_RESET_SESSION"] = "1"
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
        continueAfterFailure = false
        app.launchEnvironment["MUSEEK_UI_TEST_RESET_SESSION"] = "1"
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
