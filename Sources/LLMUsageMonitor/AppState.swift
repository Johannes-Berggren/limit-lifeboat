import AppKit
import Combine
import Foundation
import LLMUsageMonitorCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var profiles: [AccountProfile]
    @Published private(set) var snapshots: [UUID: UsageSnapshot]
    @Published private(set) var isRefreshing = false
    @Published var statusMessage = ""

    private let repository: ProfileRepository
    private let cliSwitcher: CLISwitcher
    private let parser = UsageTextParser()
    private let webUsageRefresher = WebUsageRefresher()
    private let dashboardWindowManager = DashboardWindowManager()
    private var refreshTask: Task<Void, Never>?
    private let refreshIntervalSeconds: UInt64 = 600

    init(repository: ProfileRepository, cliSwitcher: CLISwitcher) throws {
        self.repository = repository
        self.cliSwitcher = cliSwitcher
        self.profiles = try repository.loadProfiles()
        self.snapshots = try repository.loadUsageSnapshots()
    }

    deinit {
        refreshTask?.cancel()
    }

    func startBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                await self?.refreshAll()
            }
        }
    }

    func refreshAll() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        for profile in profiles {
            await refresh(profile)
        }
    }

    func refresh(_ profile: AccountProfile) async {
        do {
            let text = try await webUsageRefresher.fetchVisibleText(for: profile)
            ingestDashboardText(text, for: profile, source: profile.provider.dashboardURL.absoluteString)
        } catch {
            let snapshot = UsageSnapshot(
                accountID: profile.id,
                provider: profile.provider,
                riskLevel: .stale,
                source: profile.provider.dashboardURL.absoluteString,
                parseConfidence: .none,
                message: error.localizedDescription
            )
            snapshots[profile.id] = snapshot
            saveSnapshots()
            statusMessage = "\(profile.label): \(error.localizedDescription)"
        }
    }

    func ingestDashboardText(_ text: String, for profile: AccountProfile, source: String) {
        let snapshot = parser.parse(text: text, account: profile, source: source)
        snapshots[profile.id] = snapshot
        saveSnapshots()
        statusMessage = "\(profile.label): \(snapshot.message)"
    }

    func openDashboard(for profile: AccountProfile) {
        dashboardWindowManager.open(profile: profile) { [weak self] text in
            self?.ingestDashboardText(text, for: profile, source: profile.provider.dashboardURL.absoluteString)
        }
    }

    func captureCLISnapshot(for profile: AccountProfile) {
        do {
            _ = try cliSwitcher.captureAndStoreSnapshot(for: profile)
            statusMessage = "Captured \(profile.provider.displayName) CLI snapshot for \(profile.label)."
            objectWillChange.send()
        } catch {
            statusMessage = "Capture failed for \(profile.label): \(error.localizedDescription)"
            showError(message: "Capture failed", details: error.localizedDescription)
        }
    }

    func switchCLI(to profile: AccountProfile) {
        if cliSwitcher.hasActiveProcesses(provider: profile.provider) {
            let alert = NSAlert()
            alert.messageText = "\(profile.provider.displayName) is running"
            alert.informativeText = "The account will be switched for new credential reads. Existing sessions may keep credentials they already loaded."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        do {
            let result = try cliSwitcher.restoreSnapshot(for: profile)
            for index in profiles.indices where profiles[index].provider == profile.provider {
                profiles[index].isActiveCLI = profiles[index].id == profile.id
                profiles[index].updatedAt = Date()
            }
            try repository.saveProfiles(profiles)
            statusMessage = "Switched \(profile.provider.displayName) CLI to \(profile.label). Backups: \(result.backupURLs.count)."
        } catch {
            statusMessage = "Switch failed for \(profile.label): \(error.localizedDescription)"
            showError(message: "Switch failed", details: error.localizedDescription)
        }
    }

    func hasStoredSnapshot(for profile: AccountProfile) -> Bool {
        (try? cliSwitcher.hasStoredSnapshot(for: profile)) ?? false
    }

    func validateActiveLogin(provider: Provider) -> Bool {
        cliSwitcher.validateActiveLogin(provider: provider)
    }

    func copyLoginCommand(for provider: Provider) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(provider.loginCommand, forType: .string)
        statusMessage = "Copied: \(provider.loginCommand)"

        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func saveSnapshots() {
        do {
            try repository.saveUsageSnapshots(snapshots)
        } catch {
            statusMessage = "Could not save usage snapshots: \(error.localizedDescription)"
        }
    }

    private func showError(message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }
}
