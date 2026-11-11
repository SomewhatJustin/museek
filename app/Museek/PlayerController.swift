import AVFoundation
import MediaPlayer
import Observation
import UIKit

@MainActor @Observable
final class PlayerController: NSObject {
    private(set) var collection: MusicCollection?
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private let player = AVQueuePlayer()
    private var itemURLs: [URL] = []
    private var artwork: UIImage?
    private var timeObserver: Any?
    var analytics: PlaybackAnalytics?
    private var itemObservation: NSKeyValueObservation?
    private var queuedIndices: [ObjectIdentifier: Int] = [:]
    private var listenItem: AVPlayerItem?
    private var listenIndex: Int?
    private var listenProgress = ListenProgress()
    private var seekID: UUID?
    private var statusObservation: NSKeyValueObservation?

    var currentTrack: MusicTrack? {
        guard let collection, let currentIndex, collection.tracks.indices.contains(currentIndex) else { return nil }
        return collection.tracks[currentIndex]
    }
    var hasNext: Bool { guard let collection, let currentIndex else { return false }; return currentIndex + 1 < collection.tracks.count }

    override init() {
        super.init()
        configureAudioSession()
        observePlayer()
        configureRemoteCommands()
    }

    func play(collection: MusicCollection, index: Int, api: APIClient, offline: OfflineLibrary) async {
        guard collection.tracks.indices.contains(index) else { return }
        isLoading = true
        errorMessage = nil
        do {
            var urls: [URL] = []
            for track in collection.tracks {
                if let local = offline.localURL(for: track) { urls.append(local) }
                else { urls.append(try await api.playURL(trackID: track.id)) }
            }
            let newArtwork = await loadArtwork(for: collection.tracks[index], collection: collection, api: api, offline: offline)
            finishListen()
            self.collection = collection
            itemURLs = urls
            artwork = newArtwork
            begin(at: index, autoplay: true)
        } catch let error as APIError { errorMessage = error.message }
        catch { errorMessage = "This track could not be played." }
        isLoading = false
    }

    func toggle() {
        if isPlaying { player.pause() } else { player.play() }
        updatePlaybackState()
    }

    func next() {
        guard hasNext else { return }
        finishListen()
        player.advanceToNextItem()
        synchronizePlaybackItem()
        updatePlaybackState()
    }

    func previous() {
        guard let currentIndex else { return }
        if position > 4 || currentIndex == 0 {
            sampleListen()
            listenProgress = ListenProgress()
            seek(to: 0)
        }
        else { begin(at: currentIndex - 1, autoplay: isPlaying) }
    }

    func seek(to seconds: TimeInterval) {
        sampleListen()
        listenProgress.invalidateBaseline()
        let id = UUID()
        seekID = id
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, seekID == id else { return }
                seekID = nil
                listenProgress.invalidateBaseline()
                sampleListen()
            }
        }
        position = max(0, seconds)
        updateMetadata()
    }

    func stop() {
        finishListen()
        queuedIndices = [:]
        player.pause()
        player.removeAllItems()
        collection = nil
        currentIndex = nil
        itemURLs = []
        isPlaying = false
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func dismissError() { errorMessage = nil }

    private func begin(at index: Int, autoplay: Bool) {
        finishListen()
        queuedIndices = [:]
        player.removeAllItems()
        for (offset, url) in itemURLs.enumerated().dropFirst(index) {
            let item = AVPlayerItem(url: url)
            queuedIndices[ObjectIdentifier(item)] = offset
            player.insert(item, after: nil)
        }
        currentIndex = index
        synchronizePlaybackItem()
        position = 0
        duration = collection?.tracks[index].duration ?? 0
        updateMetadata()
        if autoplay { player.play() }
        updatePlaybackState()
    }

    private func loadArtwork(for track: MusicTrack, collection: MusicCollection, api: APIClient, offline: OfflineLibrary) async -> UIImage? {
        let id = track.artworkID ?? collection.artworkID
        if let data = offline.artworkData(id: id) { return UIImage(data: data) }
        guard let id, let data = try? await api.artwork(id: id) else { return nil }
        return UIImage(data: data)
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch { errorMessage = "Background audio could not be enabled." }
    }

    private func observePlayer() {
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePlaybackState() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 2), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                synchronizePlaybackItem()
                sampleListen()
                let seconds = player.currentTime().seconds
                position = max(0, seconds.isFinite ? seconds : 0)
                if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 { duration = seconds }
                updateMetadata()
            }
        }
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.synchronizePlaybackItem()
                self?.updatePlaybackState()
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.play(); self?.updatePlaybackState() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause(); self?.updatePlaybackState() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func synchronizePlaybackItem() {
        guard player.currentItem !== listenItem else { return }
        finishListen()
        guard let item = player.currentItem, let index = queuedIndices[ObjectIdentifier(item)] else { return }
        listenItem = item
        listenIndex = index
        currentIndex = index
        position = 0
        duration = collection?.tracks[index].duration ?? 0
        sampleListen()
    }

    private func sampleListen() {
        guard seekID == nil, let item = listenItem, let index = listenIndex,
              let collection, collection.tracks.indices.contains(index) else { return }
        if listenProgress.sample(position: item.currentTime().seconds, uptime: ProcessInfo.processInfo.systemUptime,
                                 playing: player.currentItem === item && player.timeControlStatus == .playing) {
            analytics?.record(collectionID: collection.id, trackID: collection.tracks[index].id, seconds: listenProgress.seconds)
        }
    }

    private func finishListen() {
        sampleListen()
        listenItem = nil
        listenIndex = nil
        listenProgress = ListenProgress()
        seekID = nil
    }

    private func updatePlaybackState() {
        synchronizePlaybackItem()
        sampleListen()
        isPlaying = player.timeControlStatus == .playing
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        updateMetadata()
    }

    private func updateMetadata() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyAlbumTitle: track.album.isEmpty ? (collection?.name ?? "Museek") : track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : track.duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
