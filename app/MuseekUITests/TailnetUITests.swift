import XCTest

final class TailnetUITests: XCTestCase {
    @MainActor func testSwipeDownDismissesNowPlayingToPlaylist() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["MUSEEK_UI_TEST_RESET_SESSION"] = "1"
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "success"
        app.launch()
        XCTAssertTrue(app.buttons["tailnet.join"].waitForExistence(timeout: 8))
        app.buttons["tailnet.join"].tap()
        let playlist = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Joined fixture collection")).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 8))
        playlist.tap()
        app.buttons["Play Playing song"].tap()
        let openPlayer = app.buttons["Open Now Playing"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 8))
        openPlayer.tap()
        let title = app.staticTexts["nowPlaying.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["playlist.share"].isHittable)
        XCTAssertTrue(openPlayer.isHittable)

        // Open from the library: dismissal must navigate to the playing playlist.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        app.staticTexts["Playing song"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["playlist.share"].waitForExistence(timeout: 5))
        XCTAssertTrue(openPlayer.isHittable)
    }

    @MainActor func testPlaylistShareExposesCopyLink() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["MUSEEK_UI_TEST_RESET_SESSION"] = "1"
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "success"
        app.launch()
        XCTAssertTrue(app.buttons["tailnet.join"].waitForExistence(timeout: 8))
        app.buttons["tailnet.join"].tap()
        let playlist = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Joined fixture collection")).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 8))
        playlist.tap()
        let share = app.buttons["playlist.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        share.tap()
        let copy = app.buttons["playlist.copyLink"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Anyone with this link can add this playlist in Museek. The link works for 24 hours."].exists)
        copy.tap()
        XCTAssertEqual(copy.label, "Link copied")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Share playlist and copy URL"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    @MainActor func testNotesReadWithoutChangingPlayback() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["MUSEEK_UI_TEST_RESET_SESSION"] = "1"
        app.launchEnvironment["MUSEEK_UI_TEST_SCENARIO"] = "success"
        app.launch()
        XCTAssertTrue(app.buttons["tailnet.join"].waitForExistence(timeout: 8))
        app.buttons["tailnet.join"].tap()
        let collection = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Joined fixture collection")).firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 8))
        collection.tap()
        let note = app.buttons["track.note.song-b"]
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        note.tap()
        XCTAssertTrue(app.staticTexts["A different song’s note."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open Now Playing"].exists)
        XCTAssertFalse(app.staticTexts["nowPlaying.title"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Anchored playlist note"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close note"].tap()
        app.buttons["Play Playing song"].tap()
        XCTAssertTrue(app.buttons["Open Now Playing"].waitForExistence(timeout: 8))
        note.tap()
        XCTAssertTrue(app.staticTexts["A different song’s note."].waitForExistence(timeout: 5))
        app.buttons["Close note"].tap()
        app.buttons["Open Now Playing"].tap()
        XCTAssertTrue(app.staticTexts["nowPlaying.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nowPlaying.title"].label, "Playing song")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["The playing song’s note."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["A different song’s note."].exists)
    }

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
