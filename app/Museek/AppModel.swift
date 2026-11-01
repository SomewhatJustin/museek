import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AppModel {
    enum LibraryState { case loading, loaded, failed(String, revoked: Bool) }

    private(set) var session: AppSession?
    private(set) var initializing = true
    private(set) var pairing = false
    private(set) var pairError: String?
    private(set) var libraryState: LibraryState = .loading
    private(set) var collections: [CollectionSummary] = []
    private(set) var collectionDetails: [String: MusicCollection] = [:]
    private(set) var offline: OfflineLibrary
    let player = PlayerController()
    private let sessionStore = SessionStore()

    init() {
        let restored = try? sessionStore.load()
        session = restored
        offline = OfflineLibrary(session: restored)
        collections = offline.summaries
        initializing = false
        if restored != nil { Task { await refresh() } }
    }

    func api() throws -> APIClient {
        guard let session else { throw APIError(message: "This device is not paired.", statusCode: nil) }
        return try APIClient(serverURL: session.serverURL, token: session.token)
    }

    func pair(serverURL: String, code: String) async {
        pairing = true
        pairError = nil
        defer { pairing = false }
        do {
            let client = try APIClient(serverURL: serverURL)
            let newSession = try await client.pair(code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), deviceName: UIDevice.current.name)
            try sessionStore.save(newSession)
            session = newSession
            offline = OfflineLibrary(session: newSession)
            await refresh()
        } catch let error as APIError { pairError = error.message }
        catch { pairError = "Pairing failed. Please try again." }
    }

    func joinTailnet(_ discovery: TailnetDiscovery) async {
        guard session == nil, !pairing else { return }
        pairing = true
        defer { pairing = false }
        guard let newSession = await discovery.join() else { return }
        do {
            try sessionStore.save(newSession)
            session = newSession
            offline = OfflineLibrary(session: newSession)
            await refresh()
        } catch { pairError = "Could not save this device session. Please try again." }
    }

    func open(_ link: PairingLink) async {
        if let session, !session.sharesHost(with: link) { return }
        await pair(serverURL: link.serverURL, code: link.code)
    }

    func refresh() async {
        libraryState = .loading
        do {
            let remote = try await api().collections()
            var merged = Dictionary(uniqueKeysWithValues: offline.summaries.map { ($0.id, $0) })
            remote.forEach { merged[$0.id] = $0 }
            collections = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            libraryState = .loaded
        } catch let error as APIError {
            if offline.summaries.isEmpty || error.statusCode == 401 {
                libraryState = .failed(error.message, revoked: error.statusCode == 401)
            } else {
                collections = offline.summaries
                libraryState = .loaded
            }
        } catch { libraryState = .failed("Your library could not be loaded.", revoked: false) }
    }

    func collection(id: String, refresh: Bool = false) async throws -> MusicCollection {
        if !refresh, let cached = collectionDetails[id] ?? offline.collection(id) { return cached }
        do {
            let remote = try await api().collection(id: id)
            collectionDetails[id] = remote
            return remote
        } catch {
            if let local = offline.collection(id), (error as? APIError)?.statusCode != 401 { return local }
            throw error
        }
    }

    func signOut() {
        player.stop()
        try? sessionStore.clear()
        session = nil
        collections = []
        collectionDetails = [:]
        offline = OfflineLibrary(session: nil)
    }
}
