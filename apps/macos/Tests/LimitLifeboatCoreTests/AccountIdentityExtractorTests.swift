import XCTest
@testable import LimitLifeboatCore

final class AccountIdentityExtractorTests: XCTestCase {
    func testExtractsDashboardEmailAndOrganization() throws {
        let identity = try XCTUnwrap(AccountIdentityExtractor().extractFromDashboardText(
            "Settings Profile alex@example.com Workspace: Example Labs Usage"
        ))

        XCTAssertEqual(identity.email, "alex@example.com")
        XCTAssertEqual(identity.organization, "Example Labs")
        XCTAssertEqual(identity.source, .dashboard)
    }

    func testReadsCodexIdentityFromIDToken() throws {
        let fixture = try TemporaryIdentityFixture()
        defer { fixture.cleanup() }

        let authURL = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let payload = #"{"email":"codex@example.com","name":"Codex User","https://api.openai.com/auth":{"organizations":[{"id":"org_1","title":"Personal","is_default":false},{"id":"org_2","title":"Example Labs","is_default":true}]}}"#
        let token = "header.\(Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")).signature"
        let auth = #"{"tokens":{"id_token":"\#(token)","account_id":"acct_123"}}"#
        try Data(auth.utf8).write(to: authURL)

        let identity = try XCTUnwrap(CodexIdentityReader(homeDirectory: fixture.home).readIdentity())

        XCTAssertEqual(identity.email, "codex@example.com")
        XCTAssertEqual(identity.displayName, "Codex User")
        XCTAssertEqual(identity.organization, "Example Labs")
        XCTAssertEqual(identity.accountID, "acct_123")
        XCTAssertEqual(identity.source, .codexIDToken)
    }

    func testDecodesCodexPlanTierFromIDToken() throws {
        let payload = #"{"email":"codex@example.com","name":"Codex User","https://api.openai.com/auth":{"chatgpt_plan_type":"pro","organizations":[{"id":"org_2","title":"Example Labs","is_default":true}]}}"#
        let token = "header.\(Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")).signature"
        let auth = #"{"tokens":{"id_token":"\#(token)","account_id":"acct_123"}}"#

        let info = try XCTUnwrap(CodexIdentityReader.accountInfo(fromAuthJSON: Data(auth.utf8)))
        XCTAssertEqual(info.planLabel, "Pro")
        XCTAssertEqual(info.identity?.email, "codex@example.com")
        XCTAssertEqual(info.identity?.accountID, "acct_123")
        XCTAssertEqual(info.identity?.organization, "Example Labs")
    }

    /// The inactive-account path: identity + plan derived from a captured
    /// auth.json blob, no live file needed.
    func testAccountInfoFromCapturedAuthJSONData() throws {
        let payload = #"{"email":"team-user@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"team"}}"#
        let token = "h.\(Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")).s"
        let auth = #"{"tokens":{"id_token":"\#(token)","account_id":"acct_9"}}"#

        let info = try XCTUnwrap(CodexIdentityReader.accountInfo(fromAuthJSON: Data(auth.utf8)))
        XCTAssertEqual(info.planLabel, "Team")
        XCTAssertEqual(info.identity?.email, "team-user@example.com")
    }

    func testCodexPlanLabelNormalizer() {
        XCTAssertEqual(CodexIdentityReader.planLabel(forPlanType: "free"), "Free")
        XCTAssertEqual(CodexIdentityReader.planLabel(forPlanType: "plus"), "Plus")
        XCTAssertEqual(CodexIdentityReader.planLabel(forPlanType: "pro"), "Pro")
        XCTAssertEqual(CodexIdentityReader.planLabel(forPlanType: "team"), "Team")
        XCTAssertEqual(CodexIdentityReader.planLabel(forPlanType: "enterprise"), "Enterprise")
        // Unknown values pass through title-cased rather than being dropped.
        XCTAssertEqual(CodexIdentityReader.planLabel(forPlanType: "founders"), "Founders")
        XCTAssertNil(CodexIdentityReader.planLabel(forPlanType: nil))
        XCTAssertNil(CodexIdentityReader.planLabel(forPlanType: ""))
    }

    func testReadsClaudeIdentityFromLocalAccountMetadata() throws {
        let fixture = try TemporaryIdentityFixture()
        defer { fixture.cleanup() }

        let configURL = fixture.home.appendingPathComponent(".claude.json")
        try """
        {
          "oauthAccount": {
            "accountUuid": "account-1",
            "displayName": "Taylor",
            "emailAddress": "developer@example.com",
            "organizationName": "developer@example.com's Organization",
            "organizationUuid": "org-1"
          }
        }
        """.data(using: .utf8)!.write(to: configURL)

        let identity = try XCTUnwrap(ClaudeIdentityReader(homeDirectory: fixture.home).readIdentity())

        XCTAssertEqual(identity.email, "developer@example.com")
        XCTAssertEqual(identity.displayName, "Taylor")
        XCTAssertEqual(identity.organization, "developer@example.com's Organization")
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
            .appendingPathComponent("LimitLifeboatIdentityTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
