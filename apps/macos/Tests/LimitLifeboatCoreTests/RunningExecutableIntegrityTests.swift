import Foundation
import XCTest
@testable import LimitLifeboatCore

final class RunningExecutableIntegrityTests: XCTestCase {
    func testIntactExecutableValidates() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let guardValue = try RunningExecutableIntegrityGuard(executableURL: fixture.executable)

        XCTAssertNoThrow(try guardValue.validate())
    }

    func testMissingExecutableFailsValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let guardValue = try RunningExecutableIntegrityGuard(executableURL: fixture.executable)

        try FileManager.default.removeItem(at: fixture.executable)

        XCTAssertThrowsError(try guardValue.validate()) { error in
            XCTAssertEqual(
                error as? RunningExecutableIntegrityError,
                .unavailable(path: fixture.executable.path)
            )
        }
    }

    func testReplacementAtSamePathFailsValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let guardValue = try RunningExecutableIntegrityGuard(executableURL: fixture.executable)

        let original = fixture.directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: fixture.executable, to: original)
        try Data("replacement".utf8).write(to: fixture.executable)

        XCTAssertThrowsError(try guardValue.validate()) { error in
            XCTAssertEqual(
                error as? RunningExecutableIntegrityError,
                .replaced(path: fixture.executable.path)
            )
        }
    }

    func testMonitorDeliversInvalidationOnlyOnce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let invalidated = expectation(description: "Executable invalidated")
        invalidated.assertForOverFulfill = true
        let lock = NSLock()
        var callbackCount = 0
        let queue = DispatchQueue(label: "RunningExecutableIntegrityTests.monitor")
        let monitor = try RunningExecutableMonitor(executableURL: fixture.executable, queue: queue) {
            lock.lock()
            callbackCount += 1
            lock.unlock()
            invalidated.fulfill()
        }

        let original = fixture.directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: fixture.executable, to: original)
        try Data("replacement".utf8).write(to: fixture.executable)

        wait(for: [invalidated], timeout: 2)
        queue.sync {}
        withExtendedLifetime(monitor) {}
        lock.lock()
        let finalCount = callbackCount
        lock.unlock()
        XCTAssertEqual(finalCount, 1)
    }

    private func makeFixture() throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboat-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("LimitLifeboat")
        try Data("original".utf8).write(to: executable)
        return (directory, executable)
    }
}
