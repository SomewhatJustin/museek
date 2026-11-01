import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Listener", value: model.session?.recipientName ?? "")
                    LabeledContent("Server") { Text(model.session?.serverURL ?? "").multilineTextAlignment(.trailing).foregroundStyle(.secondary) }
                }
                Section {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmingSignOut = true }
                } footer: { Text("You’ll need a new invitation code to pair this iPhone again. Downloaded music stays on this device for this listener.") }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { dismiss(); model.signOut() }
            } message: { Text("You’ll need a new invitation code to pair this device again.") }
        }
    }
}
