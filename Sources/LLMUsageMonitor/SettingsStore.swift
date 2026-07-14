import Foundation
import LLMUsageMonitorCore

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

    /// Opt-in: switch the CLI automatically when the active Claude account is
    /// depleted and another account has clearly more headroom.
    @Published var autoSwitchEnabled: Bool {
        didSet { defaults.set(autoSwitchEnabled, forKey: Keys.autoSwitchEnabled) }
    }

    /// Gates the "quota is likely back — switch" notifications.
    @Published var resetAlertsEnabled: Bool {
        didSet { defaults.set(resetAlertsEnabled, forKey: Keys.resetAlertsEnabled) }
    }

    /// Controls the organization component of account-card subtitles. The
    /// identity remains stored and available for account matching either way.
    @Published var showOrganizationNames: Bool {
        didSet { defaults.set(showOrganizationNames, forKey: Keys.showOrganizationNames) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheck) }
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
        self.showOrganizationNames = defaults.object(forKey: Keys.showOrganizationNames) as? Bool ?? true
    }

    private enum Keys {
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let usageAlertsEnabled = "usageAlertsEnabled"
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let resetAlertsEnabled = "resetAlertsEnabled"
        static let showOrganizationNames = "showOrganizationNames"
        static let lastUpdateCheck = "lastUpdateCheck"
    }
}
