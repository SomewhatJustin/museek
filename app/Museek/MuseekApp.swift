import SwiftUI

@main
struct MuseekApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(.museekAccent)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.analytics?.flush() } }
                }
                .onOpenURL { url in
                    guard let link = PairingLink(url: url) else { return }
                    Task { await model.open(link) }
                }
        }
    }
}

extension Color {
    static let museekAccent = Color(red: 0.42, green: 0.25, blue: 0.82)
    static let museekBackground = Color(uiColor: .systemGroupedBackground)
}

