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
    @Published private(set) var refreshStage: String?
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published var menuBarSummary: MenuBarSummary = .empty
    @Published var statusMessage = ""
    /// Per-account, per-window burn-rate projections; only `.depletesAt`
    /// values render anything in the UI.
    @Published private(set) var burnRateEstimates: [UUID: [String: BurnRateEstimate]] = [:]
    /// Per provider, the current best switch target (recomputed each refresh);
    /// drives the Switch-button highlight and auto-switching for both Claude
    /// and Codex.
    @Published private(set) var switchAdvice: [Provider: SwitchAdvice] = [:]
    /// Per-account outcome of the most recent refresh, so a failed read shows a
    /// retryable affordance in the row instead of silently aging into
    /// staleness. Absent = never refreshed / nothing to say.
    @Published private(set) var refreshStates: [UUID: AccountRefreshState] = [:]

    let settings: SettingsStore

    private let repository: ProfileRepository
    private let cliSwitcher: CLISwitcher
    private let parser = UsageTextParser()
    private let identityExtractor = AccountIdentityExtractor()
    private let syncPlanner = CLIAccountSyncPlanner()
    private let codexLocalUsageReader = CodexLocalUsageReader()
    private let claudeCodeUsageReader = ClaudeCodeUsageReader()
    private let claudeUsageService: ClaudeAccountUsageService
    private let dashboardWindowManager = DashboardWindowManager()
    private let usageAlertController = UsageAlertController()
    private let resetAlertPlanner = ResetAlertPlanner()
    private let historyStore: UsageHistoryStore?
    private let burnRateEstimator = BurnRateEstimator()
    private let switchAdvisor = SwitchAdvisor()
    private let paceAlertPlanner = PaceAlertPlanner()
    private let updateService = UpdateService()
    private let settingsWindowController = SettingsWindowController()
    private var refreshTask: Task<Void, Never>?
    private var loginFollowUpTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    /// Popover-open refreshes are throttled on attempts, not outcomes — an
    /// account whose fetch keeps failing must not re-trigger on every open.
    private var lastClaudeRefreshAttempt: Date?
    /// Auto-switch guards, per provider so a Claude switch never blocks a Codex
    /// one: a failed attempt must not retry every cycle, and a deliberate manual
    /// switch onto a constrained account must not be immediately reverted.
    private var lastAutoSwitchAttempt: [Provider: Date] = [:]
    private var lastManualSwitchAt: [Provider: Date] = [:]
    /// When each Codex account last became the active CLI login — the freshness
    /// gate for the account-blind Codex session logs (see refreshCodexUsage).
    /// In-memory: after a relaunch the worst case is one stale attribution for
    /// an account switched-to-but-not-yet-used last session (documented
    /// follow-up: persist this).
    private var codexActiveSince: [UUID: Date] = [:]
    /// Profiles whose account info was fetched this launch — plan tier and
    /// identity rarely change, and some accounts legitimately map to no plan
    /// label, so one attempt per launch is enough.
    private var accountInfoFetched: Set<UUID> = []

    init(repository: ProfileRepository, cliSwitcher: CLISwitcher, settings: SettingsStore? = nil) throws {
        self.repository = repository
        self.cliSwitcher = cliSwitcher
        self.claudeUsageService = ClaudeAccountUsageService(credentials: cliSwitcher)
        self.settings = settings ?? SettingsStore()
        self.profiles = try repository.loadProfiles()
        self.snapshots = try repository.loadUsageSnapshots()
        self.historyStore = try? UsageHistoryStore(applicationSupportDirectory: repository.applicationSupportDirectory)
        updateMenuBarSummary()
        // History can be tens of thousands of lines; load it off the launch
        // path. Appends before this finishes are safe — the store lazily
        // loads before its first mutation.
        Task { [weak self] in
            guard let self else {
                return
            }
            try? self.historyStore?.load()
            self.recomputeAllEstimates()
        }
        usageAlertController.requestAuthorization()
        observeWake()

        self.settings.$refreshIntervalMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.refreshTask != nil else {
                    return
                }
                self.startBackgroundRefresh()
            }
            .store(in: &cancellables)

        // @Published emits on willSet, so rebuild the title on the next
        // runloop turn — reading the property inside the sink directly would
        // still see the old preference.
        self.settings.$menuBarWindowPreference
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarSummary()
            }
            .store(in: &cancellables)
    }

    deinit {
        refreshTask?.cancel()
        loginFollowUpTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func startBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = self?.settings.refreshIntervalMinutes ?? 10
                try? await Task.sleep(nanoseconds: UInt64(max(1, minutes)) * 60_000_000_000)
                await self?.refreshAll()
            }
        }
    }

    /// The `Task.sleep` loop does not fire while the Mac sleeps, so the menu
    /// bar would otherwise show hours-old numbers after wake.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Give the network and the CLIs a moment to come back.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshAll()
            }
        }
    }

    /// Called when the popover opens: Codex is a cheap local file scan and is
    /// always re-read; Claude accounts refresh (sub-second usage API call,
    /// with the slow CLI probe only as fallback) when any of them has
    /// outlived the refresh interval.
    func refreshIfStale() {
        // Sync the active Codex login before reading so a terminal-side account
        // change is attributed to the right profile.
        try? captureActiveCredentials(provider: .codex)
        refreshCodexUsage()
        if shouldRefreshClaudeNow() {
            Task { await refreshAll() }
        } else {
            updateMenuBarSummary()
        }
    }

    private func shouldRefreshClaudeNow() -> Bool {
        guard !isRefreshing else {
            return false
        }
        if let lastAttempt = lastClaudeRefreshAttempt,
           Date().timeIntervalSince(lastAttempt) < TimeInterval(settings.refreshIntervalMinutes * 60) {
            return false
        }
        return profiles.contains { profile in
            guard profile.provider == .claude,
                  profile.isActiveCLI || hasStoredSnapshot(for: profile) else {
                return false
            }
            guard let snapshot = snapshots[profile.id] else {
                return true
            }
            return snapshot.isStale(maxAge: TimeInterval(settings.refreshIntervalMinutes * 60))
        }
    }

    // MARK: - Refresh (local-first)

    func refreshAll() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Reset alerts are evaluated against the pre-refresh snapshots first:
        // fresh data for a rolled-over inactive account would otherwise erase
        // the "was constrained" evidence the planner needs. The persisted
        // dedupe keys keep the post-refresh pass below from double-firing.
        notifyElapsedResets()

        // Attribute the current CLI logins to profiles (registering new
        // accounts as needed) and keep their credential snapshots fresh.
        for provider in Provider.allCases {
            do {
                try captureActiveCredentials(provider: provider)
            } catch {
                statusMessage = "Could not capture the current \(provider.displayName) login: \(error.localizedDescription)"
            }
        }

        // Claude usage comes from the account-wide usage API for every
        // profile with a captured token; Codex reads the active account's
        // local logs (gated to its own reading) and derives plan/identity for
        // every Codex account from captured credentials.
        await refreshClaudeUsage()
        refreshCodexUsage()
        notifyElapsedResets()
        updateSwitchAdvice()
        updateMenuBarSummary()
        await checkForUpdatesIfDue()
    }

    /// Recomputes the best-switch-target hint from the fresh readings and,
    /// when the opt-in is enabled, performs the switch: active account
    /// depleted, another account with clearly more headroom.
    private func updateSwitchAdvice() {
        // Candidates never mix providers: credentials and quota are
        // provider-scoped, so a Claude account can't be a switch target for a
        // depleted Codex login. The advisor itself is provider-agnostic.
        for provider in Provider.allCases {
            let candidates = profiles
                .filter { $0.provider == provider }
                .map { profile in
                    SwitchCandidate(
                        profileID: profile.id,
                        label: profile.label,
                        isActiveCLI: profile.isActiveCLI,
                        hasStoredCredentials: hasStoredSnapshot(for: profile),
                        snapshot: snapshots[profile.id]
                    )
                }
            let advice = switchAdvisor.advise(candidates: candidates)
            switchAdvice[provider] = advice
            maybeAutoSwitch(provider: provider, advice: advice)
        }
    }

    private func maybeAutoSwitch(provider: Provider, advice: SwitchAdvice) {
        guard settings.autoSwitchEnabled,
              advice.shouldAutoSwitch,
              let targetID = advice.bestCandidateID,
              let target = profiles.first(where: { $0.id == targetID }),
              !target.isActiveCLI else {
            return
        }

        // Back off after any attempt (a failing restore must not re-run every
        // cycle), and honor a recent manual switch — deliberately parking the
        // CLI on a constrained account must not be silently reverted. Both
        // guards are per-provider.
        let now = Date()
        if let lastAttempt = lastAutoSwitchAttempt[provider], now.timeIntervalSince(lastAttempt) < 60 * 60 {
            return
        }
        if let manual = lastManualSwitchAt[provider], now.timeIntervalSince(manual) < 30 * 60 {
            return
        }
        lastAutoSwitchAttempt[provider] = now

        let previousLabel = activeProfile(for: provider)?.label
        if switchCLI(to: target, interactive: false) {
            usageAlertController.handleAutoSwitch(
                fromLabel: previousLabel,
                toLabel: target.label,
                provider: provider,
                reason: advice.reason
            )
        }
    }

    /// Polls every Claude account through the usage API (active first, so its
    /// numbers land even if an inactive account's refresh stalls). The slow
    /// expect-probe of the CLI remains the fallback for the active account.
    private func refreshClaudeUsage() async {
        lastClaudeRefreshAttempt = Date()
        let claudeProfiles = profiles
            .filter { $0.provider == .claude }
            .sorted { $0.isActiveCLI && !$1.isActiveCLI }

        for profile in claudeProfiles {
            refreshStates[profile.id] = .refreshing
            do {
                let snapshot = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI
                )
                applySnapshot(snapshot, for: profile)
                await enrichAccountInfoIfMissing(for: profile)
            } catch {
                // Map the failure to a visible, retryable state rather than
                // swallowing it. The active account may still recover via the
                // local /usage probe; inactive accounts keep their last
                // snapshot (a missing token is expected until the account has
                // been the active login once).
                let fetchError = (error as? ClaudeAccountUsageFetchError) ?? .transport(error)
                let outcome = RefreshOutcomePolicy.outcome(for: fetchError, isActiveCLI: profile.isActiveCLI)
                if outcome.attemptTUIFallback {
                    await refreshActiveClaudeCodeUsage(onFailure: outcome.state, for: profile)
                } else {
                    refreshStates[profile.id] = outcome.state
                }
            }
        }
    }

    /// Plan tier and identity rarely change; fetch them at most once per
    /// launch. This also lets new mapping logic repair labels written by
    /// older builds (for example Team Premium previously showing as Max 5x).
    private func enrichAccountInfoIfMissing(for profile: AccountProfile) async {
        guard !accountInfoFetched.contains(profile.id) else {
            return
        }
        guard let info = try? await claudeUsageService.fetchAccountInfo(
            for: profile,
            isActiveCLI: profile.isActiveCLI
        ) else {
            // Thrown errors (network, missing token) retry next cycle.
            return
        }
        accountInfoFetched.insert(profile.id)

        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        var changed = false
        if let plan = info.planLabel, profiles[index].planLabel != plan {
            profiles[index].planLabel = plan
            changed = true
        }
        if let identity = info.identity {
            let merged = mergedIdentity(existing: profiles[index].identity, new: identity)
            if profiles[index].identity != merged {
                profiles[index].identity = merged
                changed = true
            }
        }
        if changed {
            profiles[index].updatedAt = Date()
            persistProfiles()
        }
    }

    /// The app's core alert: an inactive account that was near or past its
    /// limit has had its window roll over — its quota is likely back.
    private func notifyElapsedResets() {
        guard settings.resetAlertsEnabled else {
            return
        }
        let alerts = resetAlertPlanner.alerts(
            profiles: profiles,
            snapshots: snapshots,
            alreadyNotified: usageAlertController.notifiedResetKeys()
        )
        for alert in alerts {
            usageAlertController.handleResetElapsed(alert)
        }
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
                    // Anchor the Codex freshness gate on the inactive→active
                    // transition only (never every sync, or the gate would
                    // always reject the account's own latest event).
                    if shouldBeActive, provider == .codex {
                        codexActiveSince[profiles[index].id] = Date()
                    }
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

    /// The slow `/usage` CLI probe, used only as the active-account fallback
    /// when the usage API failed. `failureState` is what the row should show if
    /// even this local read cannot recover a reading.
    private func refreshActiveClaudeCodeUsage(onFailure failureState: AccountRefreshState, for profile: AccountProfile) async {
        guard cliSwitcher.validateActiveLogin(provider: .claude) else {
            refreshStates[profile.id] = failureState
            return
        }

        refreshStage = "Reading Claude Code /usage — can take ~20 seconds…"
        defer { refreshStage = nil }

        do {
            let report = try await claudeCodeUsageReader.readUsage()
            if let identity = report.identity {
                updateIdentity(identity, for: profile)
            }
            let snapshot = report.makeSnapshot(for: profile)
            applySnapshot(snapshot, for: profile)
        } catch {
            refreshStates[profile.id] = failureState
            statusMessage = "Claude Code /usage unavailable: \(error.localizedDescription)"
        }
    }

    /// Reads the active Codex account's usage (gated to its own reading — the
    /// session logs are account-blind), and derives plan tier + identity for
    /// every Codex account, active or not, from its captured credentials.
    private func refreshCodexUsage() {
        // The `~/.codex/sessions` logs carry no account identity, so the newest
        // rate-limit event can only be safely attributed to the active account
        // when it is the sole Codex account. With two or more, the newest event
        // may belong to whichever account last ran `codex`, so it is trusted
        // only when produced after this account became the live login — and if
        // there is no such event yet, the row is cleared rather than showing
        // another account's numbers. (A lone Codex account keeps the simpler
        // "the newest event is mine" behavior, unchanged.)
        let now = Date()
        let hasMultipleCodex = profiles.filter { $0.provider == .codex }.count > 1

        for profile in profiles where profile.provider == .codex {
            if profile.isActiveCLI {
                // The in-memory activation time does not survive an app
                // restart; when it is missing for a multi-account setup, anchor
                // it now so a pre-launch event is never mistaken for this
                // account's — a single fresh `codex` run then populates it.
                if hasMultipleCodex, codexActiveSince[profile.id] == nil {
                    codexActiveSince[profile.id] = now
                }
                let gate = hasMultipleCodex ? codexActiveSince[profile.id] : nil
                if let snapshot = codexLocalUsageReader.readUsage(for: profile, producedAfter: gate, now: now) {
                    applySnapshot(snapshot, for: profile)
                } else if hasMultipleCodex {
                    clearCodexSnapshot(for: profile.id)
                }
            }
            // A gated-out active read (no genuine post-activation event yet) or
            // an inactive account keeps its captured / last-known snapshot;
            // there is no per-account Codex usage source to poll.
            enrichCodexAccountInfo(for: profile)
        }
    }

    /// Drops an active Codex account's reading when it can't be attributed to
    /// that account (multi-account setup with no post-activation event), so the
    /// row shows its "run codex" placeholder instead of another account's data.
    private func clearCodexSnapshot(for profileID: UUID) {
        guard snapshots[profileID] != nil else {
            return
        }
        snapshots[profileID] = nil
        burnRateEstimates[profileID] = nil
        saveSnapshots()
        updateMenuBarSummary()
    }

    /// Plan tier + identity for a Codex account, from the live `auth.json` when
    /// active or the captured snapshot when inactive — no CLI launch, no
    /// network. One attempt per launch, mirroring the Claude enrichment gate.
    private func enrichCodexAccountInfo(for profile: AccountProfile) {
        guard profile.provider == .codex,
              profile.planLabel == nil || profile.identity?.email == nil,
              !accountInfoFetched.contains(profile.id) else {
            return
        }

        let info: CodexAccountInfo?
        if profile.isActiveCLI {
            info = CodexIdentityReader().accountInfo()
        } else if let data = try? cliSwitcher.storedCodexAuthJSON(for: profile.id) {
            info = CodexIdentityReader.accountInfo(fromAuthJSON: data)
        } else {
            info = nil
        }
        guard let info else {
            return
        }
        accountInfoFetched.insert(profile.id)

        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        var changed = false
        if let plan = info.planLabel, profiles[index].planLabel != plan {
            profiles[index].planLabel = plan
            changed = true
        }
        if let identity = info.identity {
            let merged = mergedIdentity(existing: profiles[index].identity, new: identity)
            if profiles[index].identity != merged {
                profiles[index].identity = merged
                changed = true
            }
        }
        if changed {
            profiles[index].updatedAt = Date()
            persistProfiles()
        }
    }

    private func applySnapshot(_ snapshot: UsageSnapshot, for profile: AccountProfile) {
        snapshots[profile.id] = snapshot
        refreshStates[profile.id] = .ok
        _ = try? historyStore?.append(snapshot)
        recomputeEstimates(for: profile, snapshot: snapshot)
        updateMenuBarSummary()
        // Near-limit alerts stay active-account-only: an inactive account
        // nearing its limit is not actionable (nobody is burning it down);
        // its "quota is back" reset alert is the one that matters. Inactive
        // snapshots still re-arm the dedupe keys so a healed window can
        // alert again once the account becomes active.
        if settings.usageAlertsEnabled, profile.isActiveCLI {
            usageAlertController.handleThresholds(snapshot: snapshot, profile: profile)
            notifyPaceAlerts(snapshot: snapshot, profile: profile)
        } else {
            usageAlertController.rearmThresholds(snapshot: snapshot, profile: profile)
        }
        saveSnapshots()
        statusMessage = "\(profile.label): \(snapshot.message)"
    }

    /// "On pace to run out before the reset" — weekly windows only, active
    /// account only, once per reset period (mirrors the reset-alert dedupe).
    private func notifyPaceAlerts(snapshot: UsageSnapshot, profile: AccountProfile) {
        let alerts = paceAlertPlanner.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: burnRateEstimates[profile.id] ?? [:],
            alreadyNotified: usageAlertController.notifiedPaceKeys()
        )
        for alert in alerts {
            usageAlertController.handlePaceAlert(alert, provider: profile.provider)
        }
    }

    // MARK: - Burn rate

    private func recomputeEstimates(for profile: AccountProfile, snapshot: UsageSnapshot) {
        guard let historyStore else {
            return
        }
        var estimates: [String: BurnRateEstimate] = [:]
        for window in snapshot.orderedDisplayWindows {
            let readings = historyStore
                .readings(accountID: profile.id, windowID: window.id)
                .map { BurnRateEstimator.Reading(timestamp: $0.timestamp, reading: $0.reading) }
            estimates[window.id] = burnRateEstimator.estimate(readings: readings, window: window)
        }
        burnRateEstimates[profile.id] = estimates
    }

    private func recomputeAllEstimates() {
        for profile in profiles {
            guard let snapshot = snapshots[profile.id] else {
                continue
            }
            recomputeEstimates(for: profile, snapshot: snapshot)
        }
    }

    func historyRecords(for profile: AccountProfile) -> [UsageHistoryRecord] {
        historyStore?.records(for: profile.id) ?? []
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
        refreshStates[profile.id] = nil
        try? historyStore?.removeAccount(profile.id)
        burnRateEstimates[profile.id] = nil
        usageAlertController.forgetProfile(profile.id)
        persistProfiles()
        saveSnapshots()
        updateMenuBarSummary()
        statusMessage = "Removed \(profile.label)."
    }

    // MARK: - CLI switching

    /// Switches the CLI to `profile`. `interactive: false` (auto-switch path)
    /// skips confirmation dialogs and reports problems via status/notification
    /// text instead of modals. Returns whether the switch happened.
    @discardableResult
    func switchCLI(to profile: AccountProfile, interactive: Bool = true) -> Bool {
        guard hasStoredSnapshot(for: profile) else {
            reportSwitchProblem(
                interactive: interactive,
                message: "No saved credentials for \(profile.label)",
                details: "Log into this account once in the terminal (\(profile.provider.loginCommand)); the app captures its credentials automatically."
            )
            return false
        }

        if interactive, cliSwitcher.hasActiveProcesses(provider: profile.provider) {
            let alert = NSAlert()
            alert.messageText = "\(profile.provider.displayName) is running"
            alert.informativeText = "The account will be switched for new credential reads. Existing sessions may keep credentials they already loaded."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return false
            }
        }

        // Capture the currently active login first so nothing is lost.
        do {
            try captureActiveCredentials(provider: profile.provider)
        } catch {
            statusMessage = "Switch cancelled: \(error.localizedDescription)"
            reportSwitchProblem(
                interactive: interactive,
                message: "Switch cancelled",
                details: "Could not capture the current \(profile.provider.displayName) login first, so nothing was changed. \(error.localizedDescription)"
            )
            return false
        }

        // Snapshot the outgoing Codex account's usage while auth.json still
        // belongs to it — Codex has no inactive polling, so this is how it
        // keeps its own last-known reading once it goes inactive.
        if profile.provider == .codex,
           let outgoing = activeProfile(for: .codex),
           outgoing.id != profile.id,
           var snapshot = codexLocalUsageReader.readUsage(for: outgoing) {
            snapshot.source = "local Codex CLI logs (captured at switch)"
            applySnapshot(snapshot, for: outgoing)
        }

        do {
            let result = try cliSwitcher.restoreSnapshot(for: profile)
            for index in profiles.indices where profiles[index].provider == profile.provider {
                profiles[index].isActiveCLI = profiles[index].id == profile.id
                profiles[index].updatedAt = Date()
            }
            // The target just became active: anchor the Codex freshness gate so
            // it is not shown the outgoing account's still-newest log event
            // until it has actually run `codex` itself.
            if profile.provider == .codex {
                codexActiveSince[profile.id] = Date()
            }
            persistProfiles()
            updateMenuBarSummary()

            if let newIdentity = cliSwitcher.currentIdentity(provider: profile.provider),
               let targetIdentity = profile.identity,
               !targetIdentity.matches(newIdentity) {
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Switch finished with a different account",
                    details: "The CLI now reports \(newIdentity.primaryLabel ?? "an unknown account"), which does not match \(profile.label). The previous files were backed up to: \(result.backupURLs.map(\.path).joined(separator: ", "))"
                )
                // Not a success: the auto-switch path must not announce
                // "New terminal sessions use <target>" for the wrong account.
                if interactive {
                    Task { await refreshAll() }
                }
                return false
            }

            statusMessage = "Switched \(profile.provider.displayName) CLI to \(profile.label)."
            if interactive {
                lastManualSwitchAt[profile.provider] = Date()
                Task { await refreshAll() }
            }
            return true
        } catch {
            if let storeError = error as? CredentialStoreError, case .decodeFailed = storeError {
                // The stored snapshot is unreadable (e.g. written by an older
                // build). Clear it so this account falls back to the re-capture
                // path, and tell the user how to restore it. The current login
                // was already captured above, so nothing is lost.
                try? cliSwitcher.deleteStoredSnapshot(for: profile.id)
                objectWillChange.send()
                statusMessage = "Cleared unreadable credentials for \(profile.label)."
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Saved credentials for \(profile.label) were unreadable",
                    details: "They were likely written by an older version and have been cleared. Log into this account once in the terminal (\(profile.provider.loginCommand)); the app captures its credentials automatically."
                )
            } else {
                statusMessage = "Switch failed for \(profile.label): \(error.localizedDescription)"
                reportSwitchProblem(interactive: interactive, message: "Switch failed", details: error.localizedDescription)
            }
            return false
        }
    }

    private func reportSwitchProblem(interactive: Bool, message: String, details: String) {
        if interactive {
            showError(message: message, details: details)
        } else {
            statusMessage = "\(message). \(details)"
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

    /// Whether a saved credential snapshot exists for the account, and if not,
    /// whether that is a genuine absence or a locked/denied Keychain — the two
    /// lead to different UI (log in vs. grant access).
    enum StoredSnapshotStatus {
        case present
        case absent
        case locked
    }

    func storedSnapshotStatus(for profile: AccountProfile) -> StoredSnapshotStatus {
        do {
            return try cliSwitcher.hasStoredSnapshot(for: profile) ? .present : .absent
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            return .locked
        } catch {
            return .absent
        }
    }

    func hasStoredSnapshot(for profile: AccountProfile) -> Bool {
        storedSnapshotStatus(for: profile) == .present
    }

    /// Row-level "try again" for an account whose last refresh failed.
    func retryRefresh(for profile: AccountProfile) {
        Task { await refreshAll() }
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
        let initialIdentity = cliSwitcher.currentIdentity(provider: profile.provider)

        // Codex accounts share the single `~/.codex/auth.json`, so a bare
        // `codex login` launched while another account is signed in runs
        // against that existing session instead of starting a new login.
        // Capture the active account first (so its credentials survive as a
        // restorable snapshot), then log the terminal out before logging in.
        let hasExistingSession = profile.provider == .codex && cliSwitcher.validateActiveLogin(provider: .codex)
        if hasExistingSession {
            try? captureActiveCredentials(provider: .codex)
        }
        let command = terminalLoginCommand(for: profile.provider, hasExistingSession: hasExistingSession)

        // Preferred path: drive Terminal via AppleScript (reuses a window when
        // the user has granted Automation permission).
        let appleScriptError = runTerminalCommand(command)
        if appleScriptError == nil {
            statusMessage = "Started login for \(profile.label). The account links automatically after login."
            watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialIdentity: initialIdentity)
            return
        }

        // AppleScript failed — most commonly because Terminal Automation
        // permission is off (AppleEvent error -1743), which used to silently
        // fall back to a bare Terminal that ran nothing. Instead run the
        // command by opening an executable `.command` file, which needs no
        // Apple Events permission.
        if runCommandViaScriptFile(command) {
            statusMessage = "Opened Terminal to log in \(profile.label). The account links automatically after login."
            watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialIdentity: initialIdentity)
            return
        }

        // Last resort: copy the command and open a bare Terminal for the user
        // to paste it into.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = appleScriptError
            ?? "Copied the login command. Paste it into Terminal; the account links automatically after login."
        openTerminal()
        watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialIdentity: initialIdentity)
    }

    /// Builds the CLI login command, prefixed with a PATH export so the
    /// executable resolves even when Terminal's default PATH does not include
    /// it (e.g. codex provided by Conductor's bundle). Falls back to the bare
    /// command name when the executable cannot be resolved.
    private func terminalLoginCommand(for provider: Provider, hasExistingSession: Bool) -> String {
        let base = provider.terminalLoginCommand(hasExistingSession: hasExistingSession)
        var pathDirs = ["$HOME/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        if let resolved = cliSwitcher.resolveExecutablePath(command: provider.commandName) {
            let dir = (resolved as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                pathDirs.insert(dir, at: 0)
            }
        }
        let pathExport = "export PATH=\"\(pathDirs.joined(separator: ":")):$PATH\""
        return "\(pathExport); \(base)"
    }

    private func watchForCompletedLogin(
        profileID: UUID,
        provider: Provider,
        initialIdentity: AccountIdentity?
    ) {
        loginFollowUpTask?.cancel()
        loginFollowUpTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else {
                    return
                }

                let linked = await self?.refreshAfterCompletedLogin(
                    profileID: profileID,
                    provider: provider,
                    initialIdentity: initialIdentity
                ) ?? true
                if linked {
                    return
                }
            }
        }
    }

    private func refreshAfterCompletedLogin(
        profileID: UUID,
        provider: Provider,
        initialIdentity: AccountIdentity?
    ) async -> Bool {
        guard let currentIdentity = cliSwitcher.currentIdentity(provider: provider) else {
            return false
        }
        if let initialIdentity, currentIdentity.matches(initialIdentity) {
            return false
        }

        await refreshAll()
        return profiles.first(where: { $0.id == profileID })?.identity != nil
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func openSettings() {
        settingsWindowController.show(state: self)
    }

    // MARK: - Updates

    private func checkForUpdatesIfDue() async {
        if let lastCheck = settings.lastUpdateCheck,
           lastCheck > Date().addingTimeInterval(-24 * 60 * 60) {
            return
        }
        await checkForUpdatesNow()
    }

    @discardableResult
    func checkForUpdatesNow() async -> Bool {
        settings.lastUpdateCheck = Date()
        availableUpdate = await updateService.fetchAvailableUpdate()
        return availableUpdate != nil
    }

    func openAvailableUpdate() {
        guard let availableUpdate else {
            return
        }
        NSWorkspace.shared.open(availableUpdate.url)
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
            organizationID: new.organizationID ?? existing.organizationID,
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

    /// Runs `command` in Terminal.app via AppleScript. Returns `nil` on
    /// success, or a human-readable error message on failure (previously this
    /// swallowed `errorInfo`, so a denied Automation permission failed
    /// silently and login appeared to do nothing).
    private func runTerminalCommand(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Terminal"
            do script "\(escaped)"
            activate
        end tell
        """

        var errorInfo: NSDictionary?
        if NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo) != nil {
            return nil
        }

        let code = errorInfo?[NSAppleScript.errorNumber] as? Int
        if code == -1743 {
            return "Terminal automation is turned off for LLMUsageMonitor. Enable it in System Settings → Privacy & Security → Automation to log in with one click."
        }
        if let message = errorInfo?[NSAppleScript.errorMessage] as? String, !message.isEmpty {
            return "Could not drive Terminal: \(message)"
        }
        return "Could not drive Terminal to run the login command."
    }

    /// Runs `command` by writing it to a temporary executable `.command` file
    /// and opening it with Terminal.app. Unlike AppleScript, this needs no
    /// Apple Events (Automation) permission, so it works even when the user has
    /// denied Terminal automation. The `.command` file runs in a non-login
    /// shell, which is why `command` carries its own PATH export.
    private func runCommandViaScriptFile(_ command: String) -> Bool {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-usage-monitor-login-\(UUID().uuidString).command")
        let contents = "#!/bin/zsh\n\(command)\n"
        do {
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [scriptURL],
            withApplicationAt: terminalURL,
            configuration: configuration,
            completionHandler: nil
        )
        return true
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

    /// "–" = no active CLI login, "?" = active but not read yet, and a
    /// trailing "*" marks numbers that are stale and may no longer be true.
    private func providerUsageValue(_ provider: Provider) -> String {
        guard let profile = activeProfile(for: provider) else {
            return "–"
        }
        guard let snapshot = snapshots[profile.id] else {
            return "?"
        }

        let staleMark = snapshot.isStale() ? "*" : ""
        if snapshot.billingUsageMode == .overLimitPayAsYouGo {
            return "PAYG\(staleMark)"
        }

        guard let used = preferredUsedFraction(for: snapshot) else {
            return "?"
        }
        return "\(Int((used * 100).rounded()))%\(staleMark)"
    }

    /// The fraction behind the menu-bar number, honoring the Settings choice.
    /// A pinned window that is missing falls back to most-constrained — a
    /// wrong-but-plausible steady number would hide real risk.
    func preferredUsedFraction(for snapshot: UsageSnapshot) -> Double? {
        let mostConstrained = snapshot.mostConstrainedWindow?.usedFraction ?? snapshot.usedFraction
        switch settings.menuBarWindowPreference {
        case .mostConstrained:
            return snapshot.surfacedConstrainedWindow?.usedFraction ?? mostConstrained
        case .session:
            return snapshot.window(ofKind: .session)?.usedFraction ?? mostConstrained
        case .weekly:
            return snapshot.primaryWeeklyWindow?.usedFraction ?? mostConstrained
        }
    }

    /// Menu-bar risk reflects the accounts the terminal is actually using;
    /// a stale inactive account must not paint warning glyphs.
    private func highestRisk() -> RiskLevel {
        let activeProfiles = Provider.allCases.compactMap { activeProfile(for: $0) }
        let activeSnapshots = activeProfiles.compactMap { snapshots[$0.id] }
        let snapshotRisk = activeSnapshots.map(\.riskLevel).min() ?? .unknown
        let thresholdRisk = activeSnapshots
            .compactMap(\.usedFraction)
            .map(UsageThresholds.standard.riskLevel(usedFraction:))
            .min() ?? .unknown

        let risk = min(snapshotRisk, thresholdRisk)
        // An okay-looking number that has not been re-read in a long time is
        // not okay — it is unknown. Real warnings still win.
        if risk == .healthy || risk == .unknown,
           !activeSnapshots.isEmpty,
           activeSnapshots.allSatisfy({ $0.isStale() }) {
            return .stale
        }
        return risk
    }

    private func accessibilitySummary() -> String {
        guard !profiles.isEmpty else {
            return "No accounts yet. Log into Claude Code or Codex in the terminal to register one."
        }

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

            var entry: String
            let windowSummary = snapshot.orderedDisplayWindows
                .map { "\($0.label) \(Int($0.usedPercent.rounded())) percent used" }
                .joined(separator: ", ")
            if !windowSummary.isEmpty {
                entry = "\(provider.displayName) active account \(profile.label): \(windowSummary), \(mode)"
            } else if let used = snapshot.usedFraction {
                entry = "\(provider.displayName) active account \(profile.label) \(Int((used * 100).rounded())) percent used, \(mode)"
            } else {
                entry = "\(provider.displayName) active account \(profile.label) \(mode)"
            }
            if snapshot.isStale() {
                entry += ", last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))"
            }
            parts.append(entry)
        }
        return parts.joined(separator: ". ")
    }
}

@MainActor
final class UsageAlertController {
    private var lastNotifiedRisk: [AlertWindowKey: RiskLevel] = [:]
    private let thresholdPlanner = ThresholdAlertPlanner()
    private let notifiedResetsKey = "notifiedResetDates"
    private let notifiedPaceKey = "notifiedPaceAlerts"

    /// Reset alerts survive relaunches (persisted, keyed by account+window and
    /// reset date) so a restart does not re-announce quotas that were already
    /// reported back. The UserDefaults key is `"<profileID>|<windowID>"`.
    func notifiedResetKeys() -> [AlertWindowKey: Date] {
        windowKeyedDates(forKey: notifiedResetsKey)
    }

    /// Same persistence scheme for "on pace to run out" alerts.
    func notifiedPaceKeys() -> [AlertWindowKey: Date] {
        windowKeyedDates(forKey: notifiedPaceKey)
    }

    private func windowKeyedDates(forKey defaultsKey: String) -> [AlertWindowKey: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        var result: [AlertWindowKey: Date] = [:]
        for (key, value) in stored {
            // Legacy entries were bare UUIDs (no window component); drop them —
            // the worst case is one duplicate "quota back" alert after upgrade.
            guard let separator = key.firstIndex(of: "|") else {
                continue
            }
            let idPart = String(key[..<separator])
            let windowID = String(key[key.index(after: separator)...])
            guard let id = UUID(uuidString: idPart), !windowID.isEmpty else {
                continue
            }
            result[AlertWindowKey(profileID: id, windowID: windowID)] = Date(timeIntervalSince1970: value)
        }
        return result
    }

    func handlePaceAlert(_ alert: PaceAlert, provider: Provider) {
        markWindowNotified(
            defaultsKey: notifiedPaceKey,
            profileID: alert.profileID,
            windowID: alert.windowID,
            date: alert.resetDate ?? Date()
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var parts = [
            "At the current pace, \(provider.displayName) \(alert.windowLabel) usage runs out around \(formatter.string(from: alert.projectedDepletion))."
        ]
        if let reset = alert.resetDate {
            parts.append("The window resets \(formatter.string(from: reset)).")
        }
        postNotification(
            identifier: "pace-\(alert.profileID.uuidString)-\(alert.windowID)-\(Int(alert.projectedDepletion.timeIntervalSince1970))",
            title: "\(alert.profileLabel): on pace to hit the \(alert.windowLabel) limit",
            body: parts.joined(separator: " ")
        )
    }

    func handleAutoSwitch(fromLabel: String?, toLabel: String, provider: Provider, reason: String?) {
        var parts: [String] = []
        if let fromLabel {
            parts.append("\(fromLabel) hit its limit.")
        }
        if let reason {
            parts.append(reason)
        }
        parts.append("New terminal sessions use \(toLabel).")
        postNotification(
            identifier: "autoswitch-\(toLabel)-\(Int(Date().timeIntervalSince1970))",
            title: "Switched \(provider.displayName) CLI to \(toLabel)",
            body: parts.joined(separator: " ")
        )
    }

    /// Drops every persisted and in-memory dedupe key for a removed profile
    /// so UserDefaults does not accumulate dead entries forever.
    func forgetProfile(_ profileID: UUID) {
        let prefix = "\(profileID.uuidString)|"
        for defaultsKey in [notifiedResetsKey, notifiedPaceKey] {
            let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
            let remaining = stored.filter { !$0.key.hasPrefix(prefix) }
            UserDefaults.standard.set(remaining, forKey: defaultsKey)
        }
        lastNotifiedRisk = lastNotifiedRisk.filter { $0.key.profileID != profileID }
    }

    // MARK: - Shared posting/persistence

    private func markWindowNotified(defaultsKey: String, profileID: UUID, windowID: String, date: Date) {
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        stored["\(profileID.uuidString)|\(windowID)"] = date.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    private func postNotification(identifier: String, title: String, body: String) {
        // UNUserNotificationCenter requires a real bundle; an unbundled
        // `swift run` must not crash.
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    func handleResetElapsed(_ alert: ResetAlert) {
        markWindowNotified(
            defaultsKey: notifiedResetsKey,
            profileID: alert.profileID,
            windowID: alert.windowID,
            date: alert.resetDate
        )
        postNotification(
            identifier: "reset-\(alert.profileID.uuidString)-\(alert.windowID)-\(Int(alert.resetDate.timeIntervalSince1970))",
            title: "\(alert.profileLabel): \(alert.windowLabel) quota likely back",
            body: "The \(alert.provider.displayName) \(alert.windowLabel) limit window has rolled over since the last reading. Switch the CLI to \(alert.profileLabel) to keep using included usage."
        )
    }

    func requestAuthorization() {
        // UNUserNotificationCenter requires a real bundle; guard so an
        // unbundled `swift run` does not crash at startup.
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Per-window near-limit alerts. Session (5h) windows never notify —
    /// heavy sessions would fire on every burn-down; they stay visual-only.
    /// Each window re-arms once it drops back below the warning band.
    func handleThresholds(snapshot: UsageSnapshot, profile: AccountProfile) {
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }

        guard snapshot.parseConfidence != .none else {
            return
        }

        rearmRecoveredWindows(snapshot: snapshot, profile: profile)

        let alerts = thresholdPlanner.alerts(
            snapshot: snapshot,
            profile: profile,
            lastNotified: lastNotifiedRisk
        )
        for alert in alerts {
            lastNotifiedRisk[AlertWindowKey(profileID: alert.profileID, windowID: alert.windowID)] = alert.riskLevel
            postNotification(
                identifier: "usage-\(alert.profileID.uuidString)-\(alert.windowID)-\(alert.riskLevel.rawValue)",
                title: notificationTitle(alert: alert, profile: profile),
                body: notificationBody(alert: alert, snapshot: snapshot, profile: profile)
            )
        }
    }

    /// Clears dedupe keys for windows that dropped back below the warning
    /// band, without firing anything — used directly for inactive accounts.
    func rearmThresholds(snapshot: UsageSnapshot, profile: AccountProfile) {
        guard snapshot.parseConfidence != .none else {
            return
        }
        rearmRecoveredWindows(snapshot: snapshot, profile: profile)
    }

    private func rearmRecoveredWindows(snapshot: UsageSnapshot, profile: AccountProfile) {
        let currentRisk = thresholdPlanner.currentRisk(snapshot: snapshot, profile: profile)
        for (key, risk) in currentRisk where risk != .warning && risk != .depleted {
            lastNotifiedRisk[key] = nil
        }
    }

    private func notificationTitle(alert: ThresholdAlert, profile: AccountProfile) -> String {
        if alert.riskLevel == .depleted {
            return "\(profile.label): \(alert.windowLabel) limit reached"
        }
        return "\(profile.label): \(alert.windowLabel) \(Int(alert.usedPercent.rounded()))% used"
    }

    private func notificationBody(alert: ThresholdAlert, snapshot: UsageSnapshot, profile: AccountProfile) -> String {
        var parts = [
            "\(profile.provider.displayName) \(alert.windowLabel) usage is \(alert.riskLevel == .depleted ? "depleted" : "near the limit")."
        ]
        if let reset = alert.resetDescription ?? snapshot.resetDescription {
            parts.append("Resets \(reset).")
        }
        if let credit = snapshot.creditStatus {
            parts.append(credit)
        }
        return parts.joined(separator: " ")
    }
}
