import Darwin
import Foundation
import XCTest
@testable import LimitLifeboatCore

final class ClaudeOAuthRefreshCoordinatorTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboat-OAuthLock-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        home = nil
    }

    func testAcquiresInProtocolOrderAndReleasesInReverseOrder() async throws {
        let fileSystem = RecordingOAuthLockFileSystem()
        let coordinator = makeCoordinator(fileSystem: fileSystem)

        let lease = try await coordinator.acquire()
        try lease.validate()
        try lease.release()

        XCTAssertEqual(
            fileSystem.events.filter { $0.hasPrefix("create:") },
            [
                "create:\(coordinator.claudeDirectory.path)",
                "create:\(coordinator.oauthRefreshLockURL.path)",
                "create:\(coordinator.claudeLockURL.path)"
            ]
        )
        XCTAssertEqual(
            fileSystem.events.filter { $0.hasPrefix("remove:") },
            [
                "remove:\(coordinator.claudeLockURL.path)",
                "remove:\(coordinator.oauthRefreshLockURL.path)"
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.oauthRefreshLockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.claudeLockURL.path))
    }

    func testWithLeaseInstallsTaskLocalProofAndCleansUp() async throws {
        let coordinator = makeCoordinator()

        let observed = try await coordinator.withLease { lease in
            XCTAssertTrue(ClaudeOAuthMutationLeaseContext.current === lease)
            XCTAssertTrue(try ClaudeOAuthMutationLeaseContext.requireCurrent() === lease)
            return "complete"
        }

        XCTAssertEqual(observed, "complete")
        XCTAssertNil(ClaudeOAuthMutationLeaseContext.current)
        XCTAssertThrowsError(try ClaudeOAuthMutationLeaseContext.requireCurrent()) { error in
            XCTAssertEqual(error as? ClaudeOAuthRefreshCoordinatorError, .missingLease)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.oauthRefreshLockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.claudeLockURL.path))
    }

    func testBusyLockUsesBoundedRetries() async throws {
        let holder = makeCoordinator()
        let heldLease = try await holder.acquire()
        defer { try? heldLease.release() }
        let sleeps = OAuthLockSleepRecorder()
        let contender = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(
                staleAfter: 60,
                heartbeatInterval: 3_600,
                retryCount: 2,
                retryDelayRange: 1...2
            ),
            environment: [:],
            sleep: { delay in await sleeps.record(delay) },
            jitter: { _ in 100 }
        )

        do {
            _ = try await contender.acquire()
            XCTFail("Expected busy lock")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            XCTAssertEqual(error, .busy(lock: .oauthRefresh))
        }
        let recordedSleeps = await sleeps.values
        XCTAssertEqual(recordedSleeps, [2, 2])
    }

    func testTryAcquireReturnsBusyWithoutSleeping() async throws {
        let holder = makeCoordinator()
        let heldLease = try await holder.acquire()
        defer { try? heldLease.release() }
        let sleeps = OAuthLockSleepRecorder()
        let contender = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(
                staleAfter: 60,
                heartbeatInterval: 3_600,
                retryCount: 5,
                retryDelayRange: 1...2
            ),
            environment: [:],
            sleep: { delay in await sleeps.record(delay) }
        )

        do {
            _ = try await contender.tryAcquire()
            XCTFail("Expected busy lock")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            XCTAssertEqual(error, .busy(lock: .oauthRefresh))
        }
        let recordedSleeps = await sleeps.values
        XCTAssertTrue(recordedSleeps.isEmpty)
    }

    func testContentionOnLegacyLockReleasesOAuthLock() async throws {
        let coordinator = makeCoordinator()
        try FileManager.default.createDirectory(
            at: coordinator.claudeDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: coordinator.claudeLockURL,
            withIntermediateDirectories: false
        )

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected legacy lock contention")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            XCTAssertEqual(error, .busy(lock: .claude))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.oauthRefreshLockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.claudeLockURL.path))
    }

    func testExternalProcessLockExcludesCoordinator() async throws {
        let coordinator = makeCoordinator()
        try FileManager.default.createDirectory(
            at: coordinator.claudeDirectory,
            withIntermediateDirectories: true
        )
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/zsh")
        holder.arguments = [
            "-c",
            "mkdir \"$1\" && while :; do sleep 0.1; done",
            "oauth-lock-holder",
            coordinator.oauthRefreshLockURL.path
        ]
        holder.standardOutput = Pipe()
        holder.standardError = Pipe()
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }
        for _ in 0..<100 where !FileManager.default.fileExists(
            atPath: coordinator.oauthRefreshLockURL.path
        ) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(holder.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.oauthRefreshLockURL.path))

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected external-process contention")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            XCTAssertEqual(error, .busy(lock: .oauthRefresh))
        }
    }

    func testReapsSameUserStaleDirectoryLock() async throws {
        let fileSystem = POSIXClaudeOAuthLockFileSystem()
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let staleLock = claudeDirectory.appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: staleLock, withIntermediateDirectories: true)
        let clock = Date()
        let staleDate = clock.addingTimeInterval(-61)
        try fileSystem.updateModificationDate(at: staleLock, to: staleDate)
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(heartbeatInterval: 3_600, retryCount: 0),
            environment: [:],
            now: { clock }
        )

        let lease = try await coordinator.acquire()
        let newMetadata = try XCTUnwrap(try fileSystem.metadata(at: staleLock))

        XCTAssertGreaterThan(newMetadata.modifiedAt, staleDate)
        try lease.release()
    }

    func testHeartbeatBetweenStaleReadsPreventsReap() async throws {
        let baseFileSystem = POSIXClaudeOAuthLockFileSystem()
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let lock = claudeDirectory.appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let clock = Date()
        try baseFileSystem.updateModificationDate(
            at: lock,
            to: clock.addingTimeInterval(-61)
        )
        let fileSystem = HeartbeatingDuringReapOAuthLockFileSystem(
            target: lock,
            heartbeatDate: clock
        )
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            fileSystem: fileSystem,
            configuration: .init(heartbeatInterval: 3_600, retryCount: 0),
            environment: [:],
            now: { clock }
        )

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected freshly heartbeated lock to remain busy")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            XCTAssertEqual(error, .busy(lock: .oauthRefresh))
        }

        XCTAssertEqual(fileSystem.removalCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        let finalDate = try XCTUnwrap(try baseFileSystem.metadata(at: lock)?.modifiedAt)
        XCTAssertEqual(finalDate.timeIntervalSince1970, clock.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDoesNotReapFutureDatedLock() async throws {
        let fileSystem = POSIXClaudeOAuthLockFileSystem()
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let lock = claudeDirectory.appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let clock = Date()
        try fileSystem.updateModificationDate(at: lock, to: clock.addingTimeInterval(60))
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(heartbeatInterval: 3_600, retryCount: 0),
            environment: [:],
            now: { clock }
        )

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected busy lock")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            XCTAssertEqual(error, .busy(lock: .oauthRefresh))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testRejectsSymlinkedClaudeDirectory() async throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude"),
            withDestinationURL: outside
        )
        let coordinator = makeCoordinator()

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected unsafe path")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            guard case .unsafePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.claudeLockURL.path))
    }

    func testRejectsSymlinkedLock() async throws {
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claudeDirectory.appendingPathComponent(".oauth_refresh.lock"),
            withDestinationURL: outside
        )
        let coordinator = makeCoordinator()

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected unsafe path")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            guard case .unsafePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsUnexpectedLockOwner() async throws {
        let fileSystem = ForeignOwnerOAuthLockFileSystem(
            foreignPathSuffix: ClaudeOAuthLockKind.oauthRefresh.fileName
        )
        let coordinator = makeCoordinator(fileSystem: fileSystem)

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected unsafe path")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            guard case .unsafePath(_, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("different user"))
        }
    }

    func testReplacementLosesLeaseAndReplacementIsPreserved() async throws {
        let coordinator = makeCoordinator()
        let lease = try await coordinator.acquire()
        try FileManager.default.moveItem(
            at: coordinator.oauthRefreshLockURL,
            to: root.appendingPathComponent("original-oauth-lock", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: coordinator.oauthRefreshLockURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(
                error as? ClaudeOAuthRefreshCoordinatorError,
                .leaseLost(lock: .oauthRefresh)
            )
        }
        XCTAssertThrowsError(try lease.release())
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.oauthRefreshLockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.claudeLockURL.path))
    }

    func testHeartbeatAdvancesBothLockModificationDates() async throws {
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(staleAfter: 60, heartbeatInterval: 0.02, retryCount: 0),
            environment: [:]
        )
        let fileSystem = POSIXClaudeOAuthLockFileSystem()
        let lease = try await coordinator.acquire()
        let oauthBefore = try XCTUnwrap(try fileSystem.metadata(at: coordinator.oauthRefreshLockURL)?.modifiedAt)
        let claudeBefore = try XCTUnwrap(try fileSystem.metadata(at: coordinator.claudeLockURL)?.modifiedAt)

        try await Task.sleep(nanoseconds: 80_000_000)

        let oauthAfter = try XCTUnwrap(try fileSystem.metadata(at: coordinator.oauthRefreshLockURL)?.modifiedAt)
        let claudeAfter = try XCTUnwrap(try fileSystem.metadata(at: coordinator.claudeLockURL)?.modifiedAt)
        XCTAssertGreaterThan(oauthAfter, oauthBefore)
        XCTAssertGreaterThan(claudeAfter, claudeBefore)
        try lease.release()
    }

    func testRejectsNondefaultClaudeConfigDirectory() async throws {
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(heartbeatInterval: 3_600, retryCount: 0),
            environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("custom").path]
        )

        do {
            _ = try await coordinator.acquire()
            XCTFail("Expected ambiguous configuration")
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            guard case .ambiguousConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.claudeDirectory.path))
    }

    private func makeCoordinator(
        fileSystem: any ClaudeOAuthLockFileSystem = POSIXClaudeOAuthLockFileSystem()
    ) -> ClaudeOAuthRefreshCoordinator {
        ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            fileSystem: fileSystem,
            configuration: .init(heartbeatInterval: 3_600, retryCount: 0),
            environment: [:]
        )
    }
}

