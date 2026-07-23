import AppKit
import Combine
import Foundation
import LimitLifeboatAppWorkflows
import LimitLifeboatCore
import os
import Security
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
    /// Secret-free summaries captured during bounded credential workflows.
    /// Refresh-chain digests recognize shared Claude holders without keeping
    /// decoded tokens alive or querying Keychain from presentation code.
    private var storedCredentialSummaries: [UUID: StoredCredentialSummary] = [:]
    /// Latest successfully decoded live Claude refresh-chain digest. Keeping
    /// this beside the stored summaries lets row and switch policy stay pure
    /// and prevents SwiftUI/advisor recomputation from querying Keychain.
    private var liveClaudeRefreshChainFingerprint: String?
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
    private let claudeRotationRecoveryStore: ClaudeRotationRecoveryStoring
    private let codeSignatureStatus: ApplicationCodeSignatureStatus
    private let parser = UsageTextParser()
    private let identityExtractor = AccountIdentityExtractor()
    private let syncPlanner = CLIAccountSyncPlanner()
    private let codexLocalUsageReader = CodexLocalUsageReader()
    private let codexUsageService = CodexAccountUsageService()
    private let codexResetAttemptStore = CodexResetAttemptStore()
    private let codexResetAutomationPolicy = CodexResetAutomationPolicy()
    private let claudeCodeUsageReader = ClaudeCodeUsageReader()
    private let claudeRefreshCoordinator: ClaudeOAuthRefreshCoordinator
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
    private var switchFlights: [Provider: (
        id: UUID,
        profileID: UUID,
        automatic: Bool,
        task: Task<Bool, Never>
    )] = [:]
    /// Duplicate row Retry actions share one profile flight. Notification
    /// refreshes use a provider-scoped active-profile flight because their
    /// embedded profile id is intentionally stale and must be re-resolved when
    /// execution starts; joining a row flight would lose that semantic.
    private var retryFlights: [ClaudeSessionRetryFlightKey: (
        id: UUID,
        task: Task<RetryRefreshResult, Never>
    )] = [:]
    /// Backoff ledger for automatic recovery of inactive Claude accounts whose
    /// scheduled read was deferred pending rotation. Cleared on a successful
    /// snapshot or an explicit user Retry, which re-arms the next episode.
    private var scheduledClaudeRecoveryLedger:
        [UUID: ScheduledRotationRecoveryPolicy.AttemptRecord] = [:]
    /// Profiles the scheduled poll queued for automatic recovery. Drained by
    /// `refreshAll` only after the provider gate is released — an inline
    /// recovery would deadlock on the gate the poll itself holds.
    private var pendingScheduledClaudeRecoveries: [UUID] = []
    private let scheduledRotationRecoveryPolicy = ScheduledRotationRecoveryPolicy()
    /// A single read is enough when the provider-owned state has not changed
    /// since the last accepted observation. Only a newly observed key is
    /// followed by the delayed stability-confirmation read.
    private var acceptedStabilityKeys: [Provider: String] = [:]
    /// Ownership tokens prevent an old workflow's defer from releasing a gate
    /// that has already been deliberately handed off to a login watcher.
    private var credentialMutationsInProgress: [Provider: UUID] = [:]
    /// Covers the complete scheduled provider workflow, including the stable
    /// external observation that runs before the ordinary mutation gate is
    /// acquired. Explicit Claude retries wait for this marker to clear, then
    /// re-resolve their target instead of cancelling the scheduled read.
    private var scheduledCredentialReadsInProgress: Set<Provider> = []
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
    /// Whether the current active account was chosen by the user rather than
    /// an automatic switch. A manual park is only ever left via the depleted
    /// path, never a priority rebalance.
    private var activeWasManuallySelected: [Provider: Bool] = [:]
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
    private var usagePausedNotificationTasks: [UUID: Task<Void, Never>] = [:]
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
        claudeRotationRecoveryStore: ClaudeRotationRecoveryStoring = KeychainClaudeRotationRecoveryStore(),
        claudeRefreshCoordinator: ClaudeOAuthRefreshCoordinator = ClaudeOAuthRefreshCoordinator(),
        settings: SettingsStore? = nil,
        codeSignatureStatus: ApplicationCodeSignatureStatus = .unsupported
    ) throws {
        self.repository = repository
        self.cliSwitcher = cliSwitcher
        self.claudeRotationRecoveryStore = claudeRotationRecoveryStore
        self.claudeRefreshCoordinator = claudeRefreshCoordinator
        self.codeSignatureStatus = codeSignatureStatus
        self.claudeUsageService = ClaudeAccountUsageService(
            credentials: cliSwitcher,
            refreshCoordinator: claudeRefreshCoordinator,
            recoveryStore: claudeRotationRecoveryStore
        )
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
        refreshClaudeRecoveryStates()
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
        retryFlights.values.forEach { $0.task.cancel() }
        retryFlights.removeAll()
        usagePausedNotificationTasks.values.forEach { $0.cancel() }
        usagePausedNotificationTasks.removeAll()
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
        retryFlights.values.forEach { $0.task.cancel() }
        retryFlights.removeAll()
        usagePausedNotificationTasks.values.forEach { $0.cancel() }
        usagePausedNotificationTasks.removeAll()
        credentialMutationsInProgress.removeAll()
        scheduledCredentialReadsInProgress.removeAll()
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
                self?.recheckUsagePausedNotificationsAfterWake()
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
        let scheduledProviders = Set(Provider.allCases)
        scheduledCredentialReadsInProgress.formUnion(scheduledProviders)
        defer {
            scheduledCredentialReadsInProgress.subtract(scheduledProviders)
            isRefreshing = false
        }

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
        // Removing each read marker and taking its mutation gate are
        // synchronous on the main actor, so a queued Retry cannot enter the
        // gap between reconciliation and usage.
        scheduledCredentialReadsInProgress.remove(.claude)
        guard let claudeMutation = beginCredentialMutation(for: .claude) else {
            deferredFullRefresh = true
            return
        }
        await refreshClaudeUsage()
        finishCredentialMutation(for: .claude, owner: claudeMutation)
        await drainScheduledClaudeRecoveries()

        scheduledCredentialReadsInProgress.remove(.codex)
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
            .enumerated()
            .map { rank, profile in
                let session = accountSessionEvaluation(for: profile)
                return SwitchCandidate(
                    profileID: profile.id,
                    label: profile.label,
                    isActiveCLI: profile.isActiveCLI,
                    manualSwitchEligibility: session.manualSwitchEligibility,
                    automaticSwitchEligibility: session.automaticSwitchEligibility,
                    snapshot: snapshots[profile.id],
                    // Repository order doubles as the user's switch priority.
                    priorityRank: rank
                )
            }
    }

    func accountSessionEvaluation(
        for profile: AccountProfile,
        now: Date = Date()
    ) -> AccountSessionEvaluation {
        return AccountSessionPolicy.evaluate(
            provider: profile.provider,
            isActiveCLI: profile.isActiveCLI,
            wasPreviouslyLinked: snapshots[profile.id] != nil || profile.identity != nil,
            storedCredentials: storedCredentialAvailability(for: profile),
            sharesActiveCredentialChain: sharesActiveClaudeCredentialChain(for: profile),
            refreshState: refreshStates[profile.id] ?? .idle,
            loginExpiresAt: loginExpiresAt(for: profile),
            now: now
        )
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
        guard provider == .claude else {
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Refresh no longer needed",
                body: "This refresh action only applies to a paused Claude account."
            )
            return
        }
        func shouldQueuePausedRefresh(_ profile: AccountProfile) -> Bool {
            guard profile.provider == provider else { return false }
            switch refreshStates[profile.id] {
            case .rotationDeferred, .usagePaused, .credentialRepairRequired, .refreshing:
                return true
            default:
                return false
            }
        }
        // The embedded id is stale notification context only. Rotation always
        // re-resolves to the account that is active *now*; never consume an
        // inactive account's chain because it used to be active when the
        // notification was posted.
        _ = profileID
        guard let target = activeProfile(for: provider), shouldQueuePausedRefresh(target) else {
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Refresh no longer needed",
                body: "The paused \(provider.displayName) account was removed, switched, or has already recovered."
            )
            return
        }
        // Re-arm the paused nudge while the explicit intent waits behind any
        // scheduled read. The shared retry workflow re-resolves the resulting
        // state after it acquires the provider gate.
        notifiedUsagePaused.remove(target.id)
        let result = await retryRefresh(
            profileID: target.id,
            source: .notification
        )
        // The provider operation may have waited behind a login or switch. Its
        // execution path re-resolves the active paused profile after acquiring
        // the provider gate, so use the current label for the outcome too.
        let resolvedLabel = activeProfile(for: provider)?.label ?? target.label
        switch result {
        case .completed:
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Usage refreshed",
                body: "Updated \(resolvedLabel)."
            )
        case .needsLogin(let reason):
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Claude login needs renewal",
                body: reason
            )
        case .authorizationRequired(let reason), .deferred(let reason), .failed(let reason):
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Could not refresh \(resolvedLabel)",
                body: reason
            )
        case .noLongerAvailable:
            usageAlertController.handleNotificationSwitchOutcome(
                title: "Refresh no longer needed",
                body: "That account is no longer available or paused."
            )
        }
        updateSwitchAdvice()
        updateMenuBarSummary()
    }

    func performNotificationSwitch(provider: Provider, embeddedTargetID: UUID?) async {
        let candidates = switchCandidates(for: provider)
        let currentAdvice = switchAdvisor.advise(
            candidates: candidates,
            now: Date()
        )
        switchAdvice[provider] = currentAdvice
        let resolution = NotificationSwitchResolver().resolve(
            embeddedTargetID: embeddedTargetID,
            advice: currentAdvice,
            candidates: candidates
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

        // A rebalance leaves an account that still has quota, so it must not
        // undo a deliberate manual park — only depletion moves off of one.
        if advice.isRebalance, activeWasManuallySelected[provider] == true {
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

    /// Refresh-chain ownership cached for one usage cycle. Unrelated config or
    /// organization metadata can no longer make a shared chain look unique.
    private func claudeRotationContext() -> (live: String?, byProfile: [UUID: String]) {
        let byProfile = storedCredentialSummaries.compactMapValues(
            \.claudeRefreshChainFingerprint
        )
        return (liveClaudeRefreshChainFingerprint, byProfile)
    }

    /// Secret-free, cache-only shared-chain lookup used by row presentation
    /// and switch eligibility. If no live digest has been observed yet, the
    /// active profile's stored digest is the best pinned local generation.
    func sharesActiveClaudeCredentialChain(for profile: AccountProfile) -> Bool {
        guard profile.provider == .claude, !profile.isActiveCLI else {
            return false
        }
        let candidate = storedCredentialSummaries[profile.id]?
            .claudeRefreshChainFingerprint
        let activeStored = profiles.first(where: {
            $0.provider == .claude && $0.isActiveCLI
        }).flatMap { storedCredentialSummaries[$0.id]?.claudeRefreshChainFingerprint }
        return RotationProtectionPolicy.accountIsLiveElsewhere(
            profile: profile,
            among: profiles,
            storedChainFingerprint: candidate,
            liveChainFingerprint: liveClaudeRefreshChainFingerprint ?? activeStored
        )
    }

    /// Whether rotating `profile`'s refresh token in the background could
    /// invalidate a chain the live CLI login relies on.
    private func claudeAccountIsLiveElsewhere(
        _ profile: AccountProfile,
        context: (live: String?, byProfile: [UUID: String])
    ) -> Bool {
        RotationProtectionPolicy.accountIsLiveElsewhere(
            profile: profile,
            among: profiles,
            storedChainFingerprint: context.byProfile[profile.id],
            liveChainFingerprint: context.live
        )
    }

    /// Polls every Claude account through the usage API (active first, so its
    /// numbers land even if an inactive account's refresh stalls). The slow
    /// expect-probe of the CLI remains the fallback for the active account.
    private func refreshClaudeUsage() async {
        guard validateClaudeNativeConfiguration() else { return }
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
                if profile.isActiveCLI, let resolvedUsageCredentials {
                    liveClaudeRefreshChainFingerprint =
                        ClaudeRefreshChainFingerprint.make(
                            credentials: resolvedUsageCredentials
                        )
                }
                applySnapshot(snapshot, for: profile)
                clearUsagePaused(for: profile.id)
                scheduledClaudeRecoveryLedger[profile.id] = nil
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
                    if scheduledRotationRecoveryPolicy.shouldAttempt(
                        after: fetchError,
                        isActiveCLI: profile.isActiveCLI,
                        accountIsLiveElsewhere: liveElsewhere,
                        previous: scheduledClaudeRecoveryLedger[profile.id],
                        now: Date()
                    ) {
                        pendingScheduledClaudeRecoveries.append(profile.id)
                    }
                }
            }
        }
    }

    /// Runs at most one queued automatic recovery per eligible profile, after
    /// the scheduled read has released the provider gate (an inline recovery
    /// would deadlock on the gate `refreshAll` holds). Reuses the Retry
    /// workflow — same lease, journal, and sibling reconciliation — with the
    /// scheduled-recovery intent; a concurrent user click coalesces onto the
    /// same profile flight.
    private func drainScheduledClaudeRecoveries() async {
        let candidates = pendingScheduledClaudeRecoveries
        pendingScheduledClaudeRecoveries = []
        for profileID in candidates {
            // Re-resolve: a switch while this recovery was queued may have
            // made the profile the live login, which unattended work never
            // rotates.
            guard let profile = profiles.first(where: { $0.id == profileID }),
                  !profile.isActiveCLI else {
                continue
            }
            let attemptedAt = Date()
            let result = await retryRefresh(profileID: profileID, source: .scheduledRecovery)
            switch result {
            case .completed, .noLongerAvailable:
                scheduledClaudeRecoveryLedger[profileID] = nil
            case .needsLogin, .authorizationRequired, .deferred, .failed:
                let failures = (scheduledClaudeRecoveryLedger[profileID]?.consecutiveFailures ?? 0) + 1
                scheduledClaudeRecoveryLedger[profileID] = .init(
                    lastAttempt: attemptedAt,
                    consecutiveFailures: failures
                )
            }
        }
    }

    /// Sets a Claude profile's refresh state and maintains the "usage paused too
    /// long" nudge for the active account. A login stuck in a read-only
    /// rotation deferral (formerly `.usagePaused`)
    /// (access token expired while the CLI was idle) is healthy but silent, so
    /// after a threshold it earns one actionable notification.
    private func applyClaudeRefreshState(_ state: AccountRefreshState, for profile: AccountProfile) {
        refreshStates[profile.id] = state
        let now = Date()
        guard profile.isActiveCLI,
              isUsagePausedState(state),
              !isFixedClaudeLoginExpired(profile, now: now) else {
            clearUsagePaused(for: profile.id)
            return
        }
        let pausedSince = claudeUsagePausedSince[profile.id] ?? now
        claudeUsagePausedSince[profile.id] = pausedSince
        scheduleUsagePausedNotification(for: profile, pausedSince: pausedSince, now: now)
        deliverUsagePausedNotificationIfDue(for: profile, now: now)
    }

    private func isUsagePausedState(_ state: AccountRefreshState?) -> Bool {
        switch state {
        case .usagePaused, .rotationDeferred:
            return true
        default:
            return false
        }
    }

    private func scheduleUsagePausedNotification(
        for profile: AccountProfile,
        pausedSince: Date,
        now: Date
    ) {
        usagePausedNotificationTasks[profile.id]?.cancel()
        guard !notifiedUsagePaused.contains(profile.id) else {
            usagePausedNotificationTasks[profile.id] = nil
            return
        }
        let deadline = pausedSince.addingTimeInterval(usagePausedAlertPolicy.threshold)
        let delay = max(0, deadline.timeIntervalSince(now))
        usagePausedNotificationTasks[profile.id] = Task { @MainActor [weak self] in
            if delay > 0 {
                let capped = min(delay, Double(UInt64.max) / 1_000_000_000)
                try? await Task.sleep(
                    nanoseconds: UInt64(ceil(capped * 1_000_000_000))
                )
            }
            guard !Task.isCancelled, let self,
                  let current = self.profiles.first(where: { $0.id == profile.id }) else {
                return
            }
            guard current.isActiveCLI,
                  self.isUsagePausedState(self.refreshStates[current.id]),
                  !self.isFixedClaudeLoginExpired(current, now: Date()) else {
                self.clearUsagePaused(for: profile.id)
                return
            }
            self.deliverUsagePausedNotificationIfDue(for: current, now: Date())
            if !self.notifiedUsagePaused.contains(current.id),
               let pausedSince = self.claudeUsagePausedSince[current.id] {
                // A clock correction or scheduler's early wake must not lose
                // the reminder; re-arm from the actual deadline.
                self.scheduleUsagePausedNotification(
                    for: current,
                    pausedSince: pausedSince,
                    now: Date()
                )
            }
        }
    }

    private func deliverUsagePausedNotificationIfDue(
        for profile: AccountProfile,
        now: Date
    ) {
        guard !isFixedClaudeLoginExpired(profile, now: now) else {
            clearUsagePaused(for: profile.id)
            return
        }
        if usagePausedAlertPolicy.shouldNotify(
            pausedSince: claudeUsagePausedSince[profile.id],
            fixedLoginExpiresAt: loginExpiresAt(for: profile),
            storedCredentials: storedCredentialAvailability(for: profile),
            now: now,
            alreadyNotified: notifiedUsagePaused.contains(profile.id)
        ) {
            notifiedUsagePaused.insert(profile.id)
            usagePausedNotificationTasks[profile.id]?.cancel()
            usagePausedNotificationTasks[profile.id] = nil
            usageAlertController.handleUsagePausedStuck(profile: profile)
        }
    }

    private func recheckUsagePausedNotificationsAfterWake(now: Date = Date()) {
        for profile in profiles where profile.provider == .claude && profile.isActiveCLI {
            guard isUsagePausedState(refreshStates[profile.id]),
                  !isFixedClaudeLoginExpired(profile, now: now),
                  let pausedSince = claudeUsagePausedSince[profile.id] else {
                clearUsagePaused(for: profile.id)
                continue
            }
            deliverUsagePausedNotificationIfDue(for: profile, now: now)
            if !notifiedUsagePaused.contains(profile.id) {
                scheduleUsagePausedNotification(for: profile, pausedSince: pausedSince, now: now)
            }
        }
    }

    private func isFixedClaudeLoginExpired(
        _ profile: AccountProfile,
        now: Date
    ) -> Bool {
        profile.provider == .claude
            && storedCredentialAvailability(for: profile) == .available
            && loginExpiresAt(for: profile).map { now >= $0 } == true
    }

    private func clearUsagePaused(for profileID: UUID) {
        usagePausedNotificationTasks[profileID]?.cancel()
        usagePausedNotificationTasks[profileID] = nil
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
        case .interactiveRefreshRequired:
            return .rotationDeferred
        case .accountActiveElsewhere:
            return .switchRequired
        case .rotationDeferred(let underlying):
            if let coordinatorError = underlying as? ClaudeOAuthRefreshCoordinatorError {
                switch coordinatorError {
                case .busy:
                    return .rotationBusy
                case .leaseLost, .leaseReleased, .missingLease:
                    return .leaseLost
                case .ambiguousConfiguration, .unsafePath, .fileSystem:
                    return .rotationDeferred
                }
            }
            return .rotationDeferred
        case .credentialRepairRequired:
            return .repairRequired
        case .credentialRecoveryFailed:
            return .persistenceFailed
        case .unauthorized:
            return .unauthorized
        case .forbidden:
            return .forbidden
        case .refreshFailed(let underlying):
            if let coordinatorError = underlying as? ClaudeOAuthRefreshCoordinatorError {
                switch coordinatorError {
                case .busy:
                    return .rotationBusy
                case .leaseLost, .leaseReleased, .missingLease:
                    return .leaseLost
                case .ambiguousConfiguration, .unsafePath, .fileSystem:
                    return .rotationDeferred
                }
            }
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
            } catch {
                // A malformed or mismatched saved item is neither absent nor
                // evidence that its cached login expiry is trustworthy.
                storedSnapshotStatuses[profile.id] = .unreadable(
                    reason: "The saved credential snapshot could not be decoded. Relaunch the installed app or repair this saved login."
                )
                storedCredentialSummaries[profile.id] = nil
                if profile.provider == .claude {
                    claudeLoginExpirations[profile.id] = nil
                }
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
            } catch {
                storedSnapshotStatuses[profile.id] = .unreadable(
                    reason: "The saved credential snapshot could not be decoded. Relaunch the installed app or repair this saved login."
                )
                storedCredentialSummaries[profile.id] = nil
                if provider == .claude {
                    claudeLoginExpirations[profile.id] = nil
                }
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
        if provider == .claude {
            // Defense in depth for every capture/adoption call site: custom
            // Claude configurations must never be mapped onto the default
            // macOS Keychain service, even when an observation was supplied.
            try claudeRefreshCoordinator.validateSupportedConfiguration()
        }
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
                let storedRecord = ownershipPlan.storedRecords[active.id]
                let preserveStoredRecoveryOwner = try shouldPreserveStoredClaudeRecoveryOwner(
                    profile: active,
                    observation: observation,
                    storedRecord: storedRecord
                )
                let snapshot: CredentialSnapshot
                if preserveStoredRecoveryOwner, let storedRecord {
                    // The live item is proven to be the pinned pre-exchange
                    // generation while this stored owner advanced. Scheduled
                    // reconciliation stays read-only until explicit recovery
                    // repairs the split under the Claude lease.
                    snapshot = storedRecord.snapshot
                } else {
                    snapshot = try cliSwitcher.storeObservation(
                        observation,
                        for: active,
                        storedRecord: storedRecord
                    )
                }
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
            activeWasManuallySelected[provider] = true
        }
        updateMenuBarSummary()
        return active
    }

    private func shouldPreserveStoredClaudeRecoveryOwner(
        profile: AccountProfile,
        observation: LiveCredentialObservation,
        storedRecord: StoredCredentialRecord?
    ) throws -> Bool {
        guard profile.provider == .claude,
              let stored = storedRecord?.claudeOAuthCredentials,
              let live = try cliSwitcher.claudeOAuthCredentialRecord(
                  from: observation
              )?.credentials else {
            return false
        }
        return try claudeRotationRecoveryStore.loadAll(
            accessMode: .nonInteractive
        ).contains {
            $0.protectsStoredOwnerFromStaleLiveCapture(
                profileID: profile.id,
                stored: stored,
                live: live
            )
        }
    }

    private func reconcileStableExternalChange(provider: Provider, origin: AuthChangeOrigin) async {
        if provider == .claude, !validateClaudeNativeConfiguration() {
            return
        }
        // `refreshAll` owns the full provider read from its first stability
        // observation through usage. A file/auth event arriving in the
        // Claude-to-Codex gap must queue, not create a second reconciliation
        // flight that would make the scheduled usage phase defer itself.
        if origin != .scheduledRefresh,
           scheduledCredentialReadsInProgress.contains(provider) {
            deferredReconciliationOrigins[provider] = origin
            return
        }
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

    /// Acquires the provider's mutation gate only after scheduled observation
    /// has finished. Callers that support queuing (notably Retry and
    /// notification Refresh) wait and re-resolve current state; other callers
    /// receive an ordinary busy/deferred outcome without cancelling the read.
    private func beginCredentialMutation(for provider: Provider) -> UUID? {
        if provider == .claude {
            guard ClaudeSessionOperationAdmissionPolicy.allowsMutation(
                scheduledReadInProgress: scheduledCredentialReadsInProgress.contains(provider),
                reconciliationInProgress: reconciliationFlights[provider] != nil,
                mutationInProgress: credentialMutationsInProgress[provider] != nil
            ) else {
                return nil
            }
        } else {
            guard !scheduledCredentialReadsInProgress.contains(provider),
                  reconciliationFlights[provider] == nil,
                  credentialMutationsInProgress[provider] == nil else {
                return nil
            }
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

    /// Native Claude support deliberately targets Claude Code's default macOS
    /// configuration and Keychain service. Validate this before *reads* as
    /// well as mutations so a custom configuration can never be mistaken for
    /// or captured over the default login.
    @discardableResult
    private func validateClaudeNativeConfiguration() -> Bool {
        do {
            try claudeRefreshCoordinator.validateSupportedConfiguration()
            return true
        } catch {
            let reason = "\(error.localizedDescription) Limit Lifeboat supports Claude Code's default macOS configuration only. Unset CLAUDE_CONFIG_DIR, CLAUDE_SECURESTORAGE_CONFIG_DIR, and CLAUDE_CODE_CUSTOM_OAUTH_URL, then relaunch the app."
            for profile in profiles where profile.provider == .claude {
                refreshStates[profile.id] = .credentialAccessBlocked(
                    source: .claudeCode,
                    disposition: .unavailable,
                    reason: reason
                )
            }
            statusMessage = "Claude session handling paused: \(reason)"
            return false
        }
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
        guard validateClaudeNativeConfiguration() else {
            return .unavailable
        }
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
        case .unknown, .ready, .keychainLocked, .notFound:
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
                // A redemption leaves codexResetStates at .redeeming; its
                // terminal state must be applied on every exit from this
                // iteration — including the compare-and-swap retry (continue)
                // and any throw — and only after applySnapshot, which leaves a
                // busy state untouched. A defer satisfies both constraints.
                defer {
                    if let resetState = automaticReset.stateAfterApply {
                        codexResetStates[profile.id] = resetState
                    }
                }
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

            // No refreshed snapshot came back, but redeemReset still rotated
            // the refresh token during its verify-read and consume. Persist
            // that newest generation instead of the pre-redemption credentials
            // so a rotated-away token cannot force a re-login after a used
            // reset, matching the manual path and the failure handling below.
            var retainedUsage = usageResult
            retainedUsage.updatedAuthJSON = redemption.updatedAuthJSON

            if redemption.outcome.consumedReset {
                let reason = redemption.refreshFailureReason
                    ?? "Refresh usage before another reset can be used."
                statusMessage = "Used an earned reset for \(currentProfile.label). Refresh is required to confirm its new limits."
                return AutomaticCodexResetResolution(
                    usageResult: retainedUsage,
                    stateAfterApply: .refreshRequired(reason: reason)
                )
            }

            let reason = redemption.refreshFailureReason
                ?? "Codex did not return refreshed reset availability."
            statusMessage = reason
            return AutomaticCodexResetResolution(
                usageResult: retainedUsage,
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

    /// Moves an account one step within its provider's switch-priority order
    /// (repository order). Recomputes advice immediately so the hint and any
    /// rebalance react to the new ranking; the auto-switch backoffs still
    /// apply.
    func moveProfilePriority(_ profileID: UUID, up: Bool) {
        let reordered = AccountProfileOrdering.movingProfile(profileID, up: up, in: profiles)
        guard reordered.map(\.id) != profiles.map(\.id),
              let profile = profiles.first(where: { $0.id == profileID }) else {
            return
        }
        profiles = reordered
        persistProfiles()
        statusMessage = up
            ? "Moved \(profile.label) up in switch priority."
            : "Moved \(profile.label) down in switch priority."
        updateSwitchAdvice()
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

        Task { @MainActor [weak self] in
            await self?.removeProfileAfterConfirmation(
                profileID,
                expectedProfile: profile,
                mutationOwner: mutationOwner
            )
        }
    }

    private func removeProfileAfterConfirmation(
        _ profileID: UUID,
        expectedProfile profile: AccountProfile,
        mutationOwner: UUID
    ) async {
        defer {
            finishCredentialMutation(for: profile.provider, owner: mutationOwner)
        }
        guard profiles.contains(where: { $0.id == profileID }) else { return }

        let counter = CredentialKeychainIOCounter()
        let deleted = await CredentialAccess.counting(counter) { () async -> Bool in
            do {
                if profile.provider == .claude {
                    // Keep preparation, journal reconciliation, and snapshot
                    // deletion inside one cross-process lease. A prepared
                    // record may need this snapshot as its only surviving
                    // source of the fresh post-exchange generation.
                    try await claudeRefreshCoordinator.withLease { _ in
                        try claudeUsageService.performStoredProfileRemoval(
                            profile.id,
                            accessMode: .nonInteractive
                        ) {
                            try cliSwitcher.deleteStoredSnapshot(
                                for: profile,
                                accessMode: .nonInteractive
                            )
                        }
                    }
                } else {
                    try cliSwitcher.deleteStoredSnapshot(
                        for: profile,
                        accessMode: .nonInteractive
                    )
                }
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
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles.remove(at: index)
        snapshots[profile.id] = nil
        refreshStates[profile.id] = nil
        codexResetStates[profile.id] = nil
        lastAutomaticCodexResetAttempt[profile.id] = nil
        codexResetAttemptStore.removeAccount(profile.id)
        storedSnapshotStatuses[profile.id] = nil
        storedCredentialSummaries[profile.id] = nil
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
        usagePausedNotificationTasks[profile.id]?.cancel()
        usagePausedNotificationTasks[profile.id] = nil
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

    /// Switches the CLI to `profile`. Noninteractive notification and automatic
    /// paths skip confirmation dialogs and report problems via status or a
    /// follow-up notification. Returns whether the switch happened.
    @discardableResult
    func switchCLI(
        to profile: AccountProfile,
        interactive: Bool = true,
        automatic: Bool = false
    ) async -> Bool {
        if profile.provider == .claude,
           !validateClaudeNativeConfiguration() {
            return false
        }
        if let existing = switchFlights[profile.provider] {
            // Automatic work may never borrow the rotation authority of a
            // user-started flight, even when both currently name the same
            // target. Treat provider contention as a defer without starting
            // the one-hour failed-switch backoff.
            if automatic {
                deferredAutomaticSwitchProviders.insert(profile.provider)
                lastAutoSwitchAttempt[profile.provider] = nil
                statusMessage = "Automatic switch deferred while another credential operation is in progress."
                return false
            }

            // A row or notification click is a distinct user intent. If an
            // automatic read-only flight got there first, wait for it to end,
            // then reload the requested profile and run with user authority.
            // Joining the automatic task would silently discard permission to
            // rotate a target that requires renewal.
            if existing.automatic {
                _ = await existing.task.value
                if switchFlights[profile.provider]?.id == existing.id {
                    switchFlights[profile.provider] = nil
                }
                guard let current = profiles.first(where: { $0.id == profile.id }) else {
                    statusMessage = "That \(profile.provider.displayName) account is no longer available to switch to."
                    return false
                }
                if current.isActiveCLI {
                    return true
                }
                return await switchCLI(
                    to: current,
                    interactive: interactive,
                    automatic: false
                )
            }

            if existing.profileID == profile.id {
                return await existing.task.value
            }
            statusMessage = "A \(profile.provider.displayName) credential operation is already in progress."
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
        switchFlights[profile.provider] = (flightID, profile.id, automatic, task)
        let result = await task.value
        if switchFlights[profile.provider]?.id == flightID {
            switchFlights[profile.provider] = nil
        }
        if result, !automatic {
            // The switch transaction and its Claude lease have fully ended.
            // Post-switch verification is a separate scheduled/read-only
            // workflow and cannot inherit mutation authority.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await CredentialAccess.independentWorkflow {
                    await CredentialAccess.nonInteractive { await self.refreshAll() }
                }
            }
        }
        return result
    }

    private struct ClaudeLiveGenerationBaseline {
        var credentials: ClaudeOAuthCredentials?
        var itemLocation: ClaudeKeychainItemLocation?

        init(_ record: LiveClaudeOAuthCredentialRecord?) {
            credentials = record?.credentials
            itemLocation = record?.itemLocation
        }

        func matches(_ record: LiveClaudeOAuthCredentialRecord?) -> Bool {
            credentials == record?.credentials
                && itemLocation == record?.itemLocation
        }
    }

    private func performSwitchCLI(
        to profile: AccountProfile,
        interactive: Bool,
        automatic: Bool,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow?,
        claudeLeaseAcquired: Bool = false,
        allowUnverifiedTarget: Bool = false,
        preLeaseLiveGeneration: ClaudeLiveGenerationBaseline? = nil
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

        guard let storedCredentialWorkflow else { return false }
        let preLeaseTargetFingerprint = storedCredentialWorkflow
            .record(for: profile.id)?.summary.fingerprint
        let targetStoredRecord: StoredCredentialRecord?
        if profile.provider == .claude, claudeLeaseAcquired {
            // The target snapshot is not the only shared owner. Pin the live
            // generation immediately before acquiring the cross-process lock
            // and refuse to consume a target refresh token if Claude Code
            // advanced that generation while we waited.
            if let preLeaseLiveGeneration {
                do {
                    let currentLive = try cliSwitcher.liveClaudeOAuthCredentialRecord(
                        accessMode: .nonInteractive
                    )
                    guard preLeaseLiveGeneration.matches(currentLive) else {
                        let reason = "Claude Code changed its login while Limit Lifeboat waited for the shared credential lock. The newer login was left untouched; retry the switch."
                        refreshStates[profile.id] = .rotationDeferred(reason: reason)
                        statusMessage = "Switch deferred: \(reason)"
                        updateSwitchAdvice()
                        return false
                    }
                } catch {
                    let reason = "The live Claude generation could not be re-read safely under the shared credential lock: \(error.localizedDescription)"
                    refreshStates[profile.id] = isKeychainAccessDenied(error)
                        ? .authorizationRequired(source: .claudeCode, reason: reason)
                        : .rotationDeferred(reason: reason)
                    statusMessage = "Switch deferred: \(reason)"
                    updateSwitchAdvice()
                    return false
                }
            }
            // The pre-prompt workflow record is only an authorization and UI
            // preflight. Once the shared lease is held, reload its opaque
            // revision and fixed expiry so a CLI/login change that happened
            // while the user was deciding always wins.
            do {
                targetStoredRecord = try cliSwitcher.storedCredentialRecord(
                    for: profile,
                    accessMode: .nonInteractive
                )
                storedCredentialWorkflow.markLoaded(
                    targetStoredRecord,
                    for: profile.id
                )
                guard preLeaseTargetFingerprint
                    == targetStoredRecord?.summary.fingerprint else {
                    if let targetStoredRecord {
                        cacheStoredCredentialSummary(targetStoredRecord, for: profile)
                    } else {
                        cacheStoredCredentialSummary(nil, for: profile)
                    }
                    let reason = "The saved Claude generation changed while Limit Lifeboat waited for the shared credential lock. The newer generation was left untouched; retry the switch."
                    refreshStates[profile.id] = .rotationDeferred(reason: reason)
                    statusMessage = "Switch deferred: \(reason)"
                    updateSwitchAdvice()
                    return false
                }
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                refreshStates[profile.id] = .authorizationRequired(
                    source: .savedAccount,
                    reason: error.localizedDescription
                )
                statusMessage = "Switch stopped because the saved login could not be re-read under the Claude credential lock."
                return false
            } catch {
                storedSnapshotStatuses[profile.id] = .unreadable(
                    reason: "The saved credential snapshot could not be decoded. Relaunch the installed app or repair this saved login."
                )
                storedCredentialSummaries[profile.id] = nil
                claudeLoginExpirations[profile.id] = nil
                refreshStates[profile.id] = .credentialAccessBlocked(
                    source: .savedAccount,
                    disposition: .other(errSecDecode),
                    reason: error.localizedDescription
                )
                statusMessage = "Switch stopped because the saved Claude generation is unreadable: \(error.localizedDescription)"
                return false
            }
        } else {
            targetStoredRecord = storedCredentialWorkflow.record(for: profile.id)
        }
        guard let targetStoredRecord, targetStoredRecord.summary.isRestorable else {
            let reason = "No saved credentials are available. Log in once and the app will capture them automatically."
            refreshStates[profile.id] = .needsLogin(reason: reason)
            statusMessage = reason
            if !claudeLeaseAcquired {
                finishCurrentCredentialMutation(for: profile.provider)
                handleLoginRequired(
                    for: profile,
                    reason: reason,
                    interactive: interactive
                )
            }
            return false
        }

        // Re-evaluate against the freshly loaded record rather than the
        // popover/advisor cache. A notification can be hours old and an expiry
        // boundary can pass while the menu remains open.
        cacheStoredCredentialSummary(targetStoredRecord, for: profile)
        let switchSession = AccountSessionPolicy.evaluate(
            provider: profile.provider,
            isActiveCLI: profile.isActiveCLI,
            wasPreviouslyLinked: snapshots[profile.id] != nil || profile.identity != nil,
            storedCredentials: .available,
            refreshState: refreshStates[profile.id] ?? .idle,
            loginExpiresAt: targetStoredRecord.summary.claudeRefreshTokenExpiresAt,
            now: Date()
        )
        let switchEligibility = automatic
            ? switchSession.automaticSwitchEligibility
            : switchSession.manualSwitchEligibility
        guard switchEligibility.isEligible else {
            let reason = switchEligibility.blockerReason
                ?? "This saved login is not ready to switch."
            if profile.provider == .claude,
               targetStoredRecord.summary.claudeRefreshTokenExpiresAt.map({ Date() >= $0 }) == true {
                refreshStates[profile.id] = .needsLogin(reason: reason)
                statusMessage = reason
                if !claudeLeaseAcquired {
                    finishCurrentCredentialMutation(for: profile.provider)
                    handleLoginRequired(for: profile, reason: reason, interactive: interactive)
                }
            } else {
                if automatic {
                    deferredAutomaticSwitchProviders.insert(profile.provider)
                    lastAutoSwitchAttempt[profile.provider] = nil
                }
                statusMessage = automatic
                    ? "Automatic switch deferred: \(reason)"
                    : reason
            }
            updateSwitchAdvice()
            return false
        }

        if case .needsLogin(let reason) = refreshStates[profile.id] {
            statusMessage = reason
            if !claudeLeaseAcquired {
                finishCurrentCredentialMutation(for: profile.provider)
                handleLoginRequired(for: profile, reason: reason, interactive: interactive)
            }
            return false
        }

        var allowUnverifiedTarget = allowUnverifiedTarget
        let preflightIntent: ClaudeRotationIntent = claudeLeaseAcquired
            ? (automatic ? .automaticSwitch : .userInitiatedSwitch)
            : .scheduledReadOnly
        let preflightResult: SwitchPreflightResult
        if claudeLeaseAcquired,
           claudeUsageService.hasPendingCredentialRepair {
            preflightResult = .repairRequired(
                reason: "A fresh Claude credential generation still needs local repair. Retry the affected account before switching."
            )
        } else if claudeLeaseAcquired,
           allowUnverifiedTarget,
           preLeaseTargetFingerprint == targetStoredRecord.summary.fingerprint {
            // The user accepted skipping only the remote usage check. A
            // recovery journal may have appeared after that decision, so
            // local transaction state must still be resolved before restoring
            // this snapshot into Claude Code.
            do {
                let pendingRecovery = try claudeRotationRecoveryStore.loadAll(
                    accessMode: .nonInteractive
                ).contains { !$0.pendingDestinations.isEmpty }
                if pendingRecovery {
                    refreshClaudeRecoveryStates()
                    preflightResult = .repairRequired(
                        reason: "A fresh Claude credential generation is waiting for local reconciliation. Retry the affected account before switching."
                    )
                } else {
                    preflightResult = .ready
                }
            } catch {
                if let credentialError = error as? CredentialStoreError,
                   credentialError.isKeychainAccessDenied {
                    preflightResult = .authorizationRequired(
                        source: .savedAccount,
                        reason: "Authorize access to the encrypted Claude recovery journal before switching."
                    )
                } else {
                    preflightResult = .repairRequired(
                        reason: "Claude credential recovery could not be inspected safely: \(error.localizedDescription)"
                    )
                }
            }
        } else {
            preflightResult = await preflightSwitchTarget(
                profile,
                storedRecord: targetStoredRecord,
                storedCredentialWorkflow: storedCredentialWorkflow,
                rotationIntent: preflightIntent
            )
        }
        switch preflightResult {
        case .ready:
            break
        case .requiresLogin(let reason):
            refreshStates[profile.id] = .needsLogin(reason: reason)
            statusMessage = reason
            if !claudeLeaseAcquired {
                finishCurrentCredentialMutation(for: profile.provider)
                handleLoginRequired(for: profile, reason: reason, interactive: interactive)
            }
            updateSwitchAdvice()
            return false
        case .temporarilyUnavailable(let reason):
            refreshStates[profile.id] = .readFailed(reason: reason)
            updateSwitchAdvice()
            if claudeLeaseAcquired {
                statusMessage = "Switch stopped after the target changed during final verification: \(reason)"
                return false
            }
            if !interactive {
                if automatic {
                    statusMessage = "Automatic switch skipped: \(profile.label) could not be verified. \(reason)"
                    return false
                }
                // Clicking a notification is an explicit switch intent even
                // though it has no key window for a confirmation sheet. Match
                // the row's "Switch Anyway" behavior without granting this
                // authority to an automatic switch.
                allowUnverifiedTarget = true
                break
            }
            let alert = NSAlert()
            alert.messageText = "Could not verify \(profile.label)"
            alert.informativeText = "\(reason) You can switch anyway, but the CLI may ask you to log in."
            alert.addButton(withTitle: "Switch Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModalActivating() == .alertFirstButtonReturn else {
                return false
            }
            allowUnverifiedTarget = true
        case .forbidden(let reason):
            // A scope/administrator denial is not an expired credential and
            // must never consume a refresh token. Manual switching remains a
            // valid user choice. A notification click is also user initiated,
            // but has no key window for a modal, so it proceeds without the
            // remote usage check after surfacing the guidance in app state.
            refreshStates[profile.id] = .providerAccessForbidden(reason: reason)
            statusMessage = reason
            updateSwitchAdvice()
            guard !claudeLeaseAcquired, !automatic else {
                return false
            }
            if !interactive {
                allowUnverifiedTarget = true
                break
            }
            let alert = NSAlert()
            alert.messageText = "Claude usage access is denied for \(profile.label)"
            alert.informativeText = "\(reason) Switching will not renew its scope, but you can switch the CLI anyway."
            alert.addButton(withTitle: "Switch Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModalActivating() == .alertFirstButtonReturn else {
                return false
            }
            allowUnverifiedTarget = true
        case .repairRequired(let reason):
            refreshStates[profile.id] = .credentialRepairRequired(reason: reason)
            // The transaction may have left a different shared sibling as the
            // pending owner. Inventory the encrypted journal immediately so
            // that row also exposes Retry without waiting for a relaunch.
            refreshClaudeRecoveryStates()
            statusMessage = reason
            updateSwitchAdvice()
            return false
        case .authorizationRequired(let source, let reason):
            refreshStates[profile.id] = .authorizationRequired(
                source: source,
                reason: reason
            )
            statusMessage = reason
            updateSwitchAdvice()
            return false
        case .credentialAccessBlocked(let source, let disposition, let reason):
            refreshStates[profile.id] = .credentialAccessBlocked(
                source: source,
                disposition: disposition,
                reason: reason
            )
            statusMessage = reason
            updateSwitchAdvice()
            return false
        case .rotationRequired(let reason):
            if claudeLeaseAcquired {
                refreshStates[profile.id] = .rotationDeferred(reason: reason)
                if automatic {
                    deferredAutomaticSwitchProviders.insert(profile.provider)
                    // The final leased reread can discover a rotation need
                    // that the optimistic preflight did not. This is still a
                    // read-only skip, not a failed automatic switch.
                    lastAutoSwitchAttempt[profile.provider] = nil
                }
                statusMessage = automatic
                    ? "Automatic switch deferred: \(reason)"
                    : "Switch deferred after the credential generation changed: \(reason)"
                updateSwitchAdvice()
                return false
            }
            if automatic {
                refreshStates[profile.id] = .rotationDeferred(reason: reason)
                deferredAutomaticSwitchProviders.insert(profile.provider)
                // A busy/read-only target is a skip, not a failed switch. Let
                // the next ordinary advice cycle reconsider without backoff.
                lastAutoSwitchAttempt[profile.provider] = nil
                statusMessage = "Automatic switch deferred: \(reason)"
                updateSwitchAdvice()
                return false
            }
        }

        if !claudeLeaseAcquired,
           interactive, cliSwitcher.hasActiveProcesses(provider: profile.provider) {
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
        if !claudeLeaseAcquired, interactive, profile.provider == .claude {
            guard await authorizeClaudeKeychainAccess(
                reason: "before switching to \(profile.label)",
                allowDuringCredentialMutation: true
            ) else {
                return false
            }
        }

        // All prompt-capable work is complete. Claude's final target reread,
        // optional user-authorized rotation, outgoing capture, restore,
        // validation, and safe rollback share one uninterrupted cross-process
        // lease. Re-entering with the workflow avoids another Keychain prompt.
        if profile.provider == .claude, !claudeLeaseAcquired {
            let acceptedUnverifiedTarget = allowUnverifiedTarget
            let liveGenerationBaseline: ClaudeLiveGenerationBaseline
            do {
                liveGenerationBaseline = ClaudeLiveGenerationBaseline(
                    try cliSwitcher.liveClaudeOAuthCredentialRecord(
                        accessMode: .nonInteractive
                    )
                )
            } catch {
                let reason = "The current Claude login could not be pinned before switching: \(error.localizedDescription)"
                refreshStates[profile.id] = isKeychainAccessDenied(error)
                    ? .authorizationRequired(source: .claudeCode, reason: reason)
                    : .rotationDeferred(reason: reason)
                statusMessage = "Switch deferred: \(reason)"
                updateSwitchAdvice()
                return false
            }
            do {
                let switched = try await claudeRefreshCoordinator.withLease(retrying: !automatic) { _ in
                    await self.performSwitchCLI(
                        to: profile,
                        // Any final failure UI is presented by the outer frame
                        // only after this closure releases both Claude locks.
                        interactive: false,
                        automatic: automatic,
                        storedCredentialWorkflow: storedCredentialWorkflow,
                        claudeLeaseAcquired: true,
                        allowUnverifiedTarget: acceptedUnverifiedTarget,
                        preLeaseLiveGeneration: liveGenerationBaseline
                    )
                }
                if !switched, interactive {
                    if case .needsLogin(let reason) = refreshStates[profile.id] {
                        // A terminal login may launch a provider process. Drop
                        // the app gate as well as the cross-process lease first.
                        finishCurrentCredentialMutation(for: profile.provider)
                        handleLoginRequired(
                            for: profile,
                            reason: reason,
                            interactive: true
                        )
                    } else if !statusMessage.isEmpty {
                        showError(
                            message: "Could not switch to \(profile.label)",
                            details: statusMessage
                        )
                    }
                }
                return switched
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                refreshStates[profile.id] = .rotationDeferred(reason: error.localizedDescription)
                recordClaudeCredentialOutcome(
                    Self.credentialOutcome(for: .rotationDeferred(error)),
                    for: profile,
                    codePath: automatic ? "automaticSwitch" : "userSwitch"
                )
                if automatic {
                    deferredAutomaticSwitchProviders.insert(profile.provider)
                    lastAutoSwitchAttempt[profile.provider] = nil
                }
                statusMessage = automatic
                    ? "Automatic switch deferred: \(error.localizedDescription)"
                    : "Switch deferred: \(error.localizedDescription)"
                updateSwitchAdvice()
                return false
            } catch {
                refreshStates[profile.id] = .rotationDeferred(reason: error.localizedDescription)
                statusMessage = "Switch deferred: \(error.localizedDescription)"
                updateSwitchAdvice()
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
                    origin: automatic ? .automaticSwitch : .manualSwitch,
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

        let finalTargetRecord: StoredCredentialRecord
        if profile.provider == .claude {
            do {
                guard let latest = try cliSwitcher.storedCredentialRecord(
                    for: profile,
                    accessMode: .nonInteractive
                ), latest.summary.isRestorable else {
                    let reason = "The saved Claude login disappeared before it could be restored. Log in again."
                    refreshStates[profile.id] = .needsLogin(reason: reason)
                    statusMessage = reason
                    return false
                }
                storedCredentialWorkflow.markLoaded(latest, for: profile.id)
                cacheStoredCredentialSummary(latest, for: profile)
                let finalSession = AccountSessionPolicy.evaluate(
                    provider: .claude,
                    isActiveCLI: profile.isActiveCLI,
                    wasPreviouslyLinked: snapshots[profile.id] != nil || profile.identity != nil,
                    storedCredentials: .available,
                    sharesActiveCredentialChain: sharesActiveClaudeCredentialChain(for: profile),
                    refreshState: refreshStates[profile.id] ?? .idle,
                    loginExpiresAt: latest.summary.claudeRefreshTokenExpiresAt,
                    now: Date()
                )
                let finalEligibility = automatic
                    ? finalSession.automaticSwitchEligibility
                    : finalSession.manualSwitchEligibility
                guard finalEligibility.isEligible else {
                    let reason = finalEligibility.blockerReason
                        ?? "This Claude login is no longer eligible to switch."
                    if latest.summary.claudeRefreshTokenExpiresAt
                        .map({ Date() >= $0 }) == true {
                        refreshStates[profile.id] = .needsLogin(reason: reason)
                    }
                    statusMessage = reason
                    return false
                }
                finalTargetRecord = latest
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                refreshStates[profile.id] = .authorizationRequired(
                    source: .savedAccount,
                    reason: error.localizedDescription
                )
                statusMessage = "The saved Claude login could not be re-read immediately before switching."
                return false
            } catch {
                refreshStates[profile.id] = .credentialAccessBlocked(
                    source: .savedAccount,
                    disposition: .other(errSecDecode),
                    reason: error.localizedDescription
                )
                statusMessage = "The saved Claude login became unreadable before switching: \(error.localizedDescription)"
                return false
            }
        } else {
            finalTargetRecord = storedCredentialWorkflow.record(for: profile.id)
                ?? targetStoredRecord
        }

        let outgoingProfileID = activeProfile(for: profile.provider)?.id
        do {
            let result = try cliSwitcher.restoreSnapshot(
                for: profile,
                storedRecord: finalTargetRecord,
                expectedLiveFingerprint: outgoingObservation.credentialFingerprint,
                enforceExpectedLiveState: true
            )
            let verified = result.verifiedObservation
            _ = try reconcileLiveCredentials(
                provider: profile.provider,
                origin: automatic ? .automaticSwitch : .manualSwitch,
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
                        interactive: !automatic
                    )
                )
            } catch {
                AppLog.history.error("Could not record the switch event: \(error.localizedDescription, privacy: .public)")
            }
            refreshStates[profile.id] = .ok
            activeWasManuallySelected[profile.provider] = !automatic
            if !automatic {
                lastManualSwitchAt[profile.provider] = Date()
            }
            return true
        } catch {
            AppLog.switching.error("Switch to account \(profile.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let storeError = error as? CredentialStoreError, case .decodeFailed = storeError {
                // Malformed credential material is fail-closed. Never delete
                // the only saved login as an error-recovery side effect; the
                // user must explicitly recreate the provider login or remove
                // the account after deciding the old snapshot is expendable.
                refreshStates[profile.id] = .credentialAccessBlocked(
                    source: .savedAccount,
                    disposition: .other(errSecDecode),
                    reason: "The saved credential snapshot is unreadable and was left unchanged. Relaunch the installed app or repair this saved login."
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
        case forbidden(reason: String)
        case repairRequired(reason: String)
        case authorizationRequired(
            source: CredentialAuthorizationSource,
            reason: String
        )
        case credentialAccessBlocked(
            source: CredentialAuthorizationSource,
            disposition: CredentialAccessDisposition,
            reason: String
        )
        case rotationRequired(reason: String)
    }

    private func preflightSwitchTarget(
        _ profile: AccountProfile,
        storedRecord: StoredCredentialRecord,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow,
        rotationIntent: ClaudeRotationIntent
    ) async -> SwitchPreflightResult {
        switch profile.provider {
        case .claude:
            do {
                let staleChain = storedRecord.summary.claudeRefreshChainFingerprint
                let additionalDestinations = rotationIntent.allowsCredentialRotation
                    ? try additionalClaudeRecoveryDestinations(
                        staleChainFingerprint: staleChain,
                        targetProfileID: profile.id,
                        storedCredentialWorkflow: storedCredentialWorkflow
                    )
                    : []
                let result = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    storedRecord: storedRecord,
                    accessMode: CredentialAccess.currentMode,
                    rotationIntent: rotationIntent,
                    additionalRecoveryDestinations: additionalDestinations
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
                if rotationIntent.allowsCredentialRotation,
                   claudeOAuthGenerationAdvanced(
                    from: storedRecord.claudeOAuthCredentials,
                    to: result.credentials
                   ) {
                    do {
                        try reconcileClaudeChainOwners(
                            additionalDestinations,
                            staleChainFingerprint: staleChain,
                            freshCredentials: result.credentials,
                            storedCredentialWorkflow: storedCredentialWorkflow
                        )
                    } catch {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            error
                        )
                    }
                }
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
                if case .rotationDeferred(let reason) = outcome.state {
                    return .rotationRequired(reason: reason)
                }
                if case .switchRequired(let reason) = outcome.state {
                    return .rotationRequired(reason: reason)
                }
                if case .providerAccessForbidden(let reason) = outcome.state {
                    return .forbidden(reason: reason)
                }
                if case .credentialRepairRequired(let reason) = outcome.state {
                    return .repairRequired(reason: reason)
                }
                if case .authorizationRequired(let source, let reason) = outcome.state {
                    return .authorizationRequired(source: source, reason: reason)
                }
                if case .credentialAccessBlocked(
                    let source,
                    let disposition,
                    let reason
                ) = outcome.state {
                    return .credentialAccessBlocked(
                        source: source,
                        disposition: disposition,
                        reason: reason
                    )
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

    /// The sole prompt-capable path for Claude's provider-owned item. It uses
    /// Claude Code's own `/usr/bin/security` storage identity; choosing Always
    /// Allow authorizes that shared backend for Conductor, Terminal, IDE
    /// integrations, and Limit Lifeboat together. A fresh noninteractive
    /// exact-item read is the only success condition.
    @discardableResult
    func authorizeClaudeKeychainAccess(
        reason: String = "to stop repeated password prompts",
        allowDuringCredentialMutation: Bool = false
    ) async -> Bool {
        guard validateClaudeNativeConfiguration() else { return false }
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
                case .keychainLocked:
                    workflowStatus = "keychain_locked"
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
        explanation.messageText = "Authorize Claude credential access once"
        explanation.informativeText = "macOS will ask for your login password \(reason). The system prompt names “security” because Limit Lifeboat now uses Claude Code’s own credential helper. Enter your password once, then choose Always Allow. Choosing only Allow will not stop future prompts."
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
            statusMessage = "Claude Keychain access authorized. Future background checks will not ask for your password."
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

    /// Explicitly unlocks this app's encrypted snapshot for one profile. This
    /// is separate from authorizing Claude Code's provider-owned item: each
    /// Keychain owner has an independent ACL and remediation path.
    @discardableResult
    func authorizeStoredCredentialAccess(for profile: AccountProfile) async -> Bool {
        guard let owner = beginCredentialMutation(for: profile.provider) else {
            statusMessage = "Wait for the current credential operation to finish, then authorize this saved login."
            return false
        }
        defer { finishCredentialMutation(for: profile.provider, owner: owner) }

        let counter = CredentialKeychainIOCounter()
        return await CredentialAccess.counting(counter) {
            defer {
                logCredentialWorkflow(
                    workflow: "authorize_saved_snapshot",
                    provider: profile.provider,
                    origin: "explicit_action",
                    access: "mixed",
                    status: storedSnapshotStatuses[profile.id] == .present
                        ? "ready"
                        : "needs_authorization",
                    counts: counter.snapshot
                )
            }
            do {
                let interactiveRecord = try CredentialAccess.userInitiated(
                    reason: "authorize Limit Lifeboat for \(profile.label)'s saved login",
                    operation: {
                        try cliSwitcher.storedCredentialRecord(
                            for: profile,
                            accessMode: .userInitiated
                        )
                    }
                )
                if profile.provider == .claude {
                    // Recovery entries are separate app-owned Keychain items.
                    // The saved-login action authorizes both surfaces so a
                    // journal denial never points at a button that only opens
                    // the profile snapshot.
                    _ = try CredentialAccess.userInitiated(
                        reason: "authorize Limit Lifeboat for Claude credential recovery",
                        operation: {
                            try claudeRotationRecoveryStore.loadAll(
                                accessMode: .userInitiated
                            )
                        }
                    )
                }
                guard interactiveRecord != nil else {
                    storedSnapshotStatuses[profile.id] = .absent
                    storedCredentialSummaries[profile.id] = nil
                    if profile.provider == .claude {
                        claudeLoginExpirations[profile.id] = nil
                    }
                    statusMessage = "No saved login exists for \(profile.label)."
                    return false
                }

                // A one-time Allow is not durable. Prove a fresh background
                // context can read the exact snapshot before declaring success.
                guard let verified = try await CredentialAccess.nonInteractive(operation: {
                    try cliSwitcher.storedCredentialRecord(
                        for: profile,
                        accessMode: .nonInteractive
                    )
                }) else {
                    storedSnapshotStatuses[profile.id] = .absent
                    storedCredentialSummaries[profile.id] = nil
                    if profile.provider == .claude {
                        claudeLoginExpirations[profile.id] = nil
                    }
                    return false
                }
                if profile.provider == .claude {
                    _ = try await CredentialAccess.nonInteractive(operation: {
                        try claudeRotationRecoveryStore.loadAll(
                            accessMode: .nonInteractive
                        )
                    })
                }
                cacheStoredCredentialSummary(verified, for: profile)
                if profile.provider == .claude {
                    refreshClaudeRecoveryStates()
                }
                statusMessage = "Saved login access authorized for \(profile.label)."
                return true
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedSnapshotStatuses[profile.id] = .locked
                statusMessage = error.credentialAccessDisposition == .userCancelled
                    ? "Saved login authorization cancelled."
                    : "Access was allowed once but was not saved. Choose Always Allow when you retry."
                return false
            } catch {
                let reason = "The saved credential snapshot is unreadable. Relaunch the installed app or repair this saved login."
                storedSnapshotStatuses[profile.id] = .unreadable(reason: reason)
                storedCredentialSummaries[profile.id] = nil
                claudeLoginExpirations[profile.id] = nil
                refreshStates[profile.id] = .credentialAccessBlocked(
                    source: .savedAccount,
                    disposition: .other(errSecDecode),
                    reason: reason
                )
                statusMessage = "Could not authorize \(profile.label): \(error.localizedDescription)"
                showError(
                    message: "Saved login access failed",
                    details: error.localizedDescription
                )
                return false
            }
        }
    }

    private func recordSuccessfulClaudeKeychainRead(_ observation: LiveCredentialObservation) {
        liveClaudeRefreshChainFingerprint = observation.claudeRefreshChainFingerprint
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
                if isKeychainAccessDenied(error) {
                    statusMessage = "The Claude credential changed again. Authorize the new item before linking it."
                } else {
                    pendingClaudeLoginCompletion = nil
                    statusMessage = "Could not resume the Claude login watcher: \(error.localizedDescription)"
                }
            }
        case .authorizationRequired(let source):
            if source == .claudeCode {
                statusMessage = "The Claude credential changed again. Authorize the new item before linking it."
            } else {
                pendingClaudeLoginCompletion = nil
            }
        case .failed:
            pendingClaudeLoginCompletion = nil
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
        if transientClaudeKeychainFailure(in: error) == .itemChanged {
            // A concurrent Claude login or helper write invalidates the old
            // generation, including any denial attached to it. Re-resolve on
            // the next cycle instead of permanently suppressing background
            // work as a generic failure.
            claudeKeychainAuthorizationState = .unknown
            return
        }
        if transientClaudeKeychainFailure(in: error) == .keychainLocked {
            // Do not let a wake/unlock boundary poison this item generation as
            // an authorization denial. A known ACL denial remains sticky, but
            // every other state may retry through the prompt-free metadata
            // and ACL gate on a later background cycle.
            if case .needsAuthorization = claudeKeychainAuthorizationState {
                return
            }
            claudeKeychainAuthorizationState = .keychainLocked(item)
            return
        }
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

    private enum TransientClaudeKeychainFailure: Equatable {
        case itemChanged
        case keychainLocked
    }

    /// Restore, refresh, and usage workflows preserve their root cause inside
    /// typed wrapper errors. Unwrap only the two transient provider-Keychain
    /// outcomes that must not become a sticky authorization denial. The depth
    /// bound also protects this UI-state path from a pathological custom Error
    /// that wraps itself.
    private func transientClaudeKeychainFailure(
        in error: Error,
        depth: Int = 0
    ) -> TransientClaudeKeychainFailure? {
        guard depth < 12 else { return nil }
        let nextDepth = depth + 1

        if let keychainError = error as? ClaudeCodeCredentialsKeychainError {
            switch keychainError {
            case .securityToolError(.itemChanged):
                return .itemChanged
            case .securityToolError(.keychainLocked):
                return .keychainLocked
            case .credentialAccessUnavailable(let underlying):
                return transientClaudeKeychainFailure(
                    in: underlying,
                    depth: nextDepth
                )
            default:
                return nil
            }
        }

        if let switchError = error as? CLISwitcherError {
            switch switchError {
            case .backupFailed(_, let underlying),
                 .rollbackConflict(_, _, let underlying, _):
                return transientClaudeKeychainFailure(
                    in: underlying,
                    depth: nextDepth
                )
            default:
                return nil
            }
        }

        if let fetchError = error as? ClaudeAccountUsageFetchError {
            switch fetchError {
            case .keychainLocked:
                return .keychainLocked
            case .liveCredentialAccessDenied(let underlying, _):
                return transientClaudeKeychainFailure(
                    in: underlying,
                    depth: nextDepth
                )
            case .rotationDeferred(let underlying),
                 .credentialRepairRequired(let underlying),
                 .credentialRecoveryFailed(let underlying),
                 .credentialUnavailable(let underlying),
                 .refreshFailed(let underlying),
                 .transport(let underlying):
                return transientClaudeKeychainFailure(
                    in: underlying,
                    depth: nextDepth
                )
            default:
                return nil
            }
        }

        if let storeError = error as? CredentialStoreError {
            switch storeError {
            case .credentialAccessUnavailable(let underlying):
                return transientClaudeKeychainFailure(
                    in: underlying,
                    depth: nextDepth
                )
            case .decodeFailed(let underlying?):
                return transientClaudeKeychainFailure(
                    in: underlying,
                    depth: nextDepth
                )
            default:
                return nil
            }
        }

        return nil
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

    /// A post-login recovery-journal cleanup error that does not mean the saved
    /// login itself needs repair: shared-lock contention (another process is
    /// mid-refresh) or a transient Keychain denial. The login already
    /// succeeded and the cleanup retries on the next refresh, so these must not
    /// downgrade a healthy row to "needs repair".
    private func loginRecoveryCleanupIsTransient(_ error: Error) -> Bool {
        error is ClaudeOAuthRefreshCoordinatorError || isKeychainAccessDenied(error)
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
        if profile.provider == .claude,
           !validateClaudeNativeConfiguration() {
            return
        }
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
        case unreadable(reason: String)
    }

    func storedSnapshotStatus(for profile: AccountProfile) -> StoredSnapshotStatus {
        storedSnapshotStatuses[profile.id] ?? .absent
    }

    func storedCredentialAvailability(
        for profile: AccountProfile
    ) -> StoredCredentialAvailability {
        switch storedSnapshotStatus(for: profile) {
        case .present:
            return .available
        case .absent:
            return .missing
        case .locked:
            return .authorizationRequired(source: .savedAccount)
        case .unreadable(let reason):
            return .accessBlocked(
                source: .savedAccount,
                disposition: .other(errSecDecode),
                reason: reason
            )
        }
    }

    func loginExpiresAt(for profile: AccountProfile) -> Date? {
        guard profile.provider == .claude else { return nil }
        return claudeLoginExpirations[profile.id]
    }

    private func refreshStoredSnapshotStatuses() {
        var statuses: [UUID: StoredSnapshotStatus] = [:]
        var expirations: [UUID: Date] = [:]
        var summaries: [UUID: StoredCredentialSummary] = [:]
        for provider in Provider.allCases {
            let counter = CredentialKeychainIOCounter()
            var providerLocked = false
            CredentialAccess.counting(counter) {
                for profile in profiles where profile.provider == provider {
                    do {
                        if let record = try cliSwitcher.storedCredentialRecord(for: profile) {
                            summaries[profile.id] = record.summary
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
                        statuses[profile.id] = .unreadable(
                            reason: "The saved credential snapshot could not be decoded. Relaunch the installed app or repair this saved login."
                        )
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
        storedCredentialSummaries = summaries
        claudeLoginExpirations = expirations
    }

    /// Recovery journal inventory is read-only at launch. Pending owners are
    /// surfaced as repairable—not expired—and the next explicit Retry/switch
    /// performs reconciliation under the cross-process lease.
    private func refreshClaudeRecoveryStates() {
        do {
            let records = try claudeRotationRecoveryStore.loadAll(
                accessMode: .nonInteractive
            )
            for record in records {
                for destination in record.pendingDestinations {
                    let profileID: UUID?
                    switch destination {
                    case .storedProfile(let id):
                        profileID = id
                    case .liveClaudeCode:
                        profileID = profiles.first(where: {
                            $0.provider == .claude && $0.isActiveCLI
                        })?.id
                    }
                    guard let profileID,
                          profiles.contains(where: { $0.id == profileID }) else {
                        continue
                    }
                    refreshStates[profileID] = .credentialRepairRequired(
                        reason: record.isPrepared
                            ? "A prepared Claude credential transaction needs local reconciliation before another refresh."
                            : "A fresh Claude login generation is safely journaled and needs local reconciliation."
                    )
                }
            }
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            for profile in profiles where profile.provider == .claude {
                refreshStates[profile.id] = .authorizationRequired(
                    source: .savedAccount,
                    reason: "Authorize access to the encrypted Claude recovery journal."
                )
                storedSnapshotStatuses[profile.id] = .locked
            }
        } catch {
            for profile in profiles where profile.provider == .claude {
                refreshStates[profile.id] = .credentialRepairRequired(
                    reason: "The encrypted Claude recovery journal could not be inspected. Relaunch the installed app, then Retry."
                )
            }
        }
    }

    private func cacheStoredSnapshotSummary(_ snapshot: CredentialSnapshot, for profile: AccountProfile) {
        storedSnapshotStatuses[profile.id] = .present
        storedCredentialSummaries[profile.id] = cliSwitcher.makeStoredCredentialRecord(
            from: snapshot
        ).summary
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
        storedCredentialSummaries[profile.id] = record?.summary
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

    private func claudeOAuthGenerationAdvanced(
        from old: ClaudeOAuthCredentials?,
        to fresh: ClaudeOAuthCredentials
    ) -> Bool {
        guard let old else { return true }
        return old.accessToken != fresh.accessToken
            || old.refreshToken != fresh.refreshToken
            || old.expiresAt != fresh.expiresAt
            || old.refreshTokenExpiresAt != fresh.refreshTokenExpiresAt
    }

    /// Resolves every local owner that still holds the target's old refresh
    /// chain before a token exchange. The returned destinations are included
    /// in the encrypted checkpoint *before* the irreversible request.
    private func additionalClaudeRecoveryDestinations(
        staleChainFingerprint: String?,
        targetProfileID: UUID,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow?
    ) throws -> Set<ClaudeRotationRecoveryDestination> {
        guard let staleChainFingerprint else { return [] }
        _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()

        var destinations: Set<ClaudeRotationRecoveryDestination> = []
        for sibling in profiles where sibling.provider == .claude
            && sibling.id != targetProfileID {
            let siblingRecord: StoredCredentialRecord?
            do {
                // Never use the pre-prompt workflow cache here. Owner
                // discovery is part of the credential transaction and every
                // sibling revision must be re-read after the lease is held.
                siblingRecord = try cliSwitcher.storedCredentialRecord(
                    for: sibling,
                    accessMode: .nonInteractive
                )
                storedCredentialWorkflow?.markLoaded(
                    siblingRecord,
                    for: sibling.id
                )
                cacheStoredCredentialSummary(siblingRecord, for: sibling)
            } catch let error as CredentialStoreError
                where error.isKeychainAccessDenied {
                storedSnapshotStatuses[sibling.id] = .locked
                refreshStates[sibling.id] = .authorizationRequired(
                    source: .savedAccount,
                    reason: error.localizedDescription
                )
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                // An unreadable owner may share the single-use chain. Cached
                // digests cannot prove otherwise, so fail closed before the
                // exchange instead of risking a stranded sibling.
                let reason = "A saved Claude sibling could not be re-read under the shared credential lock: \(error.localizedDescription)"
                storedSnapshotStatuses[sibling.id] = .unreadable(reason: reason)
                storedCredentialSummaries[sibling.id] = nil
                claudeLoginExpirations[sibling.id] = nil
                refreshStates[sibling.id] = .credentialAccessBlocked(
                    source: .savedAccount,
                    disposition: .other(errSecDecode),
                    reason: reason
                )
                throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
            }
            if siblingRecord?.summary.claudeRefreshChainFingerprint
                == staleChainFingerprint {
                destinations.insert(.storedProfile(sibling.id))
            }
        }

        do {
            if let live = try cliSwitcher.liveClaudeOAuthCredentialRecord(
                accessMode: .nonInteractive
            ) {
                let liveChain = ClaudeRefreshChainFingerprint.make(
                    credentials: live.credentials
                )
                liveClaudeRefreshChainFingerprint = liveChain
                if liveChain == staleChainFingerprint {
                    destinations.insert(.liveClaudeCode)
                }
            }
        } catch let error as ClaudeCodeCredentialsKeychainError
            where error.isKeychainAccessDenied {
            recordClaudeKeychainFailure(error)
            throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                error: error,
                item: nil
            )
        } catch {
            throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
        }
        return destinations
    }

    /// Reloads every sibling after the service's leased transaction so the
    /// switch workflow and presentation caches follow the committed owners.
    /// The service is the sole writer: repeating its merge here would lack the
    /// journal's pre-exchange generation baseline and could overwrite a newer
    /// access-token generation that retained the same refresh token.
    private func reconcileClaudeChainOwners(
        _ destinations: Set<ClaudeRotationRecoveryDestination>,
        staleChainFingerprint: String?,
        freshCredentials: ClaudeOAuthCredentials,
        storedCredentialWorkflow: SwitchStoredCredentialWorkflow?
    ) throws {
        guard let staleChainFingerprint, !destinations.isEmpty else { return }
        _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
        var failedProfiles: [UUID] = []
        var liveFailed = false

        for destination in destinations {
            do {
                switch destination {
                case .liveClaudeCode:
                    guard let current = try cliSwitcher.liveClaudeOAuthCredentialRecord(
                        accessMode: .nonInteractive
                    ) else {
                        throw ClaudeCredentialRepairRequiredError(
                            reason: "The live Claude Code credential disappeared while reconciling a rotated chain."
                        )
                    }
                    let currentChain = ClaudeRefreshChainFingerprint.make(
                        credentials: current.credentials
                    )
                    guard claudeRotatedFieldsMatch(
                        current.credentials,
                        freshCredentials
                    ) || currentChain != staleChainFingerprint else {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "The live Claude Code owner is still on the stale generation after credential reconciliation."
                            )
                        )
                    }
                    // Matching fresh fields are committed. A different chain
                    // is a superseding external login and wins untouched.
                    liveClaudeRefreshChainFingerprint = currentChain
                    bestEffortCompleteClaudeRecoveryDestination(
                        destination,
                        staleChainFingerprint: staleChainFingerprint,
                        freshCredentials: freshCredentials
                    )

                case .storedProfile(let profileID):
                    guard let sibling = profiles.first(where: {
                        $0.id == profileID && $0.provider == .claude
                    }), let current = try cliSwitcher.storedCredentialRecord(
                        for: sibling,
                        accessMode: .nonInteractive
                    ), let currentCredentials = current.claudeOAuthCredentials else {
                        throw ClaudeCredentialRepairRequiredError(
                            reason: "A saved sibling credential is unavailable for rotated-chain reconciliation."
                        )
                    }
                    let currentChain = current.summary.claudeRefreshChainFingerprint
                    guard claudeRotatedFieldsMatch(
                        currentCredentials,
                        freshCredentials
                    ) || currentChain != staleChainFingerprint else {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "A saved Claude sibling is still on the stale generation after credential reconciliation."
                            )
                        )
                    }
                    storedCredentialWorkflow?.markLoaded(
                        current,
                        for: profileID
                    )
                    cacheStoredCredentialSummary(current, for: sibling)
                    bestEffortCompleteClaudeRecoveryDestination(
                        destination,
                        staleChainFingerprint: staleChainFingerprint,
                        freshCredentials: freshCredentials
                    )
                }
            } catch {
                switch destination {
                case .liveClaudeCode:
                    liveFailed = true
                case .storedProfile(let profileID):
                    failedProfiles.append(profileID)
                    refreshStates[profileID] = .credentialRepairRequired(
                        reason: error.localizedDescription
                    )
                }
            }
        }

        if liveFailed || !failedProfiles.isEmpty {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude's fresh credential is safely journaled, but one or more shared local owners still need repair. Retry without signing in again."
                )
            )
        }
    }

    private func claudeRotatedFieldsMatch(
        _ lhs: ClaudeOAuthCredentials,
        _ rhs: ClaudeOAuthCredentials
    ) -> Bool {
        lhs.accessToken == rhs.accessToken
            && lhs.refreshToken == rhs.refreshToken
            && lhs.expiresAt == rhs.expiresAt
            && lhs.refreshTokenExpiresAt == rhs.refreshTokenExpiresAt
    }

    /// Journal cleanup happens after the owner CAS. If only cleanup fails, the
    /// fresh owner remains authoritative and the next explicit action can
    /// remove the stale journal entry without another exchange.
    private func bestEffortCompleteClaudeRecoveryDestination(
        _ destination: ClaudeRotationRecoveryDestination,
        staleChainFingerprint: String,
        freshCredentials: ClaudeOAuthCredentials
    ) {
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
            for var record in try claudeRotationRecoveryStore.loadAll(
                accessMode: .nonInteractive
            ) where record.staleChainFingerprint == staleChainFingerprint
                && record.credentials?.accessToken == freshCredentials.accessToken
                && record.pendingDestinations.contains(destination) {
                record.pendingDestinations.remove(destination)
                if record.pendingDestinations.isEmpty {
                    try claudeRotationRecoveryStore.delete(
                        id: record.id,
                        accessMode: .nonInteractive
                    )
                } else {
                    try claudeRotationRecoveryStore.save(
                        record,
                        accessMode: .nonInteractive
                    )
                }
            }
        } catch {
            AppLog.credentials.error("A committed Claude owner could not clear its encrypted recovery checkpoint; a later explicit action will retry cleanup.")
        }
    }

    private func readStoredSnapshotStatus(for profile: AccountProfile) -> StoredSnapshotStatus {
        do {
            return try cliSwitcher.storedCredentialRecord(for: profile)?.summary.isRestorable == true
                ? .present
                : .absent
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            return .locked
        } catch {
            return .unreadable(
                reason: "The saved credential snapshot could not be decoded. Relaunch the installed app or repair this saved login."
            )
        }
    }

    func hasStoredSnapshot(for profile: AccountProfile) -> Bool {
        storedSnapshotStatus(for: profile) == .present
    }

    private enum RetryRefreshSource: Equatable {
        case row
        case notification
        /// Policy-gated automatic recovery of an inactive Claude account,
        /// queued by the scheduled poll. Same workflow as a user Retry, but
        /// with the read-only-for-active rotation intent and no status text.
        case scheduledRecovery

        /// Diagnostics naming: rows and notifications are explicit user
        /// intents; scheduled recovery is the unattended variant.
        var credentialCodePath: String {
            self == .scheduledRecovery ? "scheduledRecovery" : "userRetry"
        }

        var workflowOrigin: String {
            switch self {
            case .row: return "row"
            case .notification: return "notification"
            case .scheduledRecovery: return "scheduled_recovery"
            }
        }
    }

    private enum RetryRefreshResult: Sendable {
        case completed
        case needsLogin(reason: String)
        case authorizationRequired(reason: String)
        case deferred(reason: String)
        case failed(reason: String)
        case noLongerAvailable
    }

    /// Row-level entry point. Notification actions call the same awaitable
    /// workflow below, so both sources share mutation gating and coalescing.
    func retryRefresh(for profile: AccountProfile) {
        Task {
            _ = await retryRefresh(profileID: profile.id, source: .row)
        }
    }

    private func retryRefresh(
        profileID: UUID,
        source: RetryRefreshSource
    ) async -> RetryRefreshResult {
        guard let requestedProfile = profiles.first(where: { $0.id == profileID }) else {
            return .noLongerAvailable
        }
        let flightKey: ClaudeSessionRetryFlightKey = source == .notification
            ? .activePausedNotification(requestedProfile.provider)
            : .profile(profileID)
        if let existing = retryFlights[flightKey] {
            return await existing.task.value
        }

        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return RetryRefreshResult.noLongerAvailable }
            return await self.performRetryRefresh(profileID: profileID, source: source)
        }
        retryFlights[flightKey] = (flightID, task)
        let result = await task.value
        if retryFlights[flightKey]?.id == flightID {
            retryFlights[flightKey] = nil
        }
        return result
    }

    private func performRetryRefresh(
        profileID: UUID,
        source: RetryRefreshSource
    ) async -> RetryRefreshResult {
        guard var profile = profiles.first(where: { $0.id == profileID }) else {
            return .noLongerAvailable
        }
        if source == .row {
            // An explicit user Retry re-arms automatic recovery for this row
            // even if this attempt fails again.
            scheduledClaudeRecoveryLedger[profileID] = nil
        }
        if profile.provider == .claude,
           !validateClaudeNativeConfiguration() {
            return .deferred(
                reason: statusMessage.isEmpty
                    ? "Claude session handling is unavailable for this configuration."
                    : statusMessage
            )
        }

        // A scheduled read or switch already owns this provider. Queue the
        // explicit intent briefly, yielding the main actor, then re-resolve the
        // profile before touching credentials. This is deterministic for
        // notification clicks and avoids carrying a stale profile value.
        let provider = profile.provider
        var mutationOwner = beginCredentialMutation(for: provider)
        // An automatic recovery never contends with a queued user action: if
        // the provider gate is busy, yield now and let a later cycle retry.
        if mutationOwner == nil, source == .scheduledRecovery {
            return .deferred(
                reason: "Another \(provider.displayName) credential operation is in progress."
            )
        }
        while mutationOwner == nil {
            if Task.isCancelled { return .deferred(reason: "Refresh was cancelled.") }
            try? await Task.sleep(nanoseconds: 100_000_000)
            switch source {
            case .row, .scheduledRecovery:
                guard let current = profiles.first(where: { $0.id == profileID }) else {
                    return .noLongerAvailable
                }
                profile = current
            case .notification:
                // The notification's original profile is stale context. A
                // switch/removal while this intent is queued must retarget the
                // account that is active now, never rotate the old inactive
                // holder merely because its paused state has not cleared yet.
                guard let current = activeProfile(for: provider) else {
                    return .noLongerAvailable
                }
                profile = current
            }
            mutationOwner = beginCredentialMutation(for: provider)
        }
        guard let mutationOwner else {
            let reason = "Another \(profile.provider.displayName) credential operation is still in progress. Try again shortly."
            statusMessage = reason
            return .deferred(reason: reason)
        }
        defer { finishCredentialMutation(for: provider, owner: mutationOwner) }

        if source == .notification {
            guard let current = activeProfile(for: provider) else {
                return .noLongerAvailable
            }
            profile = current
        }

        // A Retry tap or delivered notification may have waited across the
        // fixed login-expiry boundary. Re-evaluate the final resolved profile
        // after the provider gate and stop before acquiring a mutation lease or
        // invoking the token service; fixed-expiry recovery is an explicit
        // login, not rotation.
        if isFixedClaudeLoginExpired(profile, now: Date()) {
            let reason = "This Claude login has expired on this Mac. Log in again to renew it."
            clearUsagePaused(for: profile.id)
            refreshStates[profile.id] = .needsLogin(reason: reason)
            return .needsLogin(reason: reason)
        }

        // A scheduled read, login, or switch may have resolved the problem
        // while this user intent waited for the provider gate. Do not turn a
        // stale Retry tap into an unnecessary OAuth-capable request.
        switch (source, refreshStates[profile.id]) {
        case (.notification, .rotationDeferred),
             (.notification, .usagePaused),
             (.notification, .credentialRepairRequired),
             (.row, .readFailed),
             (.row, .rotationDeferred),
             (.row, .usagePaused),
             (.row, .credentialRepairRequired),
             // Deliberately not `.readFailed`: automatic recovery heals only
             // the rotation deferrals its queueing policy admits.
             (.scheduledRecovery, .rotationDeferred),
             (.scheduledRecovery, .usagePaused),
             (.scheduledRecovery, .credentialRepairRequired):
            break
        default:
            return .noLongerAvailable
        }

        let counter = CredentialKeychainIOCounter()
        var workflowStatus = "aborted"
        let result: RetryRefreshResult = await CredentialAccess.counting(counter) {
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
                            let reason = error.localizedDescription
                            if isKeychainAccessDenied(error) {
                                refreshStates[profile.id] = .authorizationRequired(
                                    source: .claudeCode,
                                    reason: reason
                                )
                                workflowStatus = "authorization_required"
                                return .authorizationRequired(reason: reason)
                            }
                            refreshStates[profile.id] = .readFailed(reason: reason)
                            workflowStatus = "credential_unavailable"
                            return .failed(reason: reason)
                        }
                    }
                case .knownDenied, .unavailable:
                    let reason = "Authorize Claude Code Keychain access before retrying."
                    refreshStates[profile.id] = .authorizationRequired(
                        source: .claudeCode,
                        reason: reason
                    )
                    statusMessage = reason
                    workflowStatus = "authorization_required"
                    return .authorizationRequired(reason: reason)
                }
            }

            if profile.provider == .claude {
                do {
                    try await claudeRefreshCoordinator.withLease { _ in
                        await CredentialAccess.nonInteractive {
                            await retryRefreshInteractively(for: profile, source: source)
                        }
                    }
                } catch let error as ClaudeOAuthRefreshCoordinatorError {
                    refreshStates[profile.id] = .rotationDeferred(
                        reason: error.localizedDescription
                    )
                    recordClaudeCredentialOutcome(
                        Self.credentialOutcome(for: .rotationDeferred(error)),
                        for: profile,
                        codePath: source.credentialCodePath
                    )
                    if source != .scheduledRecovery {
                        statusMessage = "Retry deferred: \(error.localizedDescription)"
                    }
                } catch {
                    refreshStates[profile.id] = .rotationDeferred(
                        reason: error.localizedDescription
                    )
                    if source != .scheduledRecovery {
                        statusMessage = "Retry deferred: \(error.localizedDescription)"
                    }
                }
            } else {
                await CredentialAccess.nonInteractive {
                    await retryRefreshInteractively(for: profile, source: source)
                }
            }
            switch refreshStates[profile.id] {
            case .ok:
                workflowStatus = "completed"
                return .completed
            case .needsLogin(let reason):
                workflowStatus = "needs_login"
                if source == .row {
                    handleLoginRequired(for: profile, reason: reason, interactive: true)
                }
                return .needsLogin(reason: reason)
            case .authorizationRequired(_, let reason),
                 .credentialAccessBlocked(_, _, let reason):
                workflowStatus = "authorization_required"
                return .authorizationRequired(reason: reason)
            case .keychainLocked:
                workflowStatus = "authorization_required"
                return .authorizationRequired(reason: "Authorize Keychain access before retrying.")
            case .rotationDeferred(let reason), .switchRequired(let reason):
                workflowStatus = "deferred"
                return .deferred(reason: reason)
            case .credentialRepairRequired(let reason), .readFailed(let reason):
                workflowStatus = "failed"
                return .failed(reason: reason)
            case .providerAccessForbidden(let reason):
                workflowStatus = "forbidden"
                return .failed(reason: reason)
            case .idle, .refreshing, .usagePaused, .none:
                workflowStatus = "failed"
                return .failed(reason: statusMessage.isEmpty
                    ? "The usage refresh did not complete."
                    : statusMessage)
            }
        }

        logCredentialWorkflow(
            workflow: "usage_retry",
            provider: profile.provider,
            origin: source.workflowOrigin,
            access: "noninteractive",
            status: workflowStatus,
            counts: counter.snapshot
        )
        updateSwitchAdvice()
        updateMenuBarSummary()
        return result
    }

    private func retryRefreshInteractively(
        for profile: AccountProfile,
        source: RetryRefreshSource
    ) async {
        // A user Retry can legitimately wait behind a scheduled refresh. It
        // owns the visible flag only when the flag is not already set by the
        // outer operation; never discard the queued explicit intent.
        let ownsRefreshFlag = !isRefreshing
        if ownsRefreshFlag { isRefreshing = true }
        defer { if ownsRefreshFlag { isRefreshing = false } }

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
        if case .unreadable(let reason) = storedStatus {
            claudeLoginExpirations[profile.id] = nil
            refreshStates[profile.id] = .credentialAccessBlocked(
                source: .savedAccount,
                disposition: .other(errSecDecode),
                reason: reason
            )
            return
        }

        switch profile.provider {
        case .claude:
            lastClaudeRefreshAttempt = Date()
            let liveElsewhere = claudeAccountIsLiveElsewhere(profile, context: claudeRotationContext())
            refreshStates[profile.id] = .refreshing
            var resolvedUsageCredentials: ClaudeOAuthCredentials?
            do {
                let retryStoredRecord = try cliSwitcher.storedCredentialRecord(
                    for: profile,
                    accessMode: .nonInteractive
                )
                let predictedCredential = preferredClaudeCredential(
                    live: retryLiveRecord?.credentials,
                    stored: retryStoredRecord?.claudeOAuthCredentials,
                    isActiveCLI: profile.isActiveCLI
                )
                let staleChain = ClaudeRefreshChainFingerprint.make(
                    credentials: predictedCredential
                )
                let additionalDestinations = try additionalClaudeRecoveryDestinations(
                    staleChainFingerprint: staleChain,
                    targetProfileID: profile.id,
                    storedCredentialWorkflow: nil
                )
                let snapshot = try await claudeUsageService.fetchSnapshot(
                    for: profile,
                    isActiveCLI: profile.isActiveCLI,
                    accountIsLiveElsewhere: liveElsewhere,
                    rotationIntent: source == .scheduledRecovery
                        ? .scheduledRecovery
                        : .userRetry,
                    additionalRecoveryDestinations: additionalDestinations,
                    liveCredentialReadPolicy: profile.isActiveCLI
                        ? .preloaded(retryLiveRecord)
                        : .read,
                    credentialDidResolve: {
                        resolvedUsageCredentials = $0
                    }
                )
                // Compare against the pre-rotation credential predicted before
                // the fetch. The resolve callback only ever reports the
                // post-rotation value, so comparing its first and last reports
                // would miss the primary rotation. Mirrors the switch path.
                if let resolvedUsageCredentials,
                   claudeOAuthGenerationAdvanced(
                    from: predictedCredential,
                    to: resolvedUsageCredentials
                   ) {
                    try reconcileClaudeChainOwners(
                        additionalDestinations,
                        staleChainFingerprint: staleChain,
                        freshCredentials: resolvedUsageCredentials,
                        storedCredentialWorkflow: nil
                    )
                }
                if let refreshedRecord = try? cliSwitcher.storedCredentialRecord(
                    for: profile,
                    accessMode: .nonInteractive
                ) {
                    cacheStoredCredentialSummary(refreshedRecord, for: profile)
                }
                if profile.isActiveCLI, let resolvedUsageCredentials {
                    liveClaudeRefreshChainFingerprint =
                        ClaudeRefreshChainFingerprint.make(
                            credentials: resolvedUsageCredentials
                        )
                }
                applySnapshot(snapshot, for: profile)
                clearUsagePaused(for: profile.id)
                scheduledClaudeRecoveryLedger[profile.id] = nil
                recordClaudeCredentialOutcome(
                    .success,
                    for: profile,
                    codePath: source.credentialCodePath
                )
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
                    codePath: source.credentialCodePath
                )
                if case .credentialRepairRequired = fetchError {
                    // Sibling propagation can be the incomplete owner even
                    // when this row initiated the exchange. Surface every
                    // journal destination now; each can repair from the saved
                    // fresh generation without another token request.
                    refreshClaudeRecoveryStates()
                }
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
        if profile.provider == .claude,
           !validateClaudeNativeConfiguration() {
            return
        }
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
                    guard let request = self.revalidatedLoginRequest(
                        for: profile.id,
                        activateAfterLogin: activateAfterLogin
                    ) else {
                        return false
                    }
                    return self.beginCLILoginPrepared(
                        for: request.profile,
                        activateAfterLogin: request.activateAfterLogin
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

    private struct RevalidatedLoginRequest {
        var profile: AccountProfile
        var activateAfterLogin: Bool
    }

    /// Re-resolves an inactive renewal after it owns the provider gate and
    /// immediately before Terminal is launched. Cached popover state is only a
    /// hint: a newly shared Claude chain must switch first, while a fixed expiry
    /// crossed since the click turns recovery into an activating login.
    private func revalidatedLoginRequest(
        for profileID: UUID,
        activateAfterLogin: Bool
    ) -> RevalidatedLoginRequest? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            statusMessage = "That account was removed before login could start."
            return nil
        }
        guard profile.provider == .claude,
              !profile.isActiveCLI,
              !activateAfterLogin else {
            return RevalidatedLoginRequest(
                profile: profile,
                activateAfterLogin: activateAfterLogin
            )
        }

        let targetRecord: StoredCredentialRecord?
        do {
            targetRecord = try cliSwitcher.storedCredentialRecord(
                for: profile,
                accessMode: .nonInteractive
            )
            cacheStoredCredentialSummary(targetRecord, for: profile)
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            storedSnapshotStatuses[profile.id] = .locked
            refreshStates[profile.id] = .authorizationRequired(
                source: .savedAccount,
                reason: error.localizedDescription
            )
            statusMessage = "Authorize this saved Claude login before renewing it."
            return nil
        } catch {
            let reason = "The saved Claude login could not be decoded: \(error.localizedDescription)"
            storedSnapshotStatuses[profile.id] = .unreadable(reason: reason)
            storedCredentialSummaries[profile.id] = nil
            claudeLoginExpirations[profile.id] = nil
            refreshStates[profile.id] = .credentialAccessBlocked(
                source: .savedAccount,
                disposition: .other(errSecDecode),
                reason: reason
            )
            statusMessage = reason
            return nil
        }

        let now = Date()
        if targetRecord?.summary.claudeRefreshTokenExpiresAt
            .map({ now >= $0 }) == true {
            let reason = "This Claude login expired before renewal started, so recovery will make it the active account."
            refreshStates[profile.id] = .needsLogin(reason: reason)
            statusMessage = reason
            return RevalidatedLoginRequest(
                profile: profile,
                activateAfterLogin: true
            )
        }

        let liveRecord: LiveClaudeOAuthCredentialRecord?
        do {
            liveRecord = try cliSwitcher.liveClaudeOAuthCredentialRecord(
                accessMode: .nonInteractive
            )
            liveClaudeRefreshChainFingerprint = ClaudeRefreshChainFingerprint.make(
                credentials: liveRecord?.credentials
            )
        } catch let error as ClaudeCodeCredentialsKeychainError
            where error.isKeychainAccessDenied {
            recordClaudeKeychainFailure(error)
            refreshStates[profile.id] = .authorizationRequired(
                source: .claudeCode,
                reason: error.localizedDescription
            )
            statusMessage = "Authorize Claude Code Keychain access before renewing an inactive account."
            return nil
        } catch {
            let reason = "The live Claude login could not be inspected safely: \(error.localizedDescription)"
            refreshStates[profile.id] = .credentialAccessBlocked(
                source: .claudeCode,
                disposition: credentialAccessDisposition(for: error) ?? .unavailable,
                reason: reason
            )
            statusMessage = reason
            return nil
        }

        let targetChain = targetRecord?.summary.claudeRefreshChainFingerprint
        let liveChain = ClaudeRefreshChainFingerprint.make(
            credentials: liveRecord?.credentials
        )
        if RotationProtectionPolicy.accountIsLiveElsewhere(
            profile: profile,
            among: profiles,
            storedChainFingerprint: targetChain,
            liveChainFingerprint: liveChain
        ) {
            let reason = "This profile shares the active Claude login. Switch the CLI to it before renewing."
            refreshStates[profile.id] = .switchRequired(reason: reason)
            statusMessage = reason
            return nil
        }

        return RevalidatedLoginRequest(
            profile: profile,
            activateAfterLogin: false
        )
    }

    private func preferredClaudeCredential(
        live: ClaudeOAuthCredentials?,
        stored: ClaudeOAuthCredentials?,
        isActiveCLI: Bool
    ) -> ClaudeOAuthCredentials? {
        guard isActiveCLI else { return stored }
        guard let live else { return stored }
        guard let stored else { return live }
        return stored.isFresher(than: live, asOf: Date()) ? stored : live
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
                        let authorizationRequired = provider == .claude
                            && self.isKeychainAccessDenied(error)
                        workflowStatus = authorizationRequired
                            ? "authorization_required"
                            : "metadata_failed"
                        if provider == .claude {
                            if authorizationRequired {
                                self.pendingClaudeLoginCompletion = PendingClaudeLoginCompletion(
                                    profileID: profileID,
                                    initialBaseline: initialBaseline,
                                    activateAfterLogin: activateAfterLogin,
                                    previousActiveID: previousActiveID
                                )
                                self.statusMessage = "Login finished. Authorize Keychain access once from the More menu to link it."
                            } else {
                                self.pendingClaudeLoginCompletion = nil
                            }
                        }
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
                                    self.pendingClaudeLoginCompletion = nil
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
                                    self.pendingClaudeLoginCompletion = nil
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
                    guard LoginCompletionWatchDecision(outcome: result) == .stopPolling else {
                        continue
                    }
                    switch result {
                    case .pending:
                        continue
                    case .completed:
                        workflowStatus = "completed"
                        if provider == .claude {
                            self.pendingClaudeLoginCompletion = nil
                        }
                        return
                    case .authorizationRequired(let source):
                        workflowStatus = "authorization_required"
                        if provider == .claude {
                            self.pendingClaudeLoginCompletion = result
                                .retainsPendingClaudeLoginCompletion
                                ? PendingClaudeLoginCompletion(
                                    profileID: profileID,
                                    initialBaseline: initialBaseline,
                                    activateAfterLogin: activateAfterLogin,
                                    previousActiveID: previousActiveID
                                )
                                : nil
                        }
                        if source == .claudeCode {
                            self.statusMessage = "Login finished. Authorize Keychain access once from the More menu to link it."
                        }
                        return
                    case .failed:
                        workflowStatus = "failed"
                        if provider == .claude {
                            self.pendingClaudeLoginCompletion = nil
                        }
                        return
                    }
                }
                if provider == .claude {
                    self.pendingClaudeLoginCompletion = nil
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
    ) async -> LoginCompletionOutcome {
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
                if provider == .claude {
                    if isKeychainAccessDenied(error) {
                        if error is ClaudeCodeCredentialsKeychainError {
                            recordClaudeKeychainFailure(error)
                        }
                        return .authorizationRequired(source: .claudeCode)
                    }
                    statusMessage = "Login finished, but its credentials could not be read safely: \(error.localizedDescription)"
                    return .failed
                }
                // Codex writes auth.json non-atomically on some releases. A
                // metadata change followed by a transient parse failure is
                // still an unsettled login, so preserve the existing retry.
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
            let completion = await handleNonActivatingLoginCompletion(
                current: current,
                profileID: profileID,
                previousActiveID: previousActiveID
            )
            if let deferredError = completion.deferredError {
                // `handleNonActivatingLoginCompletion` returns only after its
                // Claude lease has been released. Never hold Claude Code's
                // cross-process locks while a user dismisses a modal.
                showError(
                    message: deferredError.message,
                    details: deferredError.details
                )
            }
            switch completion.outcome {
            case .pending:
                return .pending
            case .completed:
                return .completed
            case .authorizationRequired(let source):
                return .authorizationRequired(source: source)
            case .failed:
                return .failed
            }
        }
        do {
            let resolved = try reconcileLiveCredentials(
                provider: provider,
                origin: .login,
                observation: current,
                preferredLoginProfileID: profileID
            )
            guard let resolved else {
                return .pending
            }
            refreshStates[resolved.id] = .ok
            if provider == .claude {
                await reconcileClaudeRecoveryAfterLogin(profileID: resolved.id)
            }
            await CredentialAccess.nonInteractive { await refreshAll() }
            return .completed
        } catch {
            // The live provider item was already read into `current`; any
            // authorization failure below comes from the app-owned snapshots
            // or Claude recovery journal used by reconciliation.
            if isKeychainAccessDenied(error) {
                statusMessage = "Login finished, but saved login access requires authorization: \(error.localizedDescription)"
                return .authorizationRequired(source: .savedAccount)
            }
            statusMessage = "Login finished, but the account could not be saved: \(error.localizedDescription)"
            return .failed
        }
    }

    /// Captures the just-completed login into its profile *without* changing the
    /// active account, then restores the previously-active account into the live
    /// session so the app's active-CLI belief and the on-disk session agree.
    private struct DeferredNonActivatingLoginError {
        var message: String
        var details: String
    }

    private struct NonActivatingLoginCompletion {
        var outcome: LoginCompletionOutcome
        var deferredError: DeferredNonActivatingLoginError? = nil
    }

    private func handleNonActivatingLoginCompletion(
        current: LiveCredentialObservation,
        profileID: UUID,
        previousActiveID: UUID?
    ) async -> NonActivatingLoginCompletion {
        let provider = current.provider
        if provider == .claude, ClaudeOAuthMutationLeaseContext.current == nil {
            do {
                let completion = try await claudeRefreshCoordinator.withLease { _ in
                    await self.handleNonActivatingLoginCompletion(
                        current: current,
                        profileID: profileID,
                        previousActiveID: previousActiveID
                    )
                }
                if completion.outcome == .completed {
                    await CredentialAccess.nonInteractive { await refreshAll() }
                }
                return completion
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                let outcome = LoginCompletionOutcome(
                    leaseAcquisitionError: error
                )
                refreshStates[profileID] = .rotationDeferred(
                    reason: error.localizedDescription
                )
                statusMessage = outcome == .pending
                    ? "Login completion is waiting for the Claude credential lock: \(error.localizedDescription)"
                    : "Login finished, but the Claude credential lock is unavailable: \(error.localizedDescription)"
                return NonActivatingLoginCompletion(outcome: outcome)
            } catch {
                if isKeychainAccessDenied(error) {
                    return NonActivatingLoginCompletion(
                        outcome: .authorizationRequired(source: .savedAccount)
                    )
                }
                refreshStates[profileID] = .credentialRepairRequired(
                    reason: error.localizedDescription
                )
                statusMessage = "Login was saved, but restoring the previous Claude account needs repair: \(error.localizedDescription)"
                return NonActivatingLoginCompletion(outcome: .failed)
            }
        }
        let effectiveCurrent: LiveCredentialObservation
        if provider == .claude {
            guard let pinnedItem = current.claudeKeychainItemLocation else {
                refreshStates[profileID] = .rotationDeferred(
                    reason: "The completed Claude login no longer has a pinned Keychain generation."
                )
                return NonActivatingLoginCompletion(outcome: .pending)
            }
            do {
                // The watcher observation predates lock acquisition. Re-read
                // that exact item while leased; a newer generation wins, and a
                // replaced item is left for the watcher to settle again.
                effectiveCurrent = try cliSwitcher.liveClaudeObservation(
                    at: pinnedItem,
                    accessMode: .nonInteractive
                )
            } catch ClaudeCodeCredentialsKeychainError.missingLiveItem {
                refreshStates[profileID] = .rotationDeferred(
                    reason: "Claude changed the completed login before it could be restored safely."
                )
                statusMessage = "Login restoration deferred because Claude changed its Keychain generation."
                return NonActivatingLoginCompletion(outcome: .pending)
            } catch {
                recordClaudeKeychainFailure(error, item: pinnedItem)
                if isKeychainAccessDenied(error) {
                    return NonActivatingLoginCompletion(
                        outcome: .authorizationRequired(source: .claudeCode)
                    )
                }
                let reason = "The completed Claude login could not be read safely: \(error.localizedDescription)"
                refreshStates[profileID] = .readFailed(reason: reason)
                statusMessage = reason
                return NonActivatingLoginCompletion(outcome: .failed)
            }
        } else {
            effectiveCurrent = current
        }
        let storedCredentialWorkflow: SwitchStoredCredentialWorkflow
        do {
            storedCredentialWorkflow = try loadSwitchStoredCredentialWorkflow(
                for: provider
            )
        } catch {
            statusMessage = "Login finished, but saved account credentials could not be inspected safely: \(error.localizedDescription)"
            return NonActivatingLoginCompletion(
                outcome: isKeychainAccessDenied(error)
                    ? .authorizationRequired(source: .savedAccount)
                    : .failed
            )
        }
        let resolved: AccountProfile?
        do {
            resolved = try captureLoginIntoProfile(
                observation: effectiveCurrent,
                provider: provider,
                targetProfileID: profileID,
                storedCredentialWorkflow: storedCredentialWorkflow
            )
        } catch {
            statusMessage = "Login finished, but the account could not be saved: \(error.localizedDescription)"
            return NonActivatingLoginCompletion(
                outcome: isKeychainAccessDenied(error)
                    ? .authorizationRequired(source: .savedAccount)
                    : .failed
            )
        }
        // No stable identity yet — keep polling.
        guard let resolved else {
            return NonActivatingLoginCompletion(outcome: .pending)
        }
        refreshStates[resolved.id] = .ok
        if provider == .claude {
            do {
                try reconcileClaudeRecoveryAfterLoginHoldingLease(
                    profileID: resolved.id
                )
            } catch let error where loginRecoveryCleanupIsTransient(error) {
                AppLog.credentials.error(
                    "Post-login recovery cleanup deferred for \(resolved.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            } catch {
                refreshStates[resolved.id] = .credentialRepairRequired(
                    reason: error.localizedDescription
                )
            }
        }

        // The terminal login may stay open long enough for the previous
        // account's fixed login expiry or stored revision to change. For
        // Claude, re-read it under the still-held OAuth lease and apply the
        // same current-clock switch policy used by every other restore path.
        var previousRestoreFailureReason = "the previous account no longer has restorable credentials"
        var previousRestoreCandidate: (AccountProfile, StoredCredentialRecord)?
        if let previousActiveID,
           let previous = profiles.first(where: { $0.id == previousActiveID }) {
            do {
                let latestRecord = provider == .claude
                    ? try cliSwitcher.storedCredentialRecord(
                        for: previous,
                        accessMode: .nonInteractive
                    )
                    : storedCredentialWorkflow.record(for: previous.id)
                storedCredentialWorkflow.markLoaded(
                    latestRecord,
                    for: previous.id
                )
                cacheStoredCredentialSummary(latestRecord, for: previous)
                if let latestRecord, latestRecord.summary.isRestorable {
                    let evaluation = AccountSessionPolicy.evaluate(
                        provider: provider,
                        isActiveCLI: previous.isActiveCLI,
                        wasPreviouslyLinked: true,
                        storedCredentials: .available,
                        refreshState: refreshStates[previous.id] ?? .idle,
                        loginExpiresAt: latestRecord.summary
                            .claudeRefreshTokenExpiresAt,
                        now: Date()
                    )
                    if evaluation.manualSwitchEligibility.isEligible {
                        previousRestoreCandidate = (previous, latestRecord)
                    } else {
                        previousRestoreFailureReason = evaluation
                            .manualSwitchEligibility.blockerReason
                            ?? "the previous account is not eligible to be restored"
                        if provider == .claude,
                           latestRecord.summary.claudeRefreshTokenExpiresAt
                            .map({ Date() >= $0 }) == true {
                            refreshStates[previous.id] = .needsLogin(
                                reason: previousRestoreFailureReason
                            )
                        }
                    }
                }
            } catch let error as CredentialStoreError
                where error.isKeychainAccessDenied {
                storedSnapshotStatuses[previous.id] = .locked
                refreshStates[previous.id] = .authorizationRequired(
                    source: .savedAccount,
                    reason: error.localizedDescription
                )
                previousRestoreFailureReason = "the previous account's saved credentials require Keychain authorization"
            } catch {
                storedSnapshotStatuses[previous.id] = .unreadable(
                    reason: error.localizedDescription
                )
                storedCredentialSummaries[previous.id] = nil
                claudeLoginExpirations[previous.id] = nil
                refreshStates[previous.id] = .credentialAccessBlocked(
                    source: .savedAccount,
                    disposition: .other(errSecDecode),
                    reason: error.localizedDescription
                )
                previousRestoreFailureReason = "the previous account's saved credentials are unreadable"
            }
        }

        // Without a previous account that remains eligible to restore, the
        // freshly logged-in account becomes active.
        guard let (previous, previousStoredRecord) = previousRestoreCandidate else {
            do {
                _ = try reconcileLiveCredentials(
                    provider: provider,
                    origin: .login,
                    observation: effectiveCurrent,
                    preferredLoginProfileID: profileID,
                    storedCredentialWorkflow: storedCredentialWorkflow
                )
            } catch {
                AppLog.credentials.error("Post-login reconcile failed for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                statusMessage = "Login was saved, but the active \(provider.displayName) account could not be reconciled: \(error.localizedDescription)"
                return NonActivatingLoginCompletion(
                    outcome: isKeychainAccessDenied(error)
                        ? .authorizationRequired(source: .savedAccount)
                        : .failed
                )
            }
            statusMessage = "Logged into \(resolved.label). Could not restore the previous account because \(previousRestoreFailureReason), so \(resolved.label) is now active."
            if provider != .claude {
                await CredentialAccess.nonInteractive { await refreshAll() }
            }
            return NonActivatingLoginCompletion(outcome: .completed)
        }

        do {
            let result = try cliSwitcher.restoreSnapshot(
                for: previous,
                storedRecord: previousStoredRecord,
                expectedLiveFingerprint: effectiveCurrent.credentialFingerprint,
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
            if provider != .claude {
                await CredentialAccess.nonInteractive { await refreshAll() }
            }
            return NonActivatingLoginCompletion(outcome: .completed)
        } catch let restoreError {
            // Restore-back failed — the live session still belongs to the new
            // account. Reconcile to that reality so the app never claims an
            // active account that isn't live, then tell the user plainly.
            AppLog.switching.error("Restore-back to account \(previous.id, privacy: .public) after a non-activating login failed: \(restoreError.localizedDescription, privacy: .public)")
            do {
                _ = try reconcileLiveCredentials(
                    provider: provider,
                    origin: .login,
                    observation: effectiveCurrent,
                    preferredLoginProfileID: profileID,
                    storedCredentialWorkflow: storedCredentialWorkflow
                )
            } catch let reconcileError {
                AppLog.credentials.error("Post-login reconcile failed for \(provider.displayName, privacy: .public): \(reconcileError.localizedDescription, privacy: .public)")
                statusMessage = "Login finished, but neither the previous nor new \(provider.displayName) account could be reconciled safely: \(reconcileError.localizedDescription)"
                return NonActivatingLoginCompletion(
                    outcome: isKeychainAccessDenied(reconcileError)
                        ? .authorizationRequired(source: .savedAccount)
                        : .failed
                )
            }
            let deferredError = DeferredNonActivatingLoginError(
                message: "Logged into \(resolved.label), but could not switch back to \(previous.label)",
                details: "\(resolved.label) is now the active \(provider.displayName) account. \(restoreError.localizedDescription)"
            )
            statusMessage = deferredError.details
            if provider != .claude {
                await CredentialAccess.nonInteractive { await refreshAll() }
            }
            return NonActivatingLoginCompletion(
                outcome: .completed,
                deferredError: deferredError
            )
        }
    }

    private func reconcileClaudeRecoveryAfterLogin(profileID: UUID) async {
        do {
            if ClaudeOAuthMutationLeaseContext.current != nil {
                try reconcileClaudeRecoveryAfterLoginHoldingLease(
                    profileID: profileID
                )
            } else {
                try await claudeRefreshCoordinator.withLease { _ in
                    try self.reconcileClaudeRecoveryAfterLoginHoldingLease(
                        profileID: profileID
                    )
                }
            }
        } catch let error where loginRecoveryCleanupIsTransient(error) {
            // The login already succeeded; a busy shared lock or a transient
            // Keychain denial during best-effort journal cleanup must not read
            // as "needs repair". The deferred refresh reconciles it.
            AppLog.credentials.error(
                "Post-login recovery cleanup deferred for \(profileID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        } catch {
            refreshStates[profileID] = .credentialRepairRequired(
                reason: "Claude login recovery cleanup is pending: \(error.localizedDescription)"
            )
        }
    }

    /// A newly observed login supersedes stale journal generations. Remove
    /// only destinations proven committed or on a different chain; never
    /// replay an older journal record over the new login.
    private func reconcileClaudeRecoveryAfterLoginHoldingLease(
        profileID: UUID
    ) throws {
        _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
        let live = try cliSwitcher.liveClaudeOAuthCredentialRecord(
            accessMode: .nonInteractive
        )?.credentials
        let profile = profiles.first(where: { $0.id == profileID })
        let stored = try profile.flatMap {
            try cliSwitcher.storedCredentialRecord(
                for: $0,
                accessMode: .nonInteractive
            )?.claudeOAuthCredentials
        }
        let storedDestination = ClaudeRotationRecoveryDestination.storedProfile(
            profileID
        )

        for var record in try claudeRotationRecoveryStore.loadAll(
            accessMode: .nonInteractive
        ) {
            guard let fresh = record.credentials else { continue }
            if record.pendingDestinations.contains(.liveClaudeCode),
               let live,
               (ClaudeRefreshChainFingerprint.make(credentials: live)
                    != record.staleChainFingerprint
                    || (!record.isPrepared
                        && claudeRotatedFieldsMatch(live, fresh))) {
                record.pendingDestinations.remove(.liveClaudeCode)
            }
            if record.pendingDestinations.contains(storedDestination),
               let stored,
               (ClaudeRefreshChainFingerprint.make(credentials: stored)
                    != record.staleChainFingerprint
                    || (!record.isPrepared
                        && claudeRotatedFieldsMatch(stored, fresh))) {
                record.pendingDestinations.remove(storedDestination)
            }
            if record.pendingDestinations.isEmpty {
                try claudeRotationRecoveryStore.delete(
                    id: record.id,
                    accessMode: .nonInteractive
                )
            } else {
                try claudeRotationRecoveryStore.save(
                    record,
                    accessMode: .nonInteractive
                )
            }
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
