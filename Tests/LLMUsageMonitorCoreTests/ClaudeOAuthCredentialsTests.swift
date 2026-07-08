import XCTest
@testable import LLMUsageMonitorCore

final class ClaudeOAuthCredentialsTests: XCTestCase {
    private let keychainItemJSON = Data("""
    {
        "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-access",
            "refreshToken": "sk-ant-ort01-refresh",
            "expiresAt": 1800000000000,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "default_max_20x",
            "unknownField": true
        },
        "mcpOAuth": {
            "someServer": {"accessToken": "mcp-token", "expiresAt": 1790000000000}
        }
    }
    """.utf8)

    func testExtractsCredentialsFromKeychainItemJSON() throws {
        let credentials = try XCTUnwrap(
            ClaudeOAuthCredentials.extract(fromKeychainItemJSON: keychainItemJSON)
        )

        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-access")
        XCTAssertEqual(credentials.refreshToken, "sk-ant-ort01-refresh")
        // expiresAt is stored in epoch milliseconds.
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(credentials.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertEqual(credentials.rateLimitTier, "default_max_20x")
        XCTAssertNil(credentials.clientID)

        // The raw JSON keeps only the claudeAiOauth object — mcpOAuth is the
        // keychain item's sibling, not part of the credentials — and keeps
        // fields the struct does not model.
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: credentials.rawClaudeAiOauth) as? [String: Any]
        )
        XCTAssertNil(raw["mcpOAuth"])
        XCTAssertEqual(raw["unknownField"] as? Bool, true)
        XCTAssertEqual(raw["accessToken"] as? String, "sk-ant-oat01-access")
    }

    func testParsesClientIDWhenPresent() throws {
        let credentials = try makeCredentials(fields: [
            "accessToken": "token",
            "clientId": "custom-client-id"
        ])
        XCTAssertEqual(credentials.clientID, "custom-client-id")
    }

    func testReturnsNilWithoutAccessToken() throws {
        let json = try JSONSerialization.data(withJSONObject: ["refreshToken": "refresh"])
        XCTAssertNil(ClaudeOAuthCredentials(claudeAiOauthJSON: json))
    }

    func testExtractReturnsNilWhenClaudeAiOauthMissing() {
        let itemJSON = Data(#"{"mcpOAuth": {"someServer": {"accessToken": "mcp-token"}}}"#.utf8)
        XCTAssertNil(ClaudeOAuthCredentials.extract(fromKeychainItemJSON: itemJSON))
    }

    func testIsExpiredHonorsLeeway() throws {
        let now = Date(timeIntervalSince1970: 1_783_000_000)

        let comfortablyValid = try makeCredentials(expiresAt: now.addingTimeInterval(600))
        XCTAssertFalse(comfortablyValid.isExpired(asOf: now))

        // Inside the 5-minute leeway counts as expired, boundary included.
        let insideLeeway = try makeCredentials(expiresAt: now.addingTimeInterval(299))
        XCTAssertTrue(insideLeeway.isExpired(asOf: now))
        let onBoundary = try makeCredentials(expiresAt: now.addingTimeInterval(300))
        XCTAssertTrue(onBoundary.isExpired(asOf: now))

        let alreadyExpired = try makeCredentials(expiresAt: now.addingTimeInterval(-1))
        XCTAssertTrue(alreadyExpired.isExpired(asOf: now))

        let customLeeway = try makeCredentials(expiresAt: now.addingTimeInterval(299))
        XCTAssertFalse(customLeeway.isExpired(asOf: now, leeway: 0))

        let noExpiry = try makeCredentials(fields: ["accessToken": "token"])
        XCTAssertFalse(noExpiry.isExpired(asOf: now))
    }

    func testMergeClaudeAiOauthPreservesSiblingKeys() throws {
        let existing = Data("""
        {
            "claudeAiOauth": {"accessToken": "stale-access"},
            "mcpOAuth": {"someServer": {"accessToken": "mcp-token"}},
            "customTopLevel": "keep me"
        }
        """.utf8)
        let newObject = Data(#"{"accessToken": "fresh-access", "refreshToken": "fresh-refresh"}"#.utf8)

        let merged = mergeClaudeAiOauth(newObject, intoItemJSON: existing)
        let item = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])

        let claudeAiOauth = try XCTUnwrap(item["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(claudeAiOauth["accessToken"] as? String, "fresh-access")
        XCTAssertEqual(claudeAiOauth["refreshToken"] as? String, "fresh-refresh")

        let mcpOAuth = try XCTUnwrap(item["mcpOAuth"] as? [String: Any])
        let someServer = try XCTUnwrap(mcpOAuth["someServer"] as? [String: Any])
        XCTAssertEqual(someServer["accessToken"] as? String, "mcp-token")
        XCTAssertEqual(item["customTopLevel"] as? String, "keep me")
    }

    func testMergeClaudeAiOauthIntoMissingItemStartsFresh() throws {
        let newObject = Data(#"{"accessToken": "fresh-access"}"#.utf8)

        let merged = mergeClaudeAiOauth(newObject, intoItemJSON: nil)
        let item = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])

        XCTAssertEqual(item.count, 1)
        let claudeAiOauth = try XCTUnwrap(item["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(claudeAiOauth["accessToken"] as? String, "fresh-access")
    }

    private func makeCredentials(expiresAt: Date) throws -> ClaudeOAuthCredentials {
        try makeCredentials(fields: [
            "accessToken": "token",
            "expiresAt": Int64((expiresAt.timeIntervalSince1970 * 1000).rounded())
        ])
    }

    private func makeCredentials(fields: [String: Any]) throws -> ClaudeOAuthCredentials {
        let json = try JSONSerialization.data(withJSONObject: fields)
        return try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: json))
    }
}

