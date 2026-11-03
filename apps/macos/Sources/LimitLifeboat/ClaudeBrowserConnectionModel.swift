import Foundation
import LimitLifeboatCore

/// Settings state for keeping Claude in Chrome connected across account
/// switches. Opt-in, and only ever undoes what it did itself.
@MainActor
final class ClaudeBrowserConnectionModel: ObservableObject {
    @Published private(set) var status: ClaudeBrowserConnection.Status = .notSet
    @Published private(set) var signedInAs: String?
    @Published private(set) var health: ClaudeBrowserConnection.Health?
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?

    private let connection = ClaudeBrowserConnection()
    private let terminalLauncher = TerminalCommandLauncher()

    init() {
        refresh()
    }

    func refresh() {
        status = connection.status()
        let identity = connection.signedInIdentity()
        signedInAs = [identity?.email, identity?.organization]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    func signIn() {
        error = nil
        if terminalLauncher.runViaAutomation(ClaudeBrowserConnection.loginCommand) != nil,
           !terminalLauncher.runViaCommandFile(ClaudeBrowserConnection.loginCommand) {
            error = "Terminal could not be opened. Run this yourself: \(ClaudeBrowserConnection.loginCommand)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        health = nil
        isWorking = true
        Task {
            do {
                if enabled {
                    try await Task.detached { try ClaudeBrowserConnection().install() }.value
                } else {
                    try await Task.detached { try ClaudeBrowserConnection().uninstall() }.value
                }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
            refresh()
            if enabled, status == .installed { checkConnection() }
        }
    }

    func checkConnection() {
        guard !isWorking else { return }
        isWorking = true
        health = nil
        Task {
            health = await Task.detached { ClaudeBrowserConnection().checkConnection() }.value
            isWorking = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
