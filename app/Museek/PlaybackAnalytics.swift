import CryptoKit
import Foundation
import Observation

// Counts advancing audio, bounded by monotonic elapsed time. A seek invalidates
// the baseline so jumping forward cannot qualify a listen.
struct ListenProgress {
    private(set) var seconds: TimeInterval = 0
    private var previousPosition: TimeInterval?
    private var previousTime: TimeInterval?
    private var wasPlaying = false
    private var reported = false

    mutating func sample(position: TimeInterval, uptime: TimeInterval, playing: Bool) -> Bool {
        guard position.isFinite, uptime.isFinite else { invalidateBaseline(); return false }
        if wasPlaying, let oldPosition = previousPosition, let oldTime = previousTime {
            seconds += min(max(0, position - oldPosition), max(0, uptime - oldTime))
        }
        previousPosition = position
        previousTime = uptime
        wasPlaying = playing
        guard seconds > 30, !reported else { return false }
        reported = true
        return true
    }

    mutating func invalidateBaseline() {
        previousPosition = nil
        previousTime = nil
        wasPlaying = false
    }
}

struct PendingListen: Codable, Equatable, Sendable {
    let id: String
    let collectionID: String
    let trackID: String
    let listenedMS: Int
}

@MainActor @Observable
final class PlaybackAnalytics {
    private(set) var revision = 0
    private(set) var pending: [PendingListen] = []
    private let api: APIClient
    private let queueURL: URL
    private var flushing = false
    private var active = true
    private var retryTask: Task<Void, Never>?

    init(session: AppSession, api: APIClient, queueURL: URL? = nil) {
        self.api = api
        let profile = "\(session.serverURL)|\(session.recipientID)"
        let key = SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
        self.queueURL = queueURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "museek-listens/\(key).json")
        if let data = try? Data(contentsOf: self.queueURL),
           let saved = try? JSONDecoder().decode([PendingListen].self, from: data) { pending = saved }
    }

    func record(collectionID: String, trackID: String, seconds: TimeInterval) {
        guard active, seconds > 30 else { return }
        pending.append(PendingListen(id: UUID().uuidString, collectionID: collectionID, trackID: trackID, listenedMS: max(30001, Int(seconds * 1_000))))
        persist()
        Task { await flush() }
    }

    func deactivate() {
        active = false
        retryTask?.cancel()
        retryTask = nil
    }

    // The same event ID survives retries, app restarts, and re-pairing. A lost
    // response therefore cannot turn one playback into two server-side plays.
    func flush() async {
        guard active, !flushing else { return }
        retryTask?.cancel()
        retryTask = nil
        flushing = true
        defer { flushing = false }
        while active, let event = pending.first {
            do {
                try await api.recordListen(event)
                guard active else { return }
                revision += 1
            } catch let error as APIError where error.statusCode == 400 || error.statusCode == 404 {
                // Removed playlist entries or withdrawn grants cannot be synced.
            } catch {
                if (error as? APIError)?.statusCode != 401 {
                    retryTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        await self?.flush()
                    }
                }
                return
            }
            guard active else { return }
            pending.removeFirst()
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: queueURL, options: .atomic)
    }
}
