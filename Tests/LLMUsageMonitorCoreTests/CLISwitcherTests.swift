import Foundation
import Security
import XCTest
@testable import LLMUsageMonitorCore

final class CLISwitcherTests: XCTestCase {
    func testCodexCaptureAndRestoreCreatesBackup() throws {
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
        let restored = try String(contentsOf: authURL)

        XCTAssertTrue(restored.contains(#""access_token":"one""#) || restored.contains(#""access_token": "one""#))
        XCTAssertEqual(result.backupURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupURLs[0].path))
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
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")

        _ = try switcher.captureAndStoreSnapshot(for: profile)
        try #"{"userThemeMode":"light","oauth:tokenCache":{"accessToken":"two"}}"#.data(using: .utf8)!.write(to: configURL)

        _ = try switcher.restoreSnapshot(for: profile)
        let restoredData = try Data(contentsOf: configURL)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: restoredData) as? [String: Any])
        let tokenCache = try XCTUnwrap(restored["oauth:tokenCache"] as? [String: Any])

        XCTAssertEqual(restored["userThemeMode"] as? String, "light")
        XCTAssertEqual(tokenCache["accessToken"] as? String, "one")
    }

    func testRestoreUsesSingleBackupDirectoryPerRestore() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        // A Claude snapshot with two items: desktop config (jsonFields) and
        // ~/.claude.json (fullFile).
        let configURL = fixture.home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":{"accessToken":"one"}}"#.data(using: .utf8)!.write(to: configURL)
        let claudeJSONURL = fixture.home.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"emailAddress":"a@example.com"}}"#.data(using: .utf8)!.write(to: claudeJSONURL)

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let captured = try switcher.captureAndStoreSnapshot(for: profile)
        XCTAssertEqual(captured.items.count, 2)

        let result = try switcher.restoreSnapshot(for: profile)

        let backupDirectories = try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path)
        XCTAssertEqual(backupDirectories.count, 1)
        XCTAssertEqual(result.backupURLs.count, 2)
        for backup in result.backupURLs {
            XCTAssertEqual(backup.deletingLastPathComponent().lastPathComponent, backupDirectories[0])
        }
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
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
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
    }

    func testRollbackRemovesFileCreatedByFailedRestore() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let blocker = fixture.home.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(
            homeDirectory: fixture.home,
            backupDirectory: fixture.backups,
            credentialStore: store,
            claudeCLICredentialSource: FakeClaudeCLICredentialSource()
        )
        let profile = AccountProfile(provider: .codex, label: "A")
        try store.save(
            snapshot: CredentialSnapshot(provider: .codex, items: [
                CredentialSnapshotItem(relativePath: "created/auth.json", kind: .fullFile, contents: Data("one".utf8), posixPermissions: 0o600),
                CredentialSnapshotItem(relativePath: "blocker/auth.json", kind: .fullFile, contents: Data("two".utf8), posixPermissions: 0o600)
            ]),
            for: profile.id
        )

        XCTAssertThrowsError(try switcher.restoreSnapshot(for: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("created/auth.json").path))
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

        XCTAssertThrowsError(try transaction.restore(snapshot)) { error in
            guard case CLISwitcherError.credentialConflict = error else {
                return XCTFail("Expected credentialConflict, got \(error)")
            }
        }
        XCTAssertEqual(try codexAccessToken(at: authURL), "external")
    }

    func testRollbackDoesNotOverwriteChangeMadeAfterFirstWrite() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let firstURL = fixture.home.appendingPathComponent("first/auth.json")
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

        XCTAssertThrowsError(try transaction.restore(snapshot)) { error in
            guard case CLISwitcherError.rollbackConflict = error else {
                return XCTFail("Expected rollbackConflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: firstURL), "external")
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
        try store.save(
            snapshot: CredentialSnapshot(provider: .claude, items: [
                CredentialSnapshotItem(
                    relativePath: "Library/Application Support/Claude/config.json",
                    kind: .jsonFields,
                    contents: Data(#"{"oauth:tokenCache":{"accessToken":"target"}}"#.utf8),
                    posixPermissions: 0o600
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

        let result = try switcher.restoreSnapshot(for: profileA)

        let live = try XCTUnwrap(source.itemJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: live) as? [String: Any])
        let oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        let mcp = try XCTUnwrap(object["mcpOAuth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "account-a")
        XCTAssertNotNil(mcp["serverX"], "mcpOAuth must survive an account switch")
        XCTAssertTrue(
            result.backupURLs.contains { $0.lastPathComponent.contains("keychain") },
            "The live keychain item should be backed up alongside file backups"
        )
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

    func testRestoreLegacySnapshotWithoutKeychainItemLogsOutPreviousAccount() throws {
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

        // The terminal is now logged into account B.
        source.itemJSON = Data(#"{"claudeAiOauth":{"accessToken":"account-b","expiresAt":1783458000000},"mcpOAuth":{"serverX":{"accessToken":"mcp"}}}"#.utf8)

        let result = try switcher.restoreSnapshot(for: profile)

        let live = try XCTUnwrap(source.itemJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: live) as? [String: Any])
        XCTAssertNil(object["claudeAiOauth"], "The previous account's token must not survive the switch")
        let mcp = try XCTUnwrap(object["mcpOAuth"] as? [String: Any])
        XCTAssertNotNil(mcp["serverX"], "mcpOAuth must survive the logout")
        XCTAssertTrue(
            result.backupURLs.contains { $0.lastPathComponent.contains("keychain") },
            "The live item must be backed up before it is rewritten"
        )
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

    private func codexAccessToken(at url: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let tokens = object?["tokens"] as? [String: Any]
        return tokens?["access_token"] as? String
    }
}

/// In-memory stand-in for the login-keychain item so tests never touch the
/// real "Claude Code-credentials" entry.
private final class FakeClaudeCLICredentialSource: ClaudeCLICredentialSource, @unchecked Sendable {
    var itemJSON: Data?
    var readError: Error?
    private(set) var writes: [Data] = []

    func readLiveItemJSON() throws -> Data? {
        if let readError {
            throw readError
        }
        return itemJSON
    }

    func writeLiveItemJSON(_ data: Data) throws {
        writes.append(data)
        itemJSON = data
    }

    func deleteLiveItem() throws {
        itemJSON = nil
    }
}

private final class MemoryCredentialStore: CredentialStoreProtocol {
    private var storage: [UUID: CredentialSnapshot] = [:]

    func save(snapshot: CredentialSnapshot, for accountID: UUID) throws {
        storage[accountID] = snapshot
    }

    func loadSnapshot(for accountID: UUID) throws -> CredentialSnapshot? {
        storage[accountID]
    }

    func deleteSnapshot(for accountID: UUID) throws {
        storage[accountID] = nil
    }

    func hasSnapshot(for accountID: UUID) throws -> Bool {
        storage[accountID] != nil
    }
}

private struct TemporaryFixture {
    let root: URL
    let home: URL
    let backups: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMUsageMonitorTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
