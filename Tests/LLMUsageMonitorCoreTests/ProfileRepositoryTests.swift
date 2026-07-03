import XCTest
@testable import LLMUsageMonitorCore

final class ProfileRepositoryTests: XCTestCase {
    func testMigratesFirstProviderProfilesToDefaultWebStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMUsageMonitorProfileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try ProfileRepository(applicationSupportDirectory: root)
        var profiles = AccountProfile.defaultProfiles(now: Date(timeIntervalSince1970: 0))
        for index in profiles.indices {
            profiles[index].webDataStoreKind = .isolated
        }
        try repository.saveProfiles(profiles)

        let migrated = try repository.loadProfiles()

        XCTAssertEqual(migrated[0].webDataStoreKind, .appDefault)
        XCTAssertEqual(migrated[1].webDataStoreKind, .isolated)
        XCTAssertEqual(migrated[2].webDataStoreKind, .appDefault)
        XCTAssertEqual(migrated[3].webDataStoreKind, .isolated)
    }
}
