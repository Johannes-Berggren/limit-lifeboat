import Foundation

/// Chooses the delay before the next full usage refresh. The user's setting
/// remains the normal cadence; a current active-account reading close to its
/// automatic-switch point temporarily caps that delay so switching, alerts,
/// and presentation react to the same timely data.
public struct UsageRefreshCadencePolicy: Sendable {
    public struct Configuration: Sendable {
        /// Start accelerating this many percentage points before a window's
        /// automatic-switch threshold.
        public var nearThresholdMarginPercent: Double
        /// Fastest cadence introduced by this policy. A shorter user-selected
        /// interval is never lengthened.
        public var acceleratedInterval: TimeInterval
        public var switchConfiguration: SwitchAdvisor.Configuration

        public static let standard = Configuration()

        public init(
            nearThresholdMarginPercent: Double = 5,
            acceleratedInterval: TimeInterval = 60,
            switchConfiguration: SwitchAdvisor.Configuration = .standard
        ) {
            self.nearThresholdMarginPercent = nearThresholdMarginPercent
            self.acceleratedInterval = acceleratedInterval
            self.switchConfiguration = switchConfiguration
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    /// `successfulActiveSnapshots` must contain only active accounts whose
    /// latest refresh succeeded. Failed or inactive accounts stay on the
    /// configured cadence by being omitted by the app layer.
    public func interval(
        configuredInterval: TimeInterval,
        successfulActiveSnapshots: [UsageSnapshot],
        now: Date = Date()
    ) -> TimeInterval {
        guard successfulActiveSnapshots.contains(where: { isNearSwitchThreshold($0, now: now) }) else {
            return configuredInterval
        }
        return min(configuredInterval, configuration.acceleratedInterval)
    }

    private func isNearSwitchThreshold(_ snapshot: UsageSnapshot, now: Date) -> Bool {
        snapshot.orderedDisplayWindows.contains { window in
            guard !window.resetHasElapsed(asOf: now) else {
                return false
            }
            let switchThreshold = configuration.switchConfiguration
                .autoSwitchTriggerRemainingPercent(for: window.kind)
            return window.remainingPercent
                <= switchThreshold + configuration.nearThresholdMarginPercent
        }
    }
}
