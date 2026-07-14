import XCTest
@testable import LimitLifeboatCore

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
            "html_url": "https://github.com/Johannes-Berggren/limit-lifeboat/releases/tag/v1.2.0",
            "name": "1.2.0",
            "draft": false,
            "prerelease": false
        }
        """
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(
            release.htmlURL.absoluteString,
            "https://github.com/Johannes-Berggren/limit-lifeboat/releases/tag/v1.2.0"
        )
    }

    func testGitHubCheckerReturnsAvailableUpdateAndBuildsRequest() async throws {
        let http = MockHTTPClient()
        http.stub(
            status: 200,
            bodyText: #"{"tag_name":"v1.2.0","html_url":"https://github.com/Johannes-Berggren/limit-lifeboat/releases/tag/v1.2.0"}"#
        )
        let checker = GitHubUpdateChecker(httpClient: http)

        let result = await checker.check(currentVersion: "1.0.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                AvailableUpdate(
                    version: "1.2.0",
                    url: URL(string: "https://github.com/Johannes-Berggren/limit-lifeboat/releases/tag/v1.2.0")!
                )
            )
        )
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, GitHubUpdateChecker.defaultReleasesURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LimitLifeboat")
    }

    func testGitHubCheckerReturnsUpToDateForCurrentOrOlderRelease() async {
        let http = MockHTTPClient()
        http.stub(
            status: 200,
            bodyText: #"{"tag_name":"v1.0.0","html_url":"https://github.com/Johannes-Berggren/limit-lifeboat/releases/tag/v1.0.0"}"#
        )

        let result = await GitHubUpdateChecker(httpClient: http).check(currentVersion: "1.0.0")

        XCTAssertEqual(result, .upToDate)
    }

    func testGitHubCheckerReportsHTTPFailure() async {
        let http = MockHTTPClient()
        http.stub(status: 503, bodyText: "unavailable")

        let result = await GitHubUpdateChecker(httpClient: http).check(currentVersion: "1.0.0")

        guard case .failed(let message) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertTrue(message.contains("HTTP 503"))
    }

    func testGitHubCheckerReportsTransportFailure() async {
        let http = MockHTTPClient()
        http.stub(error: URLError(.notConnectedToInternet))

        let result = await GitHubUpdateChecker(httpClient: http).check(currentVersion: "1.0.0")

        guard case .failed(let message) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Couldn’t check for updates"))
    }

    func testGitHubCheckerRejectsMalformedSuccessfulResponse() async {
        let http = MockHTTPClient()
        http.stub(status: 200, bodyText: #"{"unexpected":true}"#)

        let result = await GitHubUpdateChecker(httpClient: http).check(currentVersion: "1.0.0")

        guard case .failed(let message) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertTrue(message.contains("invalid release response"))
    }

    func testUpdateScheduleUsesDailySuccessAndHourlyFailureBackoff() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertFalse(
            UpdateCheckSchedule.shouldCheck(
                lastSuccessfulCheck: now.addingTimeInterval(-23 * 60 * 60),
                lastFailedCheck: nil,
                now: now
            )
        )
        XCTAssertTrue(
            UpdateCheckSchedule.shouldCheck(
                lastSuccessfulCheck: now.addingTimeInterval(-24 * 60 * 60),
                lastFailedCheck: nil,
                now: now
            )
        )
        XCTAssertFalse(
            UpdateCheckSchedule.shouldCheck(
                lastSuccessfulCheck: now.addingTimeInterval(-25 * 60 * 60),
                lastFailedCheck: now.addingTimeInterval(-59 * 60),
                now: now
            )
        )
        XCTAssertTrue(
            UpdateCheckSchedule.shouldCheck(
                lastSuccessfulCheck: now.addingTimeInterval(-25 * 60 * 60),
                lastFailedCheck: now.addingTimeInterval(-60 * 60),
                now: now
            )
        )
    }
}
