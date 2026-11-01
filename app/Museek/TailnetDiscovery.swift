import Foundation
import Observation
import UIKit

@MainActor @Observable
final class TailnetDiscovery {
    static let serverURL = "https://elitedesk-1.tail6900fe.ts.net:10002"
    enum State: Equatable { case idle, checking, found, notFound }
    private(set) var state: State = .idle
    private(set) var joining = false
    private(set) var error: String?
    let manualInvitationAvailable = true
    private let probe: @MainActor () async -> Bool
    private let joinAction: @MainActor () async throws -> AppSession

    init(probe: @escaping @MainActor () async -> Bool = {
        do { return try await APIClient(serverURL: TailnetDiscovery.serverURL).detectTailnet() }
        catch { return false }
    }, join: @escaping @MainActor () async throws -> AppSession = {
        return try await APIClient(serverURL: TailnetDiscovery.serverURL).joinTailnet(deviceName: UIDevice.current.name)
    }) {
        self.probe = probe
        self.joinAction = join
    }

    func detect() async {
        guard state == .idle || state == .notFound else { return }
        state = .checking
        let found = await probe()
        guard !Task.isCancelled else { state = .idle; return }
        state = found ? .found : .notFound
    }

    func join() async -> AppSession? {
        guard state == .found, !joining else { return nil }
        joining = true
        error = nil
        defer { joining = false }
        do { return try await joinAction() }
        catch let failure as APIError { error = failure.message }
        catch { self.error = "Museek could not join. Check Tailscale or use your invitation below." }
        return nil
    }
}
