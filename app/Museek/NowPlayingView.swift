import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var scrubPosition: Double?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ArtworkView(id: model.player.currentTrack?.artworkID ?? model.player.collection?.artworkID, model: model, cornerRadius: 28)
                            .frame(width: min(proxy.size.width - 48, 390), height: min(proxy.size.width - 48, 390))
                            .shadow(color: .black.opacity(0.22), radius: 28, y: 16).padding(.top, 18)
                        Text(model.player.currentTrack?.title ?? "Nothing Playing")
                            .accessibilityIdentifier("nowPlaying.title")
                            .font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2).padding(.top, 34)
                        Text(artist).font(.title3).foregroundStyle(.secondary).lineLimit(1).padding(.top, 7)
                        progress.padding(.top, 28)
                        controls.padding(.top, 18)
                        if let track = model.player.currentTrack, let note = track.noteText {
                            SongNoteCard(track: track, note: note)
                                .padding(22)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.songNotePaper, in: RoundedRectangle(cornerRadius: 20))
                                .padding(.top, 28)
                        }
                        if let error = model.player.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle.fill").font(.subheadline).foregroundStyle(.red).padding(.top, 28).onTapGesture { model.player.dismissError() }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 40).frame(maxWidth: .infinity)
                }
            }
            .background(Color.museekBackground)
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "chevron.down") { dismiss() }.labelStyle(.iconOnly) } }
        }
    }

    private var artist: String {
        let value = model.player.currentTrack?.artist ?? ""
        return value.isEmpty ? (model.player.collection?.name ?? "") : value
    }
    private var progress: some View {
        VStack(spacing: 5) {
            Slider(value: Binding(get: { scrubPosition ?? model.player.position }, set: { scrubPosition = $0 }), in: 0...max(model.player.duration, 1), onEditingChanged: { editing in if !editing, let value = scrubPosition { model.player.seek(to: value); scrubPosition = nil } })
            HStack { Text(clock(scrubPosition ?? model.player.position)); Spacer(); Text("−\(clock(max(0, model.player.duration - (scrubPosition ?? model.player.position))))") }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
    private var controls: some View {
        HStack(spacing: 42) {
            Button("Previous", systemImage: "backward.fill") { model.player.previous() }.labelStyle(.iconOnly).font(.system(size: 32)).frame(width: 54, height: 54)
            Button(model.player.isPlaying ? "Pause" : "Play", systemImage: model.player.isPlaying ? "pause.fill" : "play.fill") { model.player.toggle() }
                .labelStyle(.iconOnly).font(.system(size: 34)).foregroundStyle(.white).frame(width: 76, height: 76).background(Color.museekAccent, in: Circle()).disabled(model.player.isLoading)
            Button("Next", systemImage: "forward.fill") { model.player.next() }.labelStyle(.iconOnly).font(.system(size: 32)).frame(width: 54, height: 54).disabled(!model.player.hasNext)
        }
    }
}

func clock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "0:00" }
    return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}



// Both presentations use the playlist entry, never a global song lookup.
struct SongNoteCard: View {
    let track: MusicTrack
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("A NOTE FOR YOU", systemImage: "note.text")
                .font(.caption.weight(.medium)).tracking(1.2).foregroundStyle(Color.museekAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.subheadline.weight(.semibold))
                if !track.artist.isEmpty { Text(track.artist).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            Text(note).font(.system(.title3, design: .serif))
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("song.note.card")
    }
}

struct SongNotePopover: View {
    @Environment(\.dismiss) private var dismiss
    let track: MusicTrack
    let note: String
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close note", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            ScrollView {
                SongNoteCard(track: track, note: note)
                    .padding(.horizontal, 22).padding(.bottom, 24)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: NoteContentHeight.self, value: proxy.size.height)
                        }
                    }
            }
            .frame(height: min(contentHeight, 320))
            .onPreferenceChange(NoteContentHeight.self) { contentHeight = $0 }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 300)
    }
}

extension Color {
    static var songNotePaper: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.20, green: 0.21, blue: 0.17, alpha: 1)
                : UIColor(red: 0.95, green: 0.93, blue: 0.87, alpha: 1)
        })
    }
}

private struct NoteContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