private actor OAuthLockSleepRecorder {
    private var recorded: [TimeInterval] = []

    var values: [TimeInterval] { recorded }

    func record(_ value: TimeInterval) {
        recorded.append(value)
    }
}

private final class RecordingOAuthLockFileSystem: ClaudeOAuthLockFileSystem, @unchecked Sendable {
    private let underlying = POSIXClaudeOAuthLockFileSystem()
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var currentUserID: UInt32 { underlying.currentUserID }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func metadata(at url: URL) throws -> ClaudeOAuthLockFileMetadata? {
        try underlying.metadata(at: url)
    }

    func createDirectoryAtomically(at url: URL, permissions: mode_t) throws -> Bool {
        record("create:\(url.path)")
        return try underlying.createDirectoryAtomically(at: url, permissions: permissions)
    }

    func updateModificationDate(at url: URL, to date: Date) throws {
        try underlying.updateModificationDate(at: url, to: date)
    }

    func removeEmptyDirectory(at url: URL) throws {
        record("remove:\(url.path)")
        try underlying.removeEmptyDirectory(at: url)
    }

    private func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }
}

private struct ForeignOwnerOAuthLockFileSystem: ClaudeOAuthLockFileSystem {
    private let underlying = POSIXClaudeOAuthLockFileSystem()
    let foreignPathSuffix: String

