import Foundation

/// Decides how long to stop asking after a provider throttles usage requests.
/// Sibling of `UsageRefreshCadencePolicy`: that one shortens the cadence when
/// data matters more, this one suspends it when the provider has said to stop.
///
/// Polling a throttled endpoint on the normal cadence is what turns one 429
/// into an episode of them, so the ledger deliberately grows the wait for each
/// consecutive throttle rather than retrying at the configured interval.
public struct UsageBackoffPolicy: Sendable {
    /// How long the app waits after the nth consecutive throttle when the
    /// provider sent no `Retry-After` of its own.
    public struct Configuration: Sendable {
        public var initialDelay: TimeInterval
        public var multiplier: Double
        public var maximumDelay: Double
        /// Fraction of the delay to vary randomly, so several Macs on one
        /// account don't resynchronize onto the same retry instant.
        public var jitterFraction: Double

        public static let standard = Configuration()

        public init(
            initialDelay: TimeInterval = 2 * 60,
            multiplier: Double = 2,
            maximumDelay: TimeInterval = 30 * 60,
            jitterFraction: Double = 0.2
        ) {
            self.initialDelay = initialDelay
            self.multiplier = multiplier
            self.maximumDelay = maximumDelay
            self.jitterFraction = jitterFraction
        }
    }

    /// The cooldown currently in force for one provider.
    public struct State: Equatable, Sendable {
        public var consecutiveThrottles: Int
        public var retryAt: Date

        public init(consecutiveThrottles: Int, retryAt: Date) {
            self.consecutiveThrottles = consecutiveThrottles
            self.retryAt = retryAt
        }
    }

    public var configuration: Configuration
    /// Injectable so tests can pin the jitter. Given a delay, returns the
    /// delay actually used.
    private let jitter: @Sendable (TimeInterval, Double) -> TimeInterval

    public init(
        configuration: Configuration = .standard,
        jitter: @escaping @Sendable (TimeInterval, Double) -> TimeInterval = {
            UsageBackoffPolicy.randomJitter($0, fraction: $1)
        }
    ) {
        self.configuration = configuration
        self.jitter = jitter
    }

    /// Spreads `delay` over ±`fraction` of itself, never below zero.
    public static func randomJitter(_ delay: TimeInterval, fraction: Double) -> TimeInterval {
        guard fraction > 0, delay > 0 else {
            return max(0, delay)
        }
        let spread = delay * fraction
        return max(0, delay + Double.random(in: -spread...spread))
    }

    /// The cooldown to adopt after a throttle. A server-sent `Retry-After` is
    /// authoritative and used as-is — it is a direct instruction, and second
    /// -guessing it with jitter or a ladder would either ask again too early or
    /// wait longer than required. Without one, the delay climbs geometrically
    /// from `initialDelay` and is jittered.
    public func next(
        after previous: State?,
        retryAfter: TimeInterval?,
        now: Date = Date()
    ) -> State {
        let throttles = (previous?.consecutiveThrottles ?? 0) + 1
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return State(
                consecutiveThrottles: throttles,
                retryAt: now.addingTimeInterval(min(retryAfter, configuration.maximumDelay))
            )
        }
        let steps = max(0, throttles - 1)
        let raw = configuration.initialDelay * pow(configuration.multiplier, Double(steps))
        let capped = min(raw.isFinite ? raw : configuration.maximumDelay, configuration.maximumDelay)
        return State(
            consecutiveThrottles: throttles,
            retryAt: now.addingTimeInterval(jitter(capped, configuration.jitterFraction))
        )
    }

    /// True while scheduled work must not issue another request. The retry
    /// instant itself is no longer cooling down, so a timer that fires exactly
    /// on the deadline proceeds.
    public func isCoolingDown(_ state: State?, now: Date = Date()) -> Bool {
        guard let state else { return false }
        return now < state.retryAt
    }

    /// Seconds until the cooldown lifts; zero when nothing is in force.
    public func delayUntilRetry(_ state: State?, now: Date = Date()) -> TimeInterval {
        guard let state else { return 0 }
        return max(0, state.retryAt.timeIntervalSince(now))
    }
}
