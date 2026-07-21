import XCTest
@testable import LimitLifeboatCore

final class ClaudeOAuthTokenRefresherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testPostsRefreshGrantAndAppliesRotatedTokens() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(
            status: 200,
            bodyText: #"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 28800, "refresh_token_expires_in": 604800}"#
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
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, now.addingTimeInterval(604_800))

        // The raw claudeAiOauth JSON keeps unmodeled fields and stores the
        // new expiry back in epoch milliseconds.
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: refreshed.rawClaudeAiOauth) as? [String: Any]
        )
        XCTAssertEqual(raw["accessToken"] as? String, "new-access")
        XCTAssertEqual(raw["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual((raw["expiresAt"] as? NSNumber)?.int64Value, 1_783_028_800_000)
        XCTAssertEqual(
            (raw["refreshTokenExpiresAt"] as? NSNumber)?.int64Value,
            1_783_604_800_000
        )
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

    func testMissingAccessLifetimeRemovesStaleExpiryAndPreservesFixedLoginExpiry() async throws {
        let fixedExpiry = now.addingTimeInterval(604_800)
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: #"{"access_token":"new-access"}"#)
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)
        let credentials = try makeCredentials(extraFields: [
            "refreshTokenExpiresAt": Int64((fixedExpiry.timeIntervalSince1970 * 1000).rounded())
        ])

        let refreshed = try await refresher.refresh(credentials, now: now)

        XCTAssertNil(refreshed.expiresAt)
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, fixedExpiry)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: refreshed.rawClaudeAiOauth) as? [String: Any]
        )
        XCTAssertNil(raw["expiresAt"])
        XCTAssertEqual(
            (raw["refreshTokenExpiresAt"] as? NSNumber)?.int64Value,
            Int64((fixedExpiry.timeIntervalSince1970 * 1000).rounded())
        )
    }

    func testKeepsOldRefreshTokenWhenRotationIsExplicitNull() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(
            status: 200,
            bodyText: #"{"access_token":"new-access","refresh_token":null,"expires_in":3600}"#
        )
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)

        let refreshed = try await refresher.refresh(try makeCredentials(), now: now)

        // An explicit null refresh_token means "not rotating", exactly like an
        // omitted key: keep the fresh access token instead of discarding the
        // exchange as malformed (which would loop forever, never updating it).
        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "old-refresh")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(3600))
    }

    func testExplicitNullAccessLifetimeIsUnknownNotMalformed() async throws {
        let fixedExpiry = now.addingTimeInterval(604_800)
        let httpClient = MockHTTPClient()
        httpClient.stub(
            status: 200,
            bodyText: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":null}"#
        )
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)
        let credentials = try makeCredentials(extraFields: [
            "refreshTokenExpiresAt": Int64((fixedExpiry.timeIntervalSince1970 * 1000).rounded())
        ])

        let refreshed = try await refresher.refresh(credentials, now: now)

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertNil(refreshed.expiresAt)
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, fixedExpiry)
    }

    func testExplicitNullRefreshTokenExpiryPreservesFixedLoginExpiry() async throws {
        let fixedExpiry = now.addingTimeInterval(604_800)
        let httpClient = MockHTTPClient()
        httpClient.stub(
            status: 200,
            bodyText: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"refresh_token_expires_in":null}"#
        )
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)
        let credentials = try makeCredentials(extraFields: [
            "refreshTokenExpiresAt": Int64((fixedExpiry.timeIntervalSince1970 * 1000).rounded())
        ])

        let refreshed = try await refresher.refresh(credentials, now: now)

        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(3600))
        // An explicit null behaves like an omitted key: keep the fixed login
        // expiry rather than throwing a rotated exchange away and forcing an
        // avoidable re-login.
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, fixedExpiry)
    }

    func testRejectsExplicitlyEmptyRotatedRefreshToken() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(
            status: 200,
            bodyText: #"{"access_token":"new-access","refresh_token":"   ","expires_in":3600}"#
        )

        await assertMalformedResponse(from: httpClient)
    }

    func testRejectsNonpositiveOrNonnumericDurations() async throws {
        for body in [
            #"{"access_token":"new-access","expires_in":0}"#,
            #"{"access_token":"new-access","expires_in":-1}"#,
            #"{"access_token":"new-access","expires_in":true}"#,
            #"{"access_token":"new-access","expires_in":"3600"}"#,
            #"{"access_token":"new-access","expires_in":1e308}"#,
            #"{"access_token":"new-access","expires_in":3600,"refresh_token_expires_in":0}"#
        ] {
            let httpClient = MockHTTPClient()
            httpClient.stub(status: 200, bodyText: body)
            await assertMalformedResponse(from: httpClient)
        }
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

    func testRefreshRejectedDescriptionNeverIncludesResponseBody() {
        let secretMarker = "access-token-must-not-reach-logs"
        let error = ClaudeOAuthError.refreshRejected(
            status: 400,
            body: #"{"error":"invalid_grant","token":"\#(secretMarker)"}"#
        )

        XCTAssertFalse(error.localizedDescription.contains(secretMarker))
        XCTAssertFalse(String(describing: error).contains(secretMarker))
        XCTAssertFalse(String(reflecting: error).contains(secretMarker))
        XCTAssertTrue(error.localizedDescription.contains("400"))
        XCTAssertTrue(error.localizedDescription.contains("response bytes"))
        XCTAssertTrue(error.requiresLogin)
    }

    func testOnlyExactStructuredTerminalCodesRequireLogin() {
        let exact = ClaudeOAuthError.refreshRejected(
            status: 400,
            body: #"{"error":" INVALID_GRANT ","error_description":"token rotated"}"#
        )
        XCTAssertEqual(exact.rejectionCode, "invalid_grant")
        XCTAssertTrue(exact.requiresLogin)

        let proseOnly = ClaudeOAuthError.refreshRejected(
            status: 400,
            body: #"{"error":"invalid_request","error_description":"refresh token expired; sign in again"}"#
        )
        XCTAssertEqual(proseOnly.rejectionCode, "invalid_request")
        XCTAssertFalse(proseOnly.requiresLogin)

        XCTAssertFalse(
            ClaudeOAuthError.refreshRejected(
                status: 401,
                body: #"{"message":"invalid_grant"}"#
            ).requiresLogin
        )
        XCTAssertFalse(
            ClaudeOAuthError.refreshRejected(
                status: 400,
                body: #"{"error":"invalid_grant_extra"}"#
            ).requiresLogin
        )
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

    func testWhitespaceRefreshTokenIsMissingWithoutTouchingTheNetwork() async throws {
        let httpClient = MockHTTPClient()
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)
        let credentials = try makeCredentials(extraFields: ["refreshToken": "  \n "])

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

    func testExpiredRefreshTokenFailsWithoutTouchingTheNetwork() async throws {
        let httpClient = MockHTTPClient()
        let refresher = ClaudeOAuthTokenRefresher(httpClient: httpClient)
        let credentials = try makeCredentials(extraFields: [
            "refreshTokenExpiresAt": Int64((now.addingTimeInterval(-1).timeIntervalSince1970 * 1000).rounded())
        ])

        do {
            _ = try await refresher.refresh(credentials, now: now)
            XCTFail("Expected expired login")
        } catch let error as ClaudeOAuthError {
            guard case .refreshTokenExpired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
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

    func testOnlyAuthenticationSpecificRefreshRejectionsRequireLogin() {
        XCTAssertTrue(ClaudeOAuthError.missingRefreshToken.requiresLogin)
        XCTAssertTrue(ClaudeOAuthError.refreshTokenExpired.requiresLogin)
        XCTAssertTrue(
            ClaudeOAuthError.refreshRejected(
                status: 400,
                body: #"{"error":"invalid_grant"}"#
            ).requiresLogin
        )
        XCTAssertFalse(ClaudeOAuthError.refreshRejected(status: 401, body: "").requiresLogin)
        XCTAssertFalse(ClaudeOAuthError.refreshSuppressed(reason: "Sign in again.").requiresLogin)
        XCTAssertFalse(ClaudeOAuthError.refreshRejected(status: 408, body: "timeout").requiresLogin)
        XCTAssertFalse(ClaudeOAuthError.refreshRejected(status: 429, body: "rate limited").requiresLogin)
        XCTAssertFalse(ClaudeOAuthError.refreshRejected(status: 500, body: "server error").requiresLogin)
        XCTAssertFalse(ClaudeOAuthError.malformedResponse.requiresLogin)
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

    private func assertMalformedResponse(
        from httpClient: MockHTTPClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ClaudeOAuthTokenRefresher(httpClient: httpClient)
                .refresh(try makeCredentials(), now: now)
            XCTFail("Expected malformedResponse", file: file, line: line)
        } catch let error as ClaudeOAuthError {
            guard case .malformedResponse = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
