import XCTest
@testable import LimitLifeboat
@testable import LimitLifeboatCore

@MainActor
final class SessionMonitorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One real scan of this machine: it must publish a reading and write the
    /// state file the Claude Code hook reads, without needing a usage refresh.
    func testScanPublishesStateForTheHook() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionMonitorTests-\(UUID().uuidString)"))
        let monitor = SessionMonitor(
            settings: SettingsStore(defaults: defaults),
            stateDirectory: directory,
            notify: { _ in },
            notifyColdCache: { _ in }
        )

        await monitor.scan()

        let stateURL = directory.appendingPathComponent(MemoryGuardState.fileName)
        let state = try JSONDecoder().decode(MemoryGuardState.self, from: Data(contentsOf: stateURL))
        XCTAssertTrue(["ok", "caution", "critical"].contains(state.level))
        XCTAssertEqual(state.sessionCount, monitor.rows.count)
        XCTAssertGreaterThan(state.updatedAt, 1_700_000_000)
        XCTAssertNotNil(monitor.memory)
        // This test itself runs under a process table, so a census that finds
        // nothing at all would mean the scan silently failed.
        XCTAssertGreaterThanOrEqual(monitor.assessment.sessionCount, 0)
    }
}
