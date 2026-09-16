import XCTest
@testable import LimitLifeboatCore

final class ClaudeHookInstallerTests: XCTestCase {
    private var directory: URL!
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInstallKeepsOtherSettingsAndHooksAndIsIdempotent() throws {
        try write("""
        {"effortLevel":"xhigh","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}
        """)
        let installer = ClaudeHookInstaller(settingsURL: settingsURL)

        try installer.install(scriptPath: "/Users/me/Library/Application Support/LimitLifeboat/hooks/limit-lifeboat-memory-guard.sh")
        try installer.install(scriptPath: "/Users/me/Library/Application Support/LimitLifeboat/hooks/limit-lifeboat-memory-guard.sh")

        let settings = try read()
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(settings["effortLevel"] as? String, "xhigh")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        let prompt = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(prompt.count, 2)
        let command = (prompt[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(command, "'/Users/me/Library/Application Support/LimitLifeboat/hooks/limit-lifeboat-memory-guard.sh'")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path + ".limit-lifeboat-backup"))
    }

    func testUninstallRemovesOnlyTheManagedHookAndEmptyContainers() throws {
        let installer = ClaudeHookInstaller(settingsURL: settingsURL)
        try installer.install(scriptPath: "/x/limit-lifeboat-memory-guard.sh")

        try installer.uninstall()

        XCTAssertFalse(installer.isInstalled())
        XCTAssertNil(try read()["hooks"])
    }

    func testRefusesToRewriteUnparseableSettings() throws {
        try write("{ // comments are not JSON\n}")
        let installer = ClaudeHookInstaller(settingsURL: settingsURL)

        XCTAssertThrowsError(try installer.install(scriptPath: "/x/limit-lifeboat-memory-guard.sh"))
        XCTAssertEqual(try String(contentsOf: settingsURL), "{ // comments are not JSON\n}")
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: settingsURL)
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }
}

final class MemoryGuardHookScriptTests: XCTestCase {
    private var directory: URL!
    private var stateURL: URL { directory.appendingPathComponent("memory guard.json") }
    private var scriptURL: URL { directory.appendingPathComponent(MemoryGuardHookScript.fileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("it's \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = MemoryGuardHookScript.contents(
            stateFile: stateURL,
            heldDirectory: directory.appendingPathComponent("held")
        )
        try Data(script.utf8).write(to: scriptURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testHoldsFirstPromptOfNewSessionThenAllowsResubmission() throws {
        try writeState(.critical, updatedAt: Date())

        let first = try run(input: payload(session: "abc"))
        XCTAssertEqual(first.status, 2)
        XCTAssertTrue(first.stderr.contains("memory is critically low"))
        XCTAssertTrue(first.stderr.contains("1 agent session uses"))

        XCTAssertEqual(try run(input: payload(session: "abc")).status, 0)
        XCTAssertEqual(try run(input: payload(session: "abc")).status, 2)
    }

    func testNeverHoldsWhenNotCriticalStaleOrAlreadyRunning() throws {
        try writeState(.caution, updatedAt: Date())
        XCTAssertEqual(try run(input: payload(session: "a")).status, 0)

        try writeState(.critical, updatedAt: Date().addingTimeInterval(-3_600))
        XCTAssertEqual(try run(input: payload(session: "b")).status, 0)

        try writeState(.critical, updatedAt: Date())
        let transcript = directory.appendingPathComponent("t.jsonl")
        try Data(#"{"type":"assistant","message":{}}"#.utf8).write(to: transcript)
        XCTAssertEqual(try run(input: payload(session: "c", transcript: transcript.path)).status, 0)
        XCTAssertEqual(try run(input: payload(session: "d", agentID: "sub-1")).status, 0)
        XCTAssertEqual(try run(input: payload(session: "e", event: "SessionStart")).status, 0)
    }

    func testMissingStateNeverHolds() throws {
        XCTAssertEqual(try run(input: payload(session: "x")).status, 0)
    }

    private func writeState(_ level: MemoryGuardLevel, updatedAt: Date) throws {
        let session = AgentSession(pid: 1, provider: .claude, workingDirectory: "/w/app", startedAt: updatedAt, footprintBytes: 1 << 30, processCount: 1)
        let assessment = MemoryGuardAssessment(
            level: level,
            sessionCount: 1,
            sessionFootprintBytes: 1 << 30,
            availableBytes: 1 << 28,
            estimatedAdditionalSessions: 0,
            heaviestIdleSession: session,
            heaviestIdleSince: updatedAt
        )
        try MemoryGuardState(assessment: assessment, now: updatedAt).write(to: stateURL)
    }

    private func payload(
        session: String,
        transcript: String = "/nonexistent/transcript.jsonl",
        agentID: String? = nil,
        event: String = "UserPromptSubmit"
    ) -> String {
        var object: [String: Any] = [
            "session_id": session,
            "transcript_path": transcript,
            "cwd": "/w/app",
            "hook_event_name": event,
            "prompt": "hello"
        ]
        object["agent_id"] = agentID
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func run(input: String) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, errorText)
    }
}
