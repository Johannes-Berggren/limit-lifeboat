import Foundation

public enum MemoryGuardLevel: Int, Comparable, Sendable {
    case ok
    case caution
    case critical

    public static func < (lhs: MemoryGuardLevel, rhs: MemoryGuardLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MemoryGuardAssessment: Equatable, Sendable {
    public let level: MemoryGuardLevel
    public let sessionCount: Int
    public let sessionFootprintBytes: UInt64
    public let availableBytes: UInt64
    /// Rough count of further sessions of today's average size that fit before
    /// memory runs out. Nil without any running session to size from.
    public let estimatedAdditionalSessions: Int?
    /// The largest session idle for a while — the cheapest one to close.
    public let heaviestIdleSession: AgentSession?
    public let heaviestIdleSince: Date?

    /// Tight memory is only Memory Guard's business while agents are running;
    /// with none, there is nothing to close and nothing to hold back.
    public var isActionable: Bool {
        level > .ok && sessionCount > 0
    }

    public static let empty = MemoryGuardAssessment(
        level: .ok,
        sessionCount: 0,
        sessionFootprintBytes: 0,
        availableBytes: 0,
        estimatedAdditionalSessions: nil,
        heaviestIdleSession: nil,
        heaviestIdleSince: nil
    )

    public init(
        level: MemoryGuardLevel,
        sessionCount: Int,
        sessionFootprintBytes: UInt64,
        availableBytes: UInt64,
        estimatedAdditionalSessions: Int?,
        heaviestIdleSession: AgentSession?,
        heaviestIdleSince: Date?
    ) {
        self.level = level
        self.sessionCount = sessionCount
        self.sessionFootprintBytes = sessionFootprintBytes
        self.availableBytes = availableBytes
        self.estimatedAdditionalSessions = estimatedAdditionalSessions
        self.heaviestIdleSession = heaviestIdleSession
        self.heaviestIdleSince = heaviestIdleSince
    }
}

public struct MemoryGuardPolicy: Sendable {
    public let cautionAvailableFraction: Double
    public let criticalAvailableFraction: Double
    /// Kept free for the OS and everything that is not an agent.
    public let reserveBytes: UInt64
    /// A fresh session grows quickly; never size a new one below this.
    public let minimumSessionBytes: UInt64
    public let idleThreshold: TimeInterval

    public init(
        cautionAvailableFraction: Double = 0.12,
        criticalAvailableFraction: Double = 0.04,
        reserveBytes: UInt64 = 1_536 * 1_048_576,
        minimumSessionBytes: UInt64 = 512 * 1_048_576,
        idleThreshold: TimeInterval = 30 * 60
    ) {
        self.cautionAvailableFraction = cautionAvailableFraction
        self.criticalAvailableFraction = criticalAvailableFraction
        self.reserveBytes = reserveBytes
        self.minimumSessionBytes = minimumSessionBytes
        self.idleThreshold = idleThreshold
    }

    /// - Parameter lastActivity: last transcript activity per session pid.
    ///   A session without it has unknown idleness and is never named idle —
    ///   process age says nothing about whether it is working.
    public func assess(
        memory: SystemMemoryStatus,
        sessions: [AgentSession],
        lastActivity: [Int32: Date],
        now: Date
    ) -> MemoryGuardAssessment {
        let footprint = sessions.reduce(UInt64(0)) { $0 + $1.footprintBytes }
        let available = memory.availableBytes

        var estimate: Int?
        if !sessions.isEmpty {
            let average = max(footprint / UInt64(sessions.count), minimumSessionBytes)
            estimate = available > reserveBytes ? Int((available - reserveBytes) / average) : 0
        }

        let fraction = memory.totalBytes > 0 ? Double(available) / Double(memory.totalBytes) : 1
        let level: MemoryGuardLevel
        if memory.pressure == .critical || fraction < criticalAvailableFraction {
            level = .critical
        } else if memory.pressure == .warning || fraction < cautionAvailableFraction || estimate == 0 {
            level = .caution
        } else {
            level = .ok
        }

        let idle = sessions
            .compactMap { session in lastActivity[session.pid].map { (session, $0) } }
            .filter { now.timeIntervalSince($0.1) >= idleThreshold }
            .max { $0.0.footprintBytes < $1.0.footprintBytes }

        return MemoryGuardAssessment(
            level: level,
            sessionCount: sessions.count,
            sessionFootprintBytes: footprint,
            availableBytes: available,
            estimatedAdditionalSessions: estimate,
            heaviestIdleSession: idle?.0,
            heaviestIdleSince: idle?.1
        )
    }
}

/// Decides when a Memory Guard notification is worth posting: on escalation,
/// or when a level persists past the cooldown. A return to `.ok` re-arms.
public struct MemoryGuardAlertPlanner: Sendable {
    public struct Record: Equatable, Sendable {
        public let level: MemoryGuardLevel
        public let notifiedAt: Date

        public init(level: MemoryGuardLevel, notifiedAt: Date) {
            self.level = level
            self.notifiedAt = notifiedAt
        }
    }

    public let cooldown: TimeInterval

    public init(cooldown: TimeInterval = 45 * 60) {
        self.cooldown = cooldown
    }

    public func shouldNotify(
        _ assessment: MemoryGuardAssessment,
        lastNotified: Record?,
        now: Date
    ) -> Bool {
        // Tight memory with no agent running is not ours to warn about.
        guard assessment.level > .ok, assessment.sessionCount > 0 else {
            return false
        }
        guard let lastNotified else {
            return true
        }
        if assessment.level > lastNotified.level {
            return true
        }
        return now.timeIntervalSince(lastNotified.notifiedAt) >= cooldown
    }

    public func title(for assessment: MemoryGuardAssessment) -> String {
        assessment.level == .critical ? "Memory is critically low" : "Memory is getting tight"
    }

    public func body(for assessment: MemoryGuardAssessment, now: Date) -> String {
        let sessions = assessment.sessionCount == 1 ? "1 agent session is" : "\(assessment.sessionCount) agent sessions are"
        var body = "\(sessions) using \(MemoryFormatting.bytes(assessment.sessionFootprintBytes)). "
        body += assessment.level == .critical
            ? "Close one before starting another, or your Mac may freeze."
            : "Starting another may slow your Mac down."
        if let idle = assessment.heaviestIdleSession, let since = assessment.heaviestIdleSince {
            body += " Heaviest idle: \(idle.projectName) (\(idle.provider.displayName), idle \(MemoryFormatting.duration(now.timeIntervalSince(since))), \(MemoryFormatting.bytes(idle.footprintBytes)))."
        }
        return body
    }
}

public enum MemoryFormatting {
    public static func bytes(_ value: UInt64) -> String {
        let gigabytes = Double(value) / 1_073_741_824
        if gigabytes >= 1 {
            return String(format: "%.1f GB", gigabytes)
        }
        return "\(Int((Double(value) / 1_048_576).rounded())) MB"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 {
            return "\(max(1, minutes)) min"
        }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h" : "\(hours / 24) d"
    }

    public static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)K"
        }
        return "\(value)"
    }
}
