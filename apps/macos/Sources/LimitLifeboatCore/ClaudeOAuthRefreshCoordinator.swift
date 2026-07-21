import Darwin
import Dispatch
import Foundation

/// Claude Code serializes OAuth mutation with two directory locks. Limit
/// Lifeboat participates in the same protocol so a token exchange cannot race
/// the CLI or another app process.
public enum ClaudeOAuthLockKind: String, Sendable, CaseIterable {
    case oauthRefresh
    case claude

    public var fileName: String {
        switch self {
        case .oauthRefresh: return ".oauth_refresh.lock"
        case .claude: return ".claude.lock"
        }
    }
}

public enum ClaudeOAuthRefreshCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case ambiguousConfiguration(String)
    case unsafePath(path: String, reason: String)
    case busy(lock: ClaudeOAuthLockKind)
    case missingLease
    case leaseLost(lock: ClaudeOAuthLockKind)
    case leaseReleased
    case fileSystem(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .ambiguousConfiguration(let reason):
            return "Claude credential locking is unavailable for this configuration. \(reason)"
        case .unsafePath(_, let reason):
            return "Claude credential locking found an unsafe lock path. \(reason)"
        case .busy(let lock):
            return "Claude credentials are busy in another process (\(lock.fileName)). Try again shortly."
        case .missingLease:
            return "A Claude credential change was attempted without holding the shared Claude credential lock."
        case .leaseLost(let lock):
            return "The Claude credential lock was replaced or removed (\(lock.fileName)); no further credential changes are safe."
        case .leaseReleased:
            return "The Claude credential lock has already been released."
        case .fileSystem(_, let operation, let code):
            return "Claude credential locking could not \(operation) (system error \(code))."
        }
    }
}

public struct ClaudeOAuthRefreshCoordinatorConfiguration: Sendable, Equatable {
    public var staleAfter: TimeInterval
    public var heartbeatInterval: TimeInterval
    /// Number of waits after the initial acquisition attempt.
    public var retryCount: Int
    public var retryDelayRange: ClosedRange<TimeInterval>

    public init(
        staleAfter: TimeInterval = 60,
        heartbeatInterval: TimeInterval = 5,
        retryCount: Int = 5,
        retryDelayRange: ClosedRange<TimeInterval> = 1...2
    ) {
        self.staleAfter = staleAfter
        self.heartbeatInterval = heartbeatInterval
        self.retryCount = retryCount
        self.retryDelayRange = retryDelayRange
    }

    fileprivate var isValid: Bool {
        staleAfter.isFinite && staleAfter > 0
            && heartbeatInterval.isFinite && heartbeatInterval > 0
            && retryCount >= 0
            && retryDelayRange.lowerBound.isFinite
            && retryDelayRange.upperBound.isFinite
            && retryDelayRange.lowerBound >= 0
            && retryDelayRange.upperBound >= retryDelayRange.lowerBound
    }
}

public struct ClaudeOAuthLockFileIdentity: Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum ClaudeOAuthLockFileType: Equatable, Sendable {
    case directory
    case symbolicLink
    case other
}

public struct ClaudeOAuthLockFileMetadata: Equatable, Sendable {
    public var identity: ClaudeOAuthLockFileIdentity
    public var type: ClaudeOAuthLockFileType
    public var ownerID: UInt32
    public var modifiedAt: Date

    public init(
        identity: ClaudeOAuthLockFileIdentity,
        type: ClaudeOAuthLockFileType,
        ownerID: UInt32,
        modifiedAt: Date
    ) {
        self.identity = identity
        self.type = type
        self.ownerID = ownerID
        self.modifiedAt = modifiedAt
    }
}

/// Narrow filesystem surface used by the coordinator. Production uses POSIX
/// lstat/mkdir/rmdir so symlinks are not followed; tests can inject a fully
/// deterministic implementation.
public protocol ClaudeOAuthLockFileSystem: Sendable {
    var currentUserID: UInt32 { get }
    func metadata(at url: URL) throws -> ClaudeOAuthLockFileMetadata?
    /// Returns false when the path already exists.
    func createDirectoryAtomically(at url: URL, permissions: mode_t) throws -> Bool
    func updateModificationDate(at url: URL, to date: Date) throws
    func removeEmptyDirectory(at url: URL) throws
}

