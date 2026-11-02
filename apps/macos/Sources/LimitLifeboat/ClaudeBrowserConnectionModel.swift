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
    private let defaults: UserDefaults
    private static let addedBuiltInDenialKey = "browserConnectionAddedBuiltInDenial"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let removeDenial = defaults.bool(forKey: Self.addedBuiltInDenialKey)
        Task {
            do {
                if enabled {
                    let added = try await Task.detached { try ClaudeBrowserConnection().install() }.value
                    if added { defaults.set(true, forKey: Self.addedBuiltInDenialKey) }
                } else {
                    try await Task.detached {
                        try ClaudeBrowserConnection().uninstall(removeBuiltInDenial: removeDenial)
                    }.value
                    defaults.removeObject(forKey: Self.addedBuiltInDenialKey)
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
