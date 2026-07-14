import XCTest
@testable import LimitLifeboatCore

final class ClaudeOAuthTokenRefresherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testPostsRefreshGrantAndAppliesRotatedTokens() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(
            status: 200,
            bodyText: #"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 28800}"#
        )
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        let refreshed = try await refresher.refresh(try makeCredentials(), now: now)

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.url, ClaudeOAuthConstants.tokenEndpoint)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(body["refresh_token"] as? String, "old-refresh")
        XCTAssertEqual(body["client_id"] as? String, ClaudeOAuthConstants.clientID)

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        // expires_in is seconds from now; expiresAt lands 8 hours out.
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(28_800))

        // The raw claudeAiOauth JSON keeps unmodeled fields and stores the
        // new expiry back in epoch milliseconds.
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: refreshed.rawClaudeAiOauth) as? [String: Any]
        )
        XCTAssertEqual(raw["accessToken"] as? String, "new-access")
        XCTAssertEqual(raw["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual((raw["expiresAt"] as? NSNumber)?.int64Value, 1_783_028_800_000)
        XCTAssertEqual(raw["customField"] as? String, "survives")
        XCTAssertEqual(raw["subscriptionType"] as? String, "max")
        XCTAssertEqual(refreshed.subscriptionType, "max")
        XCTAssertEqual(refreshed.scopes, ["user:inference"])
    }

    func testUsesClientIDFromCredentialJSONWhenPresent() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: #"{"access_token": "new-access", "expires_in": 60}"#)
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        let credentials = try makeCredentials(extraFields: ["clientId": "custom-client-id"])
        _ = try await refresher.refresh(credentials, now: now)

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["client_id"] as? String, "custom-client-id")
    }

    func testKeepsOldRefreshTokenWhenRotationAbsent() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: #"{"access_token": "new-access", "expires_in": 3600}"#)
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        let refreshed = try await refresher.refresh(try makeCredentials(), now: now)

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "old-refresh")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(3600))

        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: refreshed.rawClaudeAiOauth) as? [String: Any]
        )
        XCTAssertEqual(raw["refreshToken"] as? String, "old-refresh")
    }

    func testThrowsRefreshRejectedWithStatusAndBody() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 400, bodyText: #"{"error": "invalid_grant"}"#)
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        do {
            _ = try await refresher.refresh(try makeCredentials(), now: now)
            XCTFail("Expected refreshRejected")
        } catch let error as ClaudeOAuthError {
            guard case .refreshRejected(let status, let body) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("invalid_grant"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testThrowsMissingRefreshTokenWithoutTouchingTheNetwork() async throws {
        let httpClient = MockHTTPClient()
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        let credentials = try XCTUnwrap(
            ClaudeOAuthCredentials(claudeAiOauthJSON: Data(#"{"accessToken": "old-access"}"#.utf8))
        )

        do {
            _ = try await refresher.refresh(credentials, now: now)
            XCTFail("Expected missingRefreshToken")
        } catch let error as ClaudeOAuthError {
            guard case .missingRefreshToken = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

    func testThrowsMalformedResponseWhenAccessTokenMissing() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: #"{"token_type": "Bearer"}"#)
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        do {
            _ = try await refresher.refresh(try makeCredentials(), now: now)
            XCTFail("Expected malformedResponse")
        } catch let error as ClaudeOAuthError {
            guard case .malformedResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeCredentials(extraFields: [String: Any] = [:]) throws -> ClaudeOAuthCredentials {
        var object: [String: Any] = [
            "accessToken": "old-access",
            "refreshToken": "old-refresh",
            "expiresAt": 1_750_000_000_000,
            "scopes": ["user:inference"],
            "subscriptionType": "max",
            "customField": "survives"
        ]
        for (key, value) in extraFields {
            object[key] = value
        }
        let json = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: json))
    }
}
