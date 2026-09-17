import Foundation
import LimitLifeboatCore

/// UserDefaults-backed app preferences.
@MainActor
final class SettingsStore: ObservableObject {
    static let refreshIntervalOptions = [2, 5, 10, 15, 30, 60]

    @Published var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes) }
    }

    /// Gates the "usage nearing / at its limit" notifications.
    @Published var usageAlertsEnabled: Bool {
        didSet { defaults.set(usageAlertsEnabled, forKey: Keys.usageAlertsEnabled) }
    }

    /// Opt-in: switch the CLI automatically when the active account reaches
    /// 5% session remaining or 1% weekly remaining and another account has
    /// clearly more headroom.
    @Published var autoSwitchEnabled: Bool {
        didSet { defaults.set(autoSwitchEnabled, forKey: Keys.autoSwitchEnabled) }
    }

    /// Gates the "quota is likely back — switch" notifications.
    @Published var resetAlertsEnabled: Bool {
        didSet { defaults.set(resetAlertsEnabled, forKey: Keys.resetAlertsEnabled) }
    }

    /// Opt-in: let the fast ~5h session window join the near-limit and pace
    /// alerts. Off by default — heavy sessions would notify on every burn-down.
    @Published var sessionWindowAlertsEnabled: Bool {
        didSet { defaults.set(sessionWindowAlertsEnabled, forKey: Keys.sessionWindowAlertsEnabled) }
    }

    /// Gates the once-a-week usage summary notification.
    @Published var weeklyDigestEnabled: Bool {
        didSet { defaults.set(weeklyDigestEnabled, forKey: Keys.weeklyDigestEnabled) }
    }

    /// Controls the organization component of account-card subtitles. The
    /// identity remains stored and available for account matching either way.
    @Published var showOrganizationNames: Bool {
        didSet { defaults.set(showOrganizationNames, forKey: Keys.showOrganizationNames) }
    }

    /// Warns when memory is too tight to start another agent session safely.
    @Published var memoryGuardAlertsEnabled: Bool {
        didSet { defaults.set(memoryGuardAlertsEnabled, forKey: Keys.memoryGuardAlertsEnabled) }
    }

    /// Suggests a cheaper Claude Code budget mode when the active account is
    /// on pace to run out and no saved account has room to switch to.
    @Published var budgetSuggestionsEnabled: Bool {
        didSet { defaults.set(budgetSuggestionsEnabled, forKey: Keys.budgetSuggestionsEnabled) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.object(forKey: Keys.refreshIntervalMinutes) as? Int
        // A refresh is now a sub-second API call, so the default cadence
        // dropped from 10 to 5 minutes; an explicitly chosen interval wins.
        self.refreshIntervalMinutes = min(240, max(1, storedInterval ?? 5))
        self.usageAlertsEnabled = defaults.object(forKey: Keys.usageAlertsEnabled) as? Bool ?? true
        self.autoSwitchEnabled = defaults.object(forKey: Keys.autoSwitchEnabled) as? Bool ?? false
        self.resetAlertsEnabled = defaults.object(forKey: Keys.resetAlertsEnabled) as? Bool ?? true
        self.sessionWindowAlertsEnabled = defaults.object(forKey: Keys.sessionWindowAlertsEnabled) as? Bool ?? false
        self.weeklyDigestEnabled = defaults.object(forKey: Keys.weeklyDigestEnabled) as? Bool ?? true
        self.showOrganizationNames = defaults.object(forKey: Keys.showOrganizationNames) as? Bool ?? true
        self.memoryGuardAlertsEnabled = defaults.object(forKey: Keys.memoryGuardAlertsEnabled) as? Bool ?? true
        self.budgetSuggestionsEnabled = defaults.object(forKey: Keys.budgetSuggestionsEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let usageAlertsEnabled = "usageAlertsEnabled"
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let resetAlertsEnabled = "resetAlertsEnabled"
        static let sessionWindowAlertsEnabled = "sessionWindowAlertsEnabled"
        static let weeklyDigestEnabled = "weeklyDigestEnabled"
        static let showOrganizationNames = "showOrganizationNames"
        static let memoryGuardAlertsEnabled = "memoryGuardAlertsEnabled"
        static let budgetSuggestionsEnabled = "budgetSuggestionsEnabled"
    }
}
