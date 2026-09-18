import Foundation

public struct MemoryTrendSample: Equatable, Sendable {
    public let date: Date
    /// Share of physical memory in use, 0...1.
    public let usedFraction: Double

    public init(date: Date, usedFraction: Double) {
        self.date = date
        self.usedFraction = min(1, max(0, usedFraction))
    }
}

/// The recent memory-used readings behind the optional memory graph. Lives in
/// memory only: a live trend is worth nothing after a relaunch.
public struct MemoryTrend: Equatable, Sendable {
    /// The span the graph covers.
    public static let defaultWindow: TimeInterval = 30 * 60
    /// A backstop only. Readings arrive from more than one loop, so age, not
    /// count, decides what the graph keeps.
    public static let defaultCapacity = 720

    public let window: TimeInterval
    public let capacity: Int
    public private(set) var samples: [MemoryTrendSample] = []
    /// The full reading behind the newest sample, for the byte figures.
    public private(set) var latestStatus: SystemMemoryStatus?

    public init(
        window: TimeInterval = MemoryTrend.defaultWindow,
        capacity: Int = MemoryTrend.defaultCapacity
    ) {
        self.window = window
        self.capacity = max(1, capacity)
    }

    public var latest: MemoryTrendSample? {
        samples.last
    }

    public mutating func append(_ status: SystemMemoryStatus, at date: Date) {
        latestStatus = status
        samples.append(MemoryTrendSample(date: date, usedFraction: status.usedFraction))
        let cutoff = date.addingTimeInterval(-window)
        samples.removeAll { $0.date < cutoff }
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}