/// The keychain type shells out to /usr/bin/security, so these exercise the
/// pure output-normalization and command-building helpers directly.
final class ClaudeCodeCredentialsKeychainTests: XCTestCase {
    func testDecodePasswordOutputPassesASCIIJSONThrough() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        XCTAssertEqual(
            ClaudeCodeCredentialsKeychain.decodePasswordOutput(json + "\n"),
            Data(json.utf8)
        )
    }

    func testDecodePasswordOutputDecodesBareHex() {
        // security prints a password containing any non-ASCII byte as bare
        // lowercase hex with no 0x prefix: {"k":"café"}.
        let decoded = ClaudeCodeCredentialsKeychain.decodePasswordOutput("7b226b223a22636166c3a9227d\n")
        XCTAssertEqual(decoded, Data(#"{"k":"café"}"#.utf8))
    }

    func testDecodePasswordOutputDecodes0xPrefixedHex() {
        let decoded = ClaudeCodeCredentialsKeychain.decodePasswordOutput("0x7b226b223a22636166c3a9227d")
        XCTAssertEqual(decoded, Data(#"{"k":"café"}"#.utf8))
    }

    func testDecodePasswordOutputFallsBackToUTF8ForNonHexText() {
        XCTAssertEqual(
            ClaudeCodeCredentialsKeychain.decodePasswordOutput("not-hex-at-all"),
            Data("not-hex-at-all".utf8)
        )
        // Odd-length hex-looking text is not valid hex output either.
        XCTAssertEqual(
            ClaudeCodeCredentialsKeychain.decodePasswordOutput("abc"),
            Data("abc".utf8)
        )
    }

    func testDecodePasswordOutputReturnsNilForEmptyOutput() {
        XCTAssertNil(ClaudeCodeCredentialsKeychain.decodePasswordOutput(""))
        XCTAssertNil(ClaudeCodeCredentialsKeychain.decodePasswordOutput(" \n"))
    }

    func testAddCommandEscapesQuotesAndBackslashes() {
        let command = ClaudeCodeCredentialsKeychain.makeAddGenericPasswordCommand(
            account: "user",
            service: "Claude Code-credentials",
            value: #"{"k":"a\"b","p":"x\y"}"#
        )
        XCTAssertEqual(
            command,
            #"add-generic-password -U -a "user" -s "Claude Code-credentials" -w "{\"k\":\"a\\\"b\",\"p\":\"x\\y\"}""#
        )
    }

    func testAddCommandPassesNonASCIIValueThrough() {
        let command = ClaudeCodeCredentialsKeychain.makeAddGenericPasswordCommand(
            account: "user",
            service: "svc",
            value: #"{"k":"café"}"#
        )
        XCTAssertEqual(command, #"add-generic-password -U -a "user" -s "svc" -w "{\"k\":\"café\"}""#)
    }
}
