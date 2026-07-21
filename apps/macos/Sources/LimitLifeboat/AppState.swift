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
    /// Reset spending has its own state so a redemption failure never hides a
    /// still-valid usage reading behind the ordinary refresh error UI.
    @Published private(set) var codexResetStates: [UUID: CodexResetRedemptionState] = [:]
    /// Cached so SwiftUI body evaluation and switch-advice projection never
    /// perform a Keychain query. The cache is populated non-interactively at
    /// launch and updated at every credential mutation boundary.
    @Published private(set) var storedSnapshotStatuses: [UUID: StoredSnapshotStatus] = [:]
    /// Item-scoped authorization health for Claude's provider-owned legacy
    /// Keychain item. `ready` is entered only after a fresh noninteractive data
    /// read succeeds; metadata probes and ACL guesses can never clear a known
    /// denial.
    @Published private(set) var claudeKeychainAuthorizationState: ClaudeKeychainAuthorizationState = .unknown
    /// Claude's fixed per-device login expiry, cached alongside snapshot
    /// presence so SwiftUI never reads Keychain-backed credentials in `body`.
    @Published private(set) var claudeLoginExpirations: [UUID: Date] = [:]

    let settings: SettingsStore
    let updater: AppUpdater

    private let repository: ProfileRepository
    /// Where the durable stores live, exposed so diagnostics can read the
    /// persisted event log off the live @MainActor store.
    var applicationSupportDirectory: URL { repository.applicationSupportDirectory }
    private let cliSwitcher: CLISwitcher
    private let codeSignatureStatus: ApplicationCodeSignatureStatus
    private let parser = UsageTextParser()
    private let identityExtractor = AccountIdentityExtractor()
    private let syncPlanner = CLIAccountSyncPlanner()
    private let codexLocalUsageReader = CodexLocalUsageReader()
    private let codexUsageService = CodexAccountUsageService()
    private let codexResetAttemptStore = CodexResetAttemptStore()
    private let codexResetAutomationPolicy = CodexResetAutomationPolicy()
    private let claudeCodeUsageReader = ClaudeCodeUsageReader()
    private let claudeUsageService: ClaudeAccountUsageService
    private let codexAuthPreflightService = CodexAuthPreflightService()
    private let dashboardWindowManager = DashboardWindowManager()
    private let usageAlertController = UsageAlertController()
    private let resetAlertPlanner = ResetAlertPlanner()
    private let historyStore: UsageHistoryStore?
    private let eventStore: AppEventStore
    private let burnRateEstimator = BurnRateEstimator()
    private let switchAdvisor = SwitchAdvisor()
    private let settingsWindowController = SettingsWindowController()
    private let terminalLauncher = TerminalCommandLauncher()
    private var refreshTask: Task<Void, Never>?
    private var loginFollowUpTasks: [Provider: Task<Void, Never>] = [:]
    private var authPollTask: Task<Void, Never>?
    private var authStateMonitor: AuthStateMonitor?
    private var authObservationInteractive = false
    /// Exactly one live-credential reconciliation may run for a provider at a
    /// time. Callers that arrive while a probe is in flight await that probe
    /// instead of multiplying Keychain reads.
    private var reconciliationFlights: [Provider: (id: UUID, origin: AuthChangeOrigin, task: Task<Void, Never>)] = [:]
    /// Duplicate switch clicks for the same account await one workflow instead
    /// of racing for the provider mutation gate.
    private var switchFlights: [Provider: (id: UUID, profileID: UUID, task: Task<Bool, Never>)] = [:]
    /// A single read is enough when the provider-owned state has not changed
    /// since the last accepted observation. Only a newly observed key is
    /// followed by the delayed stability-confirmation read.
    private var acceptedStabilityKeys: [Provider: String] = [:]
    /// Ownership tokens prevent an old workflow's defer from releasing a gate
    /// that has already been deliberately handed off to a login watcher.
    private var credentialMutationsInProgress: [Provider: UUID] = [:]
    private var deferredReconciliationOrigins: [Provider: AuthChangeOrigin] = [:]
    private var deferredAutomaticSwitchProviders: Set<Provider> = []
    private var deferredFullRefresh = false
    private var deferredClaudeLoginResume = false
    private var claudeAuthorizationInProgress = false
    private var pendingClaudeLoginCompletion: PendingClaudeLoginCompletion?
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
    /// Per-account backoff for automatic reset attempts. Manual redemption is
    /// never throttled and reuses any persisted unresolved idempotency key.
    private var lastAutomaticCodexResetAttempt: [UUID: Date] = [:]
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
    /// When each active Claude profile first entered the `.usagePaused` state,
    /// and which have already been notified about it — so a login that merely
    /// needs a nudge doesn't sit silently failing for hours. Cleared the moment
    /// the profile reaches any other state (re-arming the next episode).
    private var claudeUsagePausedSince: [UUID: Date] = [:]
    private var notifiedUsagePaused: Set<UUID> = []
    private let usagePausedAlertPolicy = UsagePausedAlertPolicy()
    /// The last credential outcome recorded per Claude profile, so the durable
    /// event log only appends on transitions (episode start/recovery).
    private var lastClaudeCredentialOutcome: [UUID: AppEvent.CredentialOutcome] = [:]
    /// Same-provider profiles already warned this launch about sharing one
    /// Anthropic account (a rotation-hostile configuration) — logged once.
    private var warnedSharedAccountProfiles: Set<UUID> = []

    init(
        repository: ProfileRepository,
        cliSwitcher: CLISwitcher,
        settings: SettingsStore? = nil,
        codeSignatureStatus: ApplicationCodeSignatureStatus = .unsupported
    ) throws {
        self.repository = repository
        self.cliSwitcher = cliSwitcher
        self.codeSignatureStatus = codeSignatureStatus
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
        self.eventStore = AppEventStore(applicationSupportDirectory: repository.applicationSupportDirectory)
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
            do {
                try self.eventStore.load()
            } catch {
                AppLog.history.error("Could not load the app event log: \(error.localizedDescription, privacy: .public)")
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
        reconciliationFlights.values.forEach { $0.task.cancel() }
        reconciliationFlights.removeAll()
        switchFlights.values.forEach { $0.task.cancel() }
        switchFlights.removeAll()
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
        reconciliationFlights.values.forEach { $0.task.cancel() }
        reconciliationFlights.removeAll()
        switchFlights.values.forEach { $0.task.cancel() }
        switchFlights.removeAll()
        credentialMutationsInProgress.removeAll()
        deferredReconciliationOrigins.removeAll()
        deferredAutomaticSwitchProviders.removeAll()
        deferredFullRefresh = false
        deferredClaudeLoginResume = false
        pendingClaudeLoginCompletion = nil
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
    }

    func startBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = self?.settings.refreshIntervalMinutes ?? 10
                try? await Task.sleep(nanoseconds: UInt64(max(1, minutes)) * 60_000_000_000)
                guard !Task.isCancelled else { return }
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

    /// Called when the popover opens. Reconcile both live logins immediately
    /// and start network-backed usage checks only when either provider has
    /// outlived the configured interval.
    func refreshIfStale() {
        // The in-flight full refresh already owns the popover's refresh path.
        // Asking for a local reconciliation here would only enqueue another
        // live Keychain read after its provider mutation gate is released.
        guard !isRefreshing else { return }
        let needsUsageRefresh = shouldRefreshClaudeNow() || shouldRefreshCodexNow()
        Task { [weak self] in
            guard let self else { return }
            // A scheduled refresh may have acquired the refresh flight after
            // the popover's synchronous check but before this task ran. Do
            // not enqueue a second reconciliation behind that flight.
            guard !self.isRefreshing else { return }
            if needsUsageRefresh {
                // refreshAll owns the one reconciliation pass for both
                // providers. Starting a second popover probe here used to
                // create 4-6 immediate reads of Claude's shared item.
                await self.refreshAll()
            } else {
                for provider in Provider.allCases {
                    await self.reconcileStableExternalChange(provider: provider, origin: .popover)
                }
                self.updateMenuBarSummary()
            }
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
        // Refresh is allowed to be started by a button, but it remains a
        // prompt-free workflow. In particular, never inherit the interactive
        // session of a surrounding switch/login task.
        if CredentialAccess.currentMode != .nonInteractive {
            await CredentialAccess.nonInteractive { await refreshAll() }
            return
        }
        guard credentialMutationsInProgress.isEmpty else {
            deferredFullRefresh = true
            return
        }
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

        // A user action may acquire a mutation gate while a reconciliation is
        // awaiting its confirmation delay. Do not continue into token reads or
        // refresh writes in parallel with that action.
        guard credentialMutationsInProgress.isEmpty else {
            deferredFullRefresh = true
            return
        }

        // Both providers now use account-specific live usage sources for every
        // captured profile. Codex's account-blind local logs remain only as an
        // active-account fallback for old CLIs and transient network failures.
        guard let claudeMutation = beginCredentialMutation(for: .claude) else {
            deferredFullRefresh = true
            return
        }
        await refreshClaudeUsage()
        finishCredentialMutation(for: .claude, owner: claudeMutation)

        guard let codexMutation = beginCredentialMutation(for: .codex) else {
            deferredFullRefresh = true
            return
        }
        await refreshCodexUsage()
        finishCredentialMutation(for: .codex, owner: codexMutation)
        notifyElapsedResets()
        updateSwitchAdvice()
        updateMenuBarSummary()
        maybeSendWeeklyDigest()
    }

    /// Digest due-ness is checked here rather than via a calendar-triggered
    /// notification: a calendar trigger freezes its content at scheduling
    /// time and fires when the app is not running — exactly when the numbers
    /// are stale and the user cannot act. Checked after a refresh, the digest
    /// is at most one refresh interval old; one due while the app was closed
    /// arrives on the next launch's first refresh.
    private func maybeSendWeeklyDigest(now: Date = Date()) {
        guard settings.weeklyDigestEnabled else {
            return
        }
        let planner = WeeklyDigestPlanner()
        guard let lastSent = usageAlertController.lastWeeklyDigestSentAt else {
            // First run arms the schedule without firing — a digest over
            // history that predates the feature would be near-empty.
            usageAlertController.markWeeklyDigestSent(at: now)
            return
        }
        guard planner.isDue(lastSent: lastSent, now: now) else {
            return
        }

        let period = planner.period(endingAt: now)
        let accounts = profiles.map { profile -> WeeklyDigestPlanner.AccountInput in
            var windows: [String: WeeklyDigestPlanner.WindowInput] = [:]
            for record in historyStore?.records(for: profile.id) ?? [] {
                for reading in record.windows {
                    var input = windows[reading.id] ?? WeeklyDigestPlanner.WindowInput(
                        id: reading.id,
                        kind: reading.kind,
                        label: snapshots[profile.id]?.orderedDisplayWindows
                            .first { $0.id == reading.id }?.label ?? reading.fallbackLabel,
                        readings: []
                    )
                    input.readings.append(BurnRateEstimator.Reading(timestamp: record.timestamp, reading: reading))
                    windows[reading.id] = input
                }
            }
            return WeeklyDigestPlanner.AccountInput(
                profileID: profile.id,
                label: profile.label,
                provider: profile.provider,
                windows: Array(windows.values)
            )
        }

        let digest = planner.build(
            accounts: accounts,
            events: eventStore.events(in: period),
            period: period
        )
        // Marked sent even when there is nothing to say, so an empty week
        // does not re-run this on every refresh cycle.
        usageAlertController.markWeeklyDigestSent(at: now)
        if let digest {
            usageAlertController.handleWeeklyDigest(digest)
        }
    }

    /// Recomputes the best-switch-target hint from the fresh readings and,
    /// when the opt-in is enabled, performs the switch: active account
    /// depleted, another account with clearly more headroom.
    private func updateSwitchAdvice() {
        // Candidates never mix providers: credentials and quota are
        // provider-scoped, so a Claude account can't be a switch target for a
        // depleted Codex login. The advisor itself is provider-agnostic.
        for provider in Provider.allCases {
            let advice = switchAdvisor.advise(candidates: switchCandidates(for: provider))
            switchAdvice[provider] = advice
            maybeAutoSwitch(provider: provider, advice: advice)
        }
    }

    private func switchCandidates(for provider: Provider) -> [SwitchCandidate] {
        profiles
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
    }

    /// A clicked "Switch" button on a notification. The notification may be
    /// hours old, so the embedded target is only a fallback — the click
    /// re-resolves against the current advice (see NotificationSwitchResolver).
    /// The user acted deliberately, so every outcome is answered with a
    /// notification rather than failing silently into a closed popover.
    /// Handles the "Refresh Now" action on a usage-paused notification: runs
    /// the same user-initiated retry the row's Retry button does, so the active
    /// login's expired access token is rotated without opening the popover.
    func performNotificationRefresh(provider: Provider, profileID: UUID?) async {
        let target = profileID.flatMap { id in profiles.first { $0.id == id } }
            ?? activeProfile(for: provider)
        guard let target else {
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Could not refresh",
                body: "That \(provider.displayName) account is no longer saved in Limit Lifeboat."
            )
            return
        }
        // Re-arm the paused nudge: if this refresh actually succeeds the state
        // clears anyway, but if it's dropped because a background cycle is
        // mid-flight (retryRefreshInteractively guards on isRefreshing), the
        // next cycle can nudge again instead of leaving the tap silently unmet.
        notifiedUsagePaused.remove(target.id)
        await CredentialAccess.userInitiated(
            reason: "access saved credentials for \(target.label)"
        ) {
            await retryRefreshInteractively(for: target)
        }
        updateSwitchAdvice()
        updateMenuBarSummary()
    }

    func performNotificationSwitch(provider: Provider, embeddedTargetID: UUID?) async {
        let resolution = NotificationSwitchResolver().resolve(
            embeddedTargetID: embeddedTargetID,
            advice: switchAdvice[provider],
            candidates: switchCandidates(for: provider)
        )
        switch resolution {
        case .switchTo(let profileID, let label):
            guard let target = profiles.first(where: { $0.id == profileID }) else {
                usageAlertController.handleNotificationSwitchOutcome(
                    title: "Could not switch",
                    body: "\(label) is no longer saved in Limit Lifeboat."
                )
                return
            }
            let previousLabel = activeProfile(for: provider)?.label
            // interactive: false — a notification click has no key window to
            // anchor confirmation modals on; problems surface as notifications.
            if await switchCLI(to: target, interactive: false) {
                // The user chose this switch, so auto-switch must honor it the
                // same way it honors an in-app manual switch.
                lastManualSwitchAt[provider] = Date()
                usageAlertController.handleAutoSwitch(
                    fromLabel: previousLabel,
                    toLabel: target.label,
                    provider: provider,
                    reason: nil
                )
            } else {
                usageAlertController.handleNotificationSwitchOutcome(
                    title: "Could not switch to \(target.label)",
                    body: statusMessage.isEmpty
                        ? "Open Limit Lifeboat for details."
                        : statusMessage
                )
            }
        case .alreadyActive(let label):
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Already on \(label)",
                body: "The \(provider.displayName) CLI is already using \(label)."
            )
        case .noEligibleTarget(let reason):
            usageAlertController.handleNotificationSwitchOutcome(
                title: "No account ready to switch to",
                body: "\(reason) Open Limit Lifeboat to check your accounts."
            )
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
            if await self.switchCLI(to: target, interactive: false, automatic: true) {
                self.usageAlertController.handleAutoSwitch(
                    fromLabel: previousLabel,
                    toLabel: target.label,
                    provider: provider,
                    reason: advice.reason
                )
            }
        }
    }

    /// Which stored credential fingerprints appear on more than one holder
    /// (another profile's snapshot or the live keychain item), computed once
    /// per cycle so each Claude profile can be checked against
    /// `RotationProtectionPolicy` without re-reading the keychain per profile.
    private func claudeRotationContext() -> (duplicated: Set<String>, byProfile: [UUID: String]) {
        var byProfile: [UUID: String] = [:]
        var counts: [String: Int] = [:]
        for profile in profiles where profile.provider == .claude {
            guard let fingerprint = try? cliSwitcher.storedCredentialFingerprint(for: profile.id) else {
                continue
            }
            byProfile[profile.id] = fingerprint
            counts[fingerprint, default: 0] += 1
        }
        // The live item's fingerprint is directly comparable to the stored ones
        // (the sync planner matches them for `.activate`). Counting it lets an
        // inactive profile that holds the active login's exact chain register as
        // a duplicate holder even when identities don't reveal the sharing.
        if let liveFingerprint = try? cliSwitcher.liveObservation(provider: .claude).credentialFingerprint {
            counts[liveFingerprint, default: 0] += 1
        }
        let duplicated = Set(counts.filter { $0.value > 1 }.map(\.key))
        return (duplicated, byProfile)
    }

    /// Whether rotating `profile`'s refresh token in the background could
    /// invalidate a chain the live CLI login relies on.
    private func claudeAccountIsLiveElsewhere(
        _ profile: AccountProfile,
        context: (duplicated: Set<String>, byProfile: [UUID: String])
    ) -> Bool {
        RotationProtectionPolicy.accountIsLiveElsewhere(
            profile: profile,
            among: profiles,
            storedFingerprint: context.byProfile[profile.id],
            duplicatedStoredFingerprints: context.duplicated
        )
    }

    /// Polls every Claude account through the usage API (active first, so its
    /// numbers land even if an inactive account's refresh stalls). The slow
    /// expect-probe of the CLI remains the fallback for the active account.
    private func refreshClaudeUsage() async {
        let counter = CredentialKeychainIOCounter()
        await CredentialAccess.counting(counter) {
            await refreshClaudeUsageImpl()
            logCredentialWorkflow(
                workflow: "usage",
                provider: .claude,
                origin: "scheduled_refresh",
                access: "noninteractive",
                status: usageWorkflowStatus(provider: .claude),
                counts: counter.snapshot
            )
        }
    }

    private func refreshClaudeUsageImpl() async {
        lastClaudeRefreshAttempt = Date()
        let claudeProfiles = profiles
            .filter { $0.provider == .claude }
            .sorted { $0.isActiveCLI && !$1.isActiveCLI }

        warnIfSharedClaudeAccounts(claudeProfiles)
        let context = claudeRotationContext()

        for profile in claudeProfiles {
            let liveElsewhere = claudeAccountIsLiveElsewhere(profile, context: context)
            refreshStates[profile.id] = .refreshing
            let liveContext: AutomaticClaudeUsageLiveContext?
            if profile.isActiveCLI {
                guard let resolved = automaticClaudeUsageLiveContext() else {
                    refreshStates[profile.id] = .readFailed(
                        reason: claudeKeychainAuthorizationDiagnostic
                            ?? "The shared Claude credential is unavailable."
                    )
                    continue
                }
                liveContext = resolved
            } else {
                liveContext = nil
            }
            var resolvedUsageCredentials: ClaudeOAuthCredentials?
            do {
                let snapshot = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    accountIsLiveElsewhere: liveElsewhere,
                    liveCredentialReadPolicy: liveContext?.readPolicy ?? .read,
                    credentialDidResolve: { resolvedUsageCredentials = $0 }
                )
                applySnapshot(snapshot, for: profile)
                clearUsagePaused(for: profile.id)
                recordClaudeCredentialOutcome(.success, for: profile, codePath: "background")
                await enrichAccountInfoIfMissing(
                    for: profile,
                    accountIsLiveElsewhere: liveElsewhere,
                    liveCredentialReadPolicy: liveContext?.readPolicy,
                    resolvedCredentials: resolvedUsageCredentials
                )
            } catch {
                // Map the failure to a visible, retryable state rather than
                // swallowing it. The active account may still recover via the
                // local /usage probe; inactive accounts keep their last
                // snapshot (a missing token is expected until the account has
                // been the active login once).
                let fetchError = (error as? ClaudeAccountUsageFetchError) ?? .transport(error)
                if profile.isActiveCLI,
                   case .credentialUnavailable(let underlying) = fetchError {
                    recordClaudeKeychainFailure(underlying)
                }
                if case .liveCredentialAccessDenied(let underlying, let item) = fetchError {
                    recordClaudeKeychainFailure(
                        underlying,
                        item: item,
                        resolveItemIfNeeded: false
                    )
                }
                if case .noCredentials = fetchError {
                    AppLog.usage.debug("No captured token yet for account \(profile.id, privacy: .public); skipping its usage fetch")
                } else {
                    AppLog.usage.error("Usage fetch failed for account \(profile.id, privacy: .public): \(fetchError.localizedDescription, privacy: .public)")
                }
                recordClaudeCredentialOutcome(
                    Self.credentialOutcome(for: fetchError),
                    for: profile,
                    codePath: "background"
                )
                let outcome = RefreshOutcomePolicy.outcome(for: fetchError, isActiveCLI: profile.isActiveCLI)
                if outcome.attemptTUIFallback {
                    clearUsagePaused(for: profile.id)
                    await refreshActiveClaudeCodeUsage(
                        onFailure: outcome.state,
                        for: profile,
                        resolvedUsageCredentials: resolvedUsageCredentials,
                        usageCredentialWasResolved: resolvedUsageCredentials != nil
                    )
                } else {
                    applyClaudeRefreshState(outcome.state, for: profile)
                }
            }
        }
    }

    /// Sets a Claude profile's refresh state and maintains the "usage paused too
    /// long" nudge for the active account. A login stuck in `.usagePaused`
    /// (access token expired while the CLI was idle) is healthy but silent, so
    /// after a threshold it earns one actionable notification.
    private func applyClaudeRefreshState(_ state: AccountRefreshState, for profile: AccountProfile) {
        refreshStates[profile.id] = state
        guard profile.isActiveCLI, state == .usagePaused else {
            clearUsagePaused(for: profile.id)
            return
        }
        let now = Date()
        let pausedSince = claudeUsagePausedSince[profile.id] ?? now
        claudeUsagePausedSince[profile.id] = pausedSince
        if usagePausedAlertPolicy.shouldNotify(
            pausedSince: pausedSince,
            now: now,
            alreadyNotified: notifiedUsagePaused.contains(profile.id)
        ) {
            notifiedUsagePaused.insert(profile.id)
            usageAlertController.handleUsagePausedStuck(profile: profile)
        }
    }

    private func clearUsagePaused(for profileID: UUID) {
        claudeUsagePausedSince[profileID] = nil
        notifiedUsagePaused.remove(profileID)
    }

    /// The rotation-hostile configuration behind most "logged out" reports: two
    /// profiles mapping to one Anthropic account (e.g. the same account under
    /// two organizations). Logged once per launch so the next incident's
    /// diagnostics show it.
    private func warnIfSharedClaudeAccounts(_ claudeProfiles: [AccountProfile]) {
        var byAccount: [String: [UUID]] = [:]
        for profile in claudeProfiles {
            guard let accountID = profile.identity?.accountID else { continue }
            byAccount[accountID, default: []].append(profile.id)
        }
        for (_, ids) in byAccount where ids.count > 1 {
            // Log once per launch per shared-account group: skip if every
            // profile in the group has already been warned about.
            guard !ids.allSatisfy({ warnedSharedAccountProfiles.contains($0) }) else {
                continue
            }
            for id in ids {
                warnedSharedAccountProfiles.insert(id)
            }
            AppLog.credentials.notice("Two or more profiles share one Claude account (\(ids.count, privacy: .public) profiles); their logins share a single rotating refresh-token chain.")
        }
    }

    /// Maps a fetch failure to a durable credential outcome, or nil for
    /// transient noise (network, absent token) that should not disturb a
    /// profile's recorded episode.
    private static func credentialOutcome(for error: ClaudeAccountUsageFetchError) -> AppEvent.CredentialOutcome? {
        switch error {
        case .interactiveRefreshRequired, .accountActiveElsewhere:
            return .rotationWithheld
        case .unauthorized:
            return .unauthorized
        case .refreshFailed(let underlying):
            if let oauth = underlying as? ClaudeOAuthError, oauth.requiresLogin {
                return .invalidGrant
            }
            return .refreshFailed
        // A locked/denied keychain or unusable provider credential is an access
        // problem, not a credential outcome — it's surfaced via the keychain row
        // state and its own logging, so it isn't recorded as a refresh event.
        case .keychainLocked, .liveCredentialAccessDenied, .credentialUnavailable,
             .noCredentials, .transport:
            return nil
        }
    }

    /// Appends a credential-refresh event only when a profile's outcome changes,
    /// so the durable log is a compact transition trail (episode start and
    /// recovery) rather than one line per five-minute cycle.
    private func recordClaudeCredentialOutcome(
        _ outcome: AppEvent.CredentialOutcome?,
        for profile: AccountProfile,
        codePath: String
    ) {
        guard let outcome, lastClaudeCredentialOutcome[profile.id] != outcome else {
            return
        }
        lastClaudeCredentialOutcome[profile.id] = outcome
        do {
            try eventStore.append(
                AppEvent(
                    timestamp: Date(),
                    kind: .credentialRefresh,
                    provider: .claude,
                    toProfileID: profile.id,
                    interactive: CredentialAccess.currentMode == .userInitiated,
                    outcome: outcome,
                    codePath: codePath
                )
            )
        } catch {
            AppLog.history.error("Could not record credential event for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Plan tier and identity rarely change; fetch them at most once per
    /// launch. This also lets new mapping logic repair labels written by
    /// older builds (for example Team Premium previously showing as Max 5x).
    private func enrichAccountInfoIfMissing(
        for profile: AccountProfile,
        accountIsLiveElsewhere: Bool,
        liveCredentialReadPolicy suppliedPolicy: ClaudeLiveCredentialReadPolicy? = nil,
        resolvedCredentials: ClaudeOAuthCredentials? = nil
    ) async {
        guard !accountInfoFetched.contains(profile.id) else {
            return
        }
        let livePolicy = suppliedPolicy ?? .read
        var liveDenial: CredentialAccessDisposition?
        let info: ClaudeAPIAccountInfo
        do {
            if let resolvedCredentials {
                info = try await claudeUsageService.fetchAccountInfo(
                    for: profile,
                    resolvedCredentials: resolvedCredentials
                )
            } else {
                info = try await claudeUsageService.fetchAccountInfo(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    accountIsLiveElsewhere: accountIsLiveElsewhere,
                    liveCredentialReadPolicy: livePolicy,
                    liveCredentialAccessDenied: { liveDenial = $0 }
                )
            }
            if let liveDenial {
                recordAutomaticClaudeLiveDenial(liveDenial)
            }
        } catch {
            if let liveDenial {
                recordAutomaticClaudeLiveDenial(liveDenial)
            }
            if profile.isActiveCLI,
               let fetchError = error as? ClaudeAccountUsageFetchError,
               case .credentialUnavailable(let underlying) = fetchError {
                recordClaudeKeychainFailure(underlying)
            }
            if let fetchError = error as? ClaudeAccountUsageFetchError,
               case .liveCredentialAccessDenied(let underlying, let item) = fetchError {
                recordClaudeKeychainFailure(
                    underlying,
                    item: item,
                    resolveItemIfNeeded: false
                )
            }
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
    private struct LiveOwnershipPlan {
        var action: CLIAccountSyncAction
        /// Secret-bearing decoded records live only for this reconciliation
        /// workflow. AppState retains summaries, never this map.
        var storedRecords: [UUID: StoredCredentialRecord]
    }

    /// Secret-bearing records live only for one switch or login-completion task. The class is
    /// passed down the stack but is never assigned to AppState, so finishing
    /// or cancelling the task releases every decoded credential.
    private final class SwitchStoredCredentialWorkflow {
        let provider: Provider
        private(set) var loadedProfileIDs: Set<UUID> = []
        private(set) var records: [UUID: StoredCredentialRecord] = [:]

        init(provider: Provider) {
            self.provider = provider
        }

        func record(for profileID: UUID) -> StoredCredentialRecord? {
            records[profileID]
        }

        func markLoaded(_ record: StoredCredentialRecord?, for profileID: UUID) {
            loadedProfileIDs.insert(profileID)
            records[profileID] = record
        }
    }

    private func storedCredentialRecord(
        for profile: AccountProfile,
        workflow: SwitchStoredCredentialWorkflow?
    ) throws -> StoredCredentialRecord? {
        guard let workflow else {
            return try cliSwitcher.storedCredentialRecord(for: profile)
        }
        precondition(workflow.provider == profile.provider)
        if workflow.loadedProfileIDs.contains(profile.id) {
            return workflow.record(for: profile.id)
        }
        let record = try cliSwitcher.storedCredentialRecord(for: profile)
        workflow.markLoaded(record, for: profile.id)
        return record
    }

    private func loadSwitchStoredCredentialWorkflow(
        for provider: Provider
    ) throws -> SwitchStoredCredentialWorkflow {
        let workflow = SwitchStoredCredentialWorkflow(provider: provider)
        for profile in profiles where profile.provider == provider {
            do {
                let record = try storedCredentialRecord(for: profile, workflow: workflow)
                cacheStoredCredentialSummary(record, for: profile)
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                throw error
            }
        }
        return workflow
    }

    private func planLiveOwnership(
        provider: Provider,
        observation: LiveCredentialObservation,
        preferredLoginProfileID: UUID? = nil,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow? = nil
    ) throws -> LiveOwnershipPlan {
        var storedFingerprints: [UUID: String] = [:]
        var profilesWithStoredCredentials: Set<UUID> = []
        var storedRecords: [UUID: StoredCredentialRecord] = [:]
        for profile in profiles where profile.provider == provider {
            do {
                if let record = try storedCredentialRecord(
                    for: profile,
                    workflow: storedCredentialWorkflow
                ) {
                    storedRecords[profile.id] = record
                    storedFingerprints[profile.id] = record.summary.fingerprint
                    if record.summary.isRestorable {
                        profilesWithStoredCredentials.insert(profile.id)
                        storedSnapshotStatuses[profile.id] = .present
                    } else {
                        storedSnapshotStatuses[profile.id] = .absent
                    }
                    if provider == .claude {
                        claudeLoginExpirations[profile.id] = record.summary.claudeRefreshTokenExpiresAt
                    }
                } else {
                    storedSnapshotStatuses[profile.id] = .absent
                    if provider == .claude {
                        claudeLoginExpirations[profile.id] = nil
                    }
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
        return LiveOwnershipPlan(action: action, storedRecords: storedRecords)
    }

    /// Syncs the active-CLI flags and identities from the current terminal
    /// login, then captures its credentials into the matching profile so
    /// switching never depends on a manual snapshot step.
    @discardableResult
    private func reconcileLiveCredentials(
        provider: Provider,
        origin: AuthChangeOrigin,
        observation suppliedObservation: LiveCredentialObservation? = nil,
        preferredLoginProfileID: UUID? = nil,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow? = nil
    ) throws -> AccountProfile? {
        let observation = try suppliedObservation ?? cliSwitcher.liveObservation(provider: provider)
        let previousActiveID = activeProfile(for: provider)?.id
        let ownershipPlan = try planLiveOwnership(
            provider: provider,
            observation: observation,
            preferredLoginProfileID: preferredLoginProfileID,
            storedCredentialWorkflow: storedCredentialWorkflow
        )
        var changed = false
        var activeID: UUID?

        switch ownershipPlan.action {
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
                let snapshot = try cliSwitcher.storeObservation(
                    observation,
                    for: active,
                    storedRecord: ownershipPlan.storedRecords[active.id]
                )
                storedCredentialWorkflow?.markLoaded(
                    cliSwitcher.makeStoredCredentialRecord(from: snapshot),
                    for: active.id
                )
                cacheStoredSnapshotSummary(snapshot, for: active)
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[active.id] = .locked
                throw error
            }
        }
        acceptedStabilityKeys[provider] = observation.stabilityKey
        if provider == .claude {
            recordSuccessfulClaudeKeychainRead(observation)
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
        guard credentialMutationsInProgress[provider] == nil else {
            deferredReconciliationOrigins[provider] = origin
            return
        }
        if let existing = reconciliationFlights[provider] {
            await existing.task.value
            return
        }

        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await CredentialAccess.nonInteractive {
                await self.performStableExternalReconciliation(provider: provider, origin: origin)
            }
        }
        reconciliationFlights[provider] = (flightID, origin, task)
        await task.value
        if reconciliationFlights[provider]?.id == flightID {
            reconciliationFlights[provider] = nil
        }
    }

    /// Acquires the provider's mutation gate and cancels any reconciliation
    /// that is between its first and confirmation reads. The cancelled origin
    /// is replayed once the mutation completes, so outside changes are delayed
    /// rather than lost.
    private func beginCredentialMutation(for provider: Provider) -> UUID? {
        guard credentialMutationsInProgress[provider] == nil else {
            return nil
        }
        if let flight = reconciliationFlights.removeValue(forKey: provider) {
            flight.task.cancel()
            deferredReconciliationOrigins[provider] = flight.origin
        }
        let owner = UUID()
        credentialMutationsInProgress[provider] = owner
        return owner
    }

    private func finishCredentialMutation(for provider: Provider, owner: UUID) {
        guard credentialMutationsInProgress[provider] == owner else {
            return
        }
        credentialMutationsInProgress[provider] = nil
        let deferredOrigin = deferredReconciliationOrigins.removeValue(forKey: provider)
        let shouldReconsiderAutomaticSwitch = deferredAutomaticSwitchProviders.remove(provider) != nil
        let shouldResumeFullRefresh = deferredFullRefresh && credentialMutationsInProgress.isEmpty
        let shouldResumeClaudeLogin = provider == .claude
            && deferredClaudeLoginResume
            && pendingClaudeLoginCompletion != nil
        if shouldResumeClaudeLogin {
            deferredClaudeLoginResume = false
        }
        if shouldResumeFullRefresh {
            deferredFullRefresh = false
        }
        if shouldReconsiderAutomaticSwitch {
            // A busy gate is a deferral, not a failed attempt eligible for the
            // one-hour backoff.
            lastAutoSwitchAttempt[provider] = nil
        }
        guard deferredOrigin != nil
                || shouldReconsiderAutomaticSwitch
                || shouldResumeFullRefresh
                || shouldResumeClaudeLogin else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await CredentialAccess.independentWorkflow {
                if shouldResumeClaudeLogin {
                    await self.resumePendingClaudeLoginCompletionIfPossible()
                }
                if let deferredOrigin {
                    await self.reconcileStableExternalChange(
                        provider: provider,
                        origin: deferredOrigin
                    )
                }
                if shouldReconsiderAutomaticSwitch {
                    self.updateSwitchAdvice()
                }
                if shouldResumeFullRefresh {
                    await Task.yield()
                    await self.refreshAll()
                }
            }
        }
    }

    private func finishCurrentCredentialMutation(for provider: Provider) {
        guard let owner = credentialMutationsInProgress[provider] else {
            return
        }
        finishCredentialMutation(for: provider, owner: owner)
    }

    private func performStableExternalReconciliation(provider: Provider, origin: AuthChangeOrigin) async {
        let counter = CredentialKeychainIOCounter()
        var attemptedClaudeLocation: ClaudeKeychainItemLocation?
        do {
            let outcome = try await CredentialAccess.counting(counter) { () async throws -> String in
                let first: LiveCredentialObservation
                if provider == .claude {
                    switch automaticClaudeLiveAccess() {
                    case .read(let pinnedItem):
                        let location = try pinnedItem ?? cliSwitcher
                            .locateClaudeKeychainItem(accessMode: .nonInteractive)
                        attemptedClaudeLocation = location
                        if let location {
                            first = try cliSwitcher.liveClaudeObservation(
                                at: location,
                                accessMode: .nonInteractive
                            )
                        } else {
                            first = try cliSwitcher.liveObservation(provider: .claude)
                        }
                        // Any exact successful noninteractive data read is
                        // sufficient to clear an older item-scoped denial.
                        recordSuccessfulClaudeKeychainRead(first)
                    case .knownDenied:
                        if let active = activeProfile(for: .claude) {
                            refreshStates[active.id] = .keychainLocked
                        }
                        return "authorization_suppressed"
                    case .unavailable:
                        return "credential_unavailable"
                    }
                } else {
                    first = try cliSwitcher.liveObservation(provider: provider)
                }
                if acceptedStabilityKeys[provider] == first.stabilityKey {
                    return "unchanged"
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return "cancelled" }
                let second: LiveCredentialObservation
                if provider == .claude,
                   let firstLocation = first.claudeKeychainItemLocation {
                    guard let secondLocation = try cliSwitcher.locateClaudeKeychainItem(
                        accessMode: .nonInteractive
                    ), secondLocation.modificationStamp == firstLocation.modificationStamp else {
                        return "unstable"
                    }
                    attemptedClaudeLocation = secondLocation
                    second = try cliSwitcher.liveClaudeObservation(
                        at: secondLocation,
                        accessMode: .nonInteractive
                    )
                    recordSuccessfulClaudeKeychainRead(second)
                } else {
                    second = try cliSwitcher.liveObservation(provider: provider)
                }
                guard first.stabilityKey == second.stabilityKey else { return "unstable" }
                _ = try reconcileLiveCredentials(provider: provider, origin: origin, observation: second)
                return "reconciled"
            }
            logCredentialWorkflow(
                workflow: "reconcile",
                provider: provider,
                origin: origin.rawValue,
                access: "noninteractive",
                status: outcome,
                counts: counter.snapshot
            )
        } catch {
            logCredentialWorkflow(
                workflow: "reconcile",
                provider: provider,
                origin: origin.rawValue,
                access: "noninteractive",
                status: isCredentialAccessDenied(error) ? "access_denied" : "failed",
                counts: counter.snapshot
            )
            if provider == .claude,
               error is ClaudeCodeCredentialsKeychainError {
                recordClaudeKeychainFailure(
                    error,
                    item: attemptedClaudeLocation,
                    resolveItemIfNeeded: false
                )
            }
            if isCredentialAccessDenied(error) {
                if let active = activeProfile(for: provider) {
                    refreshStates[active.id] = .keychainLocked
                }
                return
            }
            AppLog.credentials.error("Could not reconcile \(provider.displayName, privacy: .public) credentials (origin: \(String(describing: origin), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not reconcile \(provider.displayName) credentials: \(error.localizedDescription)"
        }
    }

    private func logCredentialWorkflow(
        workflow: String,
        provider: Provider,
        origin: String,
        access: String,
        status: String,
        counts: CredentialKeychainIOCounts
    ) {
        AppLog.credentials.debug(
            "workflow=\(workflow, privacy: .public) provider=\(provider.rawValue, privacy: .public) origin=\(origin, privacy: .public) access=\(access, privacy: .public) status=\(status, privacy: .public) keychain_metadata_reads=\(counts.metadataReads, privacy: .public) keychain_reads=\(counts.dataReads, privacy: .public) keychain_writes=\(counts.writes, privacy: .public)"
        )
    }

    private func usageWorkflowStatus(provider: Provider) -> String {
        let providerProfiles = profiles.filter { $0.provider == provider }
        guard !providerProfiles.isEmpty else { return "no_accounts" }
        let failures = providerProfiles.reduce(into: 0) { count, profile in
            if refreshStates[profile.id]?.isProblem == true {
                count += 1
            }
        }
        if failures == 0 { return "completed" }
        if failures == providerProfiles.count { return "failed" }
        return "partial"
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

    private enum AutomaticClaudeLiveAccess {
        /// A non-nil item is the exact replacement/modification generation
        /// which may receive one retry while the older denial remains sticky.
        case read(pinnedItem: ClaudeKeychainItemLocation?)
        case knownDenied
        case unavailable
    }

    private struct AutomaticClaudeUsageLiveContext {
        var readPolicy: ClaudeLiveCredentialReadPolicy
    }

    /// Converts a remembered denial into metadata-only polling. The shared
    /// secret is tried again automatically only after Claude changes the exact
    /// item generation; explicit Authorize continues to bypass this gate.
    private func automaticClaudeLiveAccess() -> AutomaticClaudeLiveAccess {
        switch claudeKeychainAuthorizationState {
        case .needsAuthorization(let deniedItem, let disposition):
            do {
                let currentItem = try cliSwitcher.locateClaudeKeychainItem(
                    accessMode: .nonInteractive
                )
                if deniedItem == nil, let currentItem {
                    claudeKeychainAuthorizationState = .needsAuthorization(
                        item: currentItem,
                        disposition: disposition
                    )
                }
                if claudeKeychainAuthorizationState.suppressesAutomaticDataRead(
                    currentItem: currentItem
                ) {
                    return .knownDenied
                }
                // Replacement or modification creates a candidate new
                // authorization context. Keep the old denial sticky until an
                // exact read of this pinned generation actually succeeds.
                return .read(pinnedItem: currentItem)
            } catch {
                recordClaudeKeychainFailure(error, resolveItemIfNeeded: false)
                if case .needsAuthorization = claudeKeychainAuthorizationState {
                    return .knownDenied
                }
                return .unavailable
            }
        case .authorizing, .failed:
            return .unavailable
        case .unknown, .ready, .notFound:
            return .read(pinnedItem: nil)
        }
    }

    private func recordAutomaticClaudeLiveDenial(
        _ disposition: CredentialAccessDisposition
    ) {
        let item = try? cliSwitcher.locateClaudeKeychainItem(
            accessMode: .nonInteractive
        )
        recordClaudeKeychainDisposition(
            disposition,
            item: item
        )
    }

    /// Resolves metadata first and decrypts only that exact item. Returning
    /// successfully records readiness for the same generation; callers retain
    /// the attempted location when reporting a denial, so a concurrent
    /// replacement can never inherit the old item's failure state.
    private func readAutomaticClaudeOAuthCredentials(
        pinnedItem: ClaudeKeychainItemLocation?,
        attemptedItem: inout ClaudeKeychainItemLocation?
    ) throws -> ClaudeOAuthCredentials? {
        let location = try pinnedItem ?? cliSwitcher.locateClaudeKeychainItem(
            accessMode: .nonInteractive
        )
        attemptedItem = location
        guard let location else {
            claudeKeychainAuthorizationState = .notFound
            return nil
        }
        let record = try cliSwitcher.liveClaudeOAuthCredentialRecord(
            at: location,
            accessMode: .nonInteractive
        )
        claudeKeychainAuthorizationState = .ready(location)
        return record?.credentials
    }

    /// Performs the scheduled usage workflow's single exact shared-item read
    /// up front. The resulting record is reused by the usage API, optional
    /// account-info lookup, and `/usage` fallback; known denial keeps those
    /// paths on the independently stored credential without another live read.
    private func automaticClaudeUsageLiveContext() -> AutomaticClaudeUsageLiveContext? {
        switch automaticClaudeLiveAccess() {
        case .knownDenied:
            return AutomaticClaudeUsageLiveContext(
                readPolicy: .knownDenied
            )
        case .unavailable:
            return nil
        case .read(let pinnedItem):
            var attemptedItem = pinnedItem
            do {
                let credentials = try readAutomaticClaudeOAuthCredentials(
                    pinnedItem: pinnedItem,
                    attemptedItem: &attemptedItem
                )
                let record = credentials.map {
                    LiveClaudeOAuthCredentialRecord(
                        credentials: $0,
                        itemLocation: attemptedItem
                    )
                }
                return AutomaticClaudeUsageLiveContext(
                    readPolicy: .preloaded(record)
                )
            } catch {
                recordClaudeKeychainFailure(
                    error,
                    item: attemptedItem,
                    resolveItemIfNeeded: false
                )
                if isCredentialAccessDenied(error) {
                    return AutomaticClaudeUsageLiveContext(
                        readPolicy: .knownDenied
                    )
                }
                return nil
            }
        }
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
    private func refreshActiveClaudeCodeUsage(
        onFailure failureState: AccountRefreshState,
        for profile: AccountProfile,
        resolvedUsageCredentials: ClaudeOAuthCredentials? = nil,
        usageCredentialWasResolved: Bool = false
    ) async {
        // Hand the CLI the live token so it never reads its own keychain item
        // (a SecurityAgent prompt on systems where claude's signature isn't
        // durably authorized). Resolve the app-owned snapshot independently:
        // a denied provider item must not prevent a valid captured token from
        // serving this prompt-free fallback.
        let credentials: ClaudeOAuthCredentials?
        if usageCredentialWasResolved {
            // The API service already selected live vs stored and enforced all
            // active-account rotation rules. Reuse that exact generation.
            credentials = resolvedUsageCredentials
        } else {
            var liveCredentials: ClaudeOAuthCredentials?
            switch automaticClaudeLiveAccess() {
            case .knownDenied:
                break
            case .unavailable:
                refreshStates[profile.id] = failureState
                statusMessage = "Claude Code /usage was not launched because the shared credential is unavailable."
                return
            case .read(let pinnedItem):
                var attemptedItem = pinnedItem
                do {
                    liveCredentials = try readAutomaticClaudeOAuthCredentials(
                        pinnedItem: pinnedItem,
                        attemptedItem: &attemptedItem
                    )
                } catch {
                    recordClaudeKeychainFailure(
                        error,
                        item: attemptedItem,
                        resolveItemIfNeeded: false
                    )
                    if !isCredentialAccessDenied(error) {
                        // Duplicate, malformed, or ambiguous live state is not
                        // equivalent to denial and must never be hidden by a
                        // stored-token fallback.
                        refreshStates[profile.id] = failureState
                        statusMessage = "Claude Code /usage was not launched: \(error.localizedDescription)"
                        return
                    }
                }
            }
            let storedCredentials = try? cliSwitcher.storedCredentialRecord(
                for: profile,
                accessMode: .nonInteractive
            )?.claudeOAuthCredentials
            credentials = ClaudeUsageProbeCredentialSelector.select(
                live: liveCredentials,
                stored: storedCredentials
            )
        }
        guard let oauthToken = credentials?.accessToken, !oauthToken.isEmpty else {
            // Never launch Claude without a token: doing so lets the child
            // process escape this app's noninteractive Keychain policy.
            refreshStates[profile.id] = failureState
            return
        }

        refreshStage = "Reading Claude Code /usage — can take ~20 seconds…"
        defer { refreshStage = nil }

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
        let counter = CredentialKeychainIOCounter()
        await CredentialAccess.counting(counter) {
            await refreshCodexUsageImpl()
            logCredentialWorkflow(
                workflow: "usage",
                provider: .codex,
                origin: "scheduled_refresh",
                access: "noninteractive",
                status: usageWorkflowStatus(provider: .codex),
                counts: counter.snapshot
            )
        }
    }

    private func refreshCodexUsageImpl() async {
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
                guard let record = try cliSwitcher.storedCredentialRecord(for: profile),
                      record.summary.isRestorable,
                      let authJSON = record.codexAuthJSON else {
                    if !refreshCodexLocalFallback(for: profile) {
                        refreshStates[profile.id] = .needsLogin(
                            reason: "No saved Codex credentials are available for live usage checks."
                        )
                    }
                    return
                }
                let fingerprint = record.summary.fingerprint

                let initialResult = try await codexUsageService.fetchSnapshot(
                    for: profile,
                    authJSON: authJSON,
                    executableURL: executableURL,
                    expectedIdentity: profile.identity
                )
                let automaticReset = await automaticallyRedeemCodexResetIfNeeded(
                    for: profile,
                    usageResult: initialResult,
                    executableURL: executableURL
                )
                let result = automaticReset.usageResult

                if result.updatedAuthJSON != authJSON {
                    guard let updatedRecord = try cliSwitcher.replaceStoredCodexAuthJSON(
                        result.updatedAuthJSON,
                        for: profile.id,
                        using: record,
                        ifSnapshotFingerprintMatches: fingerprint
                    ) else {
                        // A concurrent capture won. Re-read that newer snapshot
                        // once instead of persisting credentials derived from an
                        // older refresh token.
                        continue
                    }
                    cacheStoredCredentialSummary(updatedRecord, for: profile)

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
                if let resetState = automaticReset.stateAfterApply {
                    codexResetStates[profile.id] = resetState
                }
                return
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                refreshStates[profile.id] = .keychainLocked
                return
            } catch let error as CodexAccountUsageError {
                switch error {
                case .requiresLogin(let reason):
                    refreshStates[profile.id] = .needsLogin(reason: reason)
                case .unsupported(let reason), .unavailable(let reason):
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

    private struct AutomaticCodexResetResolution {
        var usageResult: CodexAccountUsageResult
        var stateAfterApply: CodexResetRedemptionState?
    }

    /// Runs inside the existing Codex mutation gate and before the fetched
    /// depleted snapshot is applied, so a successful reset prevents both a
    /// transient depleted alert and the later auto-switch decision.
    private func automaticallyRedeemCodexResetIfNeeded(
        for profile: AccountProfile,
        usageResult: CodexAccountUsageResult,
        executableURL: URL,
        now: Date = Date()
    ) async -> AutomaticCodexResetResolution {
        let currentProfile = profiles.first(where: { $0.id == profile.id }) ?? profile
        let currentState = codexResetStates[profile.id] ?? .idle
        guard codexResetAutomationPolicy.recoverySteps(
            profile: currentProfile,
            snapshot: usageResult.snapshot,
            redemptionState: currentState,
            lastAttempt: lastAutomaticCodexResetAttempt[profile.id],
            now: now
        ).first == .redeemReset else {
            return AutomaticCodexResetResolution(usageResult: usageResult, stateAfterApply: nil)
        }

        lastAutomaticCodexResetAttempt[profile.id] = now
        codexResetStates[profile.id] = .redeeming
        let idempotencyKey = codexResetAttemptStore.idempotencyKey(for: profile.id)
        do {
            let redemption = try await codexUsageService.redeemReset(
                for: currentProfile,
                authJSON: usageResult.updatedAuthJSON,
                executableURL: executableURL,
                expectedIdentity: currentProfile.identity,
                idempotencyKey: idempotencyKey,
                now: now
            )
            codexResetAttemptStore.completeAttempt(for: profile.id)

            if redemption.outcome.consumedReset {
                usageAlertController.handleAutomaticCodexReset(
                    profileLabel: currentProfile.label,
                    remainingCount: redemption.refreshedUsage?.snapshot
                        .codexRateLimitResetAvailability?.availableCount
                )
            }

            if let refreshed = redemption.refreshedUsage {
                let message: String
                switch redemption.outcome {
                case .reset, .alreadyRedeemed:
                    message = "Used an earned reset for \(currentProfile.label)."
                case .nothingToReset:
                    message = "\(currentProfile.label) has no eligible Codex limit to reset yet."
                case .noCredit:
                    message = "\(currentProfile.label) has no earned resets available."
                }
                statusMessage = message
                return AutomaticCodexResetResolution(
                    usageResult: refreshed,
                    stateAfterApply: .idle
                )
            }

            if redemption.outcome.consumedReset {
                let reason = redemption.refreshFailureReason
                    ?? "Refresh usage before another reset can be used."
                statusMessage = "Used an earned reset for \(currentProfile.label). Refresh is required to confirm its new limits."
                return AutomaticCodexResetResolution(
                    usageResult: usageResult,
                    stateAfterApply: .refreshRequired(reason: reason)
                )
            }

            let reason = redemption.refreshFailureReason
                ?? "Codex did not return refreshed reset availability."
            statusMessage = reason
            return AutomaticCodexResetResolution(
                usageResult: usageResult,
                stateAfterApply: .failed(reason: reason)
            )
        } catch let error as CodexResetRedemptionError {
            switch error.failure {
            case .requiresLogin, .unsupported:
                codexResetAttemptStore.completeAttempt(for: profile.id)
            case .unavailable:
                break
            }
            var retainedUsage = usageResult
            if let updatedAuthJSON = error.updatedAuthJSON {
                retainedUsage.updatedAuthJSON = updatedAuthJSON
            }
            let reason = error.localizedDescription
            statusMessage = "Could not automatically use a Codex reset for \(currentProfile.label): \(reason)"
            return AutomaticCodexResetResolution(
                usageResult: retainedUsage,
                stateAfterApply: .failed(reason: reason)
            )
        } catch let error as CodexAccountUsageError {
            switch error {
            case .requiresLogin, .unsupported:
                // These failures happen before a reset can be accepted.
                codexResetAttemptStore.completeAttempt(for: profile.id)
            case .unavailable:
                // Ambiguous transport failures retain the key for a safe retry.
                break
            }
            let reason = error.localizedDescription
            statusMessage = "Could not automatically use a Codex reset for \(currentProfile.label): \(reason)"
            return AutomaticCodexResetResolution(
                usageResult: usageResult,
                stateAfterApply: .failed(reason: reason)
            )
        } catch {
            let reason = error.localizedDescription
            statusMessage = "Could not automatically use a Codex reset for \(currentProfile.label): \(reason)"
            return AutomaticCodexResetResolution(
                usageResult: usageResult,
                stateAfterApply: .failed(reason: reason)
            )
        }
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
        } else if let data = try? cliSwitcher.storedCredentialRecord(for: profile)?.codexAuthJSON {
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
        if profile.provider == .codex,
           snapshot.source == "Codex app server",
           codexResetStates[profile.id]?.isBusy != true {
            codexResetStates[profile.id] = .idle
        }
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
            usageAlertController.handleThresholds(
                snapshot: snapshot,
                profile: profile,
                includeSessionWindows: settings.sessionWindowAlertsEnabled,
                advisedTargetID: switchAdvice[profile.provider]?.bestCandidateID
            )
            notifyPaceAlerts(snapshot: snapshot, profile: profile)
        } else {
            usageAlertController.rearmThresholds(snapshot: snapshot, profile: profile)
        }
        saveSnapshots()
        statusMessage = "\(profile.label): \(snapshot.message)"
    }

    /// "On pace to run out before the reset" — weekly windows (plus sessions
    /// when opted in), active account only, once per reset period (mirrors
    /// the reset-alert dedupe).
    private func notifyPaceAlerts(snapshot: UsageSnapshot, profile: AccountProfile) {
        let alerts = PaceAlertPlanner(includeSessionWindows: settings.sessionWindowAlertsEnabled).alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: burnRateEstimates[profile.id] ?? [:],
            alreadyNotified: usageAlertController.notifiedPaceKeys()
        )
        for alert in alerts {
            usageAlertController.handlePaceAlert(
                alert,
                provider: profile.provider,
                advisedTargetID: switchAdvice[profile.provider]?.bestCandidateID
            )
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

    /// The Settings-window "export everything" flow: every account's retained
    /// history in one CSV.
    func exportAllUsageHistoryCSV() {
        guard let historyStore else {
            statusMessage = "Usage history is unavailable — see Copy Diagnostics for the reason."
            return
        }
        var recordsByAccount: [UUID: [UsageHistoryRecord]] = [:]
        var descriptors: [UUID: UsageHistoryCSVExporter.AccountDescriptor] = [:]
        for profile in profiles {
            let records = historyStore.records(for: profile.id)
            guard !records.isEmpty else {
                continue
            }
            recordsByAccount[profile.id] = records
            descriptors[profile.id] = .init(label: profile.label, provider: profile.provider)
        }
        let csv = UsageHistoryCSVExporter().csv(records: recordsByAccount, accounts: descriptors)
        UsageHistoryCSVSaver.save(
            csv: csv,
            suggestedName: UsageHistoryCSVSaver.fileName(scope: "all-accounts")
        )
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

    func setAutoUseCodexRateLimitResets(for profileID: UUID, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].provider == .codex,
              profiles[index].autoUseCodexRateLimitResets != enabled else {
            return
        }
        profiles[index].autoUseCodexRateLimitResets = enabled
        profiles[index].updatedAt = Date()
        persistProfiles()
        statusMessage = enabled
            ? "Automatic earned resets enabled for \(profiles[index].label)."
            : "Automatic earned resets disabled for \(profiles[index].label)."
    }

    func confirmAndUseCodexRateLimitReset(for profile: AccountProfile) {
        guard let current = profiles.first(where: { $0.id == profile.id }),
              current.provider == .codex,
              let snapshot = snapshots[current.id],
              let availability = snapshot.codexRateLimitResetAvailability,
              availability.availableCount > 0 else {
            statusMessage = "No earned Codex reset is currently available for \(profile.label)."
            return
        }
        guard !snapshot.isStale() else {
            statusMessage = "Refresh \(current.label) before using an earned Codex reset."
            return
        }
        guard codexResetStates[current.id]?.blocksRedemption != true else {
            statusMessage = "Wait for \(current.label)'s reset status to refresh before using another reset."
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Use one earned reset for \(current.label)?"
        var details = [
            "This asks OpenAI to reset the eligible Codex rate-limit windows and cannot be undone."
        ]
        if let window = snapshots[current.id]?.mostConstrainedWindow {
            details.append("Current \(window.label.lowercased()) usage is \(Int(window.usedPercent.rounded()))%.")
        }
        if let expiry = availability.credits?
            .filter({ $0.status == "available" })
            .compactMap(\.expiresAt)
            .min() {
            details.append("The earliest listed reset expires \(expiry.formatted(date: .abbreviated, time: .shortened)).")
        }
        details.append("OpenAI will select which available reset to use.")
        alert.informativeText = details.joined(separator: " ")
        alert.addButton(withTitle: "Use Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModalActivating() == .alertFirstButtonReturn else { return }

        codexResetStates[current.id] = .redeeming
        Task { [weak self] in
            await self?.redeemCodexRateLimitResetManually(for: current)
        }
    }

    private func redeemCodexRateLimitResetManually(for profile: AccountProfile) async {
        guard let mutationOwner = beginCredentialMutation(for: .codex) else {
            let reason = "Another Codex credential operation is already in progress."
            codexResetStates[profile.id] = .failed(reason: reason)
            statusMessage = reason
            return
        }
        defer { finishCredentialMutation(for: .codex, owner: mutationOwner) }

        guard let executablePath = cliSwitcher.resolveExecutablePath(command: Provider.codex.commandName) else {
            let reason = "The Codex executable could not be found."
            codexResetStates[profile.id] = .failed(reason: reason)
            statusMessage = reason
            return
        }

        do {
            guard let record = try cliSwitcher.storedCredentialRecord(for: profile),
                  record.summary.isRestorable,
                  let authJSON = record.codexAuthJSON else {
                throw CodexAccountUsageError.requiresLogin(
                    reason: "No saved Codex credentials are available for reset redemption."
                )
            }
            let fingerprint = record.summary.fingerprint
            let idempotencyKey = codexResetAttemptStore.idempotencyKey(for: profile.id)
            let redemption: CodexResetRedemptionResult
            do {
                redemption = try await codexUsageService.redeemReset(
                    for: profile,
                    authJSON: authJSON,
                    executableURL: URL(fileURLWithPath: executablePath),
                    expectedIdentity: profile.identity,
                    idempotencyKey: idempotencyKey
                )
            } catch let error as CodexResetRedemptionError {
                let credentialCollision = try persistRotatedCodexResetAuth(
                    error.updatedAuthJSON,
                    originalAuthJSON: authJSON,
                    storedRecord: record,
                    fingerprint: fingerprint,
                    profile: profile
                )
                switch error.failure {
                case .requiresLogin(let reason):
                    codexResetAttemptStore.completeAttempt(for: profile.id)
                    refreshStates[profile.id] = .needsLogin(reason: reason)
                case .unsupported:
                    codexResetAttemptStore.completeAttempt(for: profile.id)
                case .unavailable:
                    // Keep the pending key: a retry is the same logical attempt.
                    break
                }
                let collisionSuffix = credentialCollision
                    ? " A newer external Codex login was preserved."
                    : ""
                codexResetStates[profile.id] = .failed(reason: error.localizedDescription)
                statusMessage = "Could not use a Codex reset for \(profile.label): \(error.localizedDescription)\(collisionSuffix)"
                updateSwitchAdvice()
                updateMenuBarSummary()
                return
            }
            codexResetAttemptStore.completeAttempt(for: profile.id)

            let credentialCollision = try persistRotatedCodexResetAuth(
                redemption.updatedAuthJSON,
                originalAuthJSON: authJSON,
                storedRecord: record,
                fingerprint: fingerprint,
                profile: profile
            )

            if let refreshed = redemption.refreshedUsage {
                applyCodexAccountInfo(refreshed.accountInfo, for: profile)
                applySnapshot(refreshed.snapshot, for: profile)
                codexResetStates[profile.id] = .idle
            } else if redemption.outcome.consumedReset {
                codexResetStates[profile.id] = .refreshRequired(
                    reason: redemption.refreshFailureReason
                        ?? "Refresh usage before another reset can be used."
                )
            } else {
                codexResetStates[profile.id] = .failed(
                    reason: redemption.refreshFailureReason
                        ?? "Codex did not return refreshed reset availability."
                )
            }

            let collisionSuffix = credentialCollision
                ? " A newer external Codex login was preserved."
                : ""
            switch redemption.outcome {
            case .reset:
                statusMessage = "Used one earned reset for \(profile.label).\(collisionSuffix)"
            case .alreadyRedeemed:
                statusMessage = "The pending reset for \(profile.label) had already completed.\(collisionSuffix)"
            case .nothingToReset:
                statusMessage = "No eligible Codex limit was reset for \(profile.label); no reset was spent."
            case .noCredit:
                statusMessage = "No earned reset is currently available for \(profile.label)."
            }
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            let reason = "Saved credentials are not accessible."
            codexResetStates[profile.id] = .failed(reason: reason)
            refreshStates[profile.id] = .keychainLocked
            statusMessage = reason
        } catch let error as CodexAccountUsageError {
            switch error {
            case .requiresLogin(let reason):
                codexResetAttemptStore.completeAttempt(for: profile.id)
                refreshStates[profile.id] = .needsLogin(reason: reason)
            case .unsupported:
                codexResetAttemptStore.completeAttempt(for: profile.id)
            case .unavailable:
                // Keep the pending key: a retry is the same logical attempt.
                break
            }
            codexResetStates[profile.id] = .failed(reason: error.localizedDescription)
            statusMessage = "Could not use a Codex reset for \(profile.label): \(error.localizedDescription)"
        } catch {
            codexResetStates[profile.id] = .failed(reason: error.localizedDescription)
            statusMessage = "Could not use a Codex reset for \(profile.label): \(error.localizedDescription)"
        }
        updateSwitchAdvice()
        updateMenuBarSummary()
    }

    /// Merges a token rotation only into the exact stored/live generation that
    /// started redemption. A nil return from the stored CAS means another
    /// capture or CLI login won and must remain untouched.
    private func persistRotatedCodexResetAuth(
        _ updatedAuthJSON: Data?,
        originalAuthJSON: Data,
        storedRecord: StoredCredentialRecord,
        fingerprint: String,
        profile: AccountProfile
    ) throws -> Bool {
        guard let updatedAuthJSON, updatedAuthJSON != originalAuthJSON else {
            return false
        }
        guard let updatedRecord = try cliSwitcher.replaceStoredCodexAuthJSON(
            updatedAuthJSON,
            for: profile.id,
            using: storedRecord,
            ifSnapshotFingerprintMatches: fingerprint
        ) else {
            return true
        }
        cacheStoredCredentialSummary(updatedRecord, for: profile)
        if let current = profiles.first(where: { $0.id == profile.id }),
           current.isActiveCLI,
           try cliSwitcher.replaceLiveCodexAuthJSON(
               updatedAuthJSON,
               ifCredentialFingerprintMatches: fingerprint
           ) {
            _ = try reconcileLiveCredentials(provider: .codex, origin: .manualCapture)
        }
        return false
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

        guard let mutationOwner = beginCredentialMutation(for: profile.provider) else {
            statusMessage = "Wait for the current \(profile.provider.displayName) credential operation to finish before removing this account."
            return
        }
        defer {
            finishCredentialMutation(for: profile.provider, owner: mutationOwner)
        }

        let counter = CredentialKeychainIOCounter()
        let deleted = CredentialAccess.counting(counter) { () -> Bool in
            do {
                try cliSwitcher.deleteStoredSnapshot(
                    for: profile.id,
                    accessMode: .nonInteractive
                )
                storedSnapshotStatuses[profile.id] = .absent
                return true
            } catch {
                statusMessage = "Could not delete stored credentials for \(profile.label): \(error.localizedDescription)"
                return false
            }
        }
        logCredentialWorkflow(
            workflow: "snapshot_delete",
            provider: profile.provider,
            origin: "explicit_action",
            access: "noninteractive",
            status: deleted ? "completed" : "failed",
            counts: counter.snapshot
        )
        guard deleted else { return }
        if profile.webDataStoreKind == .isolated {
            WKWebsiteDataStore.remove(forIdentifier: profile.webDataStoreID) { _ in }
        }
        profiles.remove(at: index)
        snapshots[profile.id] = nil
        refreshStates[profile.id] = nil
        codexResetStates[profile.id] = nil
        lastAutomaticCodexResetAttempt[profile.id] = nil
        codexResetAttemptStore.removeAccount(profile.id)
        storedSnapshotStatuses[profile.id] = nil
        claudeLoginExpirations[profile.id] = nil
        do {
            try historyStore?.removeAccount(profile.id)
        } catch {
            AppLog.history.error("Could not delete usage history for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        do {
            try eventStore.removeAccount(profile.id)
        } catch {
            AppLog.history.error("Could not delete switch events for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        burnRateEstimates[profile.id] = nil
        claudeUsagePausedSince[profile.id] = nil
        notifiedUsagePaused.remove(profile.id)
        lastClaudeCredentialOutcome[profile.id] = nil
        warnedSharedAccountProfiles.remove(profile.id)
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
        automatic: Bool = false
    ) async -> Bool {
        if let existing = switchFlights[profile.provider] {
            if existing.profileID == profile.id {
                return await existing.task.value
            }
            if automatic {
                deferredAutomaticSwitchProviders.insert(profile.provider)
            }
            statusMessage = automatic
                ? "Automatic switch deferred while another credential operation is in progress."
                : "A \(profile.provider.displayName) credential operation is already in progress."
            return false
        }

        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let counter = CredentialKeychainIOCounter()
            return await CredentialAccess.counting(counter) {
                let result = await self.performSwitchCLI(
                    to: profile,
                    interactive: interactive,
                    automatic: automatic,
                    storedCredentialWorkflow: nil
                )
                self.logCredentialWorkflow(
                    workflow: "switch",
                    provider: profile.provider,
                    origin: automatic ? "automatic" : "manual",
                    access: interactive && profile.provider == .claude
                        ? "mixed"
                        : "noninteractive",
                    status: result ? "completed" : "aborted",
                    counts: counter.snapshot
                )
                return result
            }
        }
        switchFlights[profile.provider] = (flightID, profile.id, task)
        let result = await task.value
        if switchFlights[profile.provider]?.id == flightID {
            switchFlights[profile.provider] = nil
        }
        return result
    }

    private func performSwitchCLI(
        to profile: AccountProfile,
        interactive: Bool,
        automatic: Bool,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow?
    ) async -> Bool {
        if storedCredentialWorkflow == nil {
            guard let mutationOwner = beginCredentialMutation(for: profile.provider) else {
                if automatic {
                    deferredAutomaticSwitchProviders.insert(profile.provider)
                }
                statusMessage = interactive
                    ? "A \(profile.provider.displayName) credential operation is already in progress."
                    : (automatic
                        ? "Automatic switch deferred while another credential operation is in progress."
                        : "A \(profile.provider.displayName) credential operation is already in progress.")
                return false
            }
            defer { finishCredentialMutation(for: profile.provider, owner: mutationOwner) }

            if !interactive, profile.provider == .claude {
                switch automaticClaudeLiveAccess() {
                case .read(let pinnedItem):
                    if let pinnedItem {
                        var attemptedItem: ClaudeKeychainItemLocation? = pinnedItem
                        do {
                            _ = try readAutomaticClaudeOAuthCredentials(
                                pinnedItem: pinnedItem,
                                attemptedItem: &attemptedItem
                            )
                        } catch {
                            recordClaudeKeychainFailure(
                                error,
                                item: attemptedItem,
                                resolveItemIfNeeded: false
                            )
                            refreshStates[profile.id] = isKeychainAccessDenied(error)
                                ? .keychainLocked
                                : .readFailed(reason: error.localizedDescription)
                            statusMessage = "Automatic switch stopped before touching the denied Claude credential again."
                            return false
                        }
                    }
                case .knownDenied, .unavailable:
                    refreshStates[profile.id] = .keychainLocked
                    statusMessage = automatic
                        ? "Automatic switch deferred until Claude Keychain access is authorized."
                        : "Switch stopped until Claude Keychain access is authorized."
                    return false
                }
            }

            let workflow: SwitchStoredCredentialWorkflow
            do {
                workflow = try await CredentialAccess.nonInteractive {
                    try loadSwitchStoredCredentialWorkflow(for: profile.provider)
                }
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                refreshStates[profile.id] = .keychainLocked
                if interactive {
                    showError(
                        message: "Saved credentials are not accessible",
                        details: "Limit Lifeboat could not read the saved accounts without prompting. Relaunch the installed app, then retry."
                    )
                }
                return false
            } catch {
                statusMessage = "Could not prepare the switch: \(error.localizedDescription)"
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Could not prepare the switch",
                    details: error.localizedDescription
                )
                return false
            }

            if interactive {
                // The explicit authorization action above is the only
                // prompt-capable Keychain operation. Preflight, capture,
                // restore, validation, and rollback all fail closed instead
                // of displaying a second password dialog.
                return await CredentialAccess.nonInteractive {
                    await performSwitchCLI(
                        to: profile,
                        interactive: true,
                        automatic: automatic,
                        storedCredentialWorkflow: workflow
                    )
                }
            }
            return await CredentialAccess.nonInteractive {
                await performSwitchCLI(
                    to: profile,
                    interactive: false,
                    automatic: automatic,
                    storedCredentialWorkflow: workflow
                )
            }
        }

        guard let storedCredentialWorkflow,
              let targetStoredRecord = storedCredentialWorkflow.record(for: profile.id),
              targetStoredRecord.summary.isRestorable else {
            refreshStates[profile.id] = .needsLogin(
                reason: "No saved credentials are available for this account."
            )
            finishCurrentCredentialMutation(for: profile.provider)
            handleLoginRequired(
                for: profile,
                reason: "No saved credentials are available. Log in once and the app will capture them automatically.",
                interactive: interactive
            )
            return false
        }

        if case .needsLogin(let reason) = refreshStates[profile.id] {
            finishCurrentCredentialMutation(for: profile.provider)
            handleLoginRequired(for: profile, reason: reason, interactive: interactive)
            return false
        }

        switch await preflightSwitchTarget(
            profile,
            storedRecord: targetStoredRecord,
            storedCredentialWorkflow: storedCredentialWorkflow
        ) {
        case .ready:
            break
        case .requiresLogin(let reason):
            refreshStates[profile.id] = .needsLogin(reason: reason)
            finishCurrentCredentialMutation(for: profile.provider)
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

        // Do not authorize the current/old item until the target has passed
        // the prompt-free stored-credential and login preflights. A target
        // that needs login may replace the item and should require at most one
        // authorization for the resulting item, never one for each side.
        if interactive, profile.provider == .claude {
            guard await authorizeClaudeKeychainAccess(
                reason: "before switching to \(profile.label)",
                allowDuringCredentialMutation: true
            ) else {
                return false
            }
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
                    observation: outgoingObservation,
                    storedCredentialWorkflow: storedCredentialWorkflow
                )
            }
        } catch {
            if profile.provider == .claude,
               error is ClaudeCodeCredentialsKeychainError,
               isKeychainAccessDenied(error) {
                recordClaudeKeychainFailure(error)
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

        let outgoingProfileID = activeProfile(for: profile.provider)?.id
        do {
            let result = try cliSwitcher.restoreSnapshot(
                for: profile,
                storedRecord: storedCredentialWorkflow.record(for: profile.id)
                    ?? targetStoredRecord,
                expectedLiveFingerprint: outgoingObservation.credentialFingerprint,
                enforceExpectedLiveState: true
            )
            let verified = result.verifiedObservation
            _ = try reconcileLiveCredentials(
                provider: profile.provider,
                origin: interactive ? .manualSwitch : .automaticSwitch,
                observation: verified,
                storedCredentialWorkflow: storedCredentialWorkflow
            )

            statusMessage = "Switched \(profile.provider.displayName) CLI to \(profile.label)."
            AppLog.switching.notice("Switched \(profile.provider.displayName, privacy: .public) CLI to account \(profile.id, privacy: .public) (interactive: \(interactive, privacy: .public))")
            // The single funnel every switch passes through (manual, auto,
            // notification click) — the weekly digest counts these events.
            do {
                try eventStore.append(
                    AppEvent(
                        timestamp: Date(),
                        kind: .cliSwitch,
                        provider: profile.provider,
                        toProfileID: profile.id,
                        fromProfileID: outgoingProfileID == profile.id ? nil : outgoingProfileID,
                        interactive: interactive
                    )
                )
            } catch {
                AppLog.history.error("Could not record the switch event: \(error.localizedDescription, privacy: .public)")
            }
            refreshStates[profile.id] = .ok
            if interactive {
                lastManualSwitchAt[profile.provider] = Date()
                Task {
                    await CredentialAccess.independentWorkflow {
                        await CredentialAccess.nonInteractive { await refreshAll() }
                    }
                }
            }
            return true
        } catch {
            AppLog.switching.error("Switch to account \(profile.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let storeError = error as? CredentialStoreError, case .decodeFailed = storeError {
                // Malformed credential material is fail-closed. Never delete
                // the only saved login as an error-recovery side effect; the
                // user must explicitly recreate the provider login or remove
                // the account after deciding the old snapshot is expendable.
                refreshStates[profile.id] = .needsLogin(
                    reason: "The saved credential snapshot is unreadable and was left unchanged."
                )
                statusMessage = "Saved credentials for \(profile.label) are unreadable; no changes were made."
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Saved credentials for \(profile.label) were unreadable",
                    details: "They were left unchanged. Relaunch the stable installed build, or explicitly log into this account again (\(profile.provider.loginCommand)) to recreate the snapshot."
                )
            } else if credentialAccessDisposition(for: error) == .userCancelled {
                statusMessage = "Switch cancelled."
            } else if let storeError = error as? CredentialStoreError,
                      storeError.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                refreshStates[profile.id] = .keychainLocked
                statusMessage = "Saved credentials are not accessible. Relaunch the installed app, then retry."
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Saved credentials are not accessible",
                    details: storeError.localizedDescription
                )
            } else if profile.provider == .claude, isKeychainAccessDenied(error) {
                recordClaudeKeychainFailure(error)
                statusMessage = "Switch failed for \(profile.label): \(error.localizedDescription)"
                reportSwitchProblem(
                    interactive: interactive,
                    message: "Switch stopped before another password prompt",
                    details: "Authorize Keychain access from the More menu, then retry. \(error.localizedDescription)"
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
                        await CredentialAccess.independentWorkflow {
                            await CredentialAccess.nonInteractive { await refreshAll() }
                        }
                    }
                }
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

    private func preflightSwitchTarget(
        _ profile: AccountProfile,
        storedRecord: StoredCredentialRecord,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow
    ) async -> SwitchPreflightResult {
        switch profile.provider {
        case .claude:
            do {
                let result = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    storedRecord: storedRecord,
                    accessMode: CredentialAccess.currentMode
                )
                // Inactive resolution is owned by the stored snapshot, so a
                // changed generation was compare-and-swap persisted there.
                // An active preflight may instead have selected a fresher
                // live token without writing the private copy; keep the
                // cached record byte-for-byte aligned with its real owner.
                let updatedRecord = profile.isActiveCLI
                    ? storedRecord
                    : updatedClaudeStoredRecord(
                        storedRecord,
                        replacing: result.credentials
                    )
                storedCredentialWorkflow.markLoaded(updatedRecord, for: profile.id)
                cacheStoredCredentialSummary(updatedRecord, for: profile)
                applySnapshot(result.snapshot, for: profile)
                return .ready
            } catch {
                let fetchError: ClaudeAccountUsageFetchError
                if let preflightError = error as? ClaudeAccountUsagePreflightError {
                    if let latest = preflightError.latestPersistedCredentials {
                        let updatedRecord = updatedClaudeStoredRecord(
                            storedCredentialWorkflow.record(for: profile.id)
                                ?? storedRecord,
                            replacing: latest
                        )
                        storedCredentialWorkflow.markLoaded(updatedRecord, for: profile.id)
                        cacheStoredCredentialSummary(updatedRecord, for: profile)
                    }
                    fetchError = preflightError.underlying
                } else {
                    fetchError = (error as? ClaudeAccountUsageFetchError)
                        ?? .transport(error)
                }
                if case .liveCredentialAccessDenied(let underlying, let item) = fetchError {
                    recordClaudeKeychainFailure(
                        underlying,
                        item: item,
                        resolveItemIfNeeded: false
                    )
                }
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
            return await preflightCodexSwitchTarget(
                profile,
                storedRecord: storedRecord,
                storedCredentialWorkflow: storedCredentialWorkflow
            )
        }
    }

    private func preflightCodexSwitchTarget(
        _ profile: AccountProfile,
        storedRecord: StoredCredentialRecord,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow
    ) async -> SwitchPreflightResult {
        guard let executablePath = cliSwitcher.resolveExecutablePath(command: Provider.codex.commandName) else {
            return .temporarilyUnavailable(reason: "The Codex executable could not be found.")
        }

        do {
            guard storedRecord.summary.isRestorable,
                  let authJSON = storedRecord.codexAuthJSON else {
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
                guard let updatedRecord = try cliSwitcher.replaceStoredCodexAuthJSON(
                    updatedAuthJSON,
                    for: profile.id,
                    using: storedRecord,
                    ifSnapshotFingerprintMatches: storedRecord.summary.fingerprint
                ) else {
                    return .temporarilyUnavailable(
                        reason: "The saved Codex credentials changed while they were being verified. Try again."
                    )
                }
                storedCredentialWorkflow.markLoaded(updatedRecord, for: profile.id)
                cacheStoredCredentialSummary(updatedRecord, for: profile)
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
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            storedSnapshotStatuses[profile.id] = .locked
            return .temporarilyUnavailable(reason: "Keychain access is required to verify this account.")
        } catch {
            return .temporarilyUnavailable(reason: error.localizedDescription)
        }
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

    // MARK: - Claude Keychain authorization

    var shouldHighlightClaudeKeychainAuthorization: Bool {
        if case .needsAuthorization = claudeKeychainAuthorizationState {
            return true
        }
        if case .failed = claudeKeychainAuthorizationState {
            return true
        }
        return false
    }

    var claudeKeychainAuthorizationDiagnostic: String? {
        guard case .failed(let message) = claudeKeychainAuthorizationState else {
            return nil
        }
        return message
    }

    var canAuthorizeClaudeKeychain: Bool {
        if case .failed = claudeKeychainAuthorizationState {
            return false
        }
        return true
    }

    var isAuthorizingClaudeKeychain: Bool {
        if case .authorizing = claudeKeychainAuthorizationState {
            return true
        }
        return false
    }

    var hasNondurableDevelopmentSignature: Bool {
        let variant = ApplicationVariant.current
        return variant == .development
            && !codeSignatureStatus.supportsDurableAuthorization(for: variant)
    }

    /// A prompt-free health check. Unknown inspection errors intentionally do
    /// not erase a previously observed authorization denial.
    func refreshClaudeKeychainAuthorizationState() async {
        await CredentialAccess.nonInteractive {
            guard case .read(let pinnedItem) = automaticClaudeLiveAccess() else {
                return
            }
            var attemptedItem = pinnedItem
            do {
                _ = try readAutomaticClaudeOAuthCredentials(
                    pinnedItem: pinnedItem,
                    attemptedItem: &attemptedItem
                )
            } catch {
                recordClaudeKeychainFailure(
                    error,
                    item: attemptedItem,
                    resolveItemIfNeeded: false
                )
            }
        }
    }

    /// The sole prompt-capable path for Claude's provider-owned item. macOS
    /// owns the password UI; choosing Always Allow updates the standard ACL and
    /// caller partition together. A fresh noninteractive exact-item read is the
    /// only success condition.
    @discardableResult
    func authorizeClaudeKeychainAccess(
        reason: String = "to stop repeated password prompts",
        allowDuringCredentialMutation: Bool = false
    ) async -> Bool {
        let result = await CredentialAccess.withWorkflowCounter { counter, ownsScope in
            let result = await authorizeClaudeKeychainAccessImpl(
                reason: reason,
                allowDuringCredentialMutation: allowDuringCredentialMutation
            )
            if ownsScope {
                let workflowStatus: String
                switch claudeKeychainAuthorizationState {
                case .ready:
                    workflowStatus = result ? "ready" : "aborted"
                case .needsAuthorization(_, let disposition):
                    workflowStatus = disposition == .userCancelled
                        ? "cancelled"
                        : "needs_authorization"
                case .notFound:
                    workflowStatus = "not_found"
                case .failed:
                    workflowStatus = "failed"
                case .unknown, .authorizing:
                    workflowStatus = "aborted"
                }
                logCredentialWorkflow(
                    workflow: "authorize",
                    provider: .claude,
                    origin: "explicit_action",
                    access: "mixed",
                    status: workflowStatus,
                    counts: counter.snapshot
                )
            }
            return result
        }
        if result, !allowDuringCredentialMutation {
            await CredentialAccess.independentWorkflow {
                await resumePendingClaudeLoginCompletionIfPossible()
            }
        }
        return result
    }

    private func authorizeClaudeKeychainAccessImpl(
        reason: String,
        allowDuringCredentialMutation: Bool
    ) async -> Bool {
        guard !claudeAuthorizationInProgress else {
            return false
        }
        var standaloneMutationOwner: UUID?
        if allowDuringCredentialMutation {
            guard credentialMutationsInProgress[.claude] != nil else {
                statusMessage = "Could not reuse the Claude credential operation. Retry the original action."
                return false
            }
        } else {
            guard let owner = beginCredentialMutation(for: .claude) else {
                statusMessage = "Wait for the current Claude credential operation to finish, then authorize the resulting item."
                return false
            }
            standaloneMutationOwner = owner
        }
        claudeAuthorizationInProgress = true
        defer {
            claudeAuthorizationInProgress = false
            if let owner = standaloneMutationOwner {
                finishCredentialMutation(for: .claude, owner: owner)
            }
        }

        func deferPendingLoginResumeIfNeeded() {
            if allowDuringCredentialMutation,
               pendingClaudeLoginCompletion != nil {
                // The enclosing switch/capture owns the gate. Resume only
                // after it releases so the pending login remains single-flight.
                deferredClaudeLoginResume = true
            }
        }

        var resolvedLocation: ClaudeKeychainItemLocation?
        do {
            guard let resolved = try cliSwitcher.locateClaudeKeychainItem(accessMode: .nonInteractive) else {
                claudeKeychainAuthorizationState = .notFound
                statusMessage = "Claude Code is not logged in."
                showError(
                    message: "No Claude Code credential was found",
                    details: "Log in with `claude` (/login), then authorize Keychain access."
                )
                return false
            }
            resolvedLocation = resolved
            if try cliSwitcher.readClaudeKeychainItem(at: resolved, accessMode: .nonInteractive) != nil {
                claudeKeychainAuthorizationState = .ready(resolved)
                statusMessage = "Keychain access is already authorized."
                deferPendingLoginResumeIfNeeded()
                return true
            }
        } catch {
            let disposition = credentialAccessDisposition(for: error)
            if disposition != .interactionRequired {
                recordClaudeKeychainFailure(error, item: resolvedLocation)
                showClaudeAuthorizationFailure(error)
                return false
            }
            // Keep the exact generation that produced the denial. A broad
            // rediscovery here could silently redirect the one interactive
            // read to a replacement item that never passed this preflight.
            guard resolvedLocation != nil else {
                recordClaudeKeychainFailure(error)
                showClaudeAuthorizationFailure(error)
                return false
            }
        }
        guard let location = resolvedLocation else {
            claudeKeychainAuthorizationState = .failed(message: "Could not resolve the Claude Code credential item.")
            return false
        }

        claudeKeychainAuthorizationState = .authorizing(location)
        let explanation = NSAlert()
        explanation.messageText = "Authorize Limit Lifeboat once"
        if hasNondurableDevelopmentSignature {
            explanation.informativeText = "macOS will ask for your login password \(reason). This development build is not signed with a stable Apple Development identity, so even Always Allow is valid only for this exact build and may be requested again after rebuilding."
        } else {
            explanation.informativeText = "macOS will ask for your login password \(reason). Enter it once, then choose Always Allow. Choosing only Allow will not stop future prompts."
        }
        explanation.addButton(withTitle: "Continue")
        explanation.addButton(withTitle: "Cancel")
        guard explanation.runModalActivating() == .alertFirstButtonReturn else {
            claudeKeychainAuthorizationState = .needsAuthorization(
                item: location,
                disposition: .userCancelled
            )
            statusMessage = "Keychain authorization cancelled."
            return false
        }

        do {
            let authorizedData = try CredentialAccess.userInitiated(
                reason: "authorize Limit Lifeboat for Claude Code credentials",
                operation: {
                    try cliSwitcher.readClaudeKeychainItem(at: location, accessMode: .userInitiated)
                }
            )
            guard authorizedData != nil else {
                throw ClaudeCodeCredentialsKeychainError.missingLiveItem
            }

            guard let freshLocation = try cliSwitcher.locateClaudeKeychainItem(accessMode: .nonInteractive),
                  freshLocation.identity == location.identity,
                  try cliSwitcher.readClaudeKeychainItem(
                      at: freshLocation,
                      accessMode: .nonInteractive
                  ) != nil else {
                claudeKeychainAuthorizationState = .needsAuthorization(
                    item: location,
                    disposition: .interactionRequired
                )
                statusMessage = "Access was allowed once but was not saved. Choose Always Allow when you retry."
                return false
            }
            claudeKeychainAuthorizationState = .ready(freshLocation)
            statusMessage = hasNondurableDevelopmentSignature
                ? "Keychain access authorized for this development build only. Use an Apple Development signature for durable approval."
                : "Keychain access authorized. Future background checks will not ask for your password."
            deferPendingLoginResumeIfNeeded()
            return true
        } catch {
            recordClaudeKeychainFailure(error, item: location)
            if credentialAccessDisposition(for: error) != .userCancelled {
                showClaudeAuthorizationFailure(error)
            } else {
                statusMessage = "Keychain authorization cancelled."
            }
            return false
        }
    }

    private func recordSuccessfulClaudeKeychainRead(_ observation: LiveCredentialObservation) {
        guard let location = observation.claudeKeychainItemLocation else {
            if !observation.isLoggedIn {
                claudeKeychainAuthorizationState = .notFound
            }
            return
        }
        // ClaudeCredentialAdapter only attaches a location after the secret
        // data read of that exact persistent item succeeds. No metadata-only
        // follow-up is allowed to mark a replacement item ready.
        claudeKeychainAuthorizationState = .ready(location)
    }

    private func resumePendingClaudeLoginCompletionIfPossible() async {
        guard let pending = pendingClaudeLoginCompletion else {
            deferredClaudeLoginResume = false
            return
        }
        guard let mutationOwner = beginCredentialMutation(for: .claude) else {
            deferredClaudeLoginResume = true
            return
        }
        deferredClaudeLoginResume = false
        var watcherOwnsMutation = false
        defer {
            if !watcherOwnsMutation {
                finishCredentialMutation(for: .claude, owner: mutationOwner)
            }
        }
        let result = await CredentialAccess.nonInteractive {
            await refreshAfterCompletedLogin(
                profileID: pending.profileID,
                provider: .claude,
                initialBaseline: pending.initialBaseline,
                activateAfterLogin: pending.activateAfterLogin,
                previousActiveID: pending.previousActiveID
            )
        }
        switch result {
        case .completed:
            pendingClaudeLoginCompletion = nil
        case .pending:
            statusMessage = "Keychain access is authorized. Waiting for Claude Code to finish writing the login."
            do {
                let currentStamp = try loginCredentialMetadataStamp(provider: .claude)
                watchForCompletedLogin(
                    profileID: pending.profileID,
                    provider: .claude,
                    initialBaseline: pending.initialBaseline,
                    initialMetadataStamp: currentStamp,
                    activateAfterLogin: pending.activateAfterLogin,
                    previousActiveID: pending.previousActiveID
                )
                watcherOwnsMutation = loginFollowUpTasks[.claude] != nil
            } catch {
                recordClaudeKeychainFailure(error)
                statusMessage = "Could not resume the Claude login watcher: \(error.localizedDescription)"
            }
        case .authorizationRequired:
            statusMessage = "The Claude credential changed again. Authorize the new item before linking it."
        }
    }

    private func recordClaudeKeychainFailure(
        _ error: Error,
        item suppliedItem: ClaudeKeychainItemLocation? = nil,
        resolveItemIfNeeded: Bool = true
    ) {
        let item = suppliedItem ?? (resolveItemIfNeeded
            ? (try? cliSwitcher.locateClaudeKeychainItem(accessMode: .nonInteractive))
            : nil)
        guard let disposition = credentialAccessDisposition(for: error) else {
            if case .needsAuthorization = claudeKeychainAuthorizationState {
                return
            }
            claudeKeychainAuthorizationState = .failed(message: error.localizedDescription)
            return
        }
        recordClaudeKeychainDisposition(
            disposition,
            item: item,
            failureMessage: error.localizedDescription
        )
    }

    private func recordClaudeKeychainDisposition(
        _ disposition: CredentialAccessDisposition,
        item: ClaudeKeychainItemLocation?,
        failureMessage: String = "macOS Keychain access is unavailable for the Claude credential item."
    ) {
        switch disposition {
        case .interactionRequired, .userCancelled:
            claudeKeychainAuthorizationState = .needsAuthorization(
                item: item,
                disposition: disposition
            )
        case .codeSignatureInvalid:
            claudeKeychainAuthorizationState = .failed(
                message: "macOS could not verify this app's signature. Quit workspace builds and relaunch the installed app."
            )
        case .unavailable, .other:
            // An inconclusive follow-up must not erase a known denial.
            if case .needsAuthorization = claudeKeychainAuthorizationState {
                return
            }
            claudeKeychainAuthorizationState = .failed(message: failureMessage)
        }
    }

    private func credentialAccessDisposition(for error: Error) -> CredentialAccessDisposition? {
        if let error = error as? ClaudeCodeCredentialsKeychainError {
            return error.credentialAccessDisposition
        }
        if let error = error as? CredentialStoreError {
            return error.credentialAccessDisposition
        }
        if let error = error as? CLISwitcherError {
            return error.credentialAccessDisposition
        }
        return nil
    }

    /// True for interaction-required or signature failures, but not a user
    /// cancellation; cancellation must never trigger another automatic prompt.
    private func isKeychainAccessDenied(_ error: Error) -> Bool {
        guard let disposition = credentialAccessDisposition(for: error) else {
            return false
        }
        return disposition.isAccessDenied && disposition != .userCancelled
    }

    private func showClaudeAuthorizationFailure(_ error: Error) {
        let details: String
        switch credentialAccessDisposition(for: error) {
        case .interactionRequired:
            details = "Access did not persist. Retry once and select Always Allow. If it still fails, quit workspace builds and relaunch /Applications/Limit Lifeboat.app."
        case .codeSignatureInvalid:
            details = "Quit any workspace copies and relaunch the stable installed app before retrying."
        default:
            details = error.localizedDescription
        }
        showError(message: "Could not authorize Keychain access", details: details)
    }

    func captureCLISnapshot(for profile: AccountProfile) {
        guard let mutationOwner = beginCredentialMutation(for: profile.provider) else {
            statusMessage = "A \(profile.provider.displayName) credential operation is already in progress."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let counter = CredentialKeychainIOCounter()
            var workflowStatus = "aborted"
            defer {
                self.finishCredentialMutation(
                    for: profile.provider,
                    owner: mutationOwner
                )
            }
            await CredentialAccess.counting(counter) {
                defer {
                    self.logCredentialWorkflow(
                        workflow: "snapshot_capture",
                        provider: profile.provider,
                        origin: "explicit_action",
                        access: profile.provider == .claude ? "mixed" : "noninteractive",
                        status: workflowStatus,
                        counts: counter.snapshot
                    )
                }
                if profile.provider == .claude,
                   !(await self.authorizeClaudeKeychainAccess(
                        reason: "before saving \(profile.label)",
                        allowDuringCredentialMutation: true
                   )) {
                    workflowStatus = "authorization_required"
                    return
                }
                let captured = await CredentialAccess.nonInteractive {
                    self.captureCLISnapshotPrepared(for: profile)
                }
                workflowStatus = captured ? "completed" : "failed"
            }
        }
    }

    private func captureCLISnapshotPrepared(for profile: AccountProfile) -> Bool {
        guard profile.isActiveCLI else {
            showError(
                message: "Capture cancelled",
                details: "Only the active terminal account can be captured. Refresh to reconcile the current login first."
            )
            return false
        }
        do {
            let observation = try cliSwitcher.stableLiveObservation(provider: profile.provider)
            guard observation.identity.map({ profile.identity?.matches($0) ?? true }) != false else {
                throw CLISwitcherError.credentialConflict("live \(profile.provider.displayName) identity")
            }
            _ = try reconcileLiveCredentials(provider: profile.provider, origin: .manualCapture, observation: observation)
            statusMessage = "Captured \(profile.provider.displayName) CLI credentials for \(profile.label)."
            storedSnapshotStatuses[profile.id] = .present
            return true
        } catch {
            statusMessage = "Capture failed for \(profile.label): \(error.localizedDescription)"
            showError(message: "Capture failed", details: error.localizedDescription)
            return false
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
        for provider in Provider.allCases {
            let counter = CredentialKeychainIOCounter()
            var providerLocked = false
            CredentialAccess.counting(counter) {
                for profile in profiles where profile.provider == provider {
                    do {
                        if let record = try cliSwitcher.storedCredentialRecord(for: profile) {
                            statuses[profile.id] = record.summary.isRestorable ? .present : .absent
                            if let expiresAt = record.summary.claudeRefreshTokenExpiresAt {
                                expirations[profile.id] = expiresAt
                            }
                        } else {
                            statuses[profile.id] = .absent
                        }
                    } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                        statuses[profile.id] = .locked
                        providerLocked = true
                    } catch {
                        statuses[profile.id] = .absent
                    }
                }
            }
            logCredentialWorkflow(
                workflow: "snapshot_inventory",
                provider: provider,
                origin: "launch",
                access: "noninteractive",
                status: providerLocked ? "partial" : "completed",
                counts: counter.snapshot
            )
        }
        storedSnapshotStatuses = statuses
        claudeLoginExpirations = expirations
    }

    private func cacheStoredSnapshotSummary(_ snapshot: CredentialSnapshot, for profile: AccountProfile) {
        storedSnapshotStatuses[profile.id] = .present
        guard profile.provider == .claude else { return }
        let item = snapshot.items.first(where: { $0.kind == .keychainJSONFields })
        claudeLoginExpirations[profile.id] = item.flatMap {
            ClaudeOAuthCredentials(claudeAiOauthJSON: $0.contents)?.refreshTokenExpiresAt
        }
    }

    private func cacheStoredCredentialSummary(
        _ record: StoredCredentialRecord?,
        for profile: AccountProfile
    ) {
        storedSnapshotStatuses[profile.id] = record?.summary.isRestorable == true
            ? .present
            : .absent
        if profile.provider == .claude {
            claudeLoginExpirations[profile.id] = record?.summary.claudeRefreshTokenExpiresAt
        }
    }

    private func updatedClaudeStoredRecord(
        _ record: StoredCredentialRecord,
        replacing credentials: ClaudeOAuthCredentials
    ) -> StoredCredentialRecord {
        var snapshot = record.snapshot
        guard let index = snapshot.items.firstIndex(where: {
            $0.kind == .keychainJSONFields
        }) else {
            return record
        }
        snapshot.items[index].contents = credentials.rawClaudeAiOauth
        return cliSwitcher.makeStoredCredentialRecord(from: snapshot)
    }

    private func readStoredSnapshotStatus(for profile: AccountProfile) -> StoredSnapshotStatus {
        do {
            return try cliSwitcher.storedCredentialRecord(for: profile)?.summary.isRestorable == true
                ? .present
                : .absent
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
            let counter = CredentialKeychainIOCounter()
            var workflowStatus = "aborted"
            await CredentialAccess.counting(counter) {
                defer {
                    logCredentialWorkflow(
                        workflow: "usage_retry",
                        provider: profile.provider,
                        origin: "explicit_action",
                        access: "noninteractive",
                        status: workflowStatus,
                        counts: counter.snapshot
                    )
                }
                guard let mutationOwner = beginCredentialMutation(for: profile.provider) else {
                    workflowStatus = "deferred"
                    statusMessage = "A \(profile.provider.displayName) credential operation is already in progress."
                    return
                }
                if profile.provider == .claude, profile.isActiveCLI {
                    switch automaticClaudeLiveAccess() {
                    case .read(let pinnedItem):
                        if let pinnedItem {
                            var attemptedItem: ClaudeKeychainItemLocation? = pinnedItem
                            do {
                                _ = try readAutomaticClaudeOAuthCredentials(
                                    pinnedItem: pinnedItem,
                                    attemptedItem: &attemptedItem
                                )
                            } catch {
                                recordClaudeKeychainFailure(
                                    error,
                                    item: attemptedItem,
                                    resolveItemIfNeeded: false
                                )
                                refreshStates[profile.id] = isKeychainAccessDenied(error)
                                    ? .keychainLocked
                                    : .readFailed(reason: error.localizedDescription)
                                statusMessage = "Retry stopped because the changed Claude credential could not be verified."
                                workflowStatus = isKeychainAccessDenied(error)
                                    ? "authorization_required"
                                    : "credential_unavailable"
                                finishCredentialMutation(
                                    for: profile.provider,
                                    owner: mutationOwner
                                )
                                return
                            }
                        }
                    case .knownDenied, .unavailable:
                        refreshStates[profile.id] = .keychainLocked
                        statusMessage = "Retry stopped. Authorize Claude Keychain access from the More menu first."
                        workflowStatus = "authorization_required"
                        finishCredentialMutation(
                            for: profile.provider,
                            owner: mutationOwner
                        )
                        return
                    }
                }
                await CredentialAccess.nonInteractive {
                    await retryRefreshInteractively(for: profile)
                }
                let loginReason: String?
                if case .needsLogin(let reason) = refreshStates[profile.id] {
                    loginReason = reason
                } else {
                    loginReason = nil
                }
                finishCredentialMutation(for: profile.provider, owner: mutationOwner)
                if let loginReason {
                    workflowStatus = "needs_login"
                    handleLoginRequired(for: profile, reason: loginReason, interactive: true)
                } else if case .ok = refreshStates[profile.id] {
                    workflowStatus = "completed"
                } else if case .keychainLocked = refreshStates[profile.id] {
                    workflowStatus = "authorization_required"
                } else {
                    workflowStatus = "failed"
                }
                updateSwitchAdvice()
                updateMenuBarSummary()
            }
        }
    }

    private func retryRefreshInteractively(for profile: AccountProfile) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var retryLiveRecord: LiveClaudeOAuthCredentialRecord?
        if profile.provider == .claude, profile.isActiveCLI {
            do {
                let observation = try cliSwitcher.stableLiveObservation(
                    provider: .claude,
                    accessMode: .nonInteractive
                )
                retryLiveRecord = try cliSwitcher.claudeOAuthCredentialRecord(
                    from: observation
                )
                let resolved = try reconcileLiveCredentials(
                    provider: .claude,
                    origin: .manualCapture,
                    observation: observation
                )
                guard resolved?.id == profile.id,
                      activeProfile(for: .claude)?.id == profile.id else {
                    refreshStates[profile.id] = .readFailed(
                        reason: "The active Claude account changed before Retry. Its credentials were left untouched; retry from the account that is active now."
                    )
                    statusMessage = "Retry stopped because Claude switched to a different account."
                    return
                }
            } catch {
                if error is ClaudeCodeCredentialsKeychainError {
                    recordClaudeKeychainFailure(error)
                }
                refreshStates[profile.id] = isKeychainAccessDenied(error)
                    ? .keychainLocked
                    : .readFailed(reason: error.localizedDescription)
                statusMessage = "Retry stopped before changing Claude credentials: \(error.localizedDescription)"
                return
            }
        }

        let storedStatus = readStoredSnapshotStatus(for: profile)
        storedSnapshotStatuses[profile.id] = storedStatus
        guard storedStatus != .locked else {
            refreshStates[profile.id] = .keychainLocked
            return
        }

        switch profile.provider {
        case .claude:
            lastClaudeRefreshAttempt = Date()
            let liveElsewhere = claudeAccountIsLiveElsewhere(profile, context: claudeRotationContext())
            refreshStates[profile.id] = .refreshing
            var resolvedUsageCredentials: ClaudeOAuthCredentials?
            do {
                let snapshot = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    accountIsLiveElsewhere: liveElsewhere,
                    userExplicitlyRequestedRefresh: true,
                    liveCredentialReadPolicy: profile.isActiveCLI
                        ? .preloaded(retryLiveRecord)
                        : .read,
                    credentialDidResolve: { resolvedUsageCredentials = $0 }
                )
                applySnapshot(snapshot, for: profile)
                clearUsagePaused(for: profile.id)
                recordClaudeCredentialOutcome(.success, for: profile, codePath: "userRetry")
                await enrichAccountInfoIfMissing(
                    for: profile,
                    accountIsLiveElsewhere: liveElsewhere,
                    liveCredentialReadPolicy: profile.isActiveCLI
                        ? .preloaded(retryLiveRecord)
                        : nil,
                    resolvedCredentials: resolvedUsageCredentials
                )
            } catch {
                let fetchError = (error as? ClaudeAccountUsageFetchError) ?? .transport(error)
                if case .liveCredentialAccessDenied(let underlying, let item) = fetchError {
                    recordClaudeKeychainFailure(
                        underlying,
                        item: item,
                        resolveItemIfNeeded: false
                    )
                }
                recordClaudeCredentialOutcome(
                    Self.credentialOutcome(for: fetchError),
                    for: profile,
                    codePath: "userRetry"
                )
                let outcome = RefreshOutcomePolicy.outcome(for: fetchError, isActiveCLI: profile.isActiveCLI)
                if outcome.attemptTUIFallback {
                    clearUsagePaused(for: profile.id)
                    await refreshActiveClaudeCodeUsage(
                        onFailure: outcome.state,
                        for: profile,
                        resolvedUsageCredentials: resolvedUsageCredentials,
                        usageCredentialWasResolved: resolvedUsageCredentials != nil
                    )
                } else {
                    applyClaudeRefreshState(outcome.state, for: profile)
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
        guard let mutationOwner = beginCredentialMutation(for: profile.provider) else {
            statusMessage = "A \(profile.provider.displayName) credential operation is already in progress."
            return
        }
        if profile.provider == .claude {
            pendingClaudeLoginCompletion = nil
            deferredClaudeLoginResume = false
        }

        Task { [weak self] in
            guard let self else { return }
            let counter = CredentialKeychainIOCounter()
            let started = await CredentialAccess.counting(counter) {
                await CredentialAccess.nonInteractive {
                    self.beginCLILoginPrepared(
                        for: profile,
                        activateAfterLogin: activateAfterLogin
                    )
                }
            }
            self.logCredentialWorkflow(
                workflow: "login_launch",
                provider: profile.provider,
                origin: "explicit_action",
                access: "noninteractive",
                status: started ? "launched" : "launch_failed",
                counts: counter.snapshot
            )
            if !started {
                self.finishCredentialMutation(
                    for: profile.provider,
                    owner: mutationOwner
                )
            }
        }
    }

    /// Performs prompt-free preparation. Claude authorization is deliberately
    /// deferred until after login changes or replaces the item, so a single
    /// login cannot ask once for the old item and again for the new one.
    /// Returns whether a completion watcher now owns the provider mutation
    /// slot.
    private func beginCLILoginPrepared(
        for profile: AccountProfile,
        activateAfterLogin: Bool
    ) -> Bool {
        // Not switching is only meaningful when there is a *different* active
        // account to preserve. With no active account (first login) or when
        // re-authenticating the account that is already active, fall back to
        // the normal activating login.
        let previousActiveID = activeProfile(for: profile.provider)?.id
        let activate = activateAfterLogin || previousActiveID == nil || previousActiveID == profile.id

        let initialObservation: LiveCredentialObservation?
        do {
            initialObservation = try cliSwitcher.stableLiveObservation(
                provider: profile.provider,
                accessMode: .nonInteractive
            )
        } catch {
            if profile.provider == .claude {
                recordClaudeKeychainFailure(error)
                if isKeychainAccessDenied(error), activate {
                    // An activating login may safely replace an unreadable old
                    // item. The watcher authorizes only the resulting item.
                    initialObservation = nil
                } else {
                    showClaudeAuthorizationFailure(error)
                    return false
                }
            } else {
                statusMessage = "Could not inspect the current \(profile.provider.displayName) login: \(error.localizedDescription)"
                return false
            }
        }
        let initialBaseline = initialObservation.map {
            LoginObservationBaseline(
                identity: $0.identity,
                credentialFingerprint: $0.credentialFingerprint,
                claudeKeychainPayloadFingerprint: $0.claudeKeychainPayloadFingerprint
            )
        }
        let initialMetadataStamp: LoginCredentialMetadataStamp?
        do {
            initialMetadataStamp = try loginCredentialMetadataStamp(provider: profile.provider)
        } catch {
            if profile.provider == .claude {
                recordClaudeKeychainFailure(error)
                showClaudeAuthorizationFailure(error)
            } else {
                statusMessage = "Could not inspect the current \(profile.provider.displayName) login: \(error.localizedDescription)"
            }
            return false
        }

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
                return false
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
            watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialBaseline: initialBaseline, initialMetadataStamp: initialMetadataStamp, activateAfterLogin: activate, previousActiveID: previousActiveID)
            return true
        }

        // AppleScript failed — most commonly because Terminal Automation
        // permission is off (AppleEvent error -1743), which used to silently
        // fall back to a bare Terminal that ran nothing. Instead run the
        // command by opening an executable `.command` file, which needs no
        // Apple Events permission.
        if terminalLauncher.runViaCommandFile(launchedCommand) {
            statusMessage = "Opened Terminal to log in \(profile.label). \(linkNote)"
            watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialBaseline: initialBaseline, initialMetadataStamp: initialMetadataStamp, activateAfterLogin: activate, previousActiveID: previousActiveID)
            return true
        }

        // Last resort: copy the command and open a bare Terminal for the user
        // to paste it into.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = appleScriptError
            ?? "Copied the login command. Paste it into Terminal; \(linkNote.prefix(1).lowercased() + linkNote.dropFirst())"
        terminalLauncher.open()
        watchForCompletedLogin(profileID: profile.id, provider: profile.provider, initialBaseline: initialBaseline, initialMetadataStamp: initialMetadataStamp, activateAfterLogin: activate, previousActiveID: previousActiveID)
        return true
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

    private struct LoginFileMetadataStamp: Equatable {
        var exists: Bool
        var modificationDate: Date?
        var size: UInt64?
        var fileNumber: UInt64?
    }

    private struct LoginCredentialMetadataStamp: Equatable {
        var claudeItemLocation: ClaudeKeychainItemLocation?
        var files: [LoginFileMetadataStamp]

        var claudeItem: ClaudeKeychainItemModificationStamp? {
            claudeItemLocation?.modificationStamp
        }
    }

    private struct LoginObservationBaseline {
        var identity: AccountIdentity?
        var credentialFingerprint: String?
        var claudeKeychainPayloadFingerprint: String?
    }

    private struct PendingClaudeLoginCompletion {
        var profileID: UUID
        var initialBaseline: LoginObservationBaseline?
        var activateAfterLogin: Bool
        var previousActiveID: UUID?
    }

    /// Metadata-only signal used by the login watcher. Secret data is read
    /// only after one of these values changes.
    private func loginCredentialMetadataStamp(provider: Provider) throws -> LoginCredentialMetadataStamp {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fileURLs: [URL]
        let claudeItemLocation: ClaudeKeychainItemLocation?
        switch provider {
        case .claude:
            claudeItemLocation = try cliSwitcher
                .locateClaudeKeychainItem(accessMode: .nonInteractive)
            fileURLs = [
                home.appendingPathComponent(".claude.json"),
                home.appendingPathComponent("Library/Application Support/Claude/config.json")
            ]
        case .codex:
            claudeItemLocation = nil
            fileURLs = [home.appendingPathComponent(".codex/auth.json")]
        }
        return LoginCredentialMetadataStamp(
            claudeItemLocation: claudeItemLocation,
            files: fileURLs.map(loginFileMetadataStamp)
        )
    }

    private func loginFileMetadataStamp(_ url: URL) -> LoginFileMetadataStamp {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return LoginFileMetadataStamp(
                exists: false,
                modificationDate: nil,
                size: nil,
                fileNumber: nil
            )
        }
        return LoginFileMetadataStamp(
            exists: true,
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private enum LoginCompletionPollResult {
        case pending
        case completed
        case authorizationRequired
    }

    private func watchForCompletedLogin(
        profileID: UUID,
        provider: Provider,
        initialBaseline: LoginObservationBaseline?,
        initialMetadataStamp: LoginCredentialMetadataStamp?,
        activateAfterLogin: Bool,
        previousActiveID: UUID?
    ) {
        guard let mutationOwner = credentialMutationsInProgress[provider] else {
            return
        }
        loginFollowUpTasks[provider]?.cancel()
        loginFollowUpTasks[provider] = Task { @MainActor [weak self] in
            guard let self else { return }
            let counter = CredentialKeychainIOCounter()
            var workflowStatus = "timeout"
            defer {
                self.finishCredentialMutation(for: provider, owner: mutationOwner)
                self.loginFollowUpTasks[provider] = nil
            }
            await CredentialAccess.counting(counter) {
                await CredentialAccess.nonInteractive {
                    var lastAttemptedStamp = initialMetadataStamp
                    var claudeMetadataGate = CredentialMetadataStabilityGate<
                        ClaudeKeychainItemModificationStamp?,
                        [LoginFileMetadataStamp]
                    >(
                        lastAttemptedItem: initialMetadataStamp?.claudeItem,
                        initialSettle: initialMetadataStamp?.files,
                        // A settled filesystem change may cover a same-second
                        // Keychain overwrite only when the readable baseline
                        // lets the payload fingerprint below reject stale data.
                        // A denied baseline still requires an item-stamp change.
                        allowSettledFallbackRead: initialBaseline?
                            .claudeKeychainPayloadFingerprint != nil
                    )
                    var cachedClaudeObservation: LiveCredentialObservation?
                    for _ in 0..<60 {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else {
                            workflowStatus = "cancelled"
                            return
                        }

                    let currentStamp: LoginCredentialMetadataStamp
                    do {
                        currentStamp = try self.loginCredentialMetadataStamp(provider: provider)
                    } catch {
                        if provider == .claude {
                            self.recordClaudeKeychainFailure(error)
                        }
                        workflowStatus = provider == .claude
                            && self.isKeychainAccessDenied(error)
                            ? "authorization_required"
                            : "metadata_failed"
                        return
                    }
                    let observation: LiveCredentialObservation?
                    if provider == .claude {
                        let decision = claudeMetadataGate.decision(
                            item: currentStamp.claudeItem,
                            settle: currentStamp.files
                        )
                        switch decision {
                        case .wait:
                            continue
                        case .read, .fallbackRead:
                            // A settled disappearance is an intermediate
                            // logout/replacement state, not a terminal error.
                            // A later item generation must settle separately.
                            guard let settledLocation = currentStamp.claudeItemLocation else {
                                cachedClaudeObservation = nil
                                continue
                            }
                            do {
                                let current = try self.cliSwitcher.liveClaudeObservation(
                                    at: settledLocation,
                                    accessMode: .nonInteractive
                                )
                                // Close the in-place update race as well: if
                                // the modification stamp advanced during the
                                // exact read, discard these bytes and require
                                // the newer generation to settle normally.
                                let verifiedStamp = try self.loginCredentialMetadataStamp(
                                    provider: .claude
                                )
                                guard verifiedStamp.claudeItem
                                        == settledLocation.modificationStamp else {
                                    cachedClaudeObservation = nil
                                    continue
                                }
                                cachedClaudeObservation = current
                                guard verifiedStamp.files == currentStamp.files else {
                                    // Keep the one exact-item read. Once this
                                    // newer filesystem generation settles, the
                                    // gate will refresh only its nonsecret
                                    // metadata around the cached observation.
                                    continue
                                }
                                if decision == .fallbackRead,
                                   current.claudeKeychainPayloadFingerprint
                                    == initialBaseline?.claudeKeychainPayloadFingerprint {
                                    // Claude wrote its identity/config first;
                                    // this is still the old provider payload.
                                    // Never combine and store those two
                                    // accounts. Wait for an exact item change.
                                    claudeMetadataGate.discardFallbackRead()
                                    cachedClaudeObservation = nil
                                    continue
                                }
                                observation = current
                            } catch ClaudeCodeCredentialsKeychainError.missingLiveItem {
                                // The pinned generation was removed between
                                // metadata discovery and the exact read. Poll
                                // metadata again; never broaden this read to a
                                // replacement that has not settled.
                                cachedClaudeObservation = nil
                                continue
                            } catch {
                                self.recordClaudeKeychainFailure(
                                    error,
                                    item: settledLocation
                                )
                                if self.isKeychainAccessDenied(error) {
                                    workflowStatus = "authorization_required"
                                    self.pendingClaudeLoginCompletion = PendingClaudeLoginCompletion(
                                        profileID: profileID,
                                        initialBaseline: initialBaseline,
                                        activateAfterLogin: activateAfterLogin,
                                        previousActiveID: previousActiveID
                                    )
                                    self.statusMessage = "Login finished. Authorize Keychain access once from the More menu to link it."
                                } else {
                                    workflowStatus = "read_failed"
                                    self.statusMessage = "Login finished, but its exact Keychain item could not be read safely: \(error.localizedDescription)"
                                }
                                return
                            }
                        case .reevaluateCachedRead:
                            guard let cached = cachedClaudeObservation else { continue }
                            let current: LiveCredentialObservation
                            do {
                                current = try self.cliSwitcher
                                    .refreshClaudeFilesystemMetadata(in: cached)
                            } catch {
                                // A partially-written identity file is not a
                                // reason to read the shared item again. Wait
                                // for its exact metadata to change and settle.
                                continue
                            }
                            let verifiedStamp: LoginCredentialMetadataStamp
                            do {
                                verifiedStamp = try self.loginCredentialMetadataStamp(
                                    provider: .claude
                                )
                            } catch {
                                // Discovery failures are not filesystem
                                // settling noise. Stop immediately so a denial
                                // or ambiguous item cannot become a 60-poll
                                // failure storm.
                                self.recordClaudeKeychainFailure(error)
                                if self.isKeychainAccessDenied(error) {
                                    workflowStatus = "authorization_required"
                                    self.pendingClaudeLoginCompletion = PendingClaudeLoginCompletion(
                                        profileID: profileID,
                                        initialBaseline: initialBaseline,
                                        activateAfterLogin: activateAfterLogin,
                                        previousActiveID: previousActiveID
                                    )
                                    self.statusMessage = "Login finished. Authorize Keychain access once from the More menu to link it."
                                } else {
                                    workflowStatus = "metadata_failed"
                                    self.statusMessage = "Login finished, but its exact Keychain item could not be verified safely: \(error.localizedDescription)"
                                }
                                return
                            }
                            guard let pinnedStamp = cached.claudeKeychainItemLocation?
                                .modificationStamp,
                                  verifiedStamp.claudeItem == pinnedStamp else {
                                cachedClaudeObservation = nil
                                continue
                            }
                            cachedClaudeObservation = current
                            guard verifiedStamp.files == currentStamp.files else {
                                // Files advanced during the metadata-only
                                // refresh. Keep the exact secret cached and
                                // wait for this generation to settle; do not
                                // spend another Keychain data read.
                                continue
                            }
                            observation = current
                        }
                        lastAttemptedStamp = currentStamp
                    } else {
                        guard currentStamp != lastAttemptedStamp else { continue }
                        lastAttemptedStamp = currentStamp
                        observation = nil
                    }

                    let result = await self.refreshAfterCompletedLogin(
                        profileID: profileID,
                        provider: provider,
                        initialBaseline: initialBaseline,
                        activateAfterLogin: activateAfterLogin,
                        previousActiveID: previousActiveID,
                        observation: observation
                    )
                    switch result {
                    case .pending:
                        continue
                    case .completed:
                        workflowStatus = "completed"
                        if provider == .claude {
                            self.pendingClaudeLoginCompletion = nil
                        }
                        return
                    case .authorizationRequired:
                        workflowStatus = "authorization_required"
                        if provider == .claude {
                            self.pendingClaudeLoginCompletion = PendingClaudeLoginCompletion(
                                profileID: profileID,
                                initialBaseline: initialBaseline,
                                activateAfterLogin: activateAfterLogin,
                                previousActiveID: previousActiveID
                            )
                        }
                        self.statusMessage = "Login finished. Authorize Keychain access once from the More menu to link it."
                        return
                    }
                }
            }
            self.logCredentialWorkflow(
                workflow: "login_watcher",
                provider: provider,
                origin: "login_completion",
                access: "noninteractive",
                status: workflowStatus,
                counts: counter.snapshot
            )
        }
    }
    }

    private func refreshAfterCompletedLogin(
        profileID: UUID,
        provider: Provider,
        initialBaseline: LoginObservationBaseline?,
        activateAfterLogin: Bool,
        previousActiveID: UUID?,
        observation suppliedObservation: LiveCredentialObservation? = nil
    ) async -> LoginCompletionPollResult {
        let current: LiveCredentialObservation
        if let suppliedObservation {
            current = suppliedObservation
        } else {
            do {
                current = try cliSwitcher.liveObservation(
                    provider: provider,
                    accessMode: .nonInteractive
                )
            } catch {
                if provider == .claude,
                   error is ClaudeCodeCredentialsKeychainError,
                   isKeychainAccessDenied(error) {
                    recordClaudeKeychainFailure(error)
                    return .authorizationRequired
                }
                return .pending
            }
        }
        guard current.isLoggedIn else {
            return .pending
        }
        if provider == .claude,
           (current.claudeKeychainItemLocation == nil
                || current.claudeKeychainPayloadFingerprint == nil) {
            // Authorization readiness and login completion both require data
            // from the exact item generation discovered by the watcher.
            return .pending
        }
        let identityChanged: Bool
        if let initial = initialBaseline?.identity, let currentIdentity = current.identity {
            identityChanged = !currentIdentity.matches(initial)
        } else {
            identityChanged = current.identity != nil && initialBaseline?.identity == nil
        }
        let credentialsChanged = current.credentialFingerprint != initialBaseline?.credentialFingerprint
        let providerPayloadChanged = current.claudeKeychainPayloadFingerprint
            != initialBaseline?.claudeKeychainPayloadFingerprint
        guard provider == .claude
            ? providerPayloadChanged
            : (identityChanged || credentialsChanged) else {
            return .pending
        }
        if provider == .claude {
            recordSuccessfulClaudeKeychainRead(current)
        }
        guard activateAfterLogin else {
            return await handleNonActivatingLoginCompletion(
                current: current,
                profileID: profileID,
                previousActiveID: previousActiveID
            ) ? .completed : .pending
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
                ? .completed
                : .pending
        } catch {
            if provider == .claude,
               error is ClaudeCodeCredentialsKeychainError,
               isKeychainAccessDenied(error) {
                recordClaudeKeychainFailure(error)
                return .authorizationRequired
            }
            statusMessage = "Login finished, but the account could not be saved: \(error.localizedDescription)"
            return .pending
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
        let storedCredentialWorkflow: SwitchStoredCredentialWorkflow
        do {
            storedCredentialWorkflow = try loadSwitchStoredCredentialWorkflow(
                for: provider
            )
        } catch {
            statusMessage = "Login finished, but saved account credentials could not be inspected safely: \(error.localizedDescription)"
            return false
        }
        let resolved: AccountProfile?
        do {
            resolved = try captureLoginIntoProfile(
                observation: current,
                provider: provider,
                targetProfileID: profileID,
                storedCredentialWorkflow: storedCredentialWorkflow
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
              let previousStoredRecord = storedCredentialWorkflow.record(for: previous.id),
              previousStoredRecord.summary.isRestorable else {
            do {
                _ = try reconcileLiveCredentials(
                    provider: provider,
                    origin: .login,
                    observation: current,
                    preferredLoginProfileID: profileID,
                    storedCredentialWorkflow: storedCredentialWorkflow
                )
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
                storedRecord: previousStoredRecord,
                expectedLiveFingerprint: current.credentialFingerprint,
                enforceExpectedLiveState: true
            )
            _ = try reconcileLiveCredentials(
                provider: provider,
                origin: .login,
                observation: result.verifiedObservation,
                storedCredentialWorkflow: storedCredentialWorkflow
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
                _ = try reconcileLiveCredentials(
                    provider: provider,
                    origin: .login,
                    observation: current,
                    preferredLoginProfileID: profileID,
                    storedCredentialWorkflow: storedCredentialWorkflow
                )
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
        targetProfileID: UUID,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow
    ) throws -> AccountProfile? {
        guard observation.isLoggedIn,
              observation.snapshot != nil,
              let identity = observation.identity else {
            return nil
        }
        let ownershipPlan = try planLiveOwnership(
            provider: provider,
            observation: observation,
            preferredLoginProfileID: targetProfileID,
            storedCredentialWorkflow: storedCredentialWorkflow
        )
        let resolvedID: UUID
        switch ownershipPlan.action {
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
            let snapshot = try cliSwitcher.storeObservation(
                observation,
                for: resolved,
                storedRecord: ownershipPlan.storedRecords[resolvedID]
            )
            storedCredentialWorkflow.markLoaded(
                cliSwitcher.makeStoredCredentialRecord(from: snapshot),
                for: resolvedID
            )
            cacheStoredSnapshotSummary(snapshot, for: resolved)
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
