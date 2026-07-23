import Foundation
import XCTest

final class ReleaseConfigurationTests: XCTestCase {
    private let publicKey = "sByqwP3sYWWv46jT+x7vgv7tt+iujcezHs7WX+gyP7g="
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
        XCTAssertTrue(packaging.contains("SPARKLE_AUTOMATIC_CHECKS=\"true\""))
        XCTAssertTrue(packaging.contains("<key>SUEnableAutomaticChecks</key>\n  <$SPARKLE_AUTOMATIC_CHECKS/>"))
        XCTAssertTrue(packaging.contains("<key>SUScheduledCheckInterval</key>\n  <integer>86400</integer>"))
        XCTAssertTrue(packaging.contains("<key>SUAutomaticallyUpdate</key>\n  <false/>"))
    }

    func testPackagingDefaultsToIsolatedDevelopmentVariant() throws {
        let packaging = try contents("scripts/package-app.sh")

        XCTAssertTrue(packaging.contains("APP_VARIANT=\"${APP_VARIANT:-development}\""))
        XCTAssertTrue(packaging.contains("DISPLAY_NAME=\"Limit Lifeboat Dev\""))
        XCTAssertTrue(packaging.contains("BUNDLE_ID=\"com.limitlifeboat.app.dev\""))
        XCTAssertTrue(packaging.contains("CREDENTIAL_SERVICE=\"com.limitlifeboat.app.dev.credentials\""))
        XCTAssertTrue(packaging.contains("APPLICATION_SUPPORT_NAME=\"LimitLifeboat-Dev\""))
        XCTAssertTrue(packaging.contains("SPARKLE_AUTOMATIC_CHECKS=\"false\""))
        XCTAssertTrue(packaging.contains("APP_DIR=\"$APP_ROOT/dist/$PRODUCT_NAME.app\""))
    }

    func testReleaseAndCIExplicitlyPackageDistributionVariant() throws {
        let release = try contents("scripts/release.sh")
        let ci = try contents("../../.github/workflows/ci.yml")

        XCTAssertTrue(release.contains("APP_VARIANT=distribution SKIP_ADHOC_SIGN=1"))
        XCTAssertTrue(release.contains("LimitLifeboatAppVariant \"distribution\""))
        XCTAssertTrue(ci.contains("APP_VARIANT: distribution"))
        XCTAssertTrue(ci.contains("LimitLifeboatAppVariant raw"))
    }

    func testReleaseAndCIVerifyStableDistributionRequirementPolicy() throws {
        let release = try contents("scripts/release.sh")
        let ci = try contents("../../.github/workflows/ci.yml")

        XCTAssertTrue(release.contains("TeamIdentifier=$TEAM_ID"))
        XCTAssertTrue(release.contains(#"codesign --display --requirements - "$APP_DIR""#))
        XCTAssertTrue(release.contains("designated => identifier \\\"$BUNDLE_ID\\\""))
        XCTAssertTrue(release.contains("anchor apple"))
        XCTAssertTrue(release.contains("subject.OU] = \\\"$TEAM_ID\\\""))
        XCTAssertTrue(ci.contains("Validate stable distribution signing policy"))
        XCTAssertTrue(ci.contains(#"codesign --display --requirements - \"\$APP_DIR\""#))
        XCTAssertTrue(ci.contains("teamIdentifier == DistributionIdentity.appleTeamIdentifier"))
    }

    func testPackagingEmbedsSparkleAndRemovesUnusedXPCServices() throws {
        let packaging = try contents("scripts/package-app.sh")
        XCTAssertTrue(packaging.contains("ditto \"$SPARKLE_SOURCE\" \"$SPARKLE_FRAMEWORK\""))
        XCTAssertTrue(packaging.contains("rm -rf \"$SPARKLE_FRAMEWORK/Versions/B/XPCServices\""))
        XCTAssertTrue(packaging.contains("ThirdPartyLicenses/Sparkle.txt"))
    }

    func testManuallyAssembledAppDoesNotUseGeneratedSwiftPMResourceAccessor() throws {
        let appSources = macOSRoot.appendingPathComponent(
            "Sources/LimitLifeboat",
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(
            at: appSources,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate the manually assembled app target")
            return
        }

        var swiftSources: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            swiftSources.append(url)
        }
        XCTAssertFalse(swiftSources.isEmpty)

        for sourceURL in swiftSources.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertNil(
                source.range(
                    of: #"\bBundle\s*\.\s*module\b"#,
                    options: .regularExpression
                ),
                "\(sourceURL.lastPathComponent) uses the fatal generated resource accessor"
            )
        }
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
