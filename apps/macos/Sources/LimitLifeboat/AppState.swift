import AppKit
import Combine
import Foundation
import LimitLifeboatCore
import os
import WebKit

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var profiles: [AccountProfile]
    @Published private(set) var snapshots: [UUID: UsageSnapshot]
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshStage: String?
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
    /// Cached so SwiftUI body evaluation and switch-advice projection never
    /// perform a Keychain query. The cache is populated non-interactively at
    /// launch and updated at every credential mutation boundary.
    @Published private(set) var storedSnapshotStatuses: [UUID: StoredSnapshotStatus] = [:]
    /// Set when the shared Claude keychain item's partition list may be missing
    /// this app's team, so the UI can highlight the manual "Fix Repeated
    /// Keychain Prompts…" action. Cleared once a live probe confirms it.
    @Published var keychainRepairSuggested = false
    /// Claude's fixed per-device login expiry, cached alongside snapshot
    /// presence so SwiftUI never reads Keychain-backed credentials in `body`.
    @Published private(set) var claudeLoginExpirations: [UUID: Date] = [:]

    let settings: SettingsStore
    let updater: AppUpdater

    private let repository: ProfileRepository
    private let cliSwitcher: CLISwitcher
    private let parser = UsageTextParser()
    private let identityExtractor = AccountIdentityExtractor()
    private let syncPlanner = CLIAccountSyncPlanner()
    private let codexLocalUsageReader = CodexLocalUsageReader()
    private let codexUsageService = CodexAccountUsageService()
    private let claudeCodeUsageReader = ClaudeCodeUsageReader()
    private let claudeUsageService: ClaudeAccountUsageService
    private let codexAuthPreflightService = CodexAuthPreflightService()
    private let dashboardWindowManager = DashboardWindowManager()
    private let usageAlertController = UsageAlertController()
    private let resetAlertPlanner = ResetAlertPlanner()
    private let historyStore: UsageHistoryStore?
    private let burnRateEstimator = BurnRateEstimator()
    private let switchAdvisor = SwitchAdvisor()
    private let paceAlertPlanner = PaceAlertPlanner()
    private let settingsWindowController = SettingsWindowController()
    private let terminalLauncher = TerminalCommandLauncher()
    private var refreshTask: Task<Void, Never>?
    private var loginFollowUpTasks: [Provider: Task<Void, Never>] = [:]
    private var authPollTask: Task<Void, Never>?
    private var authStateMonitor: AuthStateMonitor?
    private var authObservationInteractive = false
    private var wakeObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    /// Popover-open refreshes are throttled on attempts, not outcomes — an
    /// account whose fetch keeps failing must not re-trigger on every open.
    private var lastClaudeRefreshAttempt: Date?
    private var lastCodexRefreshAttempt: Date?
    /// Auto-switch guards, per provider so a Claude switch never blocks a Codex
    /// one: a failed attempt must not retry every cycle, and a deliberate manual
    /// switch onto a constrained account must not be immediately reverted.
    private var lastAutoSwitchAttempt: [Provider: Date] = [:]
    private var lastManualSwitchAt: [Provider: Date] = [:]
    /// When each Codex account last became the active CLI login — the freshness
    /// gate for the account-blind Codex session-log fallback.
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
        self.updater = AppUpdater()
        self.profiles = try repository.loadProfiles()
        self.snapshots = try repository.loadUsageSnapshots()
        // History is an enhancement (burn-rate estimates), so a failed store
        // never blocks launch — but the failure must be visible in the log.
        do {
            self.historyStore = try UsageHistoryStore(applicationSupportDirectory: repository.applicationSupportDirectory)
        } catch {
            self.historyStore = nil
            AppLog.history.error("Could not open the usage history store: \(error.localizedDescription, privacy: .public)")
        }
        refreshStoredSnapshotStatuses()
        updateMenuBarSummary()
        // History can be tens of thousands of lines; load it off the launch
        // path. Appends before this finishes are safe — the store lazily
        // loads before its first mutation.
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try self.historyStore?.load()
            } catch {
                AppLog.history.error("Could not load usage history: \(error.localizedDescription, privacy: .public)")
            }
            self.recomputeAllEstimates()
        }
        usageAlertController.requestAuthorization()
        observeWake()
        authStateMonitor = AuthStateMonitor { [weak self] provider in
            Task { @MainActor [weak self] in
                await self?.reconcileStableExternalChange(provider: provider, origin: .fileEvent)
            }
        }
        startAuthPolling()

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

    }

    deinit {
        refreshTask?.cancel()
        loginFollowUpTasks.values.forEach { $0.cancel() }
        authPollTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Stops all work that may touch credentials after the executable backing
    /// this process has disappeared or been replaced. The app delegate shows a
    /// single explanation and terminates immediately afterwards.
    func stopForInvalidatedBundle() {
        refreshTask?.cancel()
        refreshTask = nil
        loginFollowUpTasks.values.forEach { $0.cancel() }
        loginFollowUpTasks.removeAll()
        authPollTask?.cancel()
        authPollTask = nil
        authStateMonitor = nil
        statusMessage = "The running app bundle was replaced or deleted. Relaunch Limit Lifeboat to continue."
    }

    private func startAuthPolling() {
        authPollTask?.cancel()
        authPollTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.authObservationInteractive == true ? 5 : 30
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                for provider in Provider.allCases {
                    await self?.reconcileStableExternalChange(provider: provider, origin: .polling)
                }
            }
        }
    }

    func setAuthObservationInteractive(_ interactive: Bool) {
        guard authObservationInteractive != interactive else { return }
        authObservationInteractive = interactive
        startAuthPolling()
        if interactive {
            for provider in Provider.allCases {
                Task { await reconcileStableExternalChange(provider: provider, origin: .popover) }
            }
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
                for provider in Provider.allCases {
                    await self?.reconcileStableExternalChange(provider: provider, origin: .wake)
                }
                await self?.refreshAll()
            }
        }
    }

    /// Called when the popover opens. Reconcile both live logins immediately
    /// and start network-backed usage checks only when either provider has
    /// outlived the configured interval.
    func refreshIfStale() {
        // Both providers can be changed by another app. Reconcile them before
        // rendering or attributing usage, even when usage itself is still fresh.
        do {
            _ = try reconcileLiveCredentials(provider: .codex, origin: .popover)
        } catch {
            AppLog.credentials.error("Popover Codex reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { await reconcileStableExternalChange(provider: .claude, origin: .popover) }
        if shouldRefreshClaudeNow() || shouldRefreshCodexNow() {
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

    private func shouldRefreshCodexNow() -> Bool {
        guard !isRefreshing else { return false }
        if let lastAttempt = lastCodexRefreshAttempt,
           Date().timeIntervalSince(lastAttempt) < TimeInterval(settings.refreshIntervalMinutes * 60) {
            return false
        }
        return profiles.contains {
            $0.provider == .codex && ($0.isActiveCLI || hasStoredSnapshot(for: $0))
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
            await reconcileStableExternalChange(provider: provider, origin: .scheduledRefresh)
        }

        // Both providers now use account-specific live usage sources for every
        // captured profile. Codex's account-blind local logs remain only as an
        // active-account fallback for old CLIs and transient network failures.
        await refreshClaudeUsage()
        await refreshCodexUsage()
        notifyElapsedResets()
        updateSwitchAdvice()
        updateMenuBarSummary()
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
                        hasStoredCredentials: hasStoredSnapshot(for: profile)
                            && !(refreshStates[profile.id]?.requiresLogin ?? false),
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
        Task { [weak self] in
            guard let self else { return }
            if await self.switchCLI(to: target, interactive: false) {
                self.usageAlertController.handleAutoSwitch(
                    fromLabel: previousLabel,
                    toLabel: target.label,
                    provider: provider,
                    reason: advice.reason
                )
            }
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
                refreshClaudeLoginExpiration(for: profile)
                applySnapshot(snapshot, for: profile)
                await enrichAccountInfoIfMissing(for: profile)
            } catch {
                // Map the failure to a visible, retryable state rather than
                // swallowing it. The active account may still recover via the
                // local /usage probe; inactive accounts keep their last
                // snapshot (a missing token is expected until the account has
                // been the active login once).
                let fetchError = (error as? ClaudeAccountUsageFetchError) ?? .transport(error)
                if case .noCredentials = fetchError {
                    AppLog.usage.debug("No captured token yet for account \(profile.id, privacy: .public); skipping its usage fetch")
                } else {
                    AppLog.usage.error("Usage fetch failed for account \(profile.id, privacy: .public): \(fetchError.localizedDescription, privacy: .public)")
                }
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
        let info: ClaudeAPIAccountInfo
        do {
            info = try await claudeUsageService.fetchAccountInfo(
                for: profile,
                isActiveCLI: profile.isActiveCLI
            )
            refreshClaudeLoginExpiration(for: profile)
        } catch {
            // Thrown errors (network, missing token) retry next cycle.
            AppLog.usage.debug("Account info fetch failed for account \(profile.id, privacy: .public); retrying next cycle: \(error.localizedDescription, privacy: .public)")
            return
        }
        accountInfoFetched.insert(profile.id)

        if AccountProfileUpdater.enrich(
            profiles: &profiles,
            profileID: profile.id,
            enrichment: AccountProfileEnrichment(planLabel: info.planLabel, identity: info.identity)
        ) {
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

    /// Resolves which profile the current live CLI login belongs to, refreshing
    /// `storedSnapshotStatuses` as a side effect. Shared by `reconcileLiveCredentials`
    /// and the non-activating capture path so ownership is decided one way only.
    private func planLiveOwnership(
        provider: Provider,
        observation: LiveCredentialObservation,
        preferredLoginProfileID: UUID? = nil
    ) throws -> CLIAccountSyncAction {
        var storedFingerprints: [UUID: String] = [:]
        var profilesWithStoredCredentials: Set<UUID> = []
        for profile in profiles where profile.provider == provider {
            do {
                if let fingerprint = try cliSwitcher.storedCredentialFingerprint(for: profile.id) {
                    storedFingerprints[profile.id] = fingerprint
                    if try cliSwitcher.hasRestorableSnapshot(for: profile) {
                        profilesWithStoredCredentials.insert(profile.id)
                        storedSnapshotStatuses[profile.id] = .present
                    } else {
                        storedSnapshotStatuses[profile.id] = .absent
                    }
                } else {
                    storedSnapshotStatuses[profile.id] = .absent
                }
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                throw error
            }
        }
        var action = syncPlanner.plan(
            provider: provider,
            currentIdentity: observation.identity,
            profiles: profiles,
            liveCredentialFingerprint: observation.credentialFingerprint,
            storedCredentialFingerprints: storedFingerprints,
            profilesWithStoredCredentials: profilesWithStoredCredentials
        )
        if let preferredLoginProfileID,
           let identity = observation.identity,
           let preferred = profiles.first(where: { $0.id == preferredLoginProfileID && $0.provider == provider }),
           preferred.identity == nil,
           !profilesWithStoredCredentials.contains(preferred.id),
           !profiles.contains(where: { $0.provider == provider && $0.identity?.matches(identity) == true }) {
            action = .adopt(preferred.id)
        }
        return action
    }

    /// Syncs the active-CLI flags and identities from the current terminal
    /// login, then captures its credentials into the matching profile so
    /// switching never depends on a manual snapshot step.
    @discardableResult
    private func reconcileLiveCredentials(
        provider: Provider,
        origin: AuthChangeOrigin,
        observation suppliedObservation: LiveCredentialObservation? = nil,
        preferredLoginProfileID: UUID? = nil
    ) throws -> AccountProfile? {
        let observation = try suppliedObservation ?? cliSwitcher.liveObservation(provider: provider)
        let previousActiveID = activeProfile(for: provider)?.id
        let action = try planLiveOwnership(
            provider: provider,
            observation: observation,
            preferredLoginProfileID: preferredLoginProfileID
        )
        var changed = false
        var activeID: UUID?

        switch action {
        case .deactivateAll:
            changed = AccountProfileUpdater.setActiveCLI(
                profiles: &profiles,
                provider: provider,
                profileID: nil
            ).changed
        case .activate(let id), .adopt(let id):
            activeID = id
        case .create:
            guard let currentIdentity = observation.identity else {
                statusMessage = "Detected new \(provider.displayName) credentials; waiting for stable account identity."
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
        if let activeID {
            let activation = AccountProfileUpdater.setActiveCLI(
                profiles: &profiles,
                provider: provider,
                profileID: activeID
            )
            changed = changed || activation.changed
            // Anchor the Codex freshness gate on the inactive→active
            // transition only (never every sync, or the gate would always
            // reject the account's own latest event).
            if let activatedID = activation.activatedID, provider == .codex {
                codexActiveSince[activatedID] = Date()
            }
            if let index = profiles.firstIndex(where: { $0.id == activeID }) {
                if let currentIdentity = observation.identity {
                let merged = AccountProfileUpdater.mergeIdentity(
                    existing: profiles[index].identity,
                    new: currentIdentity
                )
                if profiles[index].identity != merged {
                    profiles[index].identity = merged
                    profiles[index].updatedAt = Date()
                    changed = true
                }
                }
                active = profiles[index]
            }
        }

        if changed {
            persistProfiles()
        }
        if let active,
           observation.isLoggedIn,
           observation.snapshot != nil {
            do {
                _ = try cliSwitcher.storeObservation(observation, for: active)
                storedSnapshotStatuses[active.id] = .present
                refreshClaudeLoginExpiration(for: active)
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[active.id] = .locked
                throw error
            }
        }
        let newActiveID = active?.id
        let isExternalOrigin = origin == .fileEvent
            || origin == .polling
            || origin == .popover
            || origin == .wake
            || origin == .scheduledRefresh
        if previousActiveID != newActiveID,
           isExternalOrigin {
            // An outside account choice is deliberate user intent. Give it the
            // same protection as a switch made from this app.
            lastManualSwitchAt[provider] = Date()
            lastAutoSwitchAttempt[provider] = nil
        }
        updateMenuBarSummary()
        return active
    }

    private func reconcileStableExternalChange(provider: Provider, origin: AuthChangeOrigin) async {
        do {
            let first = try cliSwitcher.liveObservation(provider: provider)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let second = try cliSwitcher.liveObservation(provider: provider)
            guard first.stabilityKey == second.stabilityKey else { return }
            _ = try reconcileLiveCredentials(provider: provider, origin: origin, observation: second)
        } catch {
            if isCredentialAccessDenied(error) {
                if let active = activeProfile(for: provider) {
                    refreshStates[active.id] = .keychainLocked
                }
                if provider == .claude {
                    markKeychainRepairSuggested()
                }
                return
            }
            AppLog.credentials.error("Could not reconcile \(provider.displayName, privacy: .public) credentials (origin: \(String(describing: origin), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not reconcile \(provider.displayName) credentials: \(error.localizedDescription)"
        }
    }

    private func isCredentialAccessDenied(_ error: Error) -> Bool {
        if let error = error as? CredentialStoreError {
            return error.isKeychainAccessDenied
        }
        if let error = error as? ClaudeCodeCredentialsKeychainError {
            return error.isKeychainAccessDenied
        }
        return false
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

        // Hand the CLI the live token so it never reads its own keychain item
        // (a SecurityAgent prompt on systems where claude's signature isn't
        // durably authorized). An expired token is withheld rather than
        // refreshed: a background probe must not mutate the live login.
        var oauthToken: String?
        if let credentials = (try? cliSwitcher.liveClaudeOAuthCredentials()) ?? nil,
           !credentials.isExpired() {
            oauthToken = credentials.accessToken
        }

        do {
            let report = try await claudeCodeUsageReader.readUsage(oauthToken: oauthToken)
            if let identity = report.identity {
                updateIdentity(identity, for: profile)
            }
            let snapshot = report.makeSnapshot(for: profile)
            applySnapshot(snapshot, for: profile)
        } catch {
            refreshStates[profile.id] = failureState
            AppLog.usage.error("Claude Code /usage probe failed for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statusMessage = "Claude Code /usage unavailable: \(error.localizedDescription)"
        }
    }

    /// Polls every captured Codex account through the stable app-server rate
    /// limit API. Accounts are serialized (active first) so copied refresh
    /// tokens are never used concurrently by this app.
    private func refreshCodexUsage() async {
        lastCodexRefreshAttempt = Date()
        let codexProfiles = profiles
            .filter { $0.provider == .codex }
            .sorted { $0.isActiveCLI && !$1.isActiveCLI }
        guard let executablePath = cliSwitcher.resolveExecutablePath(command: Provider.codex.commandName) else {
            for profile in codexProfiles {
                failCodexUsageRefresh(
                    for: profile,
                    reason: "The Codex executable could not be found."
                )
            }
            return
        }
        let executableURL = URL(fileURLWithPath: executablePath)
        for profile in codexProfiles {
            await refreshCodexUsage(for: profile, executableURL: executableURL)
        }
    }

    private func refreshCodexUsage(for profile: AccountProfile, executableURL: URL) async {
        refreshStates[profile.id] = .refreshing
        for _ in 0..<2 {
            do {
                guard let fingerprint = try cliSwitcher.storedCredentialFingerprint(for: profile.id),
                      let authJSON = try cliSwitcher.storedCodexAuthJSON(for: profile.id) else {
                    if !refreshCodexLocalFallback(for: profile) {
                        refreshStates[profile.id] = .needsLogin(
                            reason: "No saved Codex credentials are available for live usage checks."
                        )
                    }
                    return
                }

                let result = try await codexUsageService.fetchSnapshot(
                    for: profile,
                    authJSON: authJSON,
                    executableURL: executableURL,
                    expectedIdentity: profile.identity
                )

                if result.updatedAuthJSON != authJSON {
                    guard try cliSwitcher.replaceStoredCodexAuthJSON(
                        result.updatedAuthJSON,
                        for: profile.id,
                        ifSnapshotFingerprintMatches: fingerprint
                    ) else {
                        // A concurrent capture won. Re-read that newer snapshot
                        // once instead of persisting credentials derived from an
                        // older refresh token.
                        continue
                    }
                    storedSnapshotStatuses[profile.id] = .present

                    // Keep the live login in sync only when it still has the
                    // exact credentials copied for this check and the same
                    // profile remains active. Any outside account/CLI change
                    // wins this compare-and-swap.
                    if let current = profiles.first(where: { $0.id == profile.id }),
                       current.isActiveCLI,
                       try cliSwitcher.replaceLiveCodexAuthJSON(
                           result.updatedAuthJSON,
                           ifCredentialFingerprintMatches: fingerprint
                       ) {
                        _ = try reconcileLiveCredentials(
                            provider: .codex,
                            origin: .scheduledRefresh
                        )
                    }
                }

                applyCodexAccountInfo(result.accountInfo, for: profile)
                applySnapshot(result.snapshot, for: profile)
                return
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                refreshStates[profile.id] = .keychainLocked
                return
            } catch let error as CodexAccountUsageError {
                switch error {
                case .requiresLogin(let reason):
                    refreshStates[profile.id] = .needsLogin(reason: reason)
                case .unavailable(let reason):
                    failCodexUsageRefresh(for: profile, reason: reason)
                }
                return
            } catch {
                failCodexUsageRefresh(for: profile, reason: error.localizedDescription)
                return
            }
        }

        failCodexUsageRefresh(
            for: profile,
            reason: "Saved Codex credentials changed during the usage check. Try again."
        )
    }

    private func failCodexUsageRefresh(for profile: AccountProfile, reason: String) {
        if !refreshCodexLocalFallback(for: profile) {
            refreshStates[profile.id] = .readFailed(reason: reason)
        }
        AppLog.usage.error(
            "Codex usage fetch failed for account \(profile.id, privacy: .public): \(reason, privacy: .public)"
        )
    }

    /// Compatibility fallback for older Codex versions and transient network
    /// failures. Session events have no identity, so only the active account is
    /// eligible and multi-account reads retain the post-activation freshness
    /// gate. A missing fallback never deletes a previously valid API snapshot.
    @discardableResult
    private func refreshCodexLocalFallback(for profile: AccountProfile, now: Date = Date()) -> Bool {
        guard let current = profiles.first(where: { $0.id == profile.id }),
              current.isActiveCLI else {
            enrichCodexAccountInfo(for: profile)
            return false
        }
        let hasMultipleCodex = profiles.filter { $0.provider == .codex }.count > 1
        if hasMultipleCodex, codexActiveSince[current.id] == nil {
            codexActiveSince[current.id] = now
        }
        let gate = hasMultipleCodex ? codexActiveSince[current.id] : nil
        guard let snapshot = codexLocalUsageReader.readUsage(for: current, producedAfter: gate, now: now) else {
            enrichCodexAccountInfo(for: current)
            return false
        }
        applySnapshot(snapshot, for: current)
        enrichCodexAccountInfo(for: current)
        return true
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
        applyCodexAccountInfo(info, for: profile)
    }

    private func applyCodexAccountInfo(_ info: CodexAccountInfo, for profile: AccountProfile) {
        accountInfoFetched.insert(profile.id)

        if AccountProfileUpdater.enrich(
            profiles: &profiles,
            profileID: profile.id,
            enrichment: AccountProfileEnrichment(planLabel: info.planLabel, identity: info.identity)
        ) {
            persistProfiles()
        }
    }

    private func applySnapshot(_ snapshot: UsageSnapshot, for profile: AccountProfile) {
        snapshots[profile.id] = snapshot
        refreshStates[profile.id] = .ok
        do {
            _ = try historyStore?.append(snapshot)
        } catch {
            AppLog.history.error("Could not record a usage reading for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
        storedSnapshotStatuses[profile.id] = .absent
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
        guard alert.runModalActivating() == .alertFirstButtonReturn else {
            return
        }

        do {
            try CredentialAccess.userInitiated(
                reason: "remove saved credentials for \(profile.label)"
            ) {
                try cliSwitcher.deleteStoredSnapshot(for: profile.id)
            }
            storedSnapshotStatuses[profile.id] = .absent
        } catch {
            statusMessage = "Could not delete stored credentials for \(profile.label): \(error.localizedDescription)"
        }
        if profile.webDataStoreKind == .isolated {
            WKWebsiteDataStore.remove(forIdentifier: profile.webDataStoreID) { _ in }
        }
        profiles.remove(at: index)
        snapshots[profile.id] = nil
        refreshStates[profile.id] = nil
        storedSnapshotStatuses[profile.id] = nil
        claudeLoginExpirations[profile.id] = nil
        do {
            try historyStore?.removeAccount(profile.id)
        } catch {
            AppLog.history.error("Could not delete usage history for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
    func switchCLI(
        to profile: AccountProfile,
        interactive: Bool = true,
        allowKeychainRepairRetry: Bool = true
    ) async -> Bool {
        if interactive, CredentialAccess.currentMode != .userInitiated {
            return await CredentialAccess.userInitiated(
                reason: "switch the CLI to \(profile.label)"
            ) {
                storedSnapshotStatuses[profile.id] = readStoredSnapshotStatus(for: profile)
                return await switchCLI(
                    to: profile,
                    interactive: true,
                    allowKeychainRepairRetry: allowKeychainRepairRetry
                )
            }
        }

        guard hasStoredSnapshot(for: profile) else {
            refreshStates[profile.id] = .needsLogin(
                reason: "No saved credentials are available for this account."
            )
            handleLoginRequired(
                for: profile,
                reason: "No saved credentials are available. Log in once and the app will capture them automatically.",
                interactive: interactive
            )
            return false
        }

        if case .needsLogin(let reason) = refreshStates[profile.id] {
            handleLoginRequired(for: profile, reason: reason, interactive: interactive)
            return false
        }

        switch await preflightSwitchTarget(profile) {
        case .ready:
            break
        case .requiresLogin(let reason):
            refreshStates[profile.id] = .needsLogin(reason: reason)
            handleLoginRequired(for: profile, reason: reason, interactive: interactive)
            updateSwitchAdvice()
            return false
        case .temporarilyUnavailable(let reason):
            refreshStates[profile.id] = .readFailed(reason: reason)
            updateSwitchAdvice()
            if !interactive {
                statusMessage = "Automatic switch skipped: \(profile.label) could not be verified. \(reason)"
                return false
            }
            let alert = NSAlert()
            alert.messageText = "Could not verify \(profile.label)"
            alert.informativeText = "\(reason) You can switch anyway, but the CLI may ask you to log in."
            alert.addButton(withTitle: "Switch Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModalActivating() == .alertFirstButtonReturn else {
                return false
            }
        }

        if interactive, cliSwitcher.hasActiveProcesses(provider: profile.provider) {
            let alert = NSAlert()
            alert.messageText = "\(profile.provider.displayName) is running"
            alert.informativeText = "The account will be switched for new credential reads. Existing sessions may keep credentials they already loaded."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModalActivating() == .alertFirstButtonReturn else {
                return false
            }
        }

        // Proactively repair the Claude keychain partition list before the
        // first SecItem read of the switch. The OS access dialog appears
        // synchronously mid-read, so fixing it up front turns a burst of
        // password prompts into one. Gated on the cached flag (the probe is a
        // slow whole-keychain dump, so it must not run on every switch);
        // proceed regardless of the user's choice — declining only means the OS
        // dialog may still appear.
        if interactive, profile.provider == .claude, keychainRepairSuggested {
            await repairClaudeKeychainPartitionList(
                reason: "so switching to \(profile.label) no longer asks for your password every time"
            )
        }

        // Capture the currently active login first so nothing is lost.
        let outgoingObservation: LiveCredentialObservation
        let liveAlreadyTargetsProfile: Bool
        do {
            outgoingObservation = try cliSwitcher.stableLiveObservation(provider: profile.provider)
            let targetIdentity = profiles.first(where: { $0.id == profile.id })?.identity
                ?? profile.identity
            liveAlreadyTargetsProfile = targetIdentity.map { target in
                outgoingObservation.identity.map(target.matches) == true
            } ?? false

            // The live login can change while an async preflight is running.
            // If it already became the target, do not capture its older live
            // credentials over the freshly refreshed target snapshot.
            if !liveAlreadyTargetsProfile {
                _ = try reconcileLiveCredentials(
                    provider: profile.provider,
                    origin: interactive ? .manualSwitch : .automaticSwitch,
                    observation: outgoingObservation
                )
            }
        } catch {
            if interactive, profile.provider == .claude, allowKeychainRepairRetry, isKeychainAccessDenied(error) {
                markKeychainRepairSuggested()
                if await repairClaudeKeychainPartitionList(
                    reason: "so \(profile.label) can be switched without repeated prompts"
                ) {
                    return await switchCLI(to: profile, interactive: true, allowKeychainRepairRetry: false)
                }
            }
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
        if !liveAlreadyTargetsProfile,
           profile.provider == .codex,
           let outgoing = activeProfile(for: .codex),
           outgoing.id != profile.id,
           var snapshot = codexLocalUsageReader.readUsage(for: outgoing) {
            snapshot.source = "local Codex CLI logs (captured at switch)"
            applySnapshot(snapshot, for: outgoing)
        }

        do {
            let result = try cliSwitcher.restoreSnapshot(
                for: profile,
                expectedLiveFingerprint: outgoingObservation.credentialFingerprint,
                enforceExpectedLiveState: true
            )
            let verified = result.verifiedObservation
            _ = try reconcileLiveCredentials(
                provider: profile.provider,
                origin: interactive ? .manualSwitch : .automaticSwitch,
                observation: verified
            )

            statusMessage = "Switched \(profile.provider.displayName) CLI to \(profile.label)."
            AppLog.switching.notice("Switched \(profile.provider.displayName, privacy: .public) CLI to account \(profile.id, privacy: .public) (interactive: \(interactive, privacy: .public))")
            refreshStates[profile.id] = .ok
            if interactive {
                lastManualSwitchAt[profile.provider] = Date()
                Task {
                    await CredentialAccess.nonInteractive { await refreshAll() }
                }
            }
            return true
        } catch {
            AppLog.switching.error("Switch to account \(profile.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let storeError = error as? CredentialStoreError, case .decodeFailed = storeError {
                // The stored snapshot is unreadable (e.g. written by an older
                // build). Clear it so this account falls back to the re-capture
                // path, and tell the user how to restore it. The current login
                // was already captured above, so nothing is lost.
                do {
                    try cliSwitcher.deleteStoredSnapshot(for: profile.id)
                } catch {
                    AppLog.credentials.error("Could not clear the unreadable snapshot for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                storedSnapshotStatuses[profile.id] = .absent
                statusMessage = "Cleared unreadable credentials for \(profile.label)."
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Saved credentials for \(profile.label) were unreadable",
                    details: "They were likely written by an older version and have been cleared. Log into this account once in the terminal (\(profile.provider.loginCommand)); the app captures its credentials automatically."
                )
            } else if let switcherError = error as? CLISwitcherError,
                      case .restoreValidationFailed = switcherError {
                statusMessage = "Switch could not be verified for \(profile.label)."
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Switch could not be verified",
                    details: switcherError.localizedDescription
                )
                if interactive {
                    Task {
                        await CredentialAccess.nonInteractive { await refreshAll() }
                    }
                }
            } else if interactive, profile.provider == .claude, allowKeychainRepairRetry, isKeychainAccessDenied(error) {
                markKeychainRepairSuggested()
                if await repairClaudeKeychainPartitionList(
                    reason: "so switching to \(profile.label) stops asking for your password"
                ) {
                    return await switchCLI(to: profile, interactive: true, allowKeychainRepairRetry: false)
                }
                statusMessage = "Switch failed for \(profile.label): \(error.localizedDescription)"
                reportSwitchProblem(interactive: interactive, message: "Switch failed", details: error.localizedDescription)
            } else {
                statusMessage = "Switch failed for \(profile.label): \(error.localizedDescription)"
                reportSwitchProblem(interactive: interactive, message: "Switch failed", details: error.localizedDescription)
            }
            return false
        }
    }

    private enum SwitchPreflightResult {
        case ready
        case requiresLogin(reason: String)
        case temporarilyUnavailable(reason: String)
    }

    private func preflightSwitchTarget(_ profile: AccountProfile) async -> SwitchPreflightResult {
        switch profile.provider {
        case .claude:
            do {
                let snapshot = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    accessMode: CredentialAccess.currentMode
                )
                refreshClaudeLoginExpiration(for: profile)
                applySnapshot(snapshot, for: profile)
                return .ready
            } catch {
                let fetchError = (error as? ClaudeAccountUsageFetchError) ?? .transport(error)
                let outcome = RefreshOutcomePolicy.outcome(for: fetchError, isActiveCLI: profile.isActiveCLI)
                if case .needsLogin(let reason) = outcome.state {
                    return .requiresLogin(reason: reason)
                }
                if case .keychainLocked = outcome.state {
                    return .temporarilyUnavailable(reason: "Keychain access is required to verify this account.")
                }
                return .temporarilyUnavailable(reason: error.localizedDescription)
            }
        case .codex:
            return await preflightCodexSwitchTarget(profile)
        }
    }

    private func preflightCodexSwitchTarget(_ profile: AccountProfile) async -> SwitchPreflightResult {
        guard let executablePath = cliSwitcher.resolveExecutablePath(command: Provider.codex.commandName) else {
            return .temporarilyUnavailable(reason: "The Codex executable could not be found.")
        }

        for _ in 0..<2 {
            do {
                guard let fingerprint = try cliSwitcher.storedCredentialFingerprint(for: profile.id),
                      let authJSON = try cliSwitcher.storedCodexAuthJSON(for: profile.id) else {
                    return .requiresLogin(reason: "The saved Codex account has no usable ChatGPT credentials.")
                }
                let result = await codexAuthPreflightService.preflight(
                    authJSON: authJSON,
                    executableURL: URL(fileURLWithPath: executablePath),
                    expectedIdentity: profile.identity
                )
                switch result {
                case .requiresLogin(let reason):
                    return .requiresLogin(reason: reason)
                case .temporarilyUnavailable(let reason):
                    return .temporarilyUnavailable(reason: reason)
                case .ready(let updatedAuthJSON):
                    if try cliSwitcher.replaceStoredCodexAuthJSON(
                        updatedAuthJSON,
                        for: profile.id,
                        ifSnapshotFingerprintMatches: fingerprint
                    ) {
                        storedSnapshotStatuses[profile.id] = .present
                        if let info = CodexIdentityReader.accountInfo(fromAuthJSON: updatedAuthJSON) {
                            accountInfoFetched.insert(profile.id)
                            if AccountProfileUpdater.enrich(
                                profiles: &profiles,
                                profileID: profile.id,
                                enrichment: AccountProfileEnrichment(
                                    planLabel: info.planLabel,
                                    identity: info.identity
                                )
                            ) {
                                persistProfiles()
                            }
                        }
                        return .ready
                    }
                    // A concurrent capture won. Re-read and preflight that
                    // newer snapshot once instead of overwriting it.
                }
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                return .temporarilyUnavailable(reason: "Keychain access is required to verify this account.")
            } catch {
                return .temporarilyUnavailable(reason: error.localizedDescription)
            }
        }
        return .temporarilyUnavailable(
            reason: "The saved Codex credentials changed while they were being verified. Try again."
        )
    }

    private func handleLoginRequired(
        for profile: AccountProfile,
        reason: String,
        interactive: Bool
    ) {
        guard interactive else {
            statusMessage = "Automatic switch skipped: \(profile.label) needs login."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(profile.label) again?"
        alert.informativeText = reason
        alert.addButton(withTitle: "Log In Again")
        alert.addButton(withTitle: "Cancel")
        if alert.runModalActivating() == .alertFirstButtonReturn {
            beginCLILogin(for: profile)
        }
    }

    private func reportSwitchProblem(interactive: Bool, message: String, details: String) {
        if interactive {
            showError(message: message, details: details)
        } else {
            statusMessage = "\(message). \(details)"
        }
    }

    // MARK: - Keychain partition-list repair

    private func makeKeychainPartitionRepair() -> KeychainPartitionRepair {
        KeychainPartitionRepair(
            requiredPartitions: DistributionIdentity.requiredClaudeKeychainPartitions
        )
    }

    private func confirmKeychainPartitionComplete() {
        keychainRepairSuggested = false
    }

    /// A live keychain denial means the last observed complete item may have
    /// been replaced. Flag the action immediately; the metadata probe confirms
    /// the current item's ACL without prompting.
    private func markKeychainRepairSuggested() {
        keychainRepairSuggested = true
    }

    /// Non-interactive launch probe: highlights the manual repair action when
    /// the shared Claude keychain item's partition list is missing this app's
    /// team. It runs once per launch and after a newly observed Claude login,
    /// while access denials immediately mark the action as potentially needed.
    /// No result is persisted across launches, and the probe never prompts.
    func refreshKeychainRepairSuggestion() async {
        switch await claudeKeychainPartitionStatus() {
        case .complete:
            confirmKeychainPartitionComplete()
        case .missing:
            keychainRepairSuggested = true
        case .unparseable, .itemNotFound, .none:
            // Not logged in yet, or the probe failed: nothing actionable to flag.
            keychainRepairSuggested = false
        }
    }

    /// Reads the partition-list status of the shared `Claude Code-credentials`
    /// item off the main actor. This never prompts for a password. Returns nil
    /// if the probe itself failed (treated as "don't interrupt the user").
    private func claudeKeychainPartitionStatus() async -> KeychainPartitionStatus? {
        let repair = makeKeychainPartitionRepair()
        return await Task.detached(priority: .userInitiated) {
            try? repair.status()
        }.value
    }

    /// True for errors that mean the Keychain denied access (rather than a
    /// missing item), unwrapping the switch/transaction error wrappers.
    private func isKeychainAccessDenied(_ error: Error) -> Bool {
        if let error = error as? ClaudeCodeCredentialsKeychainError {
            return error.isKeychainAccessDenied
        }
        if let error = error as? CredentialStoreError {
            return error.isKeychainAccessDenied
        }
        if let error = error as? CLISwitcherError, case .backupFailed(_, let underlying) = error {
            return isKeychainAccessDenied(underlying)
        }
        return false
    }

    private struct KeychainRepairAttempt: Sendable {
        var outcome: KeychainPartitionRepairOutcome?
        var wrongPassword = false
        var message: String?
    }

    /// Applies an already-computed safe write plan on a background task,
    /// mapping thrown errors to a Sendable result.
    private func runKeychainRepair(
        _ repair: KeychainPartitionRepair,
        csv: String,
        added: [String],
        password: String
    ) async -> KeychainRepairAttempt {
        await Task.detached(priority: .userInitiated) {
            do {
                let outcome = try repair.apply(csv: csv, added: added, password: password)
                return KeychainRepairAttempt(outcome: outcome)
            } catch let error as KeychainPartitionRepairError {
                if case .wrongPassword = error {
                    return KeychainRepairAttempt(wrongPassword: true, message: error.localizedDescription)
                }
                return KeychainRepairAttempt(message: error.localizedDescription)
            } catch {
                return KeychainRepairAttempt(message: error.localizedDescription)
            }
        }.value
    }

    /// Shared entry point for the proactive switch gate, the reactive fallback,
    /// and the manual menu item. Adds this app's team to the item's partition
    /// list so `Always Allow` finally sticks. Returns true when the list ends up
    /// complete (already-complete or newly repaired). Prompts for the login
    /// password only when a write is actually required.
    @discardableResult
    func repairClaudeKeychainPartitionList(reason: String) async -> Bool {
        let repair = makeKeychainPartitionRepair()

        // One slow dump (it enumerates the whole keychain) to decide everything
        // before prompting; surface progress so the pause is not a silent hang.
        statusMessage = "Checking keychain access…"
        guard let plan = await Task.detached(priority: .userInitiated, operation: {
            try? repair.plan()
        }).value else {
            statusMessage = "Could not inspect keychain access."
            showError(
                message: "Could not inspect the keychain item",
                details: "The existing keychain access list could not be read, so no password was requested and no changes were made."
            )
            return false
        }
        let csv: String
        let added: [String]
        switch plan {
        case .complete:
            confirmKeychainPartitionComplete()
            statusMessage = "Keychain access is already set up — no changes needed."
            return true
        case .itemNotFound:
            statusMessage = "No Claude Code keychain item was found."
            showError(
                message: "Claude Code isn't logged in yet",
                details: "There's no Claude Code keychain item to repair. Log in with `claude` (/login) first, then try again."
            )
            return false
        case .unparseable:
            statusMessage = "Could not safely read the keychain access list."
            showError(
                message: "Could not safely inspect keychain access",
                details: "The existing partition list could not be parsed. No password was requested and no changes were made."
            )
            return false
        case .needsWrite(let plannedCSV, let plannedAdded):
            csv = plannedCSV
            added = plannedAdded
        }

        guard var password = promptForLoginKeychainPassword(
            message: "Enter your macOS login password once \(reason). It's used only to authorize this one keychain change and is never stored."
        ) else {
            statusMessage = "Keychain repair cancelled."
            return false
        }

        statusMessage = "Updating keychain access…"
        for attempt in 0..<3 {
            let result = await runKeychainRepair(
                repair,
                csv: csv,
                added: added,
                password: password
            )
            if let outcome = result.outcome {
                confirmKeychainPartitionComplete()
                switch outcome {
                case .alreadyComplete:
                    statusMessage = "Keychain access is already set up — no changes needed."
                case .repaired:
                    statusMessage = "Fixed repeated keychain prompts — switching accounts won't ask for your password anymore."
                }
                return true
            }
            if result.wrongPassword, attempt < 2 {
                guard let retry = promptForLoginKeychainPassword(
                    message: "That login password was not correct. Enter your macOS login password to authorize the keychain change."
                ) else {
                    statusMessage = "Keychain repair cancelled."
                    return false
                }
                password = retry
                continue
            }
            showError(
                message: "Could not stop the keychain prompts",
                details: result.message ?? "The keychain partition list could not be updated."
            )
            statusMessage = "Could not update keychain access."
            return false
        }
        return false
    }

    /// Modal secure-entry prompt for the login-keychain password. The value is
    /// read straight into the repair call and is never stored on `self` or
    /// logged.
    private func promptForLoginKeychainPassword(message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Stop repeated keychain prompts"
        alert.informativeText = message
        alert.addButton(withTitle: "Authorize")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "macOS login password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    func captureCLISnapshot(for profile: AccountProfile) {
        if CredentialAccess.currentMode != .userInitiated {
            CredentialAccess.userInitiated(
                reason: "save CLI credentials for \(profile.label)"
            ) {
                captureCLISnapshot(for: profile)
            }
            return
        }

        guard profile.isActiveCLI else {
            showError(
                message: "Capture cancelled",
                details: "Only the active terminal account can be captured. Refresh to reconcile the current login first."
            )
            return
        }
        do {
            let observation = try cliSwitcher.stableLiveObservation(provider: profile.provider)
            guard observation.identity.map({ profile.identity?.matches($0) ?? true }) != false else {
                throw CLISwitcherError.credentialConflict("live \(profile.provider.displayName) identity")
            }
            _ = try reconcileLiveCredentials(provider: profile.provider, origin: .manualCapture, observation: observation)
            statusMessage = "Captured \(profile.provider.displayName) CLI credentials for \(profile.label)."
            storedSnapshotStatuses[profile.id] = .present
        } catch {
            statusMessage = "Capture failed for \(profile.label): \(error.localizedDescription)"
            showError(message: "Capture failed", details: error.localizedDescription)
        }
    }

    /// Whether a saved credential snapshot exists for the account, and if not,
    /// whether that is a genuine absence or a locked/denied Keychain — the two
    /// lead to different UI (log in vs. grant access).
    enum StoredSnapshotStatus: Equatable {
        case present
        case absent
        case locked
    }

    func storedSnapshotStatus(for profile: AccountProfile) -> StoredSnapshotStatus {
        storedSnapshotStatuses[profile.id] ?? .absent
    }

    func loginExpiresAt(for profile: AccountProfile) -> Date? {
        guard profile.provider == .claude else { return nil }
        return claudeLoginExpirations[profile.id]
    }

    private func refreshStoredSnapshotStatuses() {
        var statuses: [UUID: StoredSnapshotStatus] = [:]
        var expirations: [UUID: Date] = [:]
        for profile in profiles {
            statuses[profile.id] = readStoredSnapshotStatus(for: profile)
            if profile.provider == .claude,
               let credentials = try? cliSwitcher.storedClaudeOAuthCredentials(for: profile.id),
               let expiresAt = credentials.refreshTokenExpiresAt {
                expirations[profile.id] = expiresAt
            }
        }
        storedSnapshotStatuses = statuses
        claudeLoginExpirations = expirations
    }

    private func refreshClaudeLoginExpiration(for profile: AccountProfile) {
        guard profile.provider == .claude else {
            claudeLoginExpirations[profile.id] = nil
            return
        }
        do {
            claudeLoginExpirations[profile.id] = try cliSwitcher
                .storedClaudeOAuthCredentials(for: profile.id)?
                .refreshTokenExpiresAt
        } catch {
            // Keep an existing cached warning through a transient Keychain
            // denial; the credential status reports that problem separately.
        }
    }

    private func readStoredSnapshotStatus(for profile: AccountProfile) -> StoredSnapshotStatus {
        do {
            return try cliSwitcher.hasRestorableSnapshot(for: profile) ? .present : .absent
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
        Task {
            await CredentialAccess.userInitiated(
                reason: "access saved credentials for \(profile.label)"
            ) {
                await retryRefreshInteractively(for: profile)
            }
            updateSwitchAdvice()
            updateMenuBarSummary()
        }
    }

    private func retryRefreshInteractively(for profile: AccountProfile) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let storedStatus = readStoredSnapshotStatus(for: profile)
        storedSnapshotStatuses[profile.id] = storedStatus
        guard storedStatus != .locked else {
            refreshStates[profile.id] = .keychainLocked
            return
        }

        switch profile.provider {
        case .claude:
            lastClaudeRefreshAttempt = Date()
            refreshStates[profile.id] = .refreshing
            do {
                let snapshot = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI
                )
                refreshClaudeLoginExpiration(for: profile)
                applySnapshot(snapshot, for: profile)
                await enrichAccountInfoIfMissing(for: profile)
            } catch {
                let fetchError = (error as? ClaudeAccountUsageFetchError) ?? .transport(error)
                let outcome = RefreshOutcomePolicy.outcome(for: fetchError, isActiveCLI: profile.isActiveCLI)
                if outcome.attemptTUIFallback {
                    await refreshActiveClaudeCodeUsage(onFailure: outcome.state, for: profile)
                } else {
                    refreshStates[profile.id] = outcome.state
                }
            }
        case .codex:
            lastCodexRefreshAttempt = Date()
            if let executablePath = cliSwitcher.resolveExecutablePath(command: Provider.codex.commandName) {
                await refreshCodexUsage(
                    for: profile,
                    executableURL: URL(fileURLWithPath: executablePath)
                )
            } else {
                failCodexUsageRefresh(for: profile, reason: "The Codex executable could not be found.")
            }
        }

        if case .needsLogin(let reason) = refreshStates[profile.id] {
            handleLoginRequired(for: profile, reason: reason, interactive: true)
        }
    }

    func validateActiveLogin(provider: Provider) -> Bool {
        cliSwitcher.validateActiveLogin(provider: provider)
    }

    func copyLoginCommand(for provider: Provider) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(provider.loginCommand, forType: .string)
        statusMessage = "Copied: \(provider.loginCommand)"
        terminalLauncher.open()
    }

    func beginCLILogin(for profile: AccountProfile, activateAfterLogin: Bool = true) {
        if CredentialAccess.currentMode != .userInitiated {
            CredentialAccess.userInitiated(
                reason: "prepare \(profile.label) for CLI login"
            ) {
                beginCLILogin(for: profile, activateAfterLogin: activateAfterLogin)
            }
            return
        }

        let initialObservation = try? cliSwitcher.stableLiveObservation(provider: profile.provider)

        // Not switching is only meaningful when there is a *different* active
        // account to preserve. With no active account (first login) or when
        // re-authenticating the account that is already active, fall back to
        // the normal activating login.
        let previousActiveID = activeProfile(for: profile.provider)?.id
        let activate = activateAfterLogin || previousActiveID == nil || previousActiveID == profile.id

        // Codex accounts share the single `~/.codex/auth.json`, so a bare
        // `codex login` launched while another account is signed in runs
        // against that existing session instead of starting a new login.
        // Capture the active account first (so its credentials survive as a
        // restorable snapshot), then log the terminal out before logging in.
        let hasExistingSession = profile.provider == .codex && cliSwitcher.validateActiveLogin(provider: .codex)
        // A non-activating login must be able to restore the previous account
        // afterward, so capture it first for both providers. Codex is already
        // captured by the `hasExistingSession` path below; capture Claude here.
        let capturesActiveFirst = hasExistingSession || (!activate && profile.provider == .claude)
        if capturesActiveFirst {
            do {
                guard let initialObservation else {
                    throw CLISwitcherError.credentialConflict("live \(profile.provider.displayName) credentials")
                }
                _ = try reconcileLiveCredentials(provider: profile.provider, origin: .login, observation: initialObservation)
            } catch {
                statusMessage = "Login cancelled: the current \(profile.provider.displayName) account could not be saved."
                showError(
                    message: "Could not safely start \(profile.provider.displayName) login",
                    details: "The current account was not touched because its credentials could not be captured. \(error.localizedDescription)"
                )
                return
            }
        }
        let command = terminalLoginCommand(
            for: profile.provider,
            hasExistingSession: hasExistingSession,
            exitWhenDone: false
        )
        let launchedCommand = terminalLoginCommand(
            for: profile.provider,
            hasExistingSession: hasExistingSession,
            exitWhenDone: true
        )
        let linkNote = activate
            ? "The account links automatically after login."
            : "It is updated without switching your active account."

        // Preferred path: drive Terminal via AppleScript (reuses a window when
        // the user has granted Automation permission).
        let appleScriptError = terminalLauncher.runViaAutomation(launchedCommand)
        if appleScriptError == nil {
            statusMessage = "Started login for \(profile.label). \(linkNote)"
            watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialObservation: initialObservation, activateAfterLogin: activate, previousActiveID: previousActiveID)
            return
        }

        // AppleScript failed — most commonly because Terminal Automation
        // permission is off (AppleEvent error -1743), which used to silently
        // fall back to a bare Terminal that ran nothing. Instead run the
        // command by opening an executable `.command` file, which needs no
        // Apple Events permission.
        if terminalLauncher.runViaCommandFile(launchedCommand) {
            statusMessage = "Opened Terminal to log in \(profile.label). \(linkNote)"
            watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialObservation: initialObservation, activateAfterLogin: activate, previousActiveID: previousActiveID)
            return
        }

        // Last resort: copy the command and open a bare Terminal for the user
        // to paste it into.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = appleScriptError
            ?? "Copied the login command. Paste it into Terminal; \(linkNote.prefix(1).lowercased() + linkNote.dropFirst())"
        terminalLauncher.open()
        watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialObservation: initialObservation, activateAfterLogin: activate, previousActiveID: previousActiveID)
    }

    /// Builds the CLI login command, prefixed with a PATH export so the
    /// executable resolves even when Terminal's default PATH does not include
    /// it (e.g. codex provided by Conductor's bundle). Falls back to the bare
    /// command name when the executable cannot be resolved.
    private func terminalLoginCommand(
        for provider: Provider,
        hasExistingSession: Bool,
        exitWhenDone: Bool
    ) -> String {
        let base = provider.terminalLoginCommand(
            hasExistingSession: hasExistingSession,
            exitWhenDone: exitWhenDone
        )
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
        initialObservation: LiveCredentialObservation?,
        activateAfterLogin: Bool,
        previousActiveID: UUID?
    ) {
        loginFollowUpTasks[provider]?.cancel()
        loginFollowUpTasks[provider] = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else {
                    return
                }

                let linked = await self?.refreshAfterCompletedLogin(
                    profileID: profileID,
                    provider: provider,
                    initialObservation: initialObservation,
                    activateAfterLogin: activateAfterLogin,
                    previousActiveID: previousActiveID
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
        initialObservation: LiveCredentialObservation?,
        activateAfterLogin: Bool,
        previousActiveID: UUID?
    ) async -> Bool {
        guard let current = try? cliSwitcher.liveObservation(provider: provider),
              current.isLoggedIn else {
            return false
        }
        let identityChanged: Bool
        if let initial = initialObservation?.identity, let currentIdentity = current.identity {
            identityChanged = !currentIdentity.matches(initial)
        } else {
            identityChanged = current.identity != nil && initialObservation?.identity == nil
        }
        let credentialsChanged = current.credentialFingerprint != initialObservation?.credentialFingerprint
        guard identityChanged || credentialsChanged else {
            return false
        }
        if provider == .claude {
            await refreshKeychainRepairSuggestion()
        }
        guard activateAfterLogin else {
            return await handleNonActivatingLoginCompletion(
                current: current,
                profileID: profileID,
                previousActiveID: previousActiveID
            )
        }
        do {
            _ = try reconcileLiveCredentials(
                provider: provider,
                origin: .login,
                observation: current,
                preferredLoginProfileID: profileID
            )
            refreshStates[profileID] = .ok
            await CredentialAccess.nonInteractive { await refreshAll() }
            return profiles.first(where: { $0.id == profileID })?.isActiveCLI == true
        } catch {
            statusMessage = "Login finished, but the account could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Captures the just-completed login into its profile *without* changing the
    /// active account, then restores the previously-active account into the live
    /// session so the app's active-CLI belief and the on-disk session agree.
    private func handleNonActivatingLoginCompletion(
        current: LiveCredentialObservation,
        profileID: UUID,
        previousActiveID: UUID?
    ) async -> Bool {
        let provider = current.provider
        let resolved: AccountProfile?
        do {
            resolved = try captureLoginIntoProfile(
                observation: current,
                provider: provider,
                targetProfileID: profileID
            )
        } catch {
            statusMessage = "Login finished, but the account could not be saved: \(error.localizedDescription)"
            return false
        }
        // No stable identity yet — keep polling.
        guard let resolved else {
            return false
        }
        refreshStates[resolved.id] = .ok

        // Without a previous account to return to (or one we can restore), the
        // freshly logged-in account simply becomes active.
        guard let previousActiveID,
              let previous = profiles.first(where: { $0.id == previousActiveID }),
              hasStoredSnapshot(for: previous) else {
            do {
                _ = try reconcileLiveCredentials(provider: provider, origin: .login, observation: current, preferredLoginProfileID: profileID)
            } catch {
                AppLog.credentials.error("Post-login reconcile failed for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            statusMessage = "Logged into \(resolved.label). Could not restore the previous account, so it is now active."
            await CredentialAccess.nonInteractive { await refreshAll() }
            return true
        }

        do {
            let result = try cliSwitcher.restoreSnapshot(
                for: previous,
                expectedLiveFingerprint: current.credentialFingerprint,
                enforceExpectedLiveState: true
            )
            _ = try reconcileLiveCredentials(
                provider: provider,
                origin: .login,
                observation: result.verifiedObservation
            )
            var message = "Logged into \(resolved.label). Kept \(previous.label) as the active \(provider.displayName) account."
            if resolved.id != profileID {
                message += " The login matched an existing account."
            }
            statusMessage = message
            await CredentialAccess.nonInteractive { await refreshAll() }
            return true
        } catch {
            // Restore-back failed — the live session still belongs to the new
            // account. Reconcile to that reality so the app never claims an
            // active account that isn't live, then tell the user plainly.
            AppLog.switching.error("Restore-back to account \(previous.id, privacy: .public) after a non-activating login failed: \(error.localizedDescription, privacy: .public)")
            do {
                _ = try reconcileLiveCredentials(provider: provider, origin: .login, observation: current, preferredLoginProfileID: profileID)
            } catch {
                AppLog.credentials.error("Post-login reconcile failed for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            showError(
                message: "Logged into \(resolved.label), but could not switch back to \(previous.label)",
                details: "\(resolved.label) is now the active \(provider.displayName) account. \(error.localizedDescription)"
            )
            await CredentialAccess.nonInteractive { await refreshAll() }
            return true
        }
    }

    /// Records the live login for the profile it belongs to (matching identity,
    /// adopting a placeholder, or registering a new profile) and stores its
    /// credential snapshot, without ever marking it active. Returns the profile
    /// the login was attributed to, or `nil` if the identity is not yet stable.
    private func captureLoginIntoProfile(
        observation: LiveCredentialObservation,
        provider: Provider,
        targetProfileID: UUID
    ) throws -> AccountProfile? {
        guard observation.isLoggedIn,
              observation.snapshot != nil,
              let identity = observation.identity else {
            return nil
        }
        let action = try planLiveOwnership(
            provider: provider,
            observation: observation,
            preferredLoginProfileID: targetProfileID
        )
        let resolvedID: UUID
        switch action {
        case .activate(let id), .adopt(let id):
            resolvedID = id
        case .create:
            let profile = AccountProfile(
                provider: provider,
                label: defaultLabel(for: identity, provider: provider),
                identity: identity
            )
            profiles.append(profile)
            resolvedID = profile.id
        case .deactivateAll:
            return nil
        }
        AccountProfileUpdater.enrich(
            profiles: &profiles,
            profileID: resolvedID,
            enrichment: AccountProfileEnrichment(identity: identity)
        )
        persistProfiles()
        guard let resolved = profiles.first(where: { $0.id == resolvedID }) else {
            return nil
        }
        do {
            _ = try cliSwitcher.storeObservation(observation, for: resolved)
            storedSnapshotStatuses[resolvedID] = .present
            refreshClaudeLoginExpiration(for: resolved)
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            storedSnapshotStatuses[resolvedID] = .locked
            throw error
        }
        return resolved
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func openSettings() {
        settingsWindowController.show(state: self)
    }

    // MARK: - Identity

    private func updateIdentity(_ identity: AccountIdentity, for profile: AccountProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        profiles[index].identity = AccountProfileUpdater.mergeIdentity(existing: profiles[index].identity, new: identity)
        profiles[index].updatedAt = Date()
        persistProfiles()
    }

    // MARK: - Helpers

    private func persistProfiles() {
        do {
            try repository.saveProfiles(profiles)
        } catch {
            AppLog.persistence.error("Could not save accounts: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not save accounts: \(error.localizedDescription)"
        }
    }

    private func saveSnapshots() {
        do {
            try repository.saveUsageSnapshots(snapshots)
        } catch {
            AppLog.persistence.error("Could not save usage snapshots: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not save usage snapshots: \(error.localizedDescription)"
        }
    }

    private func showError(message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.runModalActivating()
    }

    // MARK: - Menu bar summary

    private func updateMenuBarSummary() {
        menuBarSummary = MenuBarSummaryProjector.project(
            profiles: profiles,
            snapshots: snapshots
        )
    }
}
