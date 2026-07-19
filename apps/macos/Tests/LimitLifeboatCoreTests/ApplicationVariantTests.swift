import XCTest
@testable import LimitLifeboatCore

final class ApplicationVariantTests: XCTestCase {
    func testDevelopmentNamespaceIsIsolatedAndRestricted() {
        let variant = ApplicationVariant.development

        XCTAssertEqual(variant.bundleIdentifier, "com.limitlifeboat.app.dev")
        XCTAssertEqual(variant.displayName, "Limit Lifeboat Dev")
        XCTAssertEqual(variant.credentialService, "com.limitlifeboat.app.dev.credentials")
        XCTAssertEqual(variant.applicationSupportDirectoryName, "LimitLifeboat-Dev")
        XCTAssertFalse(variant.supportsUpdates)
        XCTAssertFalse(variant.supportsLaunchAtLogin)
        XCTAssertFalse(variant.allowsLegacyMigration)
    }

    func testDistributionNamespaceRemainsStable() {
        let variant = ApplicationVariant.distribution

        XCTAssertEqual(variant.bundleIdentifier, "com.limitlifeboat.app")
        XCTAssertEqual(variant.displayName, "Limit Lifeboat")
        XCTAssertEqual(variant.credentialService, "com.limitlifeboat.app.credentials")
        XCTAssertEqual(variant.applicationSupportDirectoryName, "LimitLifeboat")
        XCTAssertTrue(variant.supportsUpdates)
        XCTAssertTrue(variant.supportsLaunchAtLogin)
        XCTAssertTrue(variant.allowsLegacyMigration)
    }

    func testUnbundledProcessDefaultsToDevelopment() throws {
        XCTAssertEqual(
            try ApplicationVariant.resolve(declaredVariant: nil, bundleIdentifier: nil),
            .development
        )
    }

    func testDeclaredVariantMustMatchBundleIdentifier() {
        XCTAssertThrowsError(
            try ApplicationVariant.resolve(
                declaredVariant: "distribution",
                bundleIdentifier: ApplicationVariant.development.bundleIdentifier
            )
        )
        XCTAssertThrowsError(
            try ApplicationVariant.resolve(
                declaredVariant: "unknown",
                bundleIdentifier: "com.limitlifeboat.app"
            )
        )
        XCTAssertThrowsError(
            try ApplicationVariant.resolve(
                declaredVariant: nil,
                bundleIdentifier: "com.limitlifeboat.app"
            )
        )
    }
}
