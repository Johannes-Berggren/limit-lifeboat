import Foundation
import XCTest
@testable import LimitLifeboatCore

final class ClaudeUsageProbeCredentialSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeniedOrMissingLiveUsesValidStoredCredential() throws {
        let stored = try credential(
            token: "stored-token",
            accessExpiry: now.addingTimeInterval(3_600)
        )

        XCTAssertEqual(
            ClaudeUsageProbeCredentialSelector.select(
                live: nil,
                stored: stored,
                now: now
            )?.accessToken,
            "stored-token"
        )
    }

    func testMissingExpiredAndMalformedCredentialsAreRejected() throws {
        let missingExpiry = try credential(token: "no-expiry", accessExpiry: nil)
        let expiredAccess = try credential(
            token: "expired",
            accessExpiry: now.addingTimeInterval(-1)
        )
        let expiredLogin = try credential(
            token: "expired-login",
            accessExpiry: now.addingTimeInterval(3_600),
            loginExpiry: now.addingTimeInterval(-1)
        )
        let malformedToken = try credential(
            token: "token\nvalue",
            accessExpiry: now.addingTimeInterval(3_600)
        )

        for credentials in [missingExpiry, expiredAccess, expiredLogin, malformedToken] {
            XCTAssertNil(
                ClaudeUsageProbeCredentialSelector.select(
                    live: credentials,
                    stored: nil,
                    now: now
                )
            )
        }
        XCTAssertNil(
            ClaudeUsageProbeCredentialSelector.select(
                live: nil,
                stored: nil,
                now: now
            )
        )
    }

    func testFresherValidGenerationWins() throws {
        let live = try credential(
            token: "live",
            accessExpiry: now.addingTimeInterval(3_600),
            loginExpiry: now.addingTimeInterval(7_200)
        )
        let stored = try credential(
            token: "stored",
            accessExpiry: now.addingTimeInterval(10_800),
            loginExpiry: now.addingTimeInterval(14_400)
        )

        XCTAssertEqual(
            ClaudeUsageProbeCredentialSelector.select(
                live: live,
                stored: stored,
                now: now
            )?.accessToken,
            "stored"
        )
    }

    private func credential(
        token: String,
        accessExpiry: Date?,
        loginExpiry: Date? = nil
    ) throws -> ClaudeOAuthCredentials {
        var object: [String: Any] = ["accessToken": token]
        if let accessExpiry {
            object["expiresAt"] = Int(accessExpiry.timeIntervalSince1970 * 1_000)
        }
        if let loginExpiry {
            object["refreshTokenExpiresAt"] = Int(loginExpiry.timeIntervalSince1970 * 1_000)
        }
        return try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: JSONSerialization.data(withJSONObject: object)
            )
        )
    }
}
