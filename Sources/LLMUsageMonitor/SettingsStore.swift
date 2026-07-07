import Foundation

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

    /// Gates the "quota is likely back — switch" notifications.
    @Published var resetAlertsEnabled: Bool {
        didSet { defaults.set(resetAlertsEnabled, forKey: Keys.resetAlertsEnabled) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheck) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.object(forKey: Keys.refreshIntervalMinutes) as? Int
        self.refreshIntervalMinutes = min(240, max(1, storedInterval ?? 10))
        self.usageAlertsEnabled = defaults.object(forKey: Keys.usageAlertsEnabled) as? Bool ?? true
        self.resetAlertsEnabled = defaults.object(forKey: Keys.resetAlertsEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let usageAlertsEnabled = "usageAlertsEnabled"
        static let resetAlertsEnabled = "resetAlertsEnabled"
        static let lastUpdateCheck = "lastUpdateCheck"
    }
}