    var currentUserID: UInt32 { underlying.currentUserID }

    func metadata(at url: URL) throws -> ClaudeOAuthLockFileMetadata? {
        guard var metadata = try underlying.metadata(at: url) else { return nil }
        if url.lastPathComponent == foreignPathSuffix {
            metadata.ownerID = currentUserID &+ 1
        }
        return metadata
    }

    func createDirectoryAtomically(at url: URL, permissions: mode_t) throws -> Bool {
        try underlying.createDirectoryAtomically(at: url, permissions: permissions)
    }

    func updateModificationDate(at url: URL, to date: Date) throws {
        try underlying.updateModificationDate(at: url, to: date)
    }

    func removeEmptyDirectory(at url: URL) throws {
        try underlying.removeEmptyDirectory(at: url)
    }
}

private final class HeartbeatingDuringReapOAuthLockFileSystem:
    ClaudeOAuthLockFileSystem,
    @unchecked Sendable
{
    private let underlying = POSIXClaudeOAuthLockFileSystem()
    private let target: URL
    private let heartbeatDate: Date
    private let lock = NSLock()
    private var targetMetadataReadCount = 0
    private var recordedRemovalCount = 0

    init(target: URL, heartbeatDate: Date) {
        self.target = target
        self.heartbeatDate = heartbeatDate
    }

    var currentUserID: UInt32 { underlying.currentUserID }

    var removalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRemovalCount
    }

    func metadata(at url: URL) throws -> ClaudeOAuthLockFileMetadata? {
        if url == target {
            let shouldHeartbeat: Bool
            lock.lock()
            targetMetadataReadCount += 1
            shouldHeartbeat = targetMetadataReadCount == 2
            lock.unlock()
            if shouldHeartbeat {
                try underlying.updateModificationDate(at: target, to: heartbeatDate)
            }
        }
        return try underlying.metadata(at: url)
    }

    func createDirectoryAtomically(at url: URL, permissions: mode_t) throws -> Bool {
        try underlying.createDirectoryAtomically(at: url, permissions: permissions)
    }

    func updateModificationDate(at url: URL, to date: Date) throws {
        try underlying.updateModificationDate(at: url, to: date)
    }

    func removeEmptyDirectory(at url: URL) throws {
        if url == target {
            lock.lock()
            recordedRemovalCount += 1
            lock.unlock()
        }
        try underlying.removeEmptyDirectory(at: url)
    }
}
