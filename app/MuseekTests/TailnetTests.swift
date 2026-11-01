import XCTest
@testable import Museek

@MainActor final class TailnetTests: XCTestCase {
    func testFoundDoesNotJoinUntilTap() async {
        var joins = 0
        let discovery = TailnetDiscovery(probe: { true }, join: {
            joins += 1
            return AppSession(serverURL: TailnetDiscovery.serverURL, token: "test", recipientID: "r", recipientName: "Listener")
        })
        await discovery.detect()
        XCTAssertEqual(discovery.state, .found)
        XCTAssertEqual(joins, 0)
        let result = await discovery.join()
        XCTAssertEqual(joins, 1)
        XCTAssertEqual(result?.recipientName, "Listener")
    }
    func testNotFoundKeepsManualInvitationAvailable() async {
        let discovery = TailnetDiscovery(probe: { false }, join: { throw URLError(.notConnectedToInternet) })
        await discovery.detect()
        XCTAssertEqual(discovery.state, .notFound)
        XCTAssertTrue(discovery.manualInvitationAvailable)
        let result = await discovery.join()
        XCTAssertNil(result)
    }
    func testUnauthorizedJoinKeepsManualInvitationAvailable() async {
        let discovery = TailnetDiscovery(probe: { true }, join: { throw APIError(message: "Not authorized", statusCode: 403) })
        await discovery.detect()
        let result = await discovery.join()
        XCTAssertNil(result)
        XCTAssertEqual(discovery.error, "Not authorized")
        XCTAssertTrue(discovery.manualInvitationAvailable)
        XCTAssertEqual(discovery.state, .found)
    }
}
