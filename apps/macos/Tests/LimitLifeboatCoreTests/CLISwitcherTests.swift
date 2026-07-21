import Foundation
import Security
import XCTest
@testable import LimitLifeboatCore

final class CLISwitcherTests: XCTestCase {
    func testClaudeFilesystemMetadataRefreshReusesSingleKeychainRead() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = fakeClaudeSource(accessToken: "new-login")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        let initial = try switcher.liveObservation(
            provider: .claude,
            accessMode: .nonInteractive
        )
        XCTAssertNil(initial.identity)
        XCTAssertEqual(source.readCount, 1)

        let claudeJSON = fixture.home.appendingPathComponent(".claude.json")
        try Data(
            #"{"oauthAccount":{"emailAddress":"late@example.com","accountUuid":"late-account"}}"#.utf8
        ).write(to: claudeJSON)
        let refreshed = try switcher.refreshClaudeFilesystemMetadata(in: initial)

        XCTAssertEqual(refreshed.identity?.email, "late@example.com")
        XCTAssertEqual(source.readCount, 1)
        XCTAssertNotEqual(refreshed.credentialFingerprint, initial.credentialFingerprint)
        XCTAssertEqual(
            refreshed.claudeKeychainPayloadFingerprint,
            initial.claudeKeychainPayloadFingerprint,
            "Filesystem identity changes must not masquerade as a provider-item update"
        )

        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"new-login","expiresAt":1783458000000},"mcpOAuth":{"server":{"accessToken":"changed-sibling"}}}"#.utf8
        )
        let siblingOnlyChange = try switcher.liveObservation(
            provider: .claude,
            accessMode: .nonInteractive
        )
        XCTAssertEqual(
            siblingOnlyChange.claudeKeychainPayloadFingerprint,
            initial.claudeKeychainPayloadFingerprint,
            "MCP sibling changes must not masquerade as a Claude account login"
        )

        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"replacement","expiresAt":1783458000000}}"#.utf8
        )
        let replaced = try switcher.liveObservation(
            provider: .claude,
            accessMode: .nonInteractive
        )
        XCTAssertNotEqual(
            replaced.claudeKeychainPayloadFingerprint,
            initial.claudeKeychainPayloadFingerprint,
            "Payload hashing must detect an in-place update even when metadata timestamps collide"
        )
    }

    func testGuardedLiveCodexRefreshMergesOwnedFieldsAndPreservesUnknownSiblings() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"old","refresh_token":"refresh-old"},"future_machine_state":"keep"}"#.utf8).write(to: authURL)
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let fingerprint = try XCTUnwrap(
            switcher.liveObservation(provider: .codex).credentialFingerprint
        )
        let refreshed = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"new","refresh_token":"refresh-new"},"last_refresh":"today"}"#.utf8)

        XCTAssertTrue(
            try switcher.replaceLiveCodexAuthJSON(
                refreshed,
                ifCredentialFingerprintMatches: fingerprint
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any])
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, "new")
        XCTAssertEqual(object["future_machine_state"] as? String, "keep")
        XCTAssertEqual(object["last_refresh"] as? String, "today")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testGuardedLiveCodexRefreshPreservesConcurrentAccountChange() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"old","refresh_token":"refresh-old"}}"#.utf8).write(to: authURL)
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let fingerprint = try XCTUnwrap(
            switcher.liveObservation(provider: .codex).credentialFingerprint
        )
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"external","refresh_token":"refresh-external"}}"#.utf8).write(to: authURL)

        XCTAssertFalse(
            try switcher.replaceLiveCodexAuthJSON(
                Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"new","refresh_token":"refresh-new"}}"#.utf8),
                ifCredentialFingerprintMatches: fingerprint
            )
        )
        XCTAssertEqual(try codexAccessToken(at: authURL), "external")
    }

    func testCodexCaptureAndRestoreCleansTemporaryRollbackMaterial() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let authURL = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"auth_mode":"chatgpt","tokens":{"access_token":"one"}}"#.data(using: .utf8)!.write(to: authURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "Codex")

        _ = try switcher.captureAndStoreSnapshot(for: profile)
        try #"{"auth_mode":"chatgpt","tokens":{"access_token":"two"}}"#.data(using: .utf8)!.write(to: authURL)

        let result = try switcher.restoreSnapshot(for: profile)

        XCTAssertEqual(try codexAccessToken(at: authURL), "one")
        XCTAssertEqual(result.touchedPaths, [authURL])
        XCTAssertEqual(result.verifiedObservation.credentialFingerprint, try switcher.storedCredentialFingerprint(for: profile.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testClaudeRestoreMergesOnlyOAuthFields() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"userThemeMode":"dark","oauth:tokenCache":{"accessToken":"one"}}"#.data(using: .utf8)!.write(to: configURL)

        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "account-a")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")

        _ = try switcher.captureAndStoreSnapshot(for: profile)
        try #"{"userThemeMode":"light","oauth:tokenCache":{"accessToken":"two"}}"#.data(using: .utf8)!.write(to: configURL)
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"account-b","expiresAt":1783458000000}}"#.utf8)

        _ = try switcher.restoreSnapshot(for: profile)
        let restoredData = try Data(contentsOf: configURL)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: restoredData) as? [String: Any])
        let tokenCache = try XCTUnwrap(restored["oauth:tokenCache"] as? [String: Any])

        XCTAssertEqual(restored["userThemeMode"] as? String, "light")
        XCTAssertEqual(tokenCache["accessToken"] as? String, "one")
    }

    func testClaudeReconciliationDoesNotOverwriteFresherStoredRotation() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "stale-live")
        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"stale-live","refreshToken":"refresh-1","expiresAt":1783000000000,"refreshTokenExpiresAt":1785000000000}}"#.utf8
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        let fresher = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh-stored","refreshToken":"refresh-2","expiresAt":1784000000000,"refreshTokenExpiresAt":1785000000000}"#.utf8
                )
            )
        )
        try switcher.updateStoredClaudeOAuthCredentials(fresher, for: profile.id)

        _ = try switcher.captureAndStoreSnapshot(for: profile)

        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "fresh-stored"
        )
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.refreshToken,
            "refresh-2"
        )
    }

    func testClaudeReconciliationAdoptsFutureDatedExternalLiveGenerationOverOlderUnknownExpiry() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let externalFutureExpiryMilliseconds = Int64(
            Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
        )
        let loginExpiryMilliseconds = Int64(
            Date().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970 * 1_000
        )
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(
            """
            {"claudeAiOauth":{"accessToken":"stored-old","refreshToken":"old-chain","refreshTokenExpiresAt":\(loginExpiryMilliseconds)}}
            """.utf8
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        source.itemJSON = Data(
            """
            {"claudeAiOauth":{"accessToken":"external-live","refreshToken":"external-chain","expiresAt":\(externalFutureExpiryMilliseconds),"refreshTokenExpiresAt":\(loginExpiryMilliseconds)}}
            """.utf8
        )
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        let stored = try XCTUnwrap(
            switcher.storedClaudeOAuthCredentials(for: profile.id)
        )
        XCTAssertEqual(stored.accessToken, "external-live")
        XCTAssertEqual(stored.refreshToken, "external-chain")
        XCTAssertNotNil(stored.expiresAt)
    }

    func testStoreObservationPreservesConcurrentNewerStoredGeneration() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "initial")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        let staleRecord = try XCTUnwrap(
            switcher.storedCredentialRecord(for: profile)
        )

        var externalSnapshot = staleRecord.snapshot
        let oauthIndex = try XCTUnwrap(
            externalSnapshot.items.firstIndex(where: { $0.kind == .keychainJSONFields })
        )
        externalSnapshot.items[oauthIndex].contents = Data(
            #"{"accessToken":"external-newer","refreshToken":"external-chain"}"#.utf8
        )
        try store.save(snapshot: externalSnapshot, for: profile.id)

        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"observed-live","refreshToken":"observed-chain"}}"#.utf8
        )
        let observation = try switcher.liveObservation(provider: .claude)

        XCTAssertThrowsError(
            try switcher.storeObservation(
                observation,
                for: profile,
                storedRecord: staleRecord
            )
        ) { error in
            guard case CLISwitcherError.credentialConflict = error else {
                return XCTFail("Expected credentialConflict, got \(error)")
            }
        }
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "external-newer"
        )
    }

    func testFirstStoreObservationPreservesConcurrentCreator() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "observed-live")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let observation = try switcher.liveObservation(provider: .claude)
        var externalSnapshot = try XCTUnwrap(observation.snapshot)
        let oauthIndex = try XCTUnwrap(
            externalSnapshot.items.firstIndex(where: {
                $0.kind == .keychainJSONFields
            })
        )
        externalSnapshot.items[oauthIndex].contents = Data(
            #"{"accessToken":"external-newer","refreshToken":"external-chain"}"#.utf8
        )
        store.beforeInsert = { accountID in
            store.beforeInsert = nil
            try! store.save(snapshot: externalSnapshot, for: accountID)
        }

        XCTAssertThrowsError(
            try switcher.storeObservation(
                observation,
                for: profile,
                storedRecord: nil
            )
        ) { error in
            guard case CLISwitcherError.credentialConflict = error else {
                return XCTFail("Expected credentialConflict, got \(error)")
            }
        }
        XCTAssertEqual(store.insertCount, 1)
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "external-newer"
        )
    }

    func testStoreObservationReusesWorkflowRecordWithoutAnotherStoredKeychainRead() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "first")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        let record = try XCTUnwrap(switcher.storedCredentialRecord(for: profile))

        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"second","expiresAt":1784458000000}}"#.utf8
        )
        let observation = try switcher.liveObservation(provider: .claude)
        let baselineLoads = store.loadCount

        _ = try switcher.storeObservation(
            observation,
            for: profile,
            storedRecord: record
        )

        XCTAssertEqual(store.loadCount, baselineLoads)
    }

    func testPreloadedClaudeRotationUsesRevisionCASWithoutAnotherStoredRead() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "stale")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        let record = try XCTUnwrap(switcher.storedCredentialRecord(for: profile))
        let stale = try XCTUnwrap(record.claudeOAuthCredentials)
        let baselineLoads = store.loadCount
        let fresh = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh","refreshToken":"refresh-2","expiresAt":1784458000000}"#.utf8
                )
            )
        )

        let updated = try XCTUnwrap(
            switcher.replaceStoredClaudeOAuthCredentials(
                fresh,
                for: profile.id,
                using: record,
                ifCurrentCredentialsMatch: stale,
                accessMode: .nonInteractive
            )
        )

        XCTAssertEqual(store.loadCount, baselineLoads)
        XCTAssertEqual(store.replaceCount, 1)
        XCTAssertEqual(updated.claudeOAuthCredentials?.accessToken, "fresh")
        XCTAssertNotEqual(updated.storeRevision, record.storeRevision)

        // Reusing the stale workflow record must lose the opaque revision CAS,
        // even though its own token predicate still matches.
        XCTAssertNil(
            try switcher.replaceStoredClaudeOAuthCredentials(
                fresh,
                for: profile.id,
                using: record,
                ifCurrentCredentialsMatch: stale,
                accessMode: .nonInteractive
            )
        )
        XCTAssertEqual(store.loadCount, baselineLoads)
        XCTAssertEqual(store.replaceCount, 2)
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "fresh"
        )
    }

    func testPreloadedCodexRotationUsesRevisionCASAndNoOpSkipsWrite() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stale = Data(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"stale","refresh_token":"refresh-1"}}"#.utf8
        )
        try stale.write(to: authURL)
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "Codex")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        let record = try XCTUnwrap(switcher.storedCredentialRecord(for: profile))
        let baselineLoads = store.loadCount

        let unchanged = try XCTUnwrap(
            switcher.replaceStoredCodexAuthJSON(
                stale,
                for: profile.id,
                using: record,
                ifSnapshotFingerprintMatches: record.summary.fingerprint,
                accessMode: .nonInteractive
            )
        )
        XCTAssertEqual(unchanged.storeRevision, record.storeRevision)
        XCTAssertEqual(store.replaceCount, 0)

        let fresh = Data(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"fresh","refresh_token":"refresh-2"}}"#.utf8
        )
        let updated = try XCTUnwrap(
            switcher.replaceStoredCodexAuthJSON(
                fresh,
                for: profile.id,
                using: record,
                ifSnapshotFingerprintMatches: record.summary.fingerprint,
                accessMode: .nonInteractive
            )
        )

        XCTAssertEqual(store.loadCount, baselineLoads)
        XCTAssertEqual(store.replaceCount, 1)
        XCTAssertNotEqual(updated.storeRevision, record.storeRevision)
        XCTAssertEqual(
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(updated.codexAuthJSON))
                    as? [String: Any]
            )["auth_mode"] as? String,
            "chatgpt"
        )
    }

    func testUnchangedStoredCodexPreflightSkipsKeychainWrite() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let authJSON = Data(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"same","refresh_token":"refresh"}}"#.utf8
        )
        try authJSON.write(to: authURL)
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = try switcher.captureAndStoreSnapshot(for: profile)
        let baselineSaves = store.saveCount

        XCTAssertTrue(
            try switcher.replaceStoredCodexAuthJSON(
                authJSON,
                for: profile.id,
                ifSnapshotFingerprintMatches: CredentialFingerprint.make(for: snapshot),
                accessMode: .nonInteractive
            )
        )
        XCTAssertEqual(store.saveCount, baselineSaves)
    }

    func testExactObservationDoesNotAttachLocationWhenResolvedItemDisappears() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.exactLocation = ClaudeKeychainItemLocation(
            serviceName: ClaudeCodeCredentialsKeychain.serviceName,
            accountName: "disposable-test-user",
            keychainPath: "/tmp/disposable.keychain-db",
            persistentReference: Data("removed-item".utf8),
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2)
        )
        source.itemJSON = nil
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        XCTAssertThrowsError(try switcher.liveObservation(provider: .claude)) { error in
            guard case ClaudeCodeCredentialsKeychainError.missingLiveItem = error else {
                return XCTFail("Expected missingLiveItem, got \(error)")
            }
        }
        XCTAssertEqual(source.readCount, 1)
    }

    func testPinnedClaudeObservationCannotBroadenToReplacementItem() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let settled = testClaudeKeychainLocation(reference: "settled-generation")
        let replacement = testClaudeKeychainLocation(reference: "replacement-generation")
        let source = fakeClaudeSource(accessToken: "replacement-token")
        source.exactLocation = replacement
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        XCTAssertThrowsError(
            try switcher.liveClaudeObservation(
                at: settled,
                accessMode: .nonInteractive
            )
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.missingLiveItem = error else {
                return XCTFail("Expected missingLiveItem, got \(error)")
            }
        }

        XCTAssertEqual(source.exactReadLocations, [settled])
        XCTAssertEqual(source.readCount, 1)
    }

    func testPinnedClaudeObservationAttachesTheSettledLocation() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let settled = testClaudeKeychainLocation(reference: "settled-generation")
        let source = fakeClaudeSource(accessToken: "settled-token")
        source.exactLocation = settled
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        let observation = try switcher.liveClaudeObservation(
            at: settled,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(observation.claudeKeychainItemLocation, settled)
        XCTAssertNotNil(observation.claudeKeychainPayloadFingerprint)
        XCTAssertEqual(source.exactReadLocations, [settled])
        XCTAssertEqual(source.readCount, 1)
    }

    func testPinnedClaudeOAuthRecordUsesOnlySettledGeneration() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let settled = testClaudeKeychainLocation(reference: "settled-generation")
        let source = fakeClaudeSource(accessToken: "settled-token")
        source.exactLocation = settled
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        let record = try XCTUnwrap(
            switcher.liveClaudeOAuthCredentialRecord(
                at: settled,
                accessMode: .nonInteractive
            )
        )

        XCTAssertEqual(record.credentials.accessToken, "settled-token")
        XCTAssertEqual(record.itemLocation, settled)
        XCTAssertEqual(source.exactReadLocations, [settled])
        XCTAssertEqual(source.readCount, 1)
    }

    func testMCPOnlyLiveItemIsLegitimateLoggedOutState() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.exactLocation = testClaudeKeychainLocation(reference: "mcp-only")
        source.itemJSON = Data(
            #"{"mcpOAuth":{"server":{"accessToken":"mcp"}}}"#.utf8
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        XCTAssertNil(
            try switcher.liveClaudeOAuthCredentialRecord(
                accessMode: .nonInteractive
            )
        )
    }

    func testMalformedLiveOAuthItemFailsClosed() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.exactLocation = testClaudeKeychainLocation(reference: "malformed")
        source.itemJSON = Data(#"{"claudeAiOauth":{"refreshToken":"missing-access"}}"#.utf8)
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )

        XCTAssertThrowsError(
            try switcher.liveClaudeOAuthCredentialRecord(
                accessMode: .nonInteractive
            )
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.malformedCredentialJSON = error else {
                return XCTFail("Expected malformedCredentialJSON, got \(error)")
            }
        }
    }

    func testSuccessfulClaudeRestoreCleansAllTemporaryRollbackMaterial() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        // A Claude snapshot with three items: keychain OAuth plus the desktop
        // config and ~/.claude.json JSON fields.
        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":{"accessToken":"one"}}"#.data(using: .utf8)!.write(to: configURL)
        let claudeJSONURL = fixture.home.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"emailAddress":"a@example.com"}}"#.data(using: .utf8)!.write(to: claudeJSONURL)

        let store = MemoryCredentialStore()
        let source = fakeClaudeSource()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let captured = try switcher.captureAndStoreSnapshot(for: profile)
        XCTAssertEqual(captured.items.count, 3)

        _ = try switcher.restoreSnapshot(for: profile)

        let backupDirectories = try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path)
        XCTAssertTrue(backupDirectories.isEmpty)
    }

    func testEnforcedClaudeRestoreDoesNotRereadLiveItemRedundantly() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let store = MemoryCredentialStore()
        let source = fakeClaudeSource()
        source.exactLocation = testClaudeKeychainLocation(reference: "restore-success")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let captured = try switcher.captureAndStoreSnapshot(for: profile)
        let expected = CredentialFingerprint.make(for: captured)

        let baseline = source.readCount
        _ = try switcher.restoreSnapshot(
            for: profile,
            expectedLiveFingerprint: expected,
            enforceExpectedLiveState: true
        )
        let restoreReads = source.readCount - baseline

        // An enforced Claude restore used to read the shared keychain item 6
        // times because restoreSnapshot ran its own live-fingerprint check that
        // the transaction immediately repeated. That duplicate is gone; pin an
        // upper bound so re-introducing it (which multiplies OS password
        // prompts) fails here. The intentional reads — backup baseline, the
        // mutation-boundary compare, post-write verify, and any rollback check
        // must remain within the workflow budget.
        XCTAssertGreaterThan(restoreReads, 0)
        XCTAssertLessThanOrEqual(restoreReads, 4)
    }

    func testFailedExactClaudeRestoreRollsBackWithinFourReads() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "account-a")
        source.exactLocation = testClaudeKeychainLocation(reference: "restore-failure")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        var profile = AccountProfile(provider: .claude, label: "Expected identity")
        let captured = try switcher.captureAndStoreSnapshot(for: profile)
        profile.identity = AccountIdentity(
            email: "expected@example.com",
            source: .manual
        )
        let baselineReads = source.readCount

        XCTAssertThrowsError(
            try switcher.restoreSnapshot(
                for: profile,
                expectedLiveFingerprint: CredentialFingerprint.make(for: captured),
                enforceExpectedLiveState: true,
                accessMode: .nonInteractive
            )
        )

        XCTAssertEqual(source.readCount - baselineReads, 4)
        XCTAssertTrue(source.accessModes.suffix(4).allSatisfy { $0 == .nonInteractive })
        XCTAssertEqual(
            ClaudeOAuthCredentials.extract(
                fromKeychainItemJSON: try XCTUnwrap(source.itemJSON)
            )?.accessToken,
            "account-a"
        )
    }

    func testRestoreAbortsWithoutWritingWhenBackupFails() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let authURL = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"one"}}"#.data(using: .utf8)!.write(to: authURL)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "Codex")
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        try #"{"tokens":{"access_token":"two"}}"#.data(using: .utf8)!.write(to: authURL)

        // Make the backup root unwritable so phase 1 must fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.backups.path) }

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile)) { error in
            guard case CLISwitcherError.backupFailed = error else {
                return XCTFail("Expected backupFailed, got \(error)")
            }
        }

        let untouched = try String(contentsOf: authURL)
        XCTAssertTrue(untouched.contains("two"), "Destination must be untouched when backup fails")
    }

    func testCaptureRestoreRoundTripSwitchesAccounts() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let authURL = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profileA = AccountProfile(provider: .codex, label: "A")
        let profileB = AccountProfile(provider: .codex, label: "B")

        let contentsA = #"{"tokens":{"access_token":"account-a"}}"#
        let contentsB = #"{"tokens":{"access_token":"account-b"}}"#

        try contentsA.data(using: .utf8)!.write(to: authURL)
        _ = try switcher.captureAndStoreSnapshot(for: profileA)
        try contentsB.data(using: .utf8)!.write(to: authURL)
        _ = try switcher.captureAndStoreSnapshot(for: profileB)

        _ = try switcher.restoreSnapshot(for: profileA)
        XCTAssertEqual(try codexAccessToken(at: authURL), "account-a")

        _ = try switcher.restoreSnapshot(for: profileB)
        XCTAssertEqual(try codexAccessToken(at: authURL), "account-b")
    }

    func testCodexRestorePreservesUnknownExternalFields() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"account-a"},"future_machine_state":"old"}"#.utf8).write(to: authURL)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "A")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        try Data(#"{"tokens":{"access_token":"account-b"},"future_machine_state":"external"}"#.utf8).write(to: authURL)

        _ = try switcher.restoreSnapshot(for: profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any])
        XCTAssertEqual(object["future_machine_state"] as? String, "external")
        XCTAssertEqual(try codexAccessToken(at: authURL), "account-a")
    }

    func testClaudeAccountRestorePreservesUnrelatedDotClaudeSettings() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let claudeURL = fixture.home.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"a@example.com"},"theme":"dark"}"#.utf8).write(to: claudeURL)
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "A")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        try Data(#"{"oauthAccount":{"emailAddress":"b@example.com"},"theme":"light"}"#.utf8).write(to: claudeURL)

        _ = try switcher.restoreSnapshot(for: profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        let account = try XCTUnwrap(object["oauthAccount"] as? [String: Any])
        XCTAssertEqual(account["emailAddress"] as? String, "a@example.com")
        XCTAssertEqual(object["theme"] as? String, "light")
    }

    func testExpectedFingerprintConflictPreservesExternalCodexLogin() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"account-a"}}"#.utf8).write(to: authURL)
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "A")
        let captured = try switcher.captureAndStoreSnapshot(for: profile)
        let expected = CredentialFingerprint.make(for: captured)
        try Data(#"{"tokens":{"access_token":"external"}}"#.utf8).write(to: authURL)

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile, expectedLiveFingerprint: expected)) { error in
            guard case CLISwitcherError.credentialConflict = error else {
                return XCTFail("Expected credentialConflict, got \(error)")
            }
        }
        XCTAssertEqual(try codexAccessToken(at: authURL), "external")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testValidationFailureRestoresOriginalCredentialsAndCleansRollbackMaterial() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"tokens":{"access_token":"original"}}"#.utf8)
        try original.write(to: authURL)
        let transaction = CredentialRestoreTransaction(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            fileManager: .default,
            claudeCredentialSource: FakeClaudeCLICredentialSource()
        )
        let snapshot = CredentialSnapshot(provider: .codex, items: [
            CredentialSnapshotItem(
                relativePath: ".codex/auth.json",
                kind: .fullFile,
                contents: Data(#"{"tokens":{"access_token":"target"}}"#.utf8),
                posixPermissions: 0o600
            )
        ])

        XCTAssertThrowsError(
            try transaction.restore(snapshot, validateRestoredCredentials: {
                throw CLISwitcherError.restoreValidationFailed(
                    provider: .codex,
                    reason: "test mismatch",
                    disposition: nil
                )
            })
        ) { error in
            guard case CLISwitcherError.restoreValidationFailed = error else {
                return XCTFail("Expected restoreValidationFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: authURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testFailureImmediatelyAfterFileWriteRollsBackAndCleansRollbackMaterial() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data(#"{"tokens":{"access_token":"original"}}"#.utf8)
        try original.write(to: authURL)

        let transaction = CredentialRestoreTransaction(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            fileManager: .default,
            claudeCredentialSource: FakeClaudeCLICredentialSource(),
            hooks: CredentialRestoreHooks(afterDestinationWrite: { _ in
                throw InjectedRestoreFailure.afterWrite
            })
        )
        let snapshot = CredentialSnapshot(provider: .codex, items: [
            CredentialSnapshotItem(
                relativePath: ".codex/auth.json",
                kind: .fullFile,
                contents: Data(#"{"tokens":{"access_token":"target"}}"#.utf8),
                posixPermissions: 0o600
            )
        ])

        XCTAssertThrowsError(
            try transaction.restore(snapshot, validateRestoredCredentials: {})
        ) { error in
            guard case InjectedRestoreFailure.afterWrite = error else {
                return XCTFail("Expected injected post-write failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: authURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testClaudeLeaseLossAfterFileWritePreventsUnlockedRollback() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let claudeURL = fixture.home.appendingPathComponent(".claude.json")
        let original = Data(
            #"{"oauthAccount":{"emailAddress":"original@example.com"}}"#.utf8
        )
        let target = Data(
            #"{"oauthAccount":{"emailAddress":"target@example.com"}}"#.utf8
        )
        try original.write(to: claudeURL)

        var validations = 0
        let transaction = CredentialRestoreTransaction(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            fileManager: .default,
            claudeCredentialSource: FakeClaudeCLICredentialSource(),
            hooks: CredentialRestoreHooks(afterDestinationWrite: { _ in
                throw InjectedRestoreFailure.afterWrite
            }),
            validateMutationLease: {
                validations += 1
                if validations >= 5 {
                    throw ClaudeOAuthRefreshCoordinatorError.leaseLost(
                        lock: .claude
                    )
                }
            }
        )
        let snapshot = CredentialSnapshot(provider: .claude, items: [
            CredentialSnapshotItem(
                relativePath: ".claude.json",
                kind: .fullFile,
                contents: target,
                posixPermissions: 0o600
            )
        ])

        var recoveryDirectory: URL?
        XCTAssertThrowsError(
            try transaction.restore(snapshot, validateRestoredCredentials: {})
        ) { error in
            guard case CLISwitcherError.rollbackConflict(
                let paths,
                let recovery,
                _,
                _
            ) = error else {
                return XCTFail("Expected rollbackConflict, got \(error)")
            }
            XCTAssertEqual(paths, [claudeURL.path])
            recoveryDirectory = recovery
        }

        XCTAssertEqual(validations, 5)
        let currentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL))
                as? [String: Any]
        )
        let currentAccount = try XCTUnwrap(
            currentObject["oauthAccount"] as? [String: Any]
        )
        XCTAssertEqual(
            currentAccount["emailAddress"] as? String,
            "target@example.com",
            "The app must not roll Claude files back after losing the lease"
        )
        let recovery = try XCTUnwrap(recoveryDirectory)
        let backups = try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
    }

    func testClaudeRestoreRevalidatesLeaseAfterCASReadBeforeFileWrite() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let claudeURL = fixture.home.appendingPathComponent(".claude.json")
        let original = Data(
            #"{"oauthAccount":{"emailAddress":"original@example.com"}}"#.utf8
        )
        let target = Data(
            #"{"oauthAccount":{"emailAddress":"target@example.com"}}"#.utf8
        )
        try original.write(to: claudeURL)

        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: fixture.home,
            configuration: .init(heartbeatInterval: 60)
        )
        let transaction = CredentialRestoreTransaction(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            fileManager: .default,
            claudeCredentialSource: FakeClaudeCLICredentialSource(),
            hooks: CredentialRestoreHooks(beforeDestinationWrite: { destination in
                guard destination == claudeURL else { return }
                try FileManager.default.removeItem(at: coordinator.claudeLockURL)
                try FileManager.default.createDirectory(
                    at: coordinator.claudeLockURL,
                    withIntermediateDirectories: false
                )
            }),
            validateMutationLease: {
                try ClaudeOAuthMutationLeaseContext.requireCurrent().validate()
            }
        )
        let snapshot = CredentialSnapshot(provider: .claude, items: [
            CredentialSnapshotItem(
                relativePath: ".claude.json",
                kind: .fullFile,
                contents: target,
                posixPermissions: 0o600
            )
        ])

        var caught: Error?
        do {
            try await coordinator.withLease { _ in
                _ = try transaction.restore(
                    snapshot,
                    validateRestoredCredentials: {}
                )
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(
            caught as? ClaudeOAuthRefreshCoordinatorError,
            .leaseLost(lock: .claude)
        )
        XCTAssertEqual(try Data(contentsOf: claudeURL), original)
    }

    func testSwitcherValidatesTargetBeforeCommit() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"tokens":{"access_token":"original"}}"#.utf8)
        try original.write(to: authURL)

        let store = MemoryCredentialStore()
        let profile = AccountProfile(provider: .codex, label: "Invalid target")
        try store.save(
            snapshot: CredentialSnapshot(provider: .codex, items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .jsonFields,
                    contents: Data("{}".utf8),
                    posixPermissions: 0o600,
                    ownedJSONKeys: CodexCredentialAdapter.ownedKeys
                )
            ]),
            for: profile.id
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile)) { error in
            guard case CLISwitcherError.restoreValidationFailed = error else {
                return XCTFail("Expected restoreValidationFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: authURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testLabeledProfileRejectsSnapshotThatRestoresDifferentIdentity() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(
            provider: .codex,
            label: "Expected account",
            identity: AccountIdentity(
                email: "expected@example.com",
                accountID: "acct-expected",
                source: .codexIDToken
            )
        )

        let mismatchedAuth = codexAuth(
            email: "different@example.com",
            accountID: "acct-different",
            accessToken: "different-token"
        )
        try mismatchedAuth.write(to: authURL)
        let mismatchedSnapshot = try switcher.captureSnapshot(provider: .codex)
        try store.save(snapshot: mismatchedSnapshot, for: profile.id)

        let originalAuth = codexAuth(
            email: "original@example.com",
            accountID: "acct-original",
            accessToken: "original-token"
        )
        try originalAuth.write(to: authURL)

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile)) { error in
            guard case CLISwitcherError.restoreValidationFailed = error else {
                return XCTFail("Expected restoreValidationFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: authURL), originalAuth)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testDestinationChangeAfterBackupAbortsAndPreservesExternalBytes() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let authURL = fixture.home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"baseline"}}"#.utf8).write(to: authURL)
        var mutated = false
        let transaction = CredentialRestoreTransaction(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            fileManager: .default,
            claudeCredentialSource: FakeClaudeCLICredentialSource(),
            hooks: CredentialRestoreHooks(beforeDestinationCheck: { destination in
                guard !mutated, destination.path == authURL.path else { return }
                mutated = true
                try Data(#"{"tokens":{"access_token":"external"}}"#.utf8).write(to: destination)
            })
        )
        let snapshot = CredentialSnapshot(provider: .codex, items: [
            CredentialSnapshotItem(
                relativePath: ".codex/auth.json",
                kind: .jsonFields,
                contents: Data(#"{"tokens":{"access_token":"target"}}"#.utf8),
                posixPermissions: 0o600,
                ownedJSONKeys: CodexCredentialAdapter.ownedKeys
            )
        ])

        XCTAssertThrowsError(try transaction.restore(snapshot, validateRestoredCredentials: {})) { error in
            guard case CLISwitcherError.credentialConflict = error else {
                return XCTFail("Expected credentialConflict, got \(error)")
            }
        }
        XCTAssertEqual(try codexAccessToken(at: authURL), "external")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testRollbackDoesNotOverwriteChangeMadeAfterFirstWrite() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let firstURL = fixture.home.appendingPathComponent("first/auth.json")
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("baseline".utf8).write(to: firstURL)
        let blocker = fixture.home.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let transaction = CredentialRestoreTransaction(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            fileManager: .default,
            claudeCredentialSource: FakeClaudeCLICredentialSource(),
            hooks: CredentialRestoreHooks(beforeDestinationCheck: { destination in
                guard destination.path.hasSuffix("blocker/auth.json") else { return }
                try Data("external".utf8).write(to: firstURL)
            })
        )
        let snapshot = CredentialSnapshot(provider: .codex, items: [
            CredentialSnapshotItem(relativePath: "first/auth.json", kind: .fullFile, contents: Data("target".utf8), posixPermissions: 0o600),
            CredentialSnapshotItem(relativePath: "blocker/auth.json", kind: .fullFile, contents: Data("fails".utf8), posixPermissions: 0o600)
        ])

        var recoveryDirectory: URL?
        XCTAssertThrowsError(try transaction.restore(snapshot, validateRestoredCredentials: {})) { error in
            guard case CLISwitcherError.rollbackConflict(let paths, let recovery, _, _) = error else {
                return XCTFail("Expected rollbackConflict, got \(error)")
            }
            XCTAssertEqual(paths, [firstURL.path])
            recoveryDirectory = recovery
        }
        XCTAssertEqual(try String(contentsOf: firstURL), "external")
        let recovery = try XCTUnwrap(recoveryDirectory)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryFiles.count, 1)
        let recoveryFile = try XCTUnwrap(recoveryFiles.first)
        XCTAssertEqual(try Data(contentsOf: recoveryFile), Data("baseline".utf8))
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: recoveryFile.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testLegacyClaudeSnapshotClearsStaleAccountFieldWithoutClobberingSettings() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let configURL = fixture.home.appendingPathComponent("Library/Application Support/Claude/config.json")
        let claudeURL = fixture.home.appendingPathComponent(".claude.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"oauth:tokenCache":{"accessToken":"live"}}"#.utf8).write(to: configURL)
        try Data(#"{"oauthAccount":{"emailAddress":"stale@example.com"},"theme":"light"}"#.utf8).write(to: claudeURL)
        let store = MemoryCredentialStore()
        let profile = AccountProfile(provider: .claude, label: "Legacy")
        let keychainItem = CredentialSnapshotItem(
            relativePath: CLISwitcher.claudeKeychainItemPath,
            kind: .keychainJSONFields,
            contents: Data(#"{"accessToken":"target","expiresAt":1783458000000}"#.utf8),
            posixPermissions: nil
        )
        try store.save(
            snapshot: CredentialSnapshot(provider: .claude, items: [
                CredentialSnapshotItem(
                    relativePath: "Library/Application Support/Claude/config.json",
                    kind: .jsonFields,
                    contents: Data(#"{"oauth:tokenCache":{"accessToken":"target"}}"#.utf8),
                    posixPermissions: 0o600
                ),
                keychainItem
            ]),
            for: profile.id
        )
        let source = fakeClaudeSource(accessToken: "live")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )

        _ = try switcher.restoreSnapshot(for: profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        XCTAssertNil(object["oauthAccount"])
        XCTAssertEqual(object["theme"] as? String, "light")
    }

    func testCurrentIdentityReadsCodexAuthFile() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        XCTAssertNil(switcher.currentIdentity(provider: .codex))

        let claudeJSONURL = fixture.home.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"emailAddress":"me@example.com","accountUuid":"acct-9"}}"#
            .data(using: .utf8)!.write(to: claudeJSONURL)

        let identity = switcher.currentIdentity(provider: .claude)
        XCTAssertEqual(identity?.email, "me@example.com")
        XCTAssertEqual(identity?.accountID, "acct-9")
    }

    func testClaudeCaptureIncludesKeychainCredentials() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"tok-a","refreshToken":"ref-a","expiresAt":1783458000000},"mcpOAuth":{"serverX":{"accessToken":"mcp"}}}"#.utf8)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")

        let snapshot = try switcher.captureAndStoreSnapshot(for: profile)

        let keychainItem = try XCTUnwrap(snapshot.items.first { $0.kind == .keychainJSONFields })
        XCTAssertEqual(keychainItem.relativePath, CLISwitcher.claudeKeychainItemPath)
        let stored = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: keychainItem.contents))
        XCTAssertEqual(stored.accessToken, "tok-a")
        XCTAssertEqual(stored.refreshToken, "ref-a")

        let viaHelper = try XCTUnwrap(switcher.storedClaudeOAuthCredentials(for: profile.id))
        XCTAssertEqual(viaHelper.accessToken, "tok-a")
    }

    func testClaudeRestoreMergeWritesKeychainPreservingMCPOAuth() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"account-a","expiresAt":1783458000000},"mcpOAuth":{"serverX":{"accessToken":"mcp"}}}"#.utf8)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profileA = AccountProfile(provider: .claude, label: "A")
        _ = try switcher.captureAndStoreSnapshot(for: profileA)

        // The terminal logs into account B; mcpOAuth stays machine-level.
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"account-b","expiresAt":1783458000000},"mcpOAuth":{"serverX":{"accessToken":"mcp"}}}"#.utf8)

        _ = try switcher.restoreSnapshot(for: profileA)

        let live = try XCTUnwrap(source.itemJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: live) as? [String: Any])
        let oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        let mcp = try XCTUnwrap(object["mcpOAuth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "account-a")
        XCTAssertNotNil(mcp["serverX"], "mcpOAuth must survive an account switch")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path), [])
    }

    func testUpdateStoredClaudeOAuthCredentialsRoundTrips() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"ref","expiresAt":1783458000000}}"#.utf8)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        let refreshedJSON = Data(#"{"accessToken":"new","refreshToken":"ref2","expiresAt":1783461600000}"#.utf8)
        let refreshed = try XCTUnwrap(ClaudeOAuthCredentials(claudeAiOauthJSON: refreshedJSON))
        try switcher.updateStoredClaudeOAuthCredentials(refreshed, for: profile.id)

        let reloaded = try XCTUnwrap(switcher.storedClaudeOAuthCredentials(for: profile.id))
        XCTAssertEqual(reloaded.accessToken, "new")
        XCTAssertEqual(reloaded.refreshToken, "ref2")
    }

    func testUpdateStoredClaudeOAuthCredentialsPreservesConcurrentSnapshotGeneration() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "stale")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        let refreshed = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"our-refresh","refreshToken":"our-chain"}"#.utf8
                )
            )
        )
        let stale = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"stale","refreshToken":"old"}"#.utf8
                )
            )
        )

        store.beforeReplace = { accountID in
            store.beforeReplace = nil
            var external = try! XCTUnwrap(store.loadSnapshot(for: accountID))
            let index = external.items.firstIndex(where: {
                $0.kind == .keychainJSONFields
            })!
            external.items[index].contents = Data(
                #"{"accessToken":"external","refreshToken":"external-chain"}"#.utf8
            )
            try! store.save(snapshot: external, for: accountID)
        }

        XCTAssertThrowsError(
            try switcher.updateStoredClaudeOAuthCredentials(
                refreshed,
                for: profile.id
            )
        ) { error in
            guard case CLISwitcherError.credentialConflict = error else {
                return XCTFail("Expected credentialConflict, got \(error)")
            }
        }
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "external"
        )
    }

    func testStoredCodexJSONFieldsCanBeReadAndCompareAndSwapUpdated() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "Codex")
        let initial = Data(#"{"tokens":{"access_token":"old","refresh_token":"refresh-1"}}"#.utf8)
        let snapshot = CredentialSnapshot(provider: .codex, items: [
            CredentialSnapshotItem(
                relativePath: ".codex/auth.json",
                kind: .jsonFields,
                contents: initial,
                posixPermissions: 0o600,
                ownedJSONKeys: CodexCredentialAdapter.ownedKeys
            )
        ])
        try store.save(snapshot: snapshot, for: profile.id)
        let fingerprint = CredentialFingerprint.make(for: snapshot)
        XCTAssertEqual(try switcher.storedCodexAuthJSON(for: profile.id), initial)

        let updated = Data(#"{"tokens":{"access_token":"new","refresh_token":"refresh-2"}}"#.utf8)
        XCTAssertTrue(
            try switcher.replaceStoredCodexAuthJSON(
                updated,
                for: profile.id,
                ifSnapshotFingerprintMatches: fingerprint
            )
        )
        XCTAssertEqual(try switcher.storedCodexAuthJSON(for: profile.id), updated)

        XCTAssertFalse(
            try switcher.replaceStoredCodexAuthJSON(
                initial,
                for: profile.id,
                ifSnapshotFingerprintMatches: fingerprint
            ),
            "The stale fingerprint must not overwrite the rotated snapshot"
        )
        XCTAssertEqual(try switcher.storedCodexAuthJSON(for: profile.id), updated)
    }

    func testLegacyFullFileCodexAuthCanBeReadAndCompareAndSwapUpdated() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "Legacy Codex")
        let initial = Data(#"{"tokens":{"access_token":"old","refresh_token":"refresh-1"}}"#.utf8)
        let snapshot = CredentialSnapshot(provider: .codex, items: [
            CredentialSnapshotItem(
                relativePath: ".codex/auth.json",
                kind: .fullFile,
                contents: initial,
                posixPermissions: 0o600
            )
        ])
        try store.save(snapshot: snapshot, for: profile.id)

        XCTAssertEqual(try switcher.storedCodexAuthJSON(for: profile.id), initial)
        let updated = Data(#"{"tokens":{"access_token":"new","refresh_token":"refresh-2"}}"#.utf8)
        XCTAssertTrue(
            try switcher.replaceStoredCodexAuthJSON(
                updated,
                for: profile.id,
                ifSnapshotFingerprintMatches: CredentialFingerprint.make(for: snapshot)
            )
        )
        XCTAssertEqual(try switcher.storedCodexAuthJSON(for: profile.id), updated)
    }

    func testClaudeCaptureAbortsWhenKeychainReadThrows() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        // Enough file-based auth material that a swallowed read error would
        // have produced a token-less snapshot instead of failing.
        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":{"accessToken":"one"}}"#.data(using: .utf8)!.write(to: configURL)

        let source = FakeClaudeCLICredentialSource()
        source.readError = ClaudeCodeCredentialsKeychainError.keychainError(errSecNotAvailable)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")

        XCTAssertThrowsError(try switcher.captureAndStoreSnapshot(for: profile))
        XCTAssertNil(try store.loadSnapshot(for: profile.id), "A failed capture must not store a snapshot")
    }

    func testClaudeCaptureWithoutLiveItemPreservesStoredKeychainItem() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":{"accessToken":"one"}}"#.data(using: .utf8)!.write(to: configURL)

        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"tok-a","refreshToken":"ref-a","expiresAt":1783458000000}}"#.utf8)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        // The terminal logs out; a re-capture must not erase the profile's
        // previously captured tokens.
        source.itemJSON = nil
        let recaptured = try switcher.captureAndStoreSnapshot(for: profile)

        XCTAssertTrue(recaptured.items.contains { $0.kind == .keychainJSONFields })
        let stored = try XCTUnwrap(switcher.storedClaudeOAuthCredentials(for: profile.id))
        XCTAssertEqual(stored.accessToken, "tok-a")
    }

    func testWriteLiveClaudeOAuthCredentialsAbortsWhenReadThrows() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let source = FakeClaudeCLICredentialSource()
        source.readError = ClaudeCodeCredentialsKeychainError.keychainError(errSecNotAvailable)

        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )
        let credentials = try XCTUnwrap(
            ClaudeOAuthCredentials(claudeAiOauthJSON: Data(#"{"accessToken":"fresh"}"#.utf8))
        )

        XCTAssertThrowsError(try switcher.writeLiveClaudeOAuthCredentials(credentials))
        XCTAssertTrue(source.writes.isEmpty, "A failed read must not lead to a merge-into-{} write")
    }

    func testWriteLiveClaudeOAuthCredentialsLeavesMalformedItemUntouched() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let malformed = Data("not-json-with-unknown-siblings".utf8)
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = malformed
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )
        let credentials = try XCTUnwrap(
            ClaudeOAuthCredentials(claudeAiOauthJSON: Data(#"{"accessToken":"fresh"}"#.utf8))
        )

        XCTAssertThrowsError(try switcher.writeLiveClaudeOAuthCredentials(credentials)) { error in
            guard case ClaudeCodeCredentialsKeychainError.malformedCredentialJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(source.itemJSON, malformed)
        XCTAssertTrue(source.writes.isEmpty)
    }

    func testProductionClaudeLiveMutationRejectsMissingSharedLease() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"old"}}"#.utf8
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source,
            requiresClaudeOAuthLease: true
        )
        let refreshed = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh","refreshToken":"new"}"#.utf8
                )
            )
        )

        XCTAssertThrowsError(
            try switcher.writeLiveClaudeOAuthCredentials(refreshed)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeOAuthRefreshCoordinatorError,
                .missingLease
            )
        }
        XCTAssertTrue(source.writes.isEmpty)
    }

    func testProductionStoredClaudeRotationRequiresSharedLease() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = fakeClaudeSource(accessToken: "stale")
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source,
            requiresClaudeOAuthLease: true
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)
        let fresh = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh","refreshToken":"new"}"#.utf8
                )
            )
        )

        XCTAssertThrowsError(
            try switcher.updateStoredClaudeOAuthCredentials(fresh, for: profile.id)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeOAuthRefreshCoordinatorError,
                .missingLease
            )
        }
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "stale"
        )

        try await ClaudeOAuthRefreshCoordinator(
            homeDirectory: fixture.home
        ).withLease { _ in
            try switcher.updateStoredClaudeOAuthCredentials(fresh, for: profile.id)
        }
        XCTAssertEqual(
            try switcher.storedClaudeOAuthCredentials(for: profile.id)?.accessToken,
            "fresh"
        )
    }

    func testProductionClaudeLiveMutationAcceptsMatchingSharedLease() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"old"}}"#.utf8
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source,
            requiresClaudeOAuthLease: true
        )
        let refreshed = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh","refreshToken":"new"}"#.utf8
                )
            )
        )

        try await ClaudeOAuthRefreshCoordinator(
            homeDirectory: fixture.home
        ).withLease { _ in
            try switcher.writeLiveClaudeOAuthCredentials(refreshed)
        }

        XCTAssertEqual(source.writes.count, 1)
    }

    func testProductionClaudeLiveCASRejectsLockReplacementAfterFinalRead() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"old"}}"#.utf8
        )
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source,
            requiresClaudeOAuthLease: true
        )
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: fixture.home,
            configuration: .init(heartbeatInterval: 60)
        )
        source.onRead = { _, count in
            guard count == 2 else { return }
            try! FileManager.default.removeItem(at: coordinator.claudeLockURL)
            try! FileManager.default.createDirectory(
                at: coordinator.claudeLockURL,
                withIntermediateDirectories: false
            )
        }
        let refreshed = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh","refreshToken":"new"}"#.utf8
                )
            )
        )
        let stale = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"stale","refreshToken":"old"}"#.utf8
                )
            )
        )

        var caught: Error?
        do {
            try await coordinator.withLease { _ in
                _ = try switcher.replaceLiveClaudeOAuthCredentials(
                    refreshed,
                    ifCurrentCredentialsMatch: stale,
                    accessMode: .nonInteractive
                )
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(
            caught as? ClaudeOAuthRefreshCoordinatorError,
            .leaseLost(lock: .claude)
        )
        XCTAssertTrue(source.writes.isEmpty)
        XCTAssertEqual(
            try switcher.liveClaudeOAuthCredentials()?.accessToken,
            "stale"
        )
    }

    func testLiveOAuthCASPreservesConcurrentMCPSiblingUpdate() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"old"},"mcpOAuth":{"server":{"accessToken":"mcp-old"}}}"#.utf8
        )
        source.onRead = { source, count in
            if count == 2 {
                source.itemJSON = Data(
                    #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"old"},"mcpOAuth":{"server":{"accessToken":"mcp-new"}}}"#.utf8
                )
            }
        }
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: source
        )
        let refreshed = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"fresh","refreshToken":"new"}"#.utf8
                )
            )
        )
        let stale = try XCTUnwrap(
            ClaudeOAuthCredentials(
                claudeAiOauthJSON: Data(
                    #"{"accessToken":"stale","refreshToken":"old"}"#.utf8
                )
            )
        )

        XCTAssertTrue(
            try switcher.replaceLiveClaudeOAuthCredentials(
                refreshed,
                ifCurrentCredentialsMatch: stale,
                accessMode: .nonInteractive
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(source.itemJSON))
                as? [String: Any]
        )
        let oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        let mcp = try XCTUnwrap(object["mcpOAuth"] as? [String: Any])
        let server = try XCTUnwrap(mcp["server"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "fresh")
        XCTAssertEqual(server["accessToken"] as? String, "mcp-new")
        XCTAssertEqual(source.readCount, 2)
    }

    func testRestoreAbortsWhenKeychainReadThrows() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":{"accessToken":"one"}}"#.data(using: .utf8)!.write(to: configURL)

        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"tok-a","expiresAt":1783458000000}}"#.utf8)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        _ = try switcher.captureAndStoreSnapshot(for: profile)

        try #"{"oauth:tokenCache":{"accessToken":"two"}}"#.data(using: .utf8)!.write(to: configURL)
        source.readError = ClaudeCodeCredentialsKeychainError.keychainError(errSecNotAvailable)

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile)) { error in
            guard case CLISwitcherError.backupFailed = error else {
                return XCTFail("Expected backupFailed, got \(error)")
            }
        }

        XCTAssertTrue(source.writes.isEmpty, "No keychain write may happen after a failed read")
        let untouchedData = try Data(contentsOf: configURL)
        let untouched = try XCTUnwrap(JSONSerialization.jsonObject(with: untouchedData) as? [String: Any])
        let tokenCache = try XCTUnwrap(untouched["oauth:tokenCache"] as? [String: Any])
        XCTAssertEqual(tokenCache["accessToken"] as? String, "two", "Files must be untouched when the keychain read fails")
    }

    func testRestoreLegacySnapshotWithoutKeychainItemIsRejectedByDefault() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":{"accessToken":"account-a"}}"#.data(using: .utf8)!.write(to: configURL)

        // Legacy snapshot: captured while the keychain item was absent, so
        // it has no keychainJSONFields item.
        let source = FakeClaudeCLICredentialSource()
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "A")
        let legacy = try switcher.captureAndStoreSnapshot(for: profile)
        XCTAssertFalse(legacy.items.contains { $0.kind == .keychainJSONFields })
        XCTAssertFalse(try switcher.hasRestorableSnapshot(for: profile))

        // The terminal is now logged into account B.
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"account-b","expiresAt":1783458000000},"mcpOAuth":{"serverX":{"accessToken":"mcp"}}}"#.utf8)
        let liveBeforeRestore = source.itemJSON

        XCTAssertThrowsError(
            try switcher.restoreSnapshot(for: profile)
        ) { error in
            guard case CLISwitcherError.missingCredentials = error else {
                return XCTFail("Expected missingCredentials, got \(error)")
            }
        }
        XCTAssertEqual(source.itemJSON, liveBeforeRestore)
        XCTAssertTrue(source.writes.isEmpty, "An incomplete snapshot must never rewrite the live login")
    }

    func testProviderMismatchIsRejected() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        try store.save(
            snapshot: CredentialSnapshot(provider: .codex, items: [
                CredentialSnapshotItem(relativePath: ".codex/auth.json", kind: .fullFile, contents: Data("{}".utf8), posixPermissions: 0o600)
            ]),
            for: profile.id
        )

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile)) { error in
            guard case CLISwitcherError.providerMismatch = error else {
                return XCTFail("Expected provider mismatch, got \(error)")
            }
        }
    }

    func testResolveExecutablePathFindsCommonCommand() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )

        let resolved = try XCTUnwrap(switcher.resolveExecutablePath(command: "ls"))
        XCTAssertTrue(resolved.hasPrefix("/"), "Expected an absolute path, got \(resolved)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved))
    }

    func testResolveExecutablePathReturnsNilForUnknownCommand() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: MemoryCredentialStore(),
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )

        XCTAssertNil(switcher.resolveExecutablePath(command: "definitely-not-a-real-cli-xyzzy"))
    }

    func testCredentialAccessModePropagatesThroughSwitcherInterfaces() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = MemoryCredentialStore()
        let source = FakeClaudeCLICredentialSource()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: source
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")

        _ = try switcher.liveObservation(provider: .claude, accessMode: .nonInteractive)
        _ = try switcher.hasStoredSnapshot(for: profile, accessMode: .userInitiated)

        XCTAssertEqual(source.accessModes, [.nonInteractive])
        XCTAssertEqual(store.accessModes, [.userInitiated])
    }

    func testRestoreValidationFailurePreservesCredentialAccessDisposition() {
        let validationError = CLISwitcherError.restoreValidationFailed(
            provider: .claude,
            reason: "authorization stopped",
            disposition: .userCancelled
        )
        XCTAssertEqual(validationError.credentialAccessDisposition, .userCancelled)

        let nestedError = CLISwitcherError.backupFailed(
            path: "keychain/Claude Code-credentials",
            underlying: CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        )
        XCTAssertEqual(nestedError.credentialAccessDisposition, .interactionRequired)
    }

    private func codexAccessToken(at url: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let tokens = object?["tokens"] as? [String: Any]
        return tokens?["access_token"] as? String
    }

    private func codexAuth(email: String, accountID: String, accessToken: String) -> Data {
        let payload = #"{"email":"\#(email)"}"#
        let encodedPayload = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let idToken = "header.\(encodedPayload).signature"
        return Data(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"\#(accessToken)","id_token":"\#(idToken)","account_id":"\#(accountID)"}}"#.utf8
        )
    }

    private func fakeClaudeSource(accessToken: String = "tok-a") -> FakeClaudeCLICredentialSource {
        let source = FakeClaudeCLICredentialSource()
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"\#(accessToken)","expiresAt":1783458000000},"mcpOAuth":{"serverX":{"accessToken":"mcp"}}}"#.utf8)
        return source
    }

    private func testClaudeKeychainLocation(
        reference: String
    ) -> ClaudeKeychainItemLocation {
        ClaudeKeychainItemLocation(
            serviceName: ClaudeCodeCredentialsKeychain.serviceName,
            accountName: "disposable-test-user",
            keychainPath: "/tmp/disposable.keychain-db",
            persistentReference: Data(reference.utf8),
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2)
        )
    }
}

