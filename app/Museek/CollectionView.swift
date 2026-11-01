import SwiftUI

struct CollectionView: View {
    let summary: CollectionSummary
    @Bindable var model: AppModel
    @State private var collection: MusicCollection?
    @State private var errorMessage: String?
    @State private var showingRemove = false
    @State private var showingPlayer = false

    var body: some View {
        Group {
            if let collection { content(collection) }
            else if let errorMessage { ContentUnavailableView("Couldn’t load this collection", systemImage: "exclamationmark.triangle", description: Text(errorMessage)).overlay(alignment: .bottom) { Button("Try again") { Task { await load(refresh: true) } }.buttonStyle(.borderedProminent).padding(.bottom, 100) } }
            else { ProgressView().controlSize(.large) }
        }
        .background(Color.museekBackground)
        .navigationTitle(summary.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { if let collection { ToolbarItem(placement: .topBarTrailing) { downloadButton(collection) } } }
        .safeAreaInset(edge: .bottom, spacing: 0) { if model.player.currentTrack != nil { collectionMiniPlayer } }
        .fullScreenCover(isPresented: $showingPlayer) { NowPlayingView(model: model) }
        .confirmationDialog("Remove download?", isPresented: $showingRemove, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { if let collection { try? model.offline.remove(collection.id); Task { await model.refresh() } } }
        } message: { Text("\(summary.name) will need an internet connection to play again.") }
        .task { await load(refresh: false) }
    }

    private func content(_ collection: MusicCollection) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ArtworkView(id: collection.artworkID, model: model, cornerRadius: 24)
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: 290)
                    .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
                    .padding(.top, 14)
                Text(collection.name).font(.title2.bold()).multilineTextAlignment(.center).padding(.top, 26)
                Text("\(collection.tracks.count) \(collection.tracks.count == 1 ? "track" : "tracks")").font(.subheadline).foregroundStyle(.secondary).padding(.top, 5).padding(.bottom, 26)
                LazyVStack(spacing: 0) {
                    ForEach(Array(collection.tracks.enumerated()), id: \.element.id) { index, track in
                        Button { play(collection, index: index) } label: { TrackRow(track: track, playingID: model.player.currentTrack?.id) }.buttonStyle(.plain)
                        if track.id != collection.tracks.last?.id { Divider().padding(.leading, 16) }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16).padding(.bottom, 30)
            }.frame(maxWidth: .infinity)
        }.refreshable { await load(refresh: true) }
    }

    @ViewBuilder private func downloadButton(_ collection: MusicCollection) -> some View {
        switch model.offline.phase(collection.id) {
        case .idle:
            Button("Download", systemImage: "arrow.down.circle") { download(collection) }.disabled(collection.tracks.isEmpty)
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 26).accessibilityLabel("Downloading \(done) of \(total)")
        case .downloaded:
            Button("Downloaded", systemImage: "checkmark.circle.fill") { showingRemove = true }
        case .failed:
            Button("Retry download", systemImage: "arrow.clockwise") { download(collection) }
        }
    }

    private var collectionMiniPlayer: some View {
        HStack(spacing: 12) {
            ArtworkView(id: model.player.currentTrack?.artworkID ?? model.player.collection?.artworkID, model: model, cornerRadius: 8).frame(width: 44, height: 44)
            Text(model.player.currentTrack?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button("Play or pause", systemImage: model.player.isPlaying ? "pause.fill" : "play.fill") { model.player.toggle() }.labelStyle(.iconOnly).font(.title3).frame(width: 44, height: 44)
        }.padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial).onTapGesture { showingPlayer = true }.overlay(alignment: .top) { Divider() }
    }

    private func load(refresh: Bool) async {
        do { collection = try await model.collection(id: summary.id, refresh: refresh); errorMessage = nil }
        catch { errorMessage = (error as? APIError)?.message ?? "This collection could not be loaded." }
    }
    private func play(_ collection: MusicCollection, index: Int) { Task { if let api = try? model.api() { await model.player.play(collection: collection, index: index, api: api, offline: model.offline) } } }
    private func download(_ collection: MusicCollection) { Task { if let api = try? model.api() { try? await model.offline.download(collection, api: api); await model.refresh() } } }
}

private struct TrackRow: View {
    let track: MusicTrack
    let playingID: String?
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if !track.artist.isEmpty { Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if playingID == track.id {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.museekAccent)
            }
            if track.duration > 0 { Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 12).frame(minHeight: 60).contentShape(Rectangle()).accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}
