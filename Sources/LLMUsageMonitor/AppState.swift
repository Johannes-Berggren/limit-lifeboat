import AppKit
import Combine
import Foundation
import LLMUsageMonitorCore
import UserNotifications

struct MenuBarSummary: Equatable {
    var title: String
    var accessibilityText: String
    var riskLevel: RiskLevel

    static let empty = MenuBarSummary(
        title: "C --  G --",
        accessibilityText: "LLM usage has not been refreshed.",
        riskLevel: .unknown
    )
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var profiles: [AccountProfile]
    @Published private(set) var snapshots: [UUID: UsageSnapshot]
    @Published private(set) var isRefreshing = false
    @Published var menuBarSummary: MenuBarSummary = .empty
    @Published var statusMessage = ""

    private let repository: ProfileRepository
    private let cliSwitcher: CLISwitcher
    private let parser = UsageTextParser()
    private let identityExtractor = AccountIdentityExtractor()
    private let codexIdentityReader = CodexIdentityReader()
    private let webUsageRefresher = WebUsageRefresher()
    private let dashboardWindowManager = DashboardWindowManager()
    private let loginFlowWindowManager = LoginFlowWindowManager()
    private let usageAlertController = UsageAlertController()
    private var refreshTask: Task<Void, Never>?

    init(repository: ProfileRepository, cliSwitcher: CLISwitcher) throws {
        self.repository = repository
        self.cliSwitcher = cliSwitcher
        self.profiles = try repository.loadProfiles()
        self.snapshots = try repository.loadUsageSnapshots()
        autoImportPrimaryCLISnapshots()
        updateMenuBarSummary()
        usageAlertController.requestAuthorization()
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
        var fallbackSnapshot: UsageSnapshot?

        do {
            for url in profile.provider.dashboardURLs {
                let text = try await webUsageRefresher.fetchVisibleText(for: profile, url: url)
                let snapshot = ingestDashboardText(text, for: profile, source: url.absoluteString)
                if snapshot.parseConfidence != .none || snapshot.riskLevel == .stale {
                    return
                }
                fallbackSnapshot = snapshot
            }

            if let fallbackSnapshot {
                snapshots[profile.id] = fallbackSnapshot
                updateMenuBarSummary()
                saveSnapshots()
                statusMessage = "\(profile.label): \(fallbackSnapshot.message)"
            }
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
            updateMenuBarSummary()
            saveSnapshots()
            statusMessage = "\(profile.label): \(error.localizedDescription)"
        }
    }

    @discardableResult
    func ingestDashboardText(_ text: String, for profile: AccountProfile, source: String) -> UsageSnapshot {
        if let identity = identityExtractor.extractFromDashboardText(text) {
            updateIdentity(identity, for: profile)
        }

        let snapshot = parser.parse(text: text, account: profile, source: source)
        snapshots[profile.id] = snapshot
        updateMenuBarSummary()
        usageAlertController.handle(snapshot: snapshot, profile: profile)
        saveSnapshots()
        statusMessage = "\(profile.label): \(snapshot.message)"
        return snapshot
    }

    func openDashboard(for profile: AccountProfile) {
        dashboardWindowManager.open(profile: profile) { [weak self] text in
            self?.ingestDashboardText(text, for: profile, source: profile.provider.dashboardURL.absoluteString)
        }
    }

    func openLoginFlow() {
        loginFlowWindowManager.open(state: self)
    }

    func importCurrentCLIForPrimaryAccounts() {
        autoImportPrimaryCLISnapshots(force: true)
    }

