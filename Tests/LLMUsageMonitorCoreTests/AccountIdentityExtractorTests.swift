import XCTest
@testable import LLMUsageMonitorCore

final class AccountIdentityExtractorTests: XCTestCase {
    func testExtractsDashboardEmailAndOrganization() throws {
        let identity = try XCTUnwrap(AccountIdentityExtractor().extractFromDashboardText(
            "Settings Profile johannes@example.com Workspace: Findable AI Usage"
        ))

        XCTAssertEqual(identity.email, "johannes@example.com")
        XCTAssertEqual(identity.organization, "Findable AI")
        XCTAssertEqual(identity.source, .dashboard)
    }

    func testReadsCodexIdentityFromIDToken() throws {
        let fixture = try TemporaryIdentityFixture()
        defer { fixture.cleanup() }

        let authURL = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let payload = #"{"email":"codex@example.com","name":"Codex User","https://api.openai.com/auth":{"organizations":[{"id":"org_1","title":"Personal","is_default":false},{"id":"org_2","title":"Findable","is_default":true}]}}"#
        let token = "header.\(Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")).signature"
        let auth = #"{"tokens":{"id_token":"\#(token)","account_id":"acct_123"}}"#
        try Data(auth.utf8).write(to: authURL)

        let identity = try XCTUnwrap(CodexIdentityReader(homeDirectory: fixture.home).readIdentity())

        XCTAssertEqual(identity.email, "codex@example.com")
        XCTAssertEqual(identity.displayName, "Codex User")
        XCTAssertEqual(identity.organization, "Findable")
        XCTAssertEqual(identity.accountID, "acct_123")
        XCTAssertEqual(identity.source, .codexIDToken)
    }

    func testReadsClaudeIdentityFromLocalAccountMetadata() throws {
        let fixture = try TemporaryIdentityFixture()
        defer { fixture.cleanup() }

        let configURL = fixture.home.appendingPathComponent(".claude.json")
        try """
        {
          "oauthAccount": {
            "accountUuid": "account-1",
            "displayName": "Johannes",
            "emailAddress": "berggren@findable.ai",
            "organizationName": "berggren@findable.ai's Organization",
            "organizationUuid": "org-1"
          }
        }
        """.data(using: .utf8)!.write(to: configURL)

        let identity = try XCTUnwrap(ClaudeIdentityReader(homeDirectory: fixture.home).readIdentity())

        XCTAssertEqual(identity.email, "berggren@findable.ai")
        XCTAssertEqual(identity.displayName, "Johannes")
        XCTAssertEqual(identity.organization, "berggren@findable.ai's Organization")
        XCTAssertEqual(identity.organizationID, "org-1")
        XCTAssertEqual(identity.accountID, "account-1")
        XCTAssertEqual(identity.source, .claudeCodeUsage)
    }
}

private struct TemporaryIdentityFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMUsageMonitorIdentityTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
