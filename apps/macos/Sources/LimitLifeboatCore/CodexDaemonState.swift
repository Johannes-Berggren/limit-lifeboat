import Foundation

/// Process generations, rather than pids alone, let a user-requested recheck
/// distinguish a restarted server from one that still caches the old login.
public struct CodexDaemonProcess: Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

public enum CodexDaemonState: Equatable, Sendable {
    case notRunning
    case running(Set<CodexDaemonProcess>)
    case unavailable
}
