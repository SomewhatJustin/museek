import XCTest
@testable import Museek

final class MuseekTests: XCTestCase {
    func testPlaylistNotesDecodeAndSurviveOfflineEncoding() throws {
        let old = Data(#"{"id":"a","collectionId":"one","title":"Song"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MusicTrack.self, from: old).noteText)
        let annotated = Data(#"{"id":"b","collectionId":"two","title":"Song","note":"A personal note\nSecond line"}"#.utf8)
        let track = try JSONDecoder().decode(MusicTrack.self, from: annotated)
        XCTAssertEqual(track.noteText, "A personal note\nSecond line")
        let restored = try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(restored, track)
        XCTAssertNil(MusicTrack(id: "c", collectionID: "three", title: "Song", note: " \n ").noteText)
    }

    func testServerNormalizationPreservesBasePath() throws {
        XCTAssertEqual(try APIClient.normalizedURL("music.example.com/museek").absoluteString, "https://music.example.com/museek")
        XCTAssertThrowsError(try APIClient.normalizedURL("http://music.example.com"))
        XCTAssertEqual(try APIClient.normalizedURL("http://127.0.0.1:8080/").absoluteString, "http://127.0.0.1:8080/")
    }

    func testPairingLinkValidation() throws {
        let url = try XCTUnwrap(URL(string: "museek://pair?server=https%3A%2F%2Fmusic.example.com%2Fmuseek&code=abcd-2345"))
        let link = try XCTUnwrap(PairingLink(url: url))
        XCTAssertEqual(link.serverURL, "https://music.example.com/museek")
        XCTAssertEqual(link.code, "ABCD-2345")
        XCTAssertNil(PairingLink(url: URL(string: "museek://pair?server=http%3A%2F%2Fmusic.example.com&code=ABCD-2345")!))
    }

    func testHostComparisonAllowsPortToPathMigration() throws {
        let session = AppSession(serverURL: "https://music.example.com:8443", token: "t", recipientID: "r", recipientName: "Listener")
        let link = try XCTUnwrap(PairingLink(url: URL(string: "museek://pair?server=https%3A%2F%2Fmusic.example.com%2Fmuseek&code=ABCD-2345")!))
        XCTAssertTrue(session.sharesHost(with: link))
    }
}
