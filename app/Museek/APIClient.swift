import Foundation

#if DEBUG
// Replace only HTTP transport: discovery, decoding, AppModel, and Keychain stay real.
final class UITestTransport: URLProtocol, @unchecked Sendable {
    static var scenario: String? {
        let value = ProcessInfo.processInfo.environment["MUSEEK_UI_TEST_SCENARIO"]
        return ["success", "restore", "unauthorized", "notFound"].contains(value ?? "") ? value : nil
    }

    static func session() -> URLSession? {
        guard scenario != nil else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UITestTransport.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int
        let body: String
        // Fail closed: never contact the live server or accept an unexpected host/method.
        switch (request.url?.absoluteString, request.httpMethod, Self.scenario) {
        case ("https://elitedesk-1.tail6900fe.ts.net:10002/v1/server", "GET", "success"),
             ("https://elitedesk-1.tail6900fe.ts.net:10002/v1/server", "GET", "unauthorized"):
            status = 200
            body = #"{"name":"Museek","tailnetJoin":true,"version":1}"#
        case ("https://elitedesk-1.tail6900fe.ts.net:10002/v1/tailnet/join", "POST", "success"):
            status = 201
            body = #"{"token":"ui-fixture-bearer","recipient":{"id":"ui-fixture-listener","name":"Fixture Listener"}}"#
        case ("https://elitedesk-1.tail6900fe.ts.net:10002/v1/tailnet/join", "POST", "unauthorized"):
            status = 403
            body = #"{"error":"This Tailscale account is not authorized to join Museek."}"#
        case ("https://elitedesk-1.tail6900fe.ts.net:10002/v1/collections", "GET", let scenario)
            where (scenario == "success" || scenario == "restore") && request.value(forHTTPHeaderField: "Authorization") == "Bearer ui-fixture-bearer":
            status = 200
            let name = scenario == "restore" ? "Restored fixture collection" : "Joined fixture collection"
            body = "{\"collections\":[{\"id\":\"ui-fixture-collection\",\"name\":\"\(name)\",\"trackCount\":1}]}"
        default:
            status = 403
            body = #"{"error":"Unexpected UI fixture request"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif

struct APIError: LocalizedError, Equatable, Sendable {
    let message: String
    let statusCode: Int?
    var errorDescription: String? { message }
}

actor APIClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(serverURL: String, token: String? = nil, session: URLSession? = nil) throws {
        self.baseURL = try Self.normalizedURL(serverURL)
        self.token = token
        #if DEBUG
        self.session = session ?? UITestTransport.session() ?? .shared
        #else
        self.session = session ?? .shared
        #endif
    }

    static func normalizedURL(_ input: String) throws -> URL {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw APIError(message: "Enter a valid server address.", statusCode: nil)
        }
        if scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(host) {
            throw APIError(message: "Museek requires HTTPS outside local development.", statusCode: nil)
        }
        while components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw APIError(message: "Enter a valid server address.", statusCode: nil) }
        return url
    }

    func pair(code: String, deviceName: String) async throws -> AppSession {
        struct Request: Encodable { let code: String; let deviceName: String }
        struct Recipient: Decodable { let id: String; let name: String }
        struct Response: Decodable { let token: String; let recipient: Recipient }
        let result: Response = try await send("/v1/pair", method: "POST", body: Request(code: code, deviceName: deviceName), expected: 201)
        return AppSession(serverURL: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: result.token, recipientID: result.recipient.id, recipientName: result.recipient.name)
    }

    func detectTailnet() async throws -> Bool {
        struct Server: Decodable { let name: String; let tailnetJoin: Bool; let version: Int }
        let (data, response) = try await request("/v1/server", timeout: 3)
        try validate(response, data: data, expected: 200)
        let server = try JSONDecoder().decode(Server.self, from: data)
        return server.name == "Museek" && server.tailnetJoin && server.version == 1
    }

    func joinTailnet(deviceName: String) async throws -> AppSession {
        struct Request: Encodable { let deviceName: String }
        struct Recipient: Decodable { let id: String; let name: String }
        struct Response: Decodable { let token: String; let recipient: Recipient }
        let result: Response = try await send("/v1/tailnet/join", method: "POST", body: Request(deviceName: deviceName), expected: 201)
        return AppSession(serverURL: baseURL.absoluteString, token: result.token, recipientID: result.recipient.id, recipientName: result.recipient.name)
    }

    func collections() async throws -> [CollectionSummary] {
        struct Response: Decodable { let collections: [CollectionSummary] }
        return try await send("/v1/collections", as: Response.self).collections
    }

    func collection(id: String) async throws -> MusicCollection {
        try await send("/v1/collections/\(encoded(id))", as: MusicCollection.self)
    }

    func playURL(trackID: String) async throws -> URL {
        struct Response: Decodable { let url: URL }
        return try await send("/v1/tracks/\(encoded(trackID))/play-url", method: "POST", as: Response.self).url
    }

    func artwork(id: String) async throws -> Data {
        let (data, response) = try await request("/v1/artwork/\(encoded(id))")
        try validate(response, data: data, expected: 200)
        return data
    }

    func download(trackID: String) async throws -> Data {
        let url = try await playURL(trackID: trackID)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, expected: 200)
            return data
        } catch let error as APIError { throw error }
        catch { throw networkError(error) }
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", as: T.Type = T.self, expected: Int = 200) async throws -> T {
        let (data, response) = try await request(path, method: method)
        try validate(response, data: data, expected: expected)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: "The server returned an unreadable response.", statusCode: nil) }
    }

    private func send<Body: Encodable, T: Decodable>(_ path: String, method: String, body: Body, expected: Int) async throws -> T {
        let encodedBody = try JSONEncoder().encode(body)
        let (data, response) = try await request(path, method: method, body: encodedBody)
        try validate(response, data: data, expected: expected)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: "The server returned an unreadable response.", statusCode: nil) }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 15) async throws -> (Data, URLResponse) {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appending(path: cleanPath)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do { return try await session.data(for: request) }
        catch { throw networkError(error) }
    }

    private func validate(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "The server returned an unreadable response.", statusCode: nil) }
        guard http.statusCode == expected else {
            var message = "The server returned an error."
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let serverMessage = json["error"] as? String { message = serverMessage }
            if http.statusCode == 401 { message = token == nil ? "That pairing code is invalid or expired." : "This device no longer has access." }
            throw APIError(message: message, statusCode: http.statusCode)
        }
    }

    private func networkError(_ error: Error) -> APIError {
        if (error as? URLError)?.code == .timedOut { return APIError(message: "The server took too long to respond.", statusCode: nil) }
        return APIError(message: "Museek could not reach this server.", statusCode: nil)
    }

    private func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value }
}
