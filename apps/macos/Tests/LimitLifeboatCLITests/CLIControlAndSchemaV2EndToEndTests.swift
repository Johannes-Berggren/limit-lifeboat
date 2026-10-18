import Foundation
import XCTest
@testable import LimitLifeboatCore

/// The built binary's `refresh` / `switch` (with the app closed, and against
/// a stand-in app on the control socket) and its schema 2 read commands.
final class CLIControlAndSchemaV2EndToEndTests: XCTestCase {
    private var harness: CLIHarness!
    private var work: AccountProfile!
    private var spare: AccountProfile!
    private var server: ControlSocketServer?

    override func setUpWithError() throws {
        harness = try CLIHarness()
        work = AccountProfile(provider: .claude, label: "Work", planLabel: "Max", isActiveCLI: true)
        spare = AccountProfile(provider: .claude, label: "Spare", planLabel: "Pro", isActiveCLI: false)
        try harness.repository.saveProfiles([work, spare])
        try harness.repository.saveUsageSnapshots([work.id: UsageSnapshot(
            accountID: work.id, provider: .claude,
            windows: [UsageWindow(id: "session", kind: .session, label: "Session (5h)", usedPercent: 30, riskLevel: .healthy)],
            riskLevel: .healthy, source: "test", lastRefreshed: Date().addingTimeInterval(-60)
        )])
    }

