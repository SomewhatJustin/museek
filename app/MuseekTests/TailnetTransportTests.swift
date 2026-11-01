import XCTest
@testable import Museek

private final class TailnetURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handle: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handle!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class TailnetTransportTests: XCTestCase {
    private func client() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TailnetURLProtocol.self]
        return try APIClient(serverURL: TailnetDiscovery.serverURL, session: URLSession(configuration: config))
    }
    func testDetectionUsesBoundedReadOnlyKnownEndpoint() async throws {
        TailnetURLProtocol.handle = { request in
            XCTAssertEqual(request.url?.absoluteString, TailnetDiscovery.serverURL + "/v1/server")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 3)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, #"{"name":"Museek","tailnetJoin":true,"version":1}"#)
        }
        let found = try await client().detectTailnet()
        XCTAssertTrue(found)
    }
    func testJoinMintsSessionWithoutClientSuppliedIdentity() async throws {
        TailnetURLProtocol.handle = { request in
            XCTAssertEqual(request.url?.path, "/v1/tailnet/join")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Tailscale-User-Login"))
            return (201, #"{"token":"test-token","recipient":{"id":"r","name":"Listener"}}"#)
        }
        let session = try await client().joinTailnet(deviceName: "Test iPhone")
        XCTAssertEqual(session.serverURL, TailnetDiscovery.serverURL)
        XCTAssertEqual(session.recipientID, "r")
        XCTAssertEqual(session.token, "test-token")
    }
    func testUnauthorizedAndTimeoutRemainErrors() async throws {
        TailnetURLProtocol.handle = { _ in (403, #"{"error":"Not authorized"}"#) }
        do { _ = try await client().joinTailnet(deviceName: "Test"); XCTFail("unauthorized join succeeded") }
        catch let error as APIError { XCTAssertEqual(error.statusCode, 403) }
        TailnetURLProtocol.handle = { _ in throw URLError(.timedOut) }
        do { _ = try await client().detectTailnet(); XCTFail("timeout succeeded") }
        catch let error as APIError { XCTAssertEqual(error.message, "The server took too long to respond.") }
    }
}
