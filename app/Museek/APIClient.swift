import Foundation

struct APIError: LocalizedError, Equatable, Sendable {
    let message: String
    let statusCode: Int?
    var errorDescription: String? { message }
}

actor APIClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(serverURL: String, token: String? = nil, session: URLSession = .shared) throws {
        self.baseURL = try Self.normalizedURL(serverURL)
        self.token = token
        self.session = session
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

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, URLResponse) {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appending(path: cleanPath)
        var request = URLRequest(url: url, timeoutInterval: 15)
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
