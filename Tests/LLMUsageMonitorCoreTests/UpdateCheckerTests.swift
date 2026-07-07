import XCTest
@testable import LLMUsageMonitorCore

final class UpdateCheckerTests: XCTestCase {
    func testParsesVersions() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("2"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion("1.2.0-beta.1"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertNil(SemanticVersion("dev"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
    }

    func testComparesVersions() {
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("1.0.1")!)
        XCTAssertLessThan(SemanticVersion("1.9.0")!, SemanticVersion("1.10.0")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
        XCTAssertEqual(SemanticVersion("v1.0")!, SemanticVersion("1.0.0")!)
    }

    func testIsUpdateAvailable() {
        XCTAssertTrue(UpdateChecker.isUpdateAvailable(currentVersion: "1.0.0", latestTag: "v1.1.0"))
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(currentVersion: "1.1.0", latestTag: "v1.1.0"))
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(currentVersion: "1.2.0", latestTag: "v1.1.0"))
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(currentVersion: "dev", latestTag: "v9.9.9"))
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(currentVersion: "1.0.0", latestTag: "nightly"))
    }

    func testDecodesGitHubLatestReleasePayload() throws {
        let json = """
        {
            "tag_name": "v1.2.0",
            "html_url": "https://github.com/Johannes-Berggren/harness-orchestrator/releases/tag/v1.2.0",
            "name": "1.2.0",
            "draft": false,
            "prerelease": false
        }
        """
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(
            release.htmlURL.absoluteString,
            "https://github.com/Johannes-Berggren/harness-orchestrator/releases/tag/v1.2.0"
        )
    }
}
