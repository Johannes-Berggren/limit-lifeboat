import Foundation
import XCTest
@testable import LimitLifeboatCore

final class ClaudeCodeProcessLaunchPolicyTests: XCTestCase {
    func testDiscoveryEnvironmentAlwaysStripsOAuthToken() {
        let environment = ClaudeCodeProcessLaunchPolicy.discoveryEnvironment(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            processEnvironment: [
                "PATH": "/custom/bin",
                ClaudeCodeProcessLaunchPolicy.oauthEnvironmentKey: "must-not-leak"
            ]
        )

        XCTAssertNil(environment[ClaudeCodeProcessLaunchPolicy.oauthEnvironmentKey])
        XCTAssertTrue(environment["PATH"]?.contains("/custom/bin") == true)
    }

    func testOnlyCredentialedFinalEnvironmentContainsValidToken() throws {
        let token = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz"
        let environment = try XCTUnwrap(
            ClaudeCodeProcessLaunchPolicy.credentialedEnvironment(
                homeDirectory: URL(fileURLWithPath: "/Users/test"),
                oauthToken: token,
                processEnvironment: [:]
            )
        )

        XCTAssertEqual(
            environment[ClaudeCodeProcessLaunchPolicy.oauthEnvironmentKey],
            token
        )
        XCTAssertNil(
            ClaudeCodeProcessLaunchPolicy.credentialedEnvironment(
                homeDirectory: URL(fileURLWithPath: "/Users/test"),
                oauthToken: ""
            )
        )
    }

    func testPathResolutionNeedsNoHelperProcess() {
        let home = URL(fileURLWithPath: "/Users/test")
        let candidates = ClaudeCodeProcessLaunchPolicy.executableCandidates(
            homeDirectory: home,
            environment: ["PATH": "/first:/second"]
        )

        XCTAssertEqual(candidates.first, home.appendingPathComponent(".local/bin/claude"))
        XCTAssertTrue(candidates.contains(URL(fileURLWithPath: "/first/claude")))
        XCTAssertTrue(candidates.contains(URL(fileURLWithPath: "/second/claude")))
    }
}
