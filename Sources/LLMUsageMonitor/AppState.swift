import AppKit
import Combine
import Foundation
import LLMUsageMonitorCore
import UserNotifications
import WebKit

struct MenuBarSummary: Equatable {
    var claudeValue: String
    var codexValue: String
    var accessibilityText: String
    var riskLevel: RiskLevel

    static let empty = MenuBarSummary(
        claudeValue: "–",
        codexValue: "–",
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
    private let syncPlanner = CLIAccountSyncPlanner()
    private let codexLocalUsageReader = CodexLocalUsageReader()
    private let claudeCodeUsageReader = ClaudeCodeUsageReader()
    private let dashboardWindowManager = DashboardWindowManager()
    private let usageAlertController = UsageAlertController()
    private var refreshTask: Task<Void, Never>?

    init(repository: ProfileRepository, cliSwitcher: CLISwitcher) throws {
        self.repository = repository
        self.cliSwitcher = cliSwitcher
        self.profiles = try repository.loadProfiles()
        self.snapshots = try repository.loadUsageSnapshots()
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

    // MARK: - Refresh (local-first)

    func refreshAll() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Attribute the current CLI logins to profiles (registering new
        // accounts as needed) and keep their credential snapshots fresh.
        for provider in Provider.allCases {
            do {
                try captureActiveCredentials(provider: provider)
            } catch {
                statusMessage = "Could not capture the current \(provider.displayName) login: \(error.localizedDescription)"
            }
        }

        // Usage is read locally for the active account per provider. Inactive
        // accounts keep their last snapshot; the UI shows how stale it is and
        // whether the limit window has already reset.
        await refreshActiveClaudeCodeUsage()
        refreshActiveCodexUsage()
        updateMenuBarSummary()
    }

    func activeProfile(for provider: Provider) -> AccountProfile? {
        profiles.first { $0.provider == provider && $0.isActiveCLI }
    }

    /// Syncs the active-CLI flags and identities from the current terminal
    /// login, then captures its credentials into the matching profile so
    /// switching never depends on a manual snapshot step.
    @discardableResult
    private func captureActiveCredentials(provider: Provider) throws -> AccountProfile? {
        guard let active = syncActiveCLIAccount(provider: provider) else {
            return nil
        }
        guard cliSwitcher.validateActiveLogin(provider: provider) else {
            return active
        }
        _ = try cliSwitcher.captureAndStoreSnapshot(for: active)
        return active
    }

    @discardableResult
    private func syncActiveCLIAccount(provider: Provider) -> AccountProfile? {
        let currentIdentity = cliSwitcher.currentIdentity(provider: provider)
        let action = syncPlanner.plan(provider: provider, currentIdentity: currentIdentity, profiles: profiles)
        var changed = false
        var activeID: UUID?

        switch action {
        case .deactivateAll:
            for index in profiles.indices where profiles[index].provider == provider && profiles[index].isActiveCLI {
                profiles[index].isActiveCLI = false
                profiles[index].updatedAt = Date()
                changed = true
            }
        case .activate(let id), .adopt(let id):
            activeID = id
        case .create:
            guard let currentIdentity else {
                break
            }
            let profile = AccountProfile(
                provider: provider,
                label: defaultLabel(for: currentIdentity, provider: provider),
                identity: currentIdentity
            )
            profiles.append(profile)
            activeID = profile.id
            changed = true
            statusMessage = "Registered \(profile.label) from the current \(provider.displayName) CLI login."
        }

        var active: AccountProfile?
        if let activeID, let currentIdentity {
            for index in profiles.indices where profiles[index].provider == provider {
                let shouldBeActive = profiles[index].id == activeID
                if profiles[index].isActiveCLI != shouldBeActive {
                    profiles[index].isActiveCLI = shouldBeActive
                    profiles[index].updatedAt = Date()
                    changed = true
                }
            }
            if let index = profiles.firstIndex(where: { $0.id == activeID }) {
                let merged = mergedIdentity(existing: profiles[index].identity, new: currentIdentity)
                if profiles[index].identity != merged {
                    profiles[index].identity = merged
                    profiles[index].updatedAt = Date()
                    changed = true
                }
                active = profiles[index]
            }
        }

        if changed {
            persistProfiles()
        }
        return active
    }

    private func defaultLabel(for identity: AccountIdentity, provider: Provider) -> String {
        if let label = identity.primaryLabel {
            return label
        }
        let count = profiles.filter { $0.provider == provider }.count
        return "\(provider.displayName) \(count + 1)"
    }

    private func refreshActiveClaudeCodeUsage() async {
        guard cliSwitcher.validateActiveLogin(provider: .claude),
              let profile = activeProfile(for: .claude) else {
            return
        }

        do {
            let report = try await claudeCodeUsageReader.readUsage()
            if let identity = report.identity {
                updateIdentity(identity, for: profile)
            }
            let snapshot = report.makeSnapshot(for: profile)
            applySnapshot(snapshot, for: profile)
        } catch {
            statusMessage = "Claude Code /usage unavailable: \(error.localizedDescription)"
        }
    }

    private func refreshActiveCodexUsage() {
        guard let profile = activeProfile(for: .codex),
              let snapshot = codexLocalUsageReader.readUsage(for: profile) else {
            return
        }
        applySnapshot(snapshot, for: profile)
    }

    private func applySnapshot(_ snapshot: UsageSnapshot, for profile: AccountProfile) {
        snapshots[profile.id] = snapshot
        updateMenuBarSummary()
        usageAlertController.handle(snapshot: snapshot, profile: profile)
        saveSnapshots()
        statusMessage = "\(profile.label): \(snapshot.message)"
    }

    // MARK: - Dashboard fallback

    @discardableResult
    func ingestDashboardText(_ text: String, for profile: AccountProfile, source: String) -> UsageSnapshot {
        if let identity = identityExtractor.extractFromDashboardText(text) {
            updateIdentity(identity, for: profile)
        }

        let snapshot = parser.parse(text: text, account: profile, source: source)
        applySnapshot(snapshot, for: profile)
        return snapshot
    }

    func openDashboard(for profile: AccountProfile) {
        dashboardWindowManager.open(profile: profile) { [weak self] text in
            self?.ingestDashboardText(text, for: profile, source: profile.provider.dashboardURL.absoluteString)
        }
    }

    // MARK: - Account management

    func addProfile(provider: Provider) {
        let count = profiles.filter { $0.provider == provider }.count
        let profile = AccountProfile(provider: provider, label: "\(provider.displayName) \(count + 1)")
        profiles.append(profile)
        persistProfiles()
        statusMessage = "Added \(profile.label). Log into it in the terminal and it links automatically."
    }

    func renameProfile(_ profileID: UUID, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].label != trimmed else {
            return
        }
        profiles[index].label = trimmed
        profiles[index].updatedAt = Date()
        persistProfiles()
    }

    func removeProfile(_ profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        let profile = profiles[index]

        let alert = NSAlert()
        alert.messageText = "Remove \(profile.label)?"
        var details = "This deletes the saved credential snapshot and usage history for this account. Your terminal login and the account itself are not touched."
        if profile.isActiveCLI {
            details += " This account is the active CLI login, so it will be registered again on the next refresh unless you log out in the terminal first."
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try cliSwitcher.deleteStoredSnapshot(for: profile.id)
        } catch {
            statusMessage = "Could not delete stored credentials for \(profile.label): \(error.localizedDescription)"
        }
        if profile.webDataStoreKind == .isolated {
            WKWebsiteDataStore.remove(forIdentifier: profile.webDataStoreID) { _ in }
        }
        profiles.remove(at: index)
        snapshots[profile.id] = nil
        persistProfiles()
        saveSnapshots()
        updateMenuBarSummary()
        statusMessage = "Removed \(profile.label)."
    }

    // MARK: - CLI switching

    func switchCLI(to profile: AccountProfile) {
        guard hasStoredSnapshot(for: profile) else {
            showError(
                message: "No saved credentials for \(profile.label)",
                details: "Log into this account once in the terminal (\(profile.provider.loginCommand)); the app captures its credentials automatically."
            )
            return
        }

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

        // Capture the currently active login first so nothing is lost.
        do {
            try captureActiveCredentials(provider: profile.provider)
        } catch {
            statusMessage = "Switch cancelled: \(error.localizedDescription)"
            showError(
                message: "Switch cancelled",
                details: "Could not capture the current \(profile.provider.displayName) login first, so nothing was changed. \(error.localizedDescription)"
            )
            return
        }

        do {
            let result = try cliSwitcher.restoreSnapshot(for: profile)
            for index in profiles.indices where profiles[index].provider == profile.provider {
                profiles[index].isActiveCLI = profiles[index].id == profile.id
                profiles[index].updatedAt = Date()
            }
            persistProfiles()
            updateMenuBarSummary()

            if let newIdentity = cliSwitcher.currentIdentity(provider: profile.provider),
               let targetIdentity = profile.identity,
               !targetIdentity.matches(newIdentity) {
                showError(
                    message: "Switch finished with a different account",
                    details: "The CLI now reports \(newIdentity.primaryLabel ?? "an unknown account"), which does not match \(profile.label). The previous files were backed up to: \(result.backupURLs.map(\.path).joined(separator: ", "))"
                )
            } else {
                statusMessage = "Switched \(profile.provider.displayName) CLI to \(profile.label)."
            }

            Task { await refreshAll() }
        } catch {
            statusMessage = "Switch failed for \(profile.label): \(error.localizedDescription)"
            showError(message: "Switch failed", details: error.localizedDescription)
        }
    }

    func captureCLISnapshot(for profile: AccountProfile) {
        do {
            _ = try cliSwitcher.captureAndStoreSnapshot(for: profile)
            if let identity = cliSwitcher.currentIdentity(provider: profile.provider) {
                updateIdentity(identity, for: profile)
            }
            statusMessage = "Captured \(profile.provider.displayName) CLI credentials for \(profile.label)."
            objectWillChange.send()
        } catch {
            statusMessage = "Capture failed for \(profile.label): \(error.localizedDescription)"
            showError(message: "Capture failed", details: error.localizedDescription)
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
            statusMessage = "Started \(profile.provider.loginCommand) for \(profile.label). The account links automatically after login."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(profile.provider.loginCommand, forType: .string)
        statusMessage = "Copied \(profile.provider.loginCommand). Run it in the terminal; the account links automatically after login."
        openTerminal()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Identity

    private func updateIdentity(_ identity: AccountIdentity, for profile: AccountProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        profiles[index].identity = mergedIdentity(existing: profiles[index].identity, new: identity)
        profiles[index].updatedAt = Date()
        persistProfiles()
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

    // MARK: - Helpers

    private func openTerminal() {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
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

    private func persistProfiles() {
        do {
            try repository.saveProfiles(profiles)
        } catch {
            statusMessage = "Could not save accounts: \(error.localizedDescription)"
        }
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

    // MARK: - Menu bar summary

    private func updateMenuBarSummary() {
        menuBarSummary = MenuBarSummary(
            claudeValue: providerUsageValue(.claude),
            codexValue: providerUsageValue(.codex),
            accessibilityText: accessibilitySummary(),
            riskLevel: highestRisk()
        )
    }

    private func providerUsageValue(_ provider: Provider) -> String {
        guard let profile = activeProfile(for: provider),
              let snapshot = snapshots[profile.id] else {
            return "–"
        }

        if snapshot.billingUsageMode == .overLimitPayAsYouGo {
            return "PAYG"
        }

        guard let used = snapshot.usedFraction else {
            return "–"
        }
        return "\(Int((used * 100).rounded()))%"
    }

    /// Menu-bar risk reflects the accounts the terminal is actually using;
    /// a stale inactive account must not paint warning glyphs.
    private func highestRisk() -> RiskLevel {
        let activeProfiles = Provider.allCases.compactMap { activeProfile(for: $0) }
        let snapshotRisk = activeProfiles.compactMap { snapshots[$0.id]?.riskLevel }.min() ?? .unknown
        let thresholdRisk = activeProfiles
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
            guard let profile = activeProfile(for: provider),
                  let snapshot = snapshots[profile.id] else {
                parts.append("\(provider.displayName) usage unknown")
                continue
            }

            let mode: String
            switch snapshot.billingUsageMode {
            case .includedSubscription:
                mode = "using included subscription usage"
            case .includedSubscriptionNearLimit:
                mode = "using included subscription usage near the limit"
            case .overLimitPayAsYouGo:
                mode = "using pay as you go or credits"
            case .payAsYouGoVisible:
                mode = "showing pay as you go status"
            case .needsLogin:
                mode = "needs login"
            case .unknown:
                mode = "usage mode unknown"
            }

            if let used = snapshot.usedFraction {
                parts.append("\(provider.displayName) active account \(profile.label) \(Int((used * 100).rounded())) percent used, \(mode)")
            } else {
                parts.append("\(provider.displayName) active account \(profile.label) \(mode)")
            }
        }
        return parts.joined(separator: ". ")
    }
}

@MainActor
final class UsageAlertController {
    private var lastNotifiedRisk: [UUID: RiskLevel] = [:]

    func requestAuthorization() {
        // UNUserNotificationCenter requires a real bundle; guard so an
        // unbundled `swift run` does not crash at startup.
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handle(snapshot: UsageSnapshot, profile: AccountProfile) {
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }

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
