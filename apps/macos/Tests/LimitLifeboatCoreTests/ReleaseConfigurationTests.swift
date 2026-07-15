import Foundation
import XCTest

final class ReleaseConfigurationTests: XCTestCase {
    private let publicKey = "9mfTfQVDLtvuNmxMr1BvduLMOiVeceFp5rOkOC3PW5Y="
    private let feedURL = "https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest/download/appcast.xml"

    func testProductVersionIsStableSemVer() throws {
        let version = try contents("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression))
    }

    func testSparkleDependencyIsPinnedExactly() throws {
        let manifest = try contents("Package.swift")
        XCTAssertTrue(manifest.contains(#"exact: "2.9.4""#))
    }

    func testResolvedSparkleVersionIsCommitted() throws {
        let resolved = try contents("Package.resolved")
        XCTAssertTrue(resolved.contains(#""identity" : "sparkle""#))
        XCTAssertTrue(resolved.contains(#""version" : "2.9.4""#))
    }

    func testSiteReadsTheNativeVersionFile() throws {
        let config = try contents("../site/src/config.ts")
        XCTAssertTrue(config.contains(#"import productVersion from "../../macos/VERSION?raw""#))
        XCTAssertTrue(config.contains("major.minor.patch SemVer"))
    }

    func testPackagedFeedUsesStableLatestAssetURL() throws {
        let packaging = try contents("scripts/package-app.sh")
        XCTAssertTrue(packaging.contains("SPARKLE_FEED_URL=\"\(feedURL)\""))
        XCTAssertTrue(packaging.contains("<key>SUFeedURL</key>"))
    }

    func testPackagedPublicKeyMatchesReleaseKey() throws {
        let packaging = try contents("scripts/package-app.sh")
        XCTAssertTrue(packaging.contains("SPARKLE_PUBLIC_KEY=\"\(publicKey)\""))
        XCTAssertTrue(packaging.contains("<key>SUPublicEDKey</key>"))
    }

    func testUpdatesCheckDailyButNeverInstallAutomatically() throws {
        let packaging = try contents("scripts/package-app.sh")
        XCTAssertTrue(packaging.contains("<key>SUEnableAutomaticChecks</key>\n  <true/>"))
        XCTAssertTrue(packaging.contains("<key>SUScheduledCheckInterval</key>\n  <integer>86400</integer>"))
        XCTAssertTrue(packaging.contains("<key>SUAutomaticallyUpdate</key>\n  <false/>"))
    }

    func testPackagingEmbedsSparkleAndRemovesUnusedXPCServices() throws {
        let packaging = try contents("scripts/package-app.sh")
        XCTAssertTrue(packaging.contains("ditto \"$SPARKLE_SOURCE\" \"$SPARKLE_FRAMEWORK\""))
        XCTAssertTrue(packaging.contains("rm -rf \"$SPARKLE_FRAMEWORK/Versions/B/XPCServices\""))
        XCTAssertTrue(packaging.contains("ThirdPartyLicenses/Sparkle.txt"))
    }

    func testReleaseGeneratesOneFullSignedUpdateWithoutDeltas() throws {
        let release = try contents("scripts/release.sh")
        XCTAssertTrue(release.contains("--maximum-versions 1"))
        XCTAssertTrue(release.contains("--maximum-deltas 0"))
        XCTAssertTrue(release.contains("--verify \"$APPCAST_PATH\""))
        XCTAssertTrue(release.contains("$PUBLIC_DOWNLOAD_ROOT/$DMG_BASENAME"))
    }

    func testCustomGitHubUpdateCheckerWasRemoved() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: macOSRoot.appendingPathComponent("Sources/LimitLifeboatCore/UpdateChecker.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: macOSRoot.appendingPathComponent("Sources/LimitLifeboat/UpdateService.swift").path))
    }

    private var macOSRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: macOSRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
