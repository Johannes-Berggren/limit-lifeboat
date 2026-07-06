import Foundation
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
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
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
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
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
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
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
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
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
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
        let profileA = AccountProfile(provider: .codex, label: "A")
        let profileB = AccountProfile(provider: .codex, label: "B")

        let contentsA = #"{"tokens":{"access_token":"account-a"}}"#
        let contentsB = #"{"tokens":{"access_token":"account-b"}}"#

        try contentsA.data(using: .utf8)!.write(to: authURL)
        _ = try switcher.captureAndStoreSnapshot(for: profileA)
        try contentsB.data(using: .utf8)!.write(to: authURL)
        _ = try switcher.captureAndStoreSnapshot(for: profileB)

        _ = try switcher.restoreSnapshot(for: profileA)
        XCTAssertEqual(try String(contentsOf: authURL), contentsA)

        _ = try switcher.restoreSnapshot(for: profileB)
        XCTAssertEqual(try String(contentsOf: authURL), contentsB)
    }

    func testCurrentIdentityReadsCodexAuthFile() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
        XCTAssertNil(switcher.currentIdentity(provider: .codex))

        let claudeJSONURL = fixture.home.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"emailAddress":"me@example.com","accountUuid":"acct-9"}}"#
            .data(using: .utf8)!.write(to: claudeJSONURL)

        let identity = switcher.currentIdentity(provider: .claude)
        XCTAssertEqual(identity?.email, "me@example.com")
        XCTAssertEqual(identity?.accountID, "acct-9")
    }

    func testProviderMismatchIsRejected() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        let store = MemoryCredentialStore()
        let switcher = CLISwitcher(homeDirectory: fixture.home, backupDirectory: fixture.backups, credentialStore: store)
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
