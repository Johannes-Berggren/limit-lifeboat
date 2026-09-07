import Foundation
@testable import LimitLifeboat
import XCTest

final class SettingsStoreTests: XCTestCase {
    func testCompactMenuBarPreferenceDefaultsToOffAndPersists() async throws {
        try await MainActor.run {
            let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let initialStore = SettingsStore(defaults: defaults)
            XCTAssertFalse(initialStore.compactMenuBarEnabled)

            initialStore.compactMenuBarEnabled = true

            let reloadedStore = SettingsStore(defaults: defaults)
            XCTAssertTrue(reloadedStore.compactMenuBarEnabled)
        }
    }
}