private enum InjectedRestoreFailure: Error {
    case afterWrite
}

/// In-memory stand-in for the login-keychain item so tests never touch the
/// real "Claude Code-credentials" entry.
private final class FakeClaudeCLICredentialSource: ClaudeCLICredentialSource, @unchecked Sendable {
    var itemJSON: Data?
    var readError: Error?
    var exactLocation: ClaudeKeychainItemLocation?
    var onRead: ((FakeClaudeCLICredentialSource, Int) -> Void)?
    private(set) var writes: [Data] = []
    private(set) var accessModes: [CredentialAccessMode] = []
    private(set) var readCount = 0
    private(set) var exactReadLocations: [ClaudeKeychainItemLocation] = []

    var supportsExactItemLocations: Bool { exactLocation != nil }

    func locateLiveItem(accessMode: CredentialAccessMode) throws -> ClaudeKeychainItemLocation? {
        accessModes.append(accessMode)
        return exactLocation
    }

    func readLiveItemJSON(accessMode: CredentialAccessMode) throws -> Data? {
        accessModes.append(accessMode)
        readCount += 1
        onRead?(self, readCount)
        if let readError {
            throw readError
        }
        return itemJSON
    }

    func readLiveItemJSON(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        accessModes.append(accessMode)
        exactReadLocations.append(location)
        readCount += 1
        onRead?(self, readCount)
        if let readError {
            throw readError
        }
        guard exactLocation?.identity == location.identity else {
            return nil
        }
        return itemJSON
    }