public struct POSIXClaudeOAuthLockFileSystem: ClaudeOAuthLockFileSystem {
    public init() {}

    public var currentUserID: UInt32 { getuid() }

    public func metadata(at url: URL) throws -> ClaudeOAuthLockFileMetadata? {
        var value = stat()
        let result = url.path.withCString { lstat($0, &value) }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let fileType: ClaudeOAuthLockFileType
        switch value.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): fileType = .directory
        case mode_t(S_IFLNK): fileType = .symbolicLink
        default: fileType = .other
        }
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return ClaudeOAuthLockFileMetadata(
            identity: ClaudeOAuthLockFileIdentity(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino)
            ),
            type: fileType,
            ownerID: value.st_uid,
            modifiedAt: modifiedAt
        )
    }

    public func createDirectoryAtomically(at url: URL, permissions: mode_t) throws -> Bool {
        let result = url.path.withCString { mkdir($0, permissions) }
        if result == 0 { return true }
        if errno == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    public func updateModificationDate(at url: URL, to date: Date) throws {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite,
              interval >= Double(Int.min),
              interval < Double(Int.max) else {
            throw POSIXError(.EINVAL)
        }
        let seconds = floor(interval)
        let nanoseconds = (date.timeIntervalSince1970 - seconds) * 1_000_000_000
        var times = [
            timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds)),
            timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
        ]
        let result = times.withUnsafeMutableBufferPointer { buffer in
            url.path.withCString {
                utimensat(AT_FDCWD, $0, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func removeEmptyDirectory(at url: URL) throws {
        let result = url.path.withCString { rmdir($0) }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public struct ClaudeOAuthRefreshCoordinator: Sendable {
    public typealias DateProvider = @Sendable () -> Date
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias Jitter = @Sendable (ClosedRange<TimeInterval>) -> TimeInterval

    public let claudeDirectory: URL
    public let oauthRefreshLockURL: URL
    public let claudeLockURL: URL

    private let homeDirectory: URL
    private let fileSystem: any ClaudeOAuthLockFileSystem
    private let configuration: ClaudeOAuthRefreshCoordinatorConfiguration
    private let environment: [String: String]
    private let now: DateProvider
    private let sleep: Sleeper
    private let jitter: Jitter

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: any ClaudeOAuthLockFileSystem = POSIXClaudeOAuthLockFileSystem(),
        configuration: ClaudeOAuthRefreshCoordinatorConfiguration = .init(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping DateProvider = { Date() },
        sleep: @escaping Sleeper = { try await ClaudeOAuthRefreshCoordinator.defaultSleep($0) },
        jitter: @escaping Jitter = { Double.random(in: $0) }
    ) {
        let homeDirectory = homeDirectory.standardizedFileURL
        let claudeDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
        self.homeDirectory = homeDirectory
        self.claudeDirectory = claudeDirectory
        self.oauthRefreshLockURL = claudeDirectory.appendingPathComponent(
            ClaudeOAuthLockKind.oauthRefresh.fileName,
            isDirectory: true
        )
        self.claudeLockURL = homeDirectory.appendingPathComponent(
            ClaudeOAuthLockKind.claude.fileName,
            isDirectory: true
        )
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.environment = environment
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Acquires `.claude/.oauth_refresh.lock` and then `~/.claude.lock`.
    /// Callers should keep the returned lease across the complete read,
    /// exchange, and durable-write transaction and validate it immediately
    /// before every irreversible credential mutation.
    public func acquire(retrying: Bool = true) async throws -> ClaudeOAuthRefreshLease {
        try validateSupportedConfiguration()
        try ensureSafeClaudeDirectory()

        let allowedRetries = retrying ? configuration.retryCount : 0
        let oauthLock = try await acquireLock(
            kind: .oauthRefresh,
            at: oauthRefreshLockURL,
            retryCount: allowedRetries
        )
        do {
            let claudeLock = try await acquireLock(
                kind: .claude,
                at: claudeLockURL,
                retryCount: allowedRetries
            )
            let lease = ClaudeOAuthRefreshLease(
                locks: [oauthLock, claudeLock],
                fileSystem: fileSystem,
                heartbeatInterval: configuration.heartbeatInterval,
                now: now
            )
            lease.startHeartbeat()
            return lease
        } catch {
            try? removeIfOwned(oauthLock)
            throw error
        }
    }

    /// A nonwaiting acquisition for automatic/background workflows. Busy is a
    /// normal typed outcome; no jitter sleep occurs.
    public func tryAcquire() async throws -> ClaudeOAuthRefreshLease {
        try await acquire(retrying: false)
    }

    /// Validates the supported Claude Code configuration without touching the
    /// lock filesystem. Native scheduled reads call this too: a custom config
    /// must fail closed rather than quietly reading the default macOS service.
    public func validateSupportedConfiguration() throws {
        guard configuration.isValid else {
            throw ClaudeOAuthRefreshCoordinatorError.ambiguousConfiguration(
                "The lock timing configuration is invalid."
            )
        }
        try validateDefaultConfiguration()
    }

    public func withLease<T: Sendable>(
        retrying: Bool = true,
        _ operation: (ClaudeOAuthRefreshLease) async throws -> T
    ) async throws -> T {
        let lease = try await acquire(retrying: retrying)
        do {
            let result = try await lease.withMutationContext {
                try await operation(lease)
            }
            try lease.validate()
            try lease.release()
            return result
        } catch {
            try? lease.release()
            throw error
        }
    }

    private func validateDefaultConfiguration() throws {
        guard let configured = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty else {
            return
        }
        let configuredURL = URL(fileURLWithPath: configured).standardizedFileURL
        guard configured.hasPrefix("/"), configuredURL == claudeDirectory else {
            throw ClaudeOAuthRefreshCoordinatorError.ambiguousConfiguration(
                "CLAUDE_CONFIG_DIR does not identify the default ~/.claude directory."
            )
        }
    }

    private func ensureSafeClaudeDirectory() throws {
        do {
            guard let homeMetadata = try fileSystem.metadata(at: homeDirectory) else {
                throw ClaudeOAuthRefreshCoordinatorError.unsafePath(
                    path: homeDirectory.path,
                    reason: "The home directory does not exist."
                )
            }
            try validateSafeDirectory(homeMetadata, at: homeDirectory)
            if try fileSystem.metadata(at: claudeDirectory) == nil {
                _ = try fileSystem.createDirectoryAtomically(
                    at: claudeDirectory,
                    permissions: 0o700
                )
            }
            guard let metadata = try fileSystem.metadata(at: claudeDirectory) else {
                throw ClaudeOAuthRefreshCoordinatorError.unsafePath(
                    path: claudeDirectory.path,
                    reason: "The ~/.claude directory disappeared during validation."
                )
            }
            try validateSafeDirectory(metadata, at: claudeDirectory)
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw error
        } catch {
            throw fileSystemError(error, at: claudeDirectory, operation: "prepare the lock directory")
        }
    }

    private func acquireLock(
        kind: ClaudeOAuthLockKind,
        at url: URL,
        retryCount: Int
    ) async throws -> OwnedLock {
        for attempt in 0...retryCount {
            if let lock = try tryAcquireOrReapStaleLock(kind: kind, at: url) {
                return lock
            }
            guard attempt < retryCount else {
                throw ClaudeOAuthRefreshCoordinatorError.busy(lock: kind)
            }
            let requested = jitter(configuration.retryDelayRange)
            let bounded = requested.isFinite
                ? min(max(requested, configuration.retryDelayRange.lowerBound), configuration.retryDelayRange.upperBound)
                : configuration.retryDelayRange.lowerBound
            do {
                try await sleep(bounded)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw fileSystemError(error, at: url, operation: "wait for the lock")
            }
        }
        throw ClaudeOAuthRefreshCoordinatorError.busy(lock: kind)
    }

    /// nil means a safe, non-stale lock is held by another process.
    private func tryAcquireOrReapStaleLock(
        kind: ClaudeOAuthLockKind,
        at url: URL
    ) throws -> OwnedLock? {
        do {
            if try fileSystem.createDirectoryAtomically(at: url, permissions: 0o700) {
                guard let metadata = try fileSystem.metadata(at: url) else {
                    throw ClaudeOAuthRefreshCoordinatorError.leaseLost(lock: kind)
                }
                try validateSafeDirectory(metadata, at: url)
                return OwnedLock(kind: kind, url: url, identity: metadata.identity)
            }

            // mkdir reported EEXIST. Validate with lstat before considering
            // staleness so a symlink or foreign-owned directory is never
            // followed or removed.
            guard let existing = try fileSystem.metadata(at: url) else {
                return try tryAcquireOrReapStaleLock(kind: kind, at: url)
            }
            try validateSafeDirectory(existing, at: url)
            let age = now().timeIntervalSince(existing.modifiedAt)
            guard age >= configuration.staleAfter else { return nil }

            // Re-read immediately before rmdir. A replacement is another
            // process's lock, even when it is also old.
            guard let current = try fileSystem.metadata(at: url),
                  current.identity == existing.identity else {
                return nil
            }
            try validateSafeDirectory(current, at: url)
            // The owner can heartbeat the same inode between our first stale
            // observation and this final reread. Recompute age from the final
            // metadata so a newly-freshened live lock is never reaped.
            let currentAge = now().timeIntervalSince(current.modifiedAt)
            guard currentAge >= configuration.staleAfter else { return nil }
            try fileSystem.removeEmptyDirectory(at: url)

            if try fileSystem.createDirectoryAtomically(at: url, permissions: 0o700) {
                guard let created = try fileSystem.metadata(at: url) else {
                    throw ClaudeOAuthRefreshCoordinatorError.leaseLost(lock: kind)
                }
                try validateSafeDirectory(created, at: url)
                return OwnedLock(kind: kind, url: url, identity: created.identity)
            }
            return nil
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw error
        } catch {
            throw fileSystemError(error, at: url, operation: "acquire the lock")
        }
    }

    private func validateSafeDirectory(
        _ metadata: ClaudeOAuthLockFileMetadata,
        at url: URL
    ) throws {
        guard metadata.type != .symbolicLink else {
            throw ClaudeOAuthRefreshCoordinatorError.unsafePath(
                path: url.path,
                reason: "Symbolic links are not allowed."
            )
        }
        guard metadata.type == .directory else {
            throw ClaudeOAuthRefreshCoordinatorError.unsafePath(
                path: url.path,
                reason: "The lock path is not a directory."
            )
        }
        guard metadata.ownerID == fileSystem.currentUserID else {
            throw ClaudeOAuthRefreshCoordinatorError.unsafePath(
                path: url.path,
                reason: "The lock path belongs to a different user."
            )
        }
    }

    private func removeIfOwned(_ lock: OwnedLock) throws {
        guard let current = try fileSystem.metadata(at: lock.url),
              current.identity == lock.identity else {
            throw ClaudeOAuthRefreshCoordinatorError.leaseLost(lock: lock.kind)
        }
        try fileSystem.removeEmptyDirectory(at: lock.url)
    }

    private func fileSystemError(
        _ error: Error,
        at url: URL,
        operation: String
    ) -> ClaudeOAuthRefreshCoordinatorError {
        let code = (error as? POSIXError)?.code.rawValue ?? EIO
        return .fileSystem(path: url.path, operation: operation, code: code)
    }

    public static func defaultSleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await ContinuousClock().sleep(for: .seconds(seconds))
    }
}

/// Task-local proof that a workflow owns Claude Code's cross-process mutation
/// lease. Credential writers can call `requireCurrent()` immediately before a
/// live mutation without taking a coordinator dependency themselves.
public enum ClaudeOAuthMutationLeaseContext {
    @TaskLocal public static var current: ClaudeOAuthRefreshLease?

    @discardableResult
    public static func requireCurrent() throws -> ClaudeOAuthRefreshLease {
        guard let lease = current else {
            throw ClaudeOAuthRefreshCoordinatorError.missingLease
        }
        try lease.validate()
        return lease
    }
}

private struct OwnedLock: Sendable {
    var kind: ClaudeOAuthLockKind
    var url: URL
    var identity: ClaudeOAuthLockFileIdentity
}

/// A lease is deliberately a reference type: every subsystem participating in
/// one transaction observes the same lost/released state. Deinitialization is
/// a safety net; callers should release explicitly so a loss is reported.
public final class ClaudeOAuthRefreshLease: @unchecked Sendable {
    private let locks: [OwnedLock]
    private let fileSystem: any ClaudeOAuthLockFileSystem
    private let heartbeatInterval: TimeInterval
    private let now: ClaudeOAuthRefreshCoordinator.DateProvider
    private let operationLock = NSLock()
    private var heartbeatTimer: DispatchSourceTimer?
    private var terminalError: ClaudeOAuthRefreshCoordinatorError?
    private var isReleased = false

    fileprivate init(
        locks: [OwnedLock],
        fileSystem: any ClaudeOAuthLockFileSystem,
        heartbeatInterval: TimeInterval,
        now: @escaping ClaudeOAuthRefreshCoordinator.DateProvider
    ) {
        self.locks = locks
        self.fileSystem = fileSystem
        self.heartbeatInterval = heartbeatInterval
        self.now = now
    }

    fileprivate func startHeartbeat() {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard heartbeatTimer == nil, !isReleased else { return }
        let timer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            try? self?.heartbeat()
        }
        heartbeatTimer = timer
        timer.activate()
    }

    /// Confirms both paths still refer to the exact directories acquired by
    /// this process. Call immediately before each credential mutation.
    public func validate() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            try validateWhileLocked()
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            terminalError = error
            throw error
        }
    }

    /// Installs this lease as the task-local mutation proof for a larger
    /// transaction which acquired the lease manually.
    public func withMutationContext<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try validate()
        return try await ClaudeOAuthMutationLeaseContext.$current.withValue(self) {
            try await operation()
        }
    }

    /// Releases `~/.claude.lock` and then `.claude/.oauth_refresh.lock`.
    /// A replaced path is preserved and reported as a lost lease.
    public func release() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isReleased else { return }
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        var firstError = terminalError
        for owned in locks.reversed() {
            do {
                guard let metadata = try fileSystem.metadata(at: owned.url),
                      metadata.identity == owned.identity,
                      metadata.type == .directory,
                      metadata.ownerID == fileSystem.currentUserID else {
                    throw ClaudeOAuthRefreshCoordinatorError.leaseLost(lock: owned.kind)
                }
                try fileSystem.removeEmptyDirectory(at: owned.url)
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                if firstError == nil { firstError = error }
            } catch {
                if firstError == nil {
                    firstError = .fileSystem(
                        path: owned.url.path,
                        operation: "release the lock",
                        code: (error as? POSIXError)?.code.rawValue ?? EIO
                    )
                }
            }
        }
        isReleased = true
        terminalError = firstError
        if let firstError { throw firstError }
    }

    deinit {
        try? release()
    }

    private func heartbeat() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            try validateWhileLocked()
            for owned in locks {
                try fileSystem.updateModificationDate(at: owned.url, to: now())
                try validateIdentity(owned)
            }
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            terminalError = error
            throw error
        } catch {
            let owned = locks.first!
            let wrapped = ClaudeOAuthRefreshCoordinatorError.fileSystem(
                path: owned.url.path,
                operation: "heartbeat the lock",
                code: (error as? POSIXError)?.code.rawValue ?? EIO
            )
            terminalError = wrapped
            throw wrapped
        }
    }

    private func validateWhileLocked() throws {
        if let terminalError { throw terminalError }
        guard !isReleased else {
            throw ClaudeOAuthRefreshCoordinatorError.leaseReleased
        }
        for owned in locks {
            try validateIdentity(owned)
        }
    }

    private func validateIdentity(_ owned: OwnedLock) throws {
        do {
            guard let metadata = try fileSystem.metadata(at: owned.url),
                  metadata.identity == owned.identity,
                  metadata.type == .directory,
                  metadata.ownerID == fileSystem.currentUserID else {
                throw ClaudeOAuthRefreshCoordinatorError.leaseLost(lock: owned.kind)
            }
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw error
        } catch {
            throw ClaudeOAuthRefreshCoordinatorError.fileSystem(
                path: owned.url.path,
                operation: "validate the lock",
                code: (error as? POSIXError)?.code.rawValue ?? EIO
            )
        }
    }
}
