import XCTest
@testable import LimitLifeboatCore

final class ClaudeBrowserConnectionTests: XCTestCase {
    private var home: URL!
    private var log: URL { home.appendingPathComponent("claude.log") }
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var configURL: URL { home.appendingPathComponent(".claude.json") }
    private var connection: ClaudeBrowserConnection {
        ClaudeBrowserConnection(
            homeDirectory: home,
            processEnvironment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/inherited"]
        )
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A stand-in `claude`: `mcp` edits `.claude.json` and the server flag
    /// answers two JSON-RPC requests.
    private func installFakeClaude(toolText: String = "[]", exitStatus: Int = 0) throws {
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("claude")
        let reply = #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"\#(toolText)"}]}}"#
        try """
        #!/bin/sh
        echo "$* CONFIG=$CLAUDE_CONFIG_DIR" >> '\(log.path)'
        [ \(exitStatus) -eq 0 ] || { echo 'mcp failed'; exit \(exitStatus); }
        case "$1 $2" in
          "mcp add-json") printf '{"mcpServers":{"%s":%s}}' "$3" "$4" > '\(configURL.path)' ;;
          "mcp remove") printf '{"mcpServers":{}}' > '\(configURL.path)' ;;
          "--claude-in-chrome-mcp "*)
            while read -r line; do
              case "$line" in
                *'"id":1'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
                *'"id":2'*) echo '\(reply)' ;;
              esac
            done ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] ?? [:]
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
    }

    func testInstallAddsTheServerAndDenialThenUninstallRemovesBoth() throws {
        try installFakeClaude()
        try writeSettings(["model": "opus"])
        XCTAssertEqual(connection.status(), .notSet)

        try connection.install()
        XCTAssertEqual(connection.status(), .installed)
        let denied = try settings()["deniedMcpServers"] as? [[String: String]]
        XCTAssertEqual(denied, [["serverName": "claude-in-chrome"]])

        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let server = (config?["mcpServers"] as? [String: Any])?["browser"] as? [String: Any]
        XCTAssertEqual(server?["command"] as? String, home.appendingPathComponent(".local/bin/claude").path)
        XCTAssertEqual(server?["args"] as? [String], ["--claude-in-chrome-mcp"])
        XCTAssertEqual(server?["env"] as? [String: String], ["CLAUDE_CONFIG_DIR": connection.configDirectory.path])

        try connection.uninstall()
        XCTAssertEqual(connection.status(), .notSet)
        XCTAssertNil(try settings()["deniedMcpServers"])
        XCTAssertEqual(try settings()["model"] as? String, "opus")
    }

    func testMcpCommandsNeverRunUnderAnInheritedConfigDirectory() throws {
        try installFakeClaude()
        try connection.install()
        let lines = try String(contentsOf: log).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("CONFIG="), String(lines[0]))
    }

    func testKeepsADenialTheUserAlreadyHad() throws {
        try installFakeClaude()
        try writeSettings(["deniedMcpServers": [["serverName": "claude-in-chrome"], ["serverName": "other"]]])

        try connection.install()
        try connection.uninstall()

        let denied = try settings()["deniedMcpServers"] as? [[String: String]]
        XCTAssertEqual(denied?.count, 2)
    }

    func testAnotherCopyOfTheAppCanUndoTheDenial() throws {
        try installFakeClaude()
        try connection.install()

        let otherCopy = ClaudeBrowserConnection(homeDirectory: home, processEnvironment: ["PATH": "/usr/bin:/bin"])
        try otherCopy.uninstall()

        XCTAssertNil(try settings()["deniedMcpServers"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: connection.configDirectory.appendingPathComponent(ClaudeBrowserConnection.addedDenialMarkerName).path
        ))
    }

    func testUninstallLeavesOtherDenialsInPlace() throws {
        try installFakeClaude()
        try writeSettings(["deniedMcpServers": [["serverName": "other"]]])

        try connection.install()
        try connection.uninstall()

        let denied = try settings()["deniedMcpServers"] as? [[String: String]]
        XCTAssertEqual(denied, [["serverName": "other"]])
    }

    func testNeverReplacesSomeoneElsesServer() throws {
        try installFakeClaude()
        let theirs = #"{"mcpServers":{"browser":{"type":"stdio","command":"/usr/local/bin/playwright"}}}"#
        try Data(theirs.utf8).write(to: configURL)

        XCTAssertEqual(connection.status(), .other("/usr/local/bin/playwright"))
        XCTAssertThrowsError(try connection.install()) { error in
            XCTAssertEqual(error as? ClaudeBrowserConnection.ConnectionError, .otherServer("/usr/local/bin/playwright"))
        }
        try connection.uninstall()
        XCTAssertEqual(try String(contentsOf: configURL), theirs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testAFailedAddChangesNoSettings() throws {
        try installFakeClaude(exitStatus: 1)
        try writeSettings(["model": "opus"])

        XCTAssertThrowsError(try connection.install()) { error in
            XCTAssertEqual(error as? ClaudeBrowserConnection.ConnectionError, .commandFailed("mcp failed"))
        }
        XCTAssertNil(try settings()["deniedMcpServers"])
    }

    func testUnreadableSettingsStopBeforeAddingTheServer() throws {
        try installFakeClaude()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: settingsURL)

        XCTAssertThrowsError(try connection.install())
        XCTAssertEqual(connection.status(), .notSet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testReadsTheBrowserLoginsIdentityFromItsOwnConfig() throws {
        XCTAssertNil(connection.signedInIdentity())
        try FileManager.default.createDirectory(at: connection.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"browser@example.com"}}"#.utf8)
            .write(to: connection.configDirectory.appendingPathComponent(".claude.json"))
        try Data(#"{"oauthAccount":{"emailAddress":"cli@example.com"}}"#.utf8).write(to: configURL)

        XCTAssertEqual(connection.signedInIdentity()?.email, "browser@example.com")
    }

    func testCheckRunsTheServerUnderTheBrowserLogin() throws {
        try installFakeClaude(toolText: #"[{\"deviceId\":\"a\"},{\"deviceId\":\"b\"}]"#)

        XCTAssertEqual(connection.checkConnection(timeout: 10), .connected(browsers: 2))
        let lines = try String(contentsOf: log).split(separator: "\n")
        XCTAssertEqual(lines, ["--claude-in-chrome-mcp CONFIG=\(connection.configDirectory.path)"])
    }

    func testCheckReportsNoBrowserFromAnEmptyListOrAnExplanation() throws {
        try installFakeClaude(toolText: "[]")
        XCTAssertEqual(connection.checkConnection(timeout: 10), .noBrowser)
        try installFakeClaude(toolText: "Browser extension is not connected.")
        XCTAssertEqual(connection.checkConnection(timeout: 10), .noBrowser)
    }

    func testCheckIsUnavailableWhenTheServerExits() throws {
        try installFakeClaude(exitStatus: 1)
        XCTAssertEqual(connection.checkConnection(timeout: 10), .unavailable)
    }
}