    func writeLiveItemJSON(_ data: Data, accessMode: CredentialAccessMode) throws {
        accessModes.append(accessMode)
        writes.append(data)
        itemJSON = data
    }

    func deleteLiveItem(accessMode: CredentialAccessMode) throws {
        accessModes.append(accessMode)
        itemJSON = nil
    }
}

private final class MemoryCredentialStore: CredentialStoreProtocol {
    private var storage: [UUID: CredentialSnapshot] = [:]
    private var revisions: [UUID: CredentialStoreRevision] = [:]
    private(set) var accessModes: [CredentialAccessMode] = []
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var insertCount = 0
    private(set) var replaceCount = 0
    var beforeInsert: ((UUID) -> Void)?
    var beforeReplace: ((UUID) -> Void)?

    func save(
        snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws {
        accessModes.append(accessMode)
        saveCount += 1
        storage[accountID] = snapshot
        revisions[accountID] = Self.freshRevision()
    }

    func insertSnapshotIfAbsent(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        accessModes.append(accessMode)
        insertCount += 1
        beforeInsert?(accountID)
        guard storage[accountID] == nil else { return false }
        storage[accountID] = snapshot
        revisions[accountID] = Self.freshRevision()
        return true
    }

    func loadSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> CredentialSnapshot? {
        accessModes.append(accessMode)
        loadCount += 1
        return storage[accountID]
    }

    func loadVersionedSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> VersionedCredentialSnapshot? {
        accessModes.append(accessMode)
        loadCount += 1
        guard let snapshot = storage[accountID],
              let revision = revisions[accountID] else {
            return nil
        }
        return VersionedCredentialSnapshot(snapshot: snapshot, revision: revision)
    }

    func replaceSnapshot(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        ifRevisionMatches expectedRevision: CredentialStoreRevision,
        accessMode: CredentialAccessMode
    ) throws -> CredentialStoreRevision? {
        accessModes.append(accessMode)
        replaceCount += 1
        beforeReplace?(accountID)
        guard revisions[accountID] == expectedRevision else { return nil }
        let revision = Self.freshRevision()
        storage[accountID] = snapshot
        revisions[accountID] = revision
        return revision
    }

    func deleteSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws {
        accessModes.append(accessMode)
        storage[accountID] = nil
        revisions[accountID] = nil
    }

    func hasSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> Bool {
        accessModes.append(accessMode)
        return storage[accountID] != nil
    }

    private static func freshRevision() -> CredentialStoreRevision {
        CredentialStoreRevision(rawValue: Data(UUID().uuidString.utf8))
    }
}

private struct TemporaryFixture {
    let root: URL
    let home: URL
    let backups: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboatTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
