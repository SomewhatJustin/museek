import Foundation

struct AppSession: Codable, Equatable, Sendable {
    let serverURL: String
    let token: String
    let recipientID: String
    let recipientName: String
}

struct CollectionSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let trackCount: Int
    let artworkID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, trackCount
        case artworkID = "artworkId"
    }
}

struct MusicTrack: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let collectionID: String
    let title: String
    let artist: String
    let album: String
    let discNumber: Int
    let trackNumber: Int
    let durationMS: Int
    let artworkID: String?

    var duration: TimeInterval { Double(durationMS) / 1_000 }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, discNumber, trackNumber
        case collectionID = "collectionId"
        case durationMS = "durationMs"
        case artworkID = "artworkId"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        collectionID = try values.decode(String.self, forKey: .collectionID)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try values.decodeIfPresent(String.self, forKey: .album) ?? ""
        discNumber = try values.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
        trackNumber = try values.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        durationMS = try values.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0
        artworkID = try values.decodeIfPresent(String.self, forKey: .artworkID)
    }

    init(id: String, collectionID: String, title: String, artist: String = "", album: String = "", discNumber: Int = 0, trackNumber: Int = 0, durationMS: Int = 0, artworkID: String? = nil) {
        self.id = id
        self.collectionID = collectionID
        self.title = title
        self.artist = artist
        self.album = album
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.durationMS = durationMS
        self.artworkID = artworkID
    }
}

struct MusicCollection: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let trackCount: Int
    let artworkID: String?
    let tracks: [MusicTrack]

    var summary: CollectionSummary {
        CollectionSummary(id: id, name: name, trackCount: trackCount, artworkID: artworkID)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, trackCount, tracks
        case artworkID = "artworkId"
    }
}

struct PairingLink: Equatable, Sendable {
    let serverURL: String
    let code: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "museek", url.host?.lowercased() == "pair",
              url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverValue = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let server = URL(string: serverValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = server.scheme?.lowercased(), ["https", "http"].contains(scheme),
              server.host != nil, server.user == nil,
              let rawCode = components.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil else { return nil }
        if scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(server.host ?? "") { return nil }
        self.serverURL = server.absoluteString
        self.code = code
    }
}

extension AppSession {
    func sharesHost(with link: PairingLink) -> Bool {
        guard let current = URL(string: serverURL), let invited = URL(string: link.serverURL) else { return false }
        return current.scheme == invited.scheme && current.host == invited.host
    }
}
