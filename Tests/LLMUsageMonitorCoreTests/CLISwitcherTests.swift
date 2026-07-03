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
