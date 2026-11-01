import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class OfflineLibrary {
    enum Phase: Equatable { case idle, downloading(Int, Int), downloaded, failed(String) }

    private(set) var collections: [String: MusicCollection] = [:]
    private(set) var phases: [String: Phase] = [:]
    private let profileKey: String?
    private let fileManager = FileManager.default

    init(session: AppSession?) {
        profileKey = session.map { "\($0.serverURL)|\($0.recipientID)" }
        load()
    }

    var summaries: [CollectionSummary] { collections.values.map(\.summary).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    func collection(_ id: String) -> MusicCollection? { collections[id] }
    func phase(_ id: String) -> Phase { phases[id] ?? (collections[id] == nil ? .idle : .downloaded) }

    func localURL(for track: MusicTrack) -> URL? {
        guard collections[track.collectionID] != nil else { return nil }
        let url = trackURL(collectionID: track.collectionID, trackID: track.id)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func artworkData(id: String?) -> Data? {
        guard let id else { return nil }
        return try? Data(contentsOf: artworkURL(id: id))
    }

    func download(_ collection: MusicCollection, api: APIClient) async throws {
        guard profileKey != nil else { return }
        phases[collection.id] = .downloading(0, collection.tracks.count)
        do {
            for (index, track) in collection.tracks.enumerated() {
                let data = try await api.download(trackID: track.id)
                let destination = trackURL(collectionID: collection.id, trackID: track.id)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                phases[collection.id] = .downloading(index + 1, collection.tracks.count)
            }
            let artIDs = Set(([collection.artworkID] + collection.tracks.map(\.artworkID)).compactMap { $0 })
            for id in artIDs {
                if let data = try? await api.artwork(id: id) {
                    let destination = artworkURL(id: id)
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                }
            }
            collections[collection.id] = collection
            try persist()
            phases[collection.id] = .downloaded
        } catch {
            let message = (error as? APIError)?.message ?? "This mixtape could not be downloaded."
            phases[collection.id] = .failed(message)
            throw error
        }
    }

    func remove(_ id: String) throws {
        collections[id] = nil
        phases[id] = nil
        try persist()
        let url = root.appending(path: "audio/\(hash(id))", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func load() {
        guard profileKey != nil, let data = try? Data(contentsOf: manifestURL),
              let items = try? JSONDecoder().decode([MusicCollection].self, from: data) else { return }
        collections = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Array(collections.values))
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    private var root: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "museek-downloads/\(hash(profileKey ?? "unpaired"))", directoryHint: .isDirectory)
    }
    private var manifestURL: URL { root.appending(path: "manifest.json") }
    private func trackURL(collectionID: String, trackID: String) -> URL { root.appending(path: "audio/\(hash(collectionID))/\(hash(trackID)).mp3") }
    private func artworkURL(id: String) -> URL { root.appending(path: "artwork/\(hash(id))") }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

