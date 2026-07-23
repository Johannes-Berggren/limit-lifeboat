import Foundation
import Security
import XCTest
@testable import LimitLifeboatCore

final class ClaudeOAuthCredentialsTests: XCTestCase {
    private let keychainItemJSON = Data("""
    {
        "claudeAiOauth": {
            "accessToken": "test-access-token",
            "refreshToken": "test-refresh-token",
            "expiresAt": 1800000000000,
            "refreshTokenExpiresAt": 1802500000000,
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

        XCTAssertEqual(credentials.accessToken, "test-access-token")
        XCTAssertEqual(credentials.refreshToken, "test-refresh-token")
        // expiresAt is stored in epoch milliseconds.
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(
            credentials.refreshTokenExpiresAt,
            Date(timeIntervalSince1970: 1_802_500_000)
        )
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
        XCTAssertEqual(raw["accessToken"] as? String, "test-access-token")
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

    func testLoginExpiryUsesRefreshTokenLifetimeWithoutLeeway() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = try makeCredentials(fields: [
            "accessToken": "token",
            "refreshTokenExpiresAt": Int64((now.addingTimeInterval(1).timeIntervalSince1970 * 1000).rounded())
        ])
        XCTAssertFalse(valid.isLoginExpired(asOf: now))

        let expired = try makeCredentials(fields: [
            "accessToken": "token",
            "refreshTokenExpiresAt": Int64((now.timeIntervalSince1970 * 1000).rounded())
        ])
        XCTAssertTrue(expired.isLoginExpired(asOf: now))
    }

    func testCredentialFreshnessPrefersRenewedLoginThenNewerAccessToken() throws {
        let olderLogin = try makeCredentials(fields: [
            "accessToken": "older-login",
            "expiresAt": 1_900_000_000_000,
            "refreshTokenExpiresAt": 1_810_000_000_000
        ])
        let renewedLogin = try makeCredentials(fields: [
            "accessToken": "renewed-login",
            "expiresAt": 1_800_000_000_000,
            "refreshTokenExpiresAt": 1_820_000_000_000
        ])
        XCTAssertTrue(renewedLogin.isFresher(than: olderLogin))

        let newerAccess = try makeCredentials(fields: [
            "accessToken": "newer-access",
            "expiresAt": 1_805_000_000_000,
            "refreshTokenExpiresAt": 1_820_000_000_000
        ])
        XCTAssertTrue(newerAccess.isFresher(than: renewedLogin))
    }

    func testGenericFreshnessDoesNotGuessThatUnknownExpiryBeatsFutureExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshedWithoutDuration = try makeCredentials(fields: [
            "accessToken": "fresh",
            "refreshToken": "rotated",
            "refreshTokenExpiresAt": 1_900_000_000_000
        ])
        let rejectedButFutureDated = try makeCredentials(fields: [
            "accessToken": "stale",
            "refreshToken": "old",
            "expiresAt": 1_800_003_600_000,
            "refreshTokenExpiresAt": 1_900_000_000_000
        ])

        XCTAssertFalse(
            refreshedWithoutDuration.isFresher(
                than: rejectedButFutureDated,
                asOf: now
            )
        )
        XCTAssertTrue(
            rejectedButFutureDated.isFresher(
                than: refreshedWithoutDuration,
                asOf: now
            )
        )
    }

    func testPreparedRecoveryProofProtectsUnknownExpiryStoredSurvivorOnlyFromPinnedStaleLiveOwner() throws {
        let profileID = UUID()
        let stale = try makeCredentials(fields: [
            "accessToken": "stale",
            "refreshToken": "old",
            "expiresAt": 1_800_003_600_000,
            "refreshTokenExpiresAt": 1_900_000_000_000
        ])
        let freshStored = try makeCredentials(fields: [
            "accessToken": "fresh",
            "refreshToken": "rotated",
            "refreshTokenExpiresAt": 1_900_000_000_000
        ])
        let externalLive = try makeCredentials(fields: [
            "accessToken": "external",
            "refreshToken": "external-chain",
            "expiresAt": 1_800_007_200_000,
            "refreshTokenExpiresAt": 1_900_000_000_000
        ])
        let storedDestination = ClaudeRotationRecoveryDestination.storedProfile(
            profileID
        )
        let record = ClaudeRotationRecoveryRecord(
            staleChainFingerprint: try XCTUnwrap(
                ClaudeRefreshChainFingerprint.make(credentials: stale)
            ),
            freshChainFingerprint: nil,
            oauthJSON: stale.rawClaudeAiOauth,
            pendingDestinations: [.liveClaudeCode, storedDestination],
            ownerGenerationBaselines: [
                .liveClaudeCode: ClaudeOAuthGenerationFingerprint.make(stale),
                storedDestination: ClaudeOAuthGenerationFingerprint.make(stale)
            ],
            phase: .prepared
        )

        XCTAssertTrue(
            record.protectsStoredOwnerFromStaleLiveCapture(
                profileID: profileID,
                stored: freshStored,
                live: stale
            )
        )
        XCTAssertFalse(
            record.protectsStoredOwnerFromStaleLiveCapture(
                profileID: profileID,
                stored: freshStored,
                live: externalLive
            )
        )

        var absentAtBaseline = record
        absentAtBaseline.ownerGenerationBaselines = [
            .liveClaudeCode: ClaudeOAuthGenerationFingerprint.make(stale)
        ]
        XCTAssertTrue(
            absentAtBaseline.protectsStoredOwnerFromStaleLiveCapture(
                profileID: profileID,
                stored: freshStored,
                live: stale
            ),
            "A newly created stored owner must survive stale live capture even when it had no baseline entry"
        )
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

        let merged = try mergeClaudeAiOauth(newObject, intoItemJSON: existing)
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

        let merged = try mergeClaudeAiOauth(newObject, intoItemJSON: nil)
        let item = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])

        XCTAssertEqual(item.count, 1)
        let claudeAiOauth = try XCTUnwrap(item["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(claudeAiOauth["accessToken"] as? String, "fresh-access")
    }

    func testMergeClaudeAiOauthRejectsMalformedExistingItem() {
        XCTAssertThrowsError(
            try mergeClaudeAiOauth(
                Data(#"{"accessToken":"fresh-access"}"#.utf8),
                intoItemJSON: Data("not-json".utf8)
            )
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.malformedCredentialJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMergeClaudeAiOauthRejectsMalformedIncomingPayload() {
        XCTAssertThrowsError(
            try mergeClaudeAiOauth(
                Data("not-json".utf8),
                intoItemJSON: Data(#"{"mcpOAuth":{"keep":true}}"#.utf8)
            )
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.malformedCredentialJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

final class ClaudeCodeCredentialsKeychainTests: XCTestCase {
    func testSecurityToolReadsAndUpdatesExistingItemWithoutDeletingIt() throws {
        let disposable = try DisposableKeychainTestSupport()
        let service = "com.limitlifeboat.app.claude-tests.\(UUID().uuidString)"
        let account = "test-\(UUID().uuidString)"
        let metadataClient = SystemClaudeKeychainSecurityClient(
            searchList: [disposable.keychain]
        )
        let keychain = ClaudeCodeCredentialsKeychain(
            serviceName: service,
            accountName: account,
            securityClient: AssumeSecurityToolReadyMetadataClient(base: metadataClient),
            liveCredentialBackend: ClaudeSecurityToolCredentialBackend()
        )

        let first = Data(#"{"claudeAiOauth":{"accessToken":"one"},"mcpOAuth":{"server":"München"}}"#.utf8)
        let providerLabel = "Custom Claude Provider Label"
        try disposable.addGenericPasswordUsingSecurityTool(
            data: first,
            service: service,
            account: account,
            label: providerLabel
        )
        XCTAssertEqual(try keychain.readLiveItemJSON(), first)
        XCTAssertEqual(
            try keychain.locateLiveItem(accessMode: .nonInteractive)?.label,
            providerLabel
        )

        let second = Data(#"{"claudeAiOauth":{"accessToken":"two"},"mcpOAuth":{"server":"München"}}"#.utf8)
        try keychain.writeLiveItemJSON(second)
        XCTAssertEqual(try keychain.readLiveItemJSON(), second)

        let third = Data(#"{"claudeAiOauth":{"accessToken":"three"},"mcpOAuth":{"server":"München"}}"#.utf8)
        try keychain.writeLiveItemJSON(third)
        XCTAssertEqual(try keychain.readLiveItemJSON(), third)
        XCTAssertEqual(
            try keychain.locateLiveItem(accessMode: .nonInteractive)?.label,
            providerLabel,
            "security -U must preserve provider-owned label metadata"
        )

        XCTAssertThrowsError(try keychain.deleteLiveItem()) { error in
            guard case ClaudeCodeCredentialsKeychainError.unsupportedSecurityToolAccess = error else {
                return XCTFail("Expected provider-owned deletion refusal, got \(error)")
            }
        }
        XCTAssertEqual(try keychain.readLiveItemJSON(), third)
    }

    func testDisposableKeychainsRejectDuplicateItemsBeforeSecurityToolRead() throws {
        let first = try DisposableKeychainTestSupport()
        let second = try DisposableKeychainTestSupport()
        let service = "com.limitlifeboat.app.claude-tests.\(UUID().uuidString)"
        let account = "test-\(UUID().uuidString)"
        let item = Data(#"{"claudeAiOauth":{"accessToken":"one"}}"#.utf8)
        try first.addGenericPasswordUsingSecurityTool(
            data: item,
            service: service,
            account: account
        )
        try second.addGenericPasswordUsingSecurityTool(
            data: item,
            service: service,
            account: account
        )

        let keychain = ClaudeCodeCredentialsKeychain(
            serviceName: service,
            accountName: account,
            securityClient: AssumeSecurityToolReadyMetadataClient(
                base: SystemClaudeKeychainSecurityClient(
                    searchList: [first.keychain, second.keychain]
                )
            ),
            liveCredentialBackend: ClaudeSecurityToolCredentialBackend()
        )

        XCTAssertThrowsError(
            try keychain.readLiveItemJSON(accessMode: .nonInteractive)
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.duplicateLiveItems(
                let items
            ) = error else {
                return XCTFail("Expected duplicateLiveItems, got \(error)")
            }
            XCTAssertEqual(items.count, 2)
        }
    }

    func testDisposableCustomKeychainDiscoveryAndPinnedAccessIntegration() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_DISPOSABLE_KEYCHAIN_TESTS"] == "1",
            "Opt-in disposable-Keychain integration suite."
        )

        let disposable = try DisposableKeychainTestSupport()
        let service = "com.limitlifeboat.app.claude-tests.\(UUID().uuidString)"
        let account = "test-\(UUID().uuidString)"
        let metadataClient = SystemClaudeKeychainSecurityClient(
            searchList: [disposable.keychain]
        )
        let keychain = ClaudeCodeCredentialsKeychain(
            serviceName: service,
            accountName: account,
            securityClient: AssumeSecurityToolReadyMetadataClient(base: metadataClient),
            liveCredentialBackend: ClaudeSecurityToolCredentialBackend()
        )

        let item = Data(#"{"claudeAiOauth":{"accessToken":"one"},"mcpOAuth":{"server":"keep"}}"#.utf8)
        try disposable.addGenericPasswordUsingSecurityTool(
            data: item,
            service: service,
            account: account
        )

        let location = try XCTUnwrap(keychain.locateLiveItem(accessMode: .nonInteractive))
        XCTAssertEqual(
            URL(fileURLWithPath: location.keychainPath).resolvingSymlinksInPath(),
            URL(fileURLWithPath: disposable.path).resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            try keychain.readLiveItemJSON(at: location, accessMode: .nonInteractive),
            item
        )
    }

    func testWriteRefusesToCreateClaudeOwnedItem() throws {
        let disposable = try DisposableKeychainTestSupport()
        let service = "com.limitlifeboat.app.claude-tests.\(UUID().uuidString)"
        let account = "test-\(UUID().uuidString)"
        let keychain = ClaudeCodeCredentialsKeychain(
            serviceName: service,
            accountName: account,
            securityClient: SystemClaudeKeychainSecurityClient(
                searchList: [disposable.keychain]
            ),
            liveCredentialBackend: ClaudeSecurityToolCredentialBackend()
        )

        XCTAssertThrowsError(try keychain.writeLiveItemJSON(Data("{}".utf8))) { error in
            guard case ClaudeCodeCredentialsKeychainError.missingLiveItem = error else {
                return XCTFail("Expected missingLiveItem, got \(error)")
            }
        }
    }

    func testIntegrityFailureStopsBeforeKeychainAccess() {
        let expected = RunningExecutableIntegrityError.replaced(path: "/tmp/deleted/LimitLifeboat")
        let keychain = ClaudeCodeCredentialsKeychain(
            serviceName: "unused",
            accountName: "unused",
            validateAccess: { throw expected }
        )

        XCTAssertThrowsError(try keychain.readLiveItemJSON()) { error in
            guard case ClaudeCodeCredentialsKeychainError.credentialAccessUnavailable(let underlying) = error else {
                return XCTFail("Expected credentialAccessUnavailable, got \(error)")
            }
            XCTAssertEqual(underlying as? RunningExecutableIntegrityError, expected)
        }
    }

    func testCodeSigningFailureExplainsRelaunch() {
        let error = ClaudeCodeCredentialsKeychainError.keychainError(-67068)

        XCTAssertTrue(error.localizedDescription.contains("-67068"))
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("relaunch"))
    }

    func testRefreshChainFingerprintIgnoresAccessAndMetadataDifferences() throws {
        let first = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: Data(
            #"{"accessToken":"access-a","refreshToken":"shared-refresh","subscriptionType":"max"}"#.utf8
        )))
        let second = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: Data(
            #"{"accessToken":"access-b","refreshToken":"shared-refresh","subscriptionType":"team","unknown":"keep"}"#.utf8
        )))

        XCTAssertEqual(
            ClaudeRefreshChainFingerprint.make(credentials: first),
            ClaudeRefreshChainFingerprint.make(credentials: second)
        )
        XCTAssertNotEqual(first.rawClaudeAiOauth, second.rawClaudeAiOauth)
    }

    func testMergingRotatedFieldsPreservesDestinationOwnedMetadata() throws {
        let destination = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: Data(
            #"{"accessToken":"old","refreshToken":"old-refresh","expiresAt":1000,"subscriptionType":"team","unknown":{"organization":"keep"}}"#.utf8
        )))
        let fresh = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: Data(
            #"{"accessToken":"fresh","refreshToken":"fresh-refresh","refreshTokenExpiresAt":1785000000000,"subscriptionType":"max"}"#.utf8
        )))

        let merged = try XCTUnwrap(destination.mergingRotatedTokenFields(from: fresh))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: merged.rawClaudeAiOauth) as? [String: Any]
        )
        XCTAssertEqual(object["accessToken"] as? String, "fresh")
        XCTAssertEqual(object["refreshToken"] as? String, "fresh-refresh")
        XCTAssertNil(object["expiresAt"], "Unknown access expiry removes a stale destination value")
        XCTAssertEqual(object["subscriptionType"] as? String, "team")
        XCTAssertNotNil(object["unknown"])
    }

    func testMergingRotatedFieldsPreservesFixedExpiryWhenSourceOmitsIt() throws {
        let destination = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: Data(
            #"{"accessToken":"old","refreshToken":"old-refresh","refreshTokenExpiresAt":1786000000000}"#.utf8
        )))
        let fresh = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: Data(
            #"{"accessToken":"fresh","refreshToken":"fresh-refresh"}"#.utf8
        )))

        let merged = try XCTUnwrap(destination.mergingRotatedTokenFields(from: fresh))
        XCTAssertEqual(merged.refreshTokenExpiresAt, destination.refreshTokenExpiresAt)
    }

}