    func captureCLISnapshot(for profile: AccountProfile) {
        do {
            _ = try cliSwitcher.captureAndStoreSnapshot(for: profile)
            updateIdentityFromCurrentCLI(for: profile)
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
            updateMenuBarSummary()
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
        openTerminal()
    }

    func beginCLILogin(for profile: AccountProfile) {
        if runTerminalCommand(profile.provider.loginCommand) {
            statusMessage = "Started \(profile.provider.loginCommand) for \(profile.label). Save the snapshot after login."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(profile.provider.loginCommand, forType: .string)
        statusMessage = "Copied \(profile.provider.loginCommand). Run it for \(profile.label), then save the snapshot."
        openTerminal()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func openTerminal() {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func autoImportPrimaryCLISnapshots(force: Bool = false) {
        var importedLabels: [String] = []
        var updatedProfiles = false

        for provider in Provider.allCases {
            guard let index = profiles.firstIndex(where: { $0.provider == provider }) else {
                continue
            }

            let profile = profiles[index]
            if provider == .codex,
               profiles[index].identity == nil,
               let identity = codexIdentityReader.readIdentity() {
                profiles[index].identity = identity
                profiles[index].updatedAt = Date()
                updatedProfiles = true
            }

            if !force, (try? cliSwitcher.hasStoredSnapshot(for: profile)) == true {
                continue
            }

            guard cliSwitcher.validateActiveLogin(provider: provider) else {
                continue
            }

            do {
                _ = try cliSwitcher.captureAndStoreSnapshot(for: profile)
                profiles[index].isActiveCLI = true
                profiles[index].updatedAt = Date()
                updatedProfiles = true
                if provider == .codex, let identity = codexIdentityReader.readIdentity() {
                    profiles[index].identity = identity
                }
                importedLabels.append(profile.label)
            } catch {
                if force {
                    statusMessage = "Could not import \(profile.label): \(error.localizedDescription)"
                }
            }
        }

        guard !importedLabels.isEmpty || updatedProfiles else {
            if force && statusMessage.isEmpty {
                statusMessage = "No active CLI logins found to import."
            }
            return
        }

        do {
            try repository.saveProfiles(profiles)
            if !importedLabels.isEmpty {
                statusMessage = "Imported current CLI login for \(importedLabels.joined(separator: ", "))."
            }
        } catch {
            statusMessage = "Imported CLI snapshots, but could not save active profile state: \(error.localizedDescription)"
        }
    }

    private func updateIdentityFromCurrentCLI(for profile: AccountProfile) {
        guard profile.provider == .codex,
              let identity = codexIdentityReader.readIdentity() else {
            return
        }
        updateIdentity(identity, for: profile)
    }

    private func updateIdentity(_ identity: AccountIdentity, for profile: AccountProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        profiles[index].identity = mergedIdentity(existing: profiles[index].identity, new: identity)
        profiles[index].updatedAt = Date()

        do {
            try repository.saveProfiles(profiles)
        } catch {
            statusMessage = "Could not save account identity: \(error.localizedDescription)"
        }
    }

    private func mergedIdentity(existing: AccountIdentity?, new: AccountIdentity) -> AccountIdentity {
        guard let existing else {
            return new
        }

        return AccountIdentity(
            email: new.email ?? existing.email,
            displayName: new.displayName ?? existing.displayName,
            organization: new.organization ?? existing.organization,
            accountID: new.accountID ?? existing.accountID,
            source: new.source,
            updatedAt: new.updatedAt
        )
    }

    private func runTerminalCommand(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo)
        return result != nil
    }

    private func updateMenuBarSummary() {
        let claudeTitle = providerUsageTitle(.claude)
        let codexTitle = providerUsageTitle(.codex)
        menuBarSummary = MenuBarSummary(
            title: "C \(claudeTitle)  G \(codexTitle)",
            accessibilityText: accessibilitySummary(),
            riskLevel: highestRisk()
        )
    }

    private func providerUsageTitle(_ provider: Provider) -> String {
        let usedValues = profiles
            .filter { $0.provider == provider }
            .compactMap { snapshots[$0.id]?.usedFraction }

        guard let maxUsed = usedValues.max() else {
            return "--"
        }

        return "\(Int((maxUsed * 100).rounded()))%"
    }

    private func highestRisk() -> RiskLevel {
        let snapshotRisk = profiles.compactMap { snapshots[$0.id]?.riskLevel }.min() ?? .unknown
        let thresholdRisk = profiles
            .compactMap { snapshots[$0.id]?.usedFraction }
            .map { used -> RiskLevel in
                if used >= 1 {
                    return .depleted
                }
                if used >= 0.8 {
                    return .warning
                }
                return .healthy
            }
            .min() ?? .unknown

        return min(snapshotRisk, thresholdRisk)
    }

    private func accessibilitySummary() -> String {
        var parts: [String] = []
        for provider in Provider.allCases {
            let values = profiles
                .filter { $0.provider == provider }
                .compactMap { profile -> String? in
                    guard let used = snapshots[profile.id]?.usedFraction else {
                        return nil
                    }
                    return "\(profile.label) \(Int((used * 100).rounded())) percent used"
                }

            parts.append(values.isEmpty ? "\(provider.displayName) usage unknown" : values.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
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

@MainActor
final class UsageAlertController {
    private var lastNotifiedRisk: [UUID: RiskLevel] = [:]

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handle(snapshot: UsageSnapshot, profile: AccountProfile) {
        guard snapshot.parseConfidence != .none else {
            return
        }

        guard snapshot.riskLevel == .warning || snapshot.riskLevel == .depleted else {
            lastNotifiedRisk[profile.id] = nil
            return
        }

        guard lastNotifiedRisk[profile.id] != snapshot.riskLevel else {
            return
        }

        lastNotifiedRisk[profile.id] = snapshot.riskLevel

        let content = UNMutableNotificationContent()
        content.title = notificationTitle(snapshot: snapshot, profile: profile)
        content.body = notificationBody(snapshot: snapshot, profile: profile)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(profile.id.uuidString)-\(snapshot.riskLevel.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    private func notificationTitle(snapshot: UsageSnapshot, profile: AccountProfile) -> String {
        if snapshot.riskLevel == .depleted {
            return "\(profile.label) limit reached"
        }

        if let used = snapshot.usedFraction {
            return "\(profile.label) is \(Int((used * 100).rounded()))% used"
        }

        return "\(profile.label) is near its limit"
    }

    private func notificationBody(snapshot: UsageSnapshot, profile: AccountProfile) -> String {
        var parts = ["\(profile.provider.displayName) included usage is \(snapshot.riskLevel == .depleted ? "depleted" : "near the limit")."]
        if let reset = snapshot.resetDescription {
            parts.append("Reset \(reset).")
        }
        if let credit = snapshot.creditStatus {
            parts.append(credit)
        }
        return parts.joined(separator: " ")
    }
}
