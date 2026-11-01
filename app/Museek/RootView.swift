import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.initializing { ProgressView().controlSize(.large) }
            else if model.session == nil { PairView(model: model) }
            else { LibraryView(model: model) }
        }
        .animation(.snappy, value: model.session)
    }
}

struct PairView: View {
    @Bindable var model: AppModel
    @State private var discovery = TailnetDiscovery()
    @State private var server = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    private enum Field { case server, code }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 58, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.museekAccent)
                        .accessibilityHidden(true)
                    Text("Your music\nis waiting.")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .tracking(-1.2)
                        .padding(.top, 26)
                    Text("Use the private invitation you received. You’ll only do this once.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        if discovery.state == .checking {
                            ProgressView("Checking for Museek on Tailscale…")
                        } else if discovery.state == .found {
                            Label("Museek found", systemImage: "checkmark.circle.fill")
                                .font(.headline).accessibilityIdentifier("tailnet.found")
                            Text("Connect using your authorized Tailscale account.").font(.subheadline).foregroundStyle(.secondary)
                            Button(discovery.joining ? "Joining…" : "Join Museek") {
                                Task { await model.joinTailnet(discovery) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.pairing || discovery.joining)
                            .accessibilityIdentifier("tailnet.join")
                        } else if discovery.state == .notFound {
                            Text("Museek wasn’t found on Tailscale. You can still use an invitation.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Check again") { Task { await discovery.detect() } }
                        }
                        if let error = discovery.error { Text(error).foregroundStyle(.red).font(.subheadline) }
                    }.padding(.top, 24)

                    Text("Or use an invitation").font(.headline).padding(.top, 24)
                    VStack(spacing: 14) {
                        field("Server address", text: $server, icon: "server.rack", field: .server)
                            .textContentType(.URL).keyboardType(.URL)
                            .submitLabel(.next).onSubmit { focus = .code }
                        field("Invitation code", text: $code, icon: "key.fill", field: .code)
                            .textInputAutocapitalization(.characters)
                            .submitLabel(.go).onSubmit(connect)
                    }
                    .padding(.top, 34)

                    if let error = model.pairError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.red)
                            .padding(.top, 16)
                    }

                    Button(action: connect) {
                        HStack {
                            if model.pairing { ProgressView().tint(.white) }
                            Text(model.pairing ? "Connecting…" : "Continue").fontWeight(.semibold)
                            Spacer()
                            if !model.pairing { Image(systemName: "arrow.right") }
                        }
                        .padding(.horizontal, 18).frame(height: 56)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16))
                    .disabled(model.pairing || server.trimmingCharacters(in: .whitespaces).isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, 26)
                }
                .frame(maxWidth: 460).padding(28).frame(maxWidth: .infinity)
            }
            .background(Color.museekBackground)
            .task { await discovery.detect() }
        }
    }

    private func field(_ title: String, text: Binding<String>, icon: String, field: Field) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            TextField(title, text: text).focused($focus, equals: field).autocorrectionDisabled()
        }
        .padding(.horizontal, 16).frame(height: 56)
        .background(.background, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(.separator.opacity(0.45), lineWidth: 0.5) }
    }

    private func connect() {
        focus = nil
        Task { await model.pair(serverURL: server, code: code) }
    }
}
