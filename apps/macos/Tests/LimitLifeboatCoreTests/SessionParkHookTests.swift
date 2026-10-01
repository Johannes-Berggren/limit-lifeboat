import XCTest
@testable import LimitLifeboatCore

final class SessionParkHookScriptTests: XCTestCase {
    private var directory: URL!
    private var stateURL: URL { directory.appendingPathComponent("park state.json") }
    private var waitingURL: URL { directory.appendingPathComponent("waiting") }
    private var scriptURL: URL { directory.appendingPathComponent(SessionParkHookScript.fileName) }
    /// The test runner is an ancestor of every hook it launches, so parking
    /// it stands in for parking the Claude Code process.
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("it's \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeScript(deadlineSeconds: 600)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testUnparkedSessionsPassStraightThrough() throws {
        try writeState(pids: [ownPID + 100_000])
        let result = try runHook()
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(result.elapsed, 1)
        XCTAssertEqual(result.stdout, "")
    }

    func testParkedSessionWaitsUntilReleased() throws {
        try writeState(pids: [ownPID])
        let process = try start()

        let marker = waitingURL.appendingPathComponent(String(ownPID))
        try waitFor { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(process.isRunning)

        try writeState(pids: [])
        try waitFor { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAStoppedAppReleasesEveryone() throws {
        try writeState(pids: [ownPID])
        let process = try start()
        try waitFor { FileManager.default.fileExists(atPath: self.waitingURL.appendingPathComponent(String(self.ownPID)).path) }

        try writeState(pids: [ownPID], updatedAt: Date().addingTimeInterval(-3_600))
        try waitFor { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testDeniesWithAWaitReasonBeforeClaudeCodeTimesOut() throws {
        try writeScript(deadlineSeconds: 1)
        try writeState(pids: [ownPID])

        let result = try runHook()

        XCTAssertEqual(result.status, 0)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let specific = try XCTUnwrap(output["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertTrue((specific["permissionDecisionReason"] as? String)?.contains("retry the same tool call") == true)
    }

    func testMissingStaleOrBypassedStateNeverParks() throws {
        XCTAssertEqual(try runHook().status, 0)

        try writeState(pids: [ownPID], updatedAt: Date().addingTimeInterval(-3_600))
        XCTAssertLessThan(try runHook().elapsed, 1)

        try writeState(pids: [ownPID])
        let bypassed = try runHook(environment: ["LIMIT_LIFEBOAT_PARK": "off"])
        XCTAssertEqual(bypassed.status, 0)
        XCTAssertLessThan(bypassed.elapsed, 1)
    }

    func testInstallsAsAPreToolUseHookWithALongTimeout() throws {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let installer = ClaudeHookInstaller(hook: SessionParkHookScript.hook, settingsURL: settingsURL)
        let memoryGuard = ClaudeHookInstaller(settingsURL: settingsURL)
        try memoryGuard.install(scriptPath: "/x/\(MemoryGuardHookScript.fileName)")

        try installer.install(scriptPath: "/x/\(SessionParkHookScript.fileName)")

        XCTAssertEqual(installer.status(expectedScriptPath: "/x/\(SessionParkHookScript.fileName)"), .installed)
        XCTAssertEqual(memoryGuard.status(expectedScriptPath: "/x/\(MemoryGuardHookScript.fileName)"), .installed)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let entry = try XCTUnwrap(((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["matcher"] as? String, "*")
        XCTAssertEqual((entry["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, SessionParkHookScript.timeoutSeconds)

        try installer.uninstall()
        XCTAssertEqual(installer.status(expectedScriptPath: "/x/\(SessionParkHookScript.fileName)"), .notInstalled)
        XCTAssertEqual(memoryGuard.status(expectedScriptPath: "/x/\(MemoryGuardHookScript.fileName)"), .installed)
    }

    // MARK: - Helpers

    private func writeScript(deadlineSeconds: Int) throws {
        let script = SessionParkHookScript.contents(
            stateFile: stateURL,
            waitingDirectory: waitingURL,
            pollSeconds: 1,
            deadlineSeconds: deadlineSeconds
        )
        try Data(script.utf8).write(to: scriptURL)
    }

    private func writeState(pids: [Int32], updatedAt: Date = Date()) throws {
        let entries = pids.map {
            SessionParkState.Entry(pid: $0, startedAt: updatedAt, project: "app", reason: .manual, parkedAt: updatedAt)
        }
        try SessionParkState(parked: entries, now: updatedAt).write(to: stateURL)
    }

    private func start(environment: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        try? stdin.fileHandleForWriting.write(contentsOf: Data(#"{"hook_event_name":"PreToolUse","session_id":"s"}"#.utf8))
        try? stdin.fileHandleForWriting.close()
        return process
    }

    private func runHook(environment: [String: String] = [:]) throws -> (status: Int32, stdout: String, elapsed: TimeInterval) {
        let began = Date()
        let process = try start(environment: environment)
        process.waitUntilExit()
        let output = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), Date().timeIntervalSince(began))
    }

    private func waitFor(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
