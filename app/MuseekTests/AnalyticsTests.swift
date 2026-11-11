import XCTest
@testable import Museek

private final class AnalyticsTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var bodies: [Data] = []
    let audio: URL?
    init(audio: URL? = nil) { self.audio = audio }
    func setStatus(_ value: Int) { lock.lock(); defer { lock.unlock() }; status = value }
    var requests: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    func respond(_ request: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        if request.url?.path.hasSuffix("/play-url") == true, let audio {
            return (200, "{\"url\":\"\(audio.absoluteString)\"}")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        bodies.append(body)
        return (status, status == 200 ? #"{"recorded":true}"# : #"{"error":"Offline fixture"}"#)
    }
}

private final class AnalyticsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state = AnalyticsTransportState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class AnalyticsTests: XCTestCase {
    private let session = AppSession(serverURL: "https://analytics.invalid", token: "fixture-token", recipientID: "listener", recipientName: "Fixture")

    private func client() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalyticsURLProtocol.self]
        return try APIClient(serverURL: session.serverURL, token: session.token, session: URLSession(configuration: config))
    }

    private func queueURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "analytics-\(UUID().uuidString).json")
    }

    func testOnlyMoreThanThirtySecondsQualifiesOnce() {
        var progress = ListenProgress()
        XCTAssertFalse(progress.sample(position: 0, uptime: 0, playing: true))
        XCTAssertFalse(progress.sample(position: 30, uptime: 30, playing: true))
        XCTAssertTrue(progress.sample(position: 30.5, uptime: 30.5, playing: true))
        XCTAssertFalse(progress.sample(position: 90, uptime: 90, playing: true))
    }

    func testPauseBufferingAndSeekingDoNotAddListeningTime() {
        var progress = ListenProgress()
        _ = progress.sample(position: 0, uptime: 0, playing: true)
        _ = progress.sample(position: 10, uptime: 10, playing: false)
        _ = progress.sample(position: 10, uptime: 110, playing: true)
        _ = progress.sample(position: 10, uptime: 210, playing: false) // buffering
        XCTAssertEqual(progress.seconds, 10)
        progress.invalidateBaseline()
        XCTAssertFalse(progress.sample(position: 120, uptime: 211, playing: true))
        XCTAssertFalse(progress.sample(position: 140, uptime: 231, playing: true))
        XCTAssertEqual(progress.seconds, 30)
        XCTAssertTrue(progress.sample(position: 141, uptime: 232, playing: true))
        // Even an unexpected forward discontinuity is bounded by real time.
        var jump = ListenProgress()
        _ = jump.sample(position: 0, uptime: 0, playing: true)
        XCTAssertFalse(jump.sample(position: 200, uptime: 0.5, playing: true))
        XCTAssertEqual(jump.seconds, 0.5)
    }

    func testCountsDecodeFromOldServersAndPersistOffline() throws {
        let old = Data(#"{"id":"t","collectionId":"p","title":"Song"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MusicTrack.self, from: old).playCount, 0)
        let track = MusicTrack(id: "t", collectionID: "p", title: "Song", playCount: 12)
        XCTAssertEqual(try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(track)).playCount, 12)
    }

    func testRecordingPersistsOneQualifyingEventBeforeSync() async throws {
        let state = AnalyticsTransportState()
        state.setStatus(503)
        AnalyticsURLProtocol.state = state
        let url = queueURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let analytics = PlaybackAnalytics(session: session, api: try client(), queueURL: url)
        analytics.record(collectionID: "p", trackID: "t", seconds: 30)
        XCTAssertTrue(analytics.pending.isEmpty)
        analytics.record(collectionID: "p", trackID: "t", seconds: 30.00001)
        await analytics.flush()
        XCTAssertEqual(analytics.pending.count, 1)
        XCTAssertEqual(analytics.pending.first?.listenedMS, 30001)
        XCTAssertEqual(try JSONDecoder().decode([PendingListen].self, from: Data(contentsOf: url)), analytics.pending)
        analytics.deactivate()
    }

    func testFailedReportsSurviveRestartWithSameID() async throws {
        let state = AnalyticsTransportState()
        AnalyticsURLProtocol.state = state
        state.setStatus(503)
        let url = queueURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let event = PendingListen(id: "offline-event", collectionID: "playlist", trackID: "song", listenedMS: 30500)
        try JSONEncoder().encode([event]).write(to: url)
        let first = PlaybackAnalytics(session: session, api: try client(), queueURL: url)
        await first.flush()
        XCTAssertEqual(first.pending, [event])
        first.deactivate()
        state.setStatus(200)
        let restored = PlaybackAnalytics(session: session, api: try client(), queueURL: url)
        await restored.flush()
        XCTAssertTrue(restored.pending.isEmpty)
        XCTAssertEqual(restored.revision, 1)
        let saved = try JSONDecoder().decode([PendingListen].self, from: Data(contentsOf: url))
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(state.requests.count, 2)
        for body in state.requests {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["id"] as? String, event.id)
            XCTAssertEqual(json["client"] as? String, "iphone")
            XCTAssertEqual(json["trackId"] as? String, "song")
            XCTAssertEqual(json["listenedMs"] as? Int, 30500)
        }
        restored.deactivate()
    }

    func testRealPlaybackSeekAndAutomaticAdvanceReportCorrectTrack() async throws {
        let audio = queueURL().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        try silentAudio(seconds: 34).write(to: audio)
        let state = AnalyticsTransportState(audio: audio)
        AnalyticsURLProtocol.state = state
        let url = queueURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try client()
        let analytics = PlaybackAnalytics(session: session, api: api, queueURL: url)
        let player = PlayerController()
        player.analytics = analytics
        defer { player.stop(); analytics.deactivate() }
        let collection = MusicCollection(id: "playlist", name: "Fixture", trackCount: 2, artworkID: nil, tracks: [
            MusicTrack(id: "skipped", collectionID: "playlist", title: "Skipped"),
            MusicTrack(id: "listened", collectionID: "playlist", title: "Listened")
        ])
        await player.play(collection: collection, index: 0, api: api, offline: OfflineLibrary(session: nil))
        for _ in 0..<100 {
            if player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(player.isPlaying)
        player.seek(to: 33.5)
        for _ in 0..<100 {
            if player.currentIndex == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertTrue(state.requests.isEmpty, "seeking past 30 seconds counted a listen")
        for _ in 0..<350 {
            if !state.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let data = try XCTUnwrap(state.requests.first, "real playback never reported a listen")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["trackId"] as? String, "listened")
        XCTAssertGreaterThan(try XCTUnwrap(json["listenedMs"] as? Int), 30000)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(state.requests.count, 1)
    }

    private func silentAudio(seconds: Int) -> Data {
        let size = UInt32(8000 * 2 * seconds)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + size); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        text("data"); u32(size); data.append(Data(count: Int(size)))
        return data
    }
}
