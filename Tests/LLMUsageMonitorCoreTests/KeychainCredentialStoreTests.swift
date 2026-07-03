import XCTest
@testable import LLMUsageMonitorCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testSaveLoadUpdateAndDeleteSnapshot() throws {
        let store = KeychainCredentialStore(service: "com.johannesberggren.LLMUsageMonitor.tests.\(UUID().uuidString)")
        let accountID = UUID()
        defer { try? store.deleteSnapshot(for: accountID) }

        let first = CredentialSnapshot(provider: .codex, capturedAt: Date(timeIntervalSince1970: 1), items: [
            CredentialSnapshotItem(relativePath: ".codex/auth.json", kind: .fullFile, contents: Data("one".utf8), posixPermissions: 0o600)
        ])
        try store.save(snapshot: first, for: accountID)

        XCTAssertTrue(try store.hasSnapshot(for: accountID))
        XCTAssertEqual(try store.loadSnapshot(for: accountID), first)

        let second = CredentialSnapshot(provider: .codex, capturedAt: Date(timeIntervalSince1970: 2), items: [
            CredentialSnapshotItem(relativePath: ".codex/auth.json", kind: .fullFile, contents: Data("two".utf8), posixPermissions: 0o600)
        ])
        try store.save(snapshot: second, for: accountID)
        XCTAssertEqual(try store.loadSnapshot(for: accountID), second)

        try store.deleteSnapshot(for: accountID)
        XCTAssertFalse(try store.hasSnapshot(for: accountID))
        XCTAssertNil(try store.loadSnapshot(for: accountID))
    }
}