    override func tearDown() {
        server?.stop()
        harness.cleanUp()
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    // MARK: - App closed

    func testRefreshAndSwitchReportAppNotRunningAsJSON() throws {
        for arguments in [["refresh", "--json"], ["refresh", work.id.uuidString, "--json"], ["switch", spare.id.uuidString, "--json"]] {
            let result = try harness.run(arguments)
            XCTAssertEqual(result.status, 4, "\(arguments): exit 4 means the app is not running")
            let object = try json(result.stdout)
            XCTAssertEqual(object["ok"] as? Bool, false)
            XCTAssertEqual(object["schema"] as? Int, 2)
            let error = try XCTUnwrap(object["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "app_not_running")
            XCTAssertTrue((error["message"] as? String ?? "").contains("Open Lifeboat"), "\(error)")
        }
    }

    func testAppNotRunningInTextModeGoesToStderr() throws {
        let result = try harness.run(["switch", spare.id.uuidString])
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("isn't running. Open Lifeboat"), result.stderr)
    }

    /// A socket file left by a crashed app is still "not running".
    func testStaleSocketIsAppNotRunning() throws {
        let fake = ControlSocketServer(socketURL: harness.socketURL) { _, id in .failure(ControlError.appNotRunning, id: id) }
        try fake.start()
        // Drop the listener but keep a socket file in place.
        fake.stop()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(ControlSocketFile.makeAddress(harness.socketURL.path))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        chmod(harness.socketURL.path, 0o600)

        let result = try harness.run(["refresh", "--json"])
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual((try json(result.stdout)["error"] as? [String: Any])?["code"] as? String, "app_not_running")
    }

    func testUsageErrorsAreCaughtBeforeTheSocket() throws {
        XCTAssertEqual(try harness.run(["switch"]).status, 1)
        XCTAssertEqual(try harness.run(["switch", "not-an-id"]).status, 1)
        XCTAssertEqual(try harness.run(["refresh", "a", "b"]).status, 1)
        // Capture, rename and remove are not CLI commands.
        for command in ["capture", "rename", "remove"] {
            XCTAssertEqual(try harness.run([command, work.id.uuidString]).status, 1, command)
        }
    }

    // MARK: - Against a stand-in app

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var intents: [ControlIntent] = []
        func add(_ intent: ControlIntent) { lock.lock(); intents.append(intent); lock.unlock() }
        var all: [ControlIntent] { lock.lock(); defer { lock.unlock() }; return intents }
    }

    func testSwitchGoesThroughTheSocketAndPrintsTheResult() throws {
        let seen = Seen()
        let spareID = spare.id.uuidString
        let server = ControlSocketServer(socketURL: harness.socketURL) { intent, id in
            seen.add(intent)
            return .success(ControlResult(
                command: "switch",
                accounts: [ControlAccountOutcome(id: spareID, provider: "claude", label: "Spare", isActive: true,
                                                 lastRefreshed: nil, ageSeconds: nil, issues: [])],
                previousAccountId: "previous", alreadyActive: false
            ), id: id)
        }
        try server.start()
        self.server = server

        let result = try harness.run(["switch", spareID, "--json"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let object = try json(result.stdout)
        XCTAssertEqual(object["ok"] as? Bool, true)
        let payload = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(payload["command"] as? String, "switch")
        XCTAssertEqual(payload["previousAccountId"] as? String, "previous")
        XCTAssertEqual(seen.all, [.switchTo(accountID: spare.id)])

        let text = try harness.run(["switch", spareID])
        XCTAssertEqual(text.status, 0)
        XCTAssertTrue(text.stdout.hasPrefix("Switched claude to Spare."), text.stdout)
    }

    func testAppFailureExitsFive() throws {
        let server = ControlSocketServer(socketURL: harness.socketURL) { _, id in
            .failure(ControlError(code: "needs_login", message: "Log in again."), id: id)
        }
        try server.start()
        self.server = server

        let result = try harness.run(["refresh", work.id.uuidString, "--json"])
        XCTAssertEqual(result.status, 5)
        XCTAssertEqual((try json(result.stdout)["error"] as? [String: Any])?["code"] as? String, "needs_login")
    }

    // MARK: - Schema 2 reads

    func testStatusDetailCarriesIssuesAndAppState() throws {
        try AccountIssueStore(applicationSupportDirectory: harness.store).write(AccountIssueSnapshot(
            updatedAt: Date(), accounts: [spare.id.uuidString: [AccountIssue.from(.needsLogin(reason: "Log in again."))!]]
        ))
        let object = try json(try harness.run(["status", "--json", "--detail"]).stdout)

        XCTAssertEqual(object["schema"] as? Int, 2)
        XCTAssertEqual((object["app"] as? [String: Any])?["running"] as? Bool, false)
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        XCTAssertEqual((accounts[0]["issues"] as? [Any])?.count, 0, "a fresh reading and no app issue")
        let spareIssues = try XCTUnwrap(accounts[1]["issues"] as? [[String: Any]])
        XCTAssertEqual(spareIssues.map { $0["code"] as? String }, ["needs_login", "no_reading"])
        XCTAssertEqual(spareIssues.first?["severity"] as? String, "error")

        let text = try harness.run(["status", "--detail"])
        XCTAssertTrue(text.stdout.contains("!!needs_login: Log in again."), text.stdout)
    }

    func testDetailReportsTheAppRunningWhenItsSocketAnswers() throws {
        let server = ControlSocketServer(socketURL: harness.socketURL) { _, id in .failure(ControlError.appNotRunning, id: id) }
        try server.start()
        self.server = server
        let object = try json(try harness.run(["status", "--json", "--detail"]).stdout)
        XCTAssertEqual((object["app"] as? [String: Any])?["running"] as? Bool, true)
    }

    func testSchemaOnePinsTheV1Document() throws {
        let object = try json(try harness.run(["status", "--json", "--detail", "--schema", "1"]).stdout)
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(Set(object.keys), ["schema", "generatedAt", "accounts"])
        XCTAssertNil((object["accounts"] as? [[String: Any]])?.first?["issues"])
        XCTAssertEqual(try harness.run(["status", "--json", "--schema", "3"]).status, 1)
    }

    func testHistoryJSONHonoursDays() throws {
        let window = UsageWindowReading(id: "session", kind: .session, usedPercent: 50, resetDate: nil, windowMinutes: 300)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var lines = Data()
        for daysAgo in [0.1, 2.0, 5.0] {
            lines.append(try encoder.encode(UsageHistoryRecord(timestamp: Date().addingTimeInterval(-daysAgo * 86_400), accountID: work.id, windows: [window])))
            lines.append(10)
        }
        try lines.write(to: harness.store.appendingPathComponent("usage-history.jsonl"))

        let week = try json(try harness.run(["history", "--json"]).stdout)
        XCTAssertEqual(week["days"] as? Int, 7)
        XCTAssertEqual(((week["accounts"] as? [[String: Any]])?[0]["records"] as? [Any])?.count, 3)

        let three = try json(try harness.run(["history", "--json", "--days", "3"]).stdout)
        XCTAssertEqual(((three["accounts"] as? [[String: Any]])?[0]["records"] as? [Any])?.count, 2)
        XCTAssertEqual(((three["accounts"] as? [[String: Any]])?[1]["records"] as? [Any])?.count, 0)

        XCTAssertEqual(try harness.run(["history", "--days", "0"]).status, 1)
        XCTAssertEqual(try harness.run(["history", "--days", "31"]).status, 1)
    }

    func testSessionsJSONHasBothProviders() throws {
        let result = try harness.run(["sessions", "--json"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let object = try json(result.stdout)
        XCTAssertEqual(object["schema"] as? Int, 2)
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.map { $0["provider"] as? String }, ["claude", "codex"])
        for provider in providers {
            XCTAssertEqual((provider["sessions"] as? [Any])?.count, provider["count"] as? Int)
        }
    }

    func testVersionJSONListsSupportedSchemas() throws {
        let object = try json(try harness.run(["version", "--json"]).stdout)
        XCTAssertEqual(object["schema"] as? Int, 2)
        XCTAssertEqual(object["supportedSchemas"] as? [Int], [1, 2])
    }
}
