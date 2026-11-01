import SwiftUI

struct ArtworkView: View {
    let id: String?
    let model: AppModel
    var cornerRadius: CGFloat = 18
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.25, green: 0.20, blue: 0.48), Color(red: 0.56, green: 0.34, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5) }
        .task(id: id) { await load() }
    }

    private func load() async {
        guard let id else { return }
        if let data = model.offline.artworkData(id: id), let result = UIImage(data: data) { image = result; return }
        guard let api = try? model.api(), let data = try? await api.artwork(id: id) else { return }
        image = UIImage(data: data)
    }
}

