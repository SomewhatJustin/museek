import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var showingSettings = false
    @State private var showingPlayer = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.libraryState {
                case .loading where model.collections.isEmpty: ProgressView().controlSize(.large)
                case .failed(let message, let revoked): LibraryErrorView(message: message, revoked: revoked, model: model)
                default: library
                }
            }
            .navigationTitle("Museek")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.player.currentTrack != nil { MiniPlayer(model: model, showingPlayer: $showingPlayer) }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .fullScreenCover(isPresented: $showingPlayer) { NowPlayingView(model: model) }
        }
    }

    private var library: some View {
        ScrollView {
            if model.collections.isEmpty {
                ContentUnavailableView("Nothing shared yet", systemImage: "music.note.list", description: Text("When a collection is shared with \(model.session?.recipientName ?? "you"), it will appear here."))
                    .padding(.top, 90)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(model.collections) { collection in
                        NavigationLink(value: collection) { CollectionRow(collection: collection, model: model) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 28)
            }
        }
        .background(Color.museekBackground)
        .refreshable { await model.refresh() }
        .navigationDestination(for: CollectionSummary.self) { CollectionView(summary: $0, model: model) }
    }
}

private struct CollectionRow: View {
    let collection: CollectionSummary
    let model: AppModel
    var body: some View {
        HStack(spacing: 15) {
            ArtworkView(id: collection.artworkID, model: model, cornerRadius: 13).frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 5) {
                Text(collection.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text("\(collection.trackCount) \(collection.trackCount == 1 ? "track" : "tracks")").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(10).background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}

private struct LibraryErrorView: View {
    let message: String
    let revoked: Bool
    let model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label(revoked ? "Pair again" : "Server unavailable", systemImage: revoked ? "lock" : "wifi.slash")
        } description: { Text(message) } actions: {
            Button(revoked ? "Pair again" : "Try again") { if revoked { model.signOut() } else { Task { await model.refresh() } } }.buttonStyle(.borderedProminent)
        }
    }
}

private struct MiniPlayer: View {
    let model: AppModel
    @Binding var showingPlayer: Bool
    var body: some View {
        let track = model.player.currentTrack
        HStack(spacing: 12) {
            ArtworkView(id: track?.artworkID ?? model.player.collection?.artworkID, model: model, cornerRadius: 8).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(track?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(model.player.isPlaying ? "Pause" : "Play", systemImage: model.player.isPlaying ? "pause.fill" : "play.fill") { model.player.toggle() }.labelStyle(.iconOnly).font(.title3).frame(width: 42, height: 42)
            Button("Next", systemImage: "forward.fill") { model.player.next() }.labelStyle(.iconOnly).font(.title3).frame(width: 42, height: 42).disabled(!model.player.hasNext)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial).contentShape(Rectangle())
        .onTapGesture { showingPlayer = true }
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
