import XCTest
@testable import LimitLifeboatCore

final class ClaudeCodeUsageLaunchGateTests: XCTestCase {
    func testEmptyTokenDoesNotLaunchProcess() async {
        let launches = LaunchCounter()

        do {
            _ = try await ClaudeCodeUsageLaunchGate.run(oauthToken: "") { _ in
                await launches.record()
                return "output"
            }
            XCTFail("Expected invalidOAuthToken")
        } catch let error as ClaudeCodeUsageLaunchGateError {
            XCTAssertEqual(error, .invalidOAuthToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let launchCount = await launches.value
        XCTAssertEqual(launchCount, 0)
    }

    func testWhitespaceAndControlCharactersDoNotLaunchProcess() async {
        let launches = LaunchCounter()

        for token in ["   ", "token\nvalue", "token\u{0}value"] {
            do {
                _ = try await ClaudeCodeUsageLaunchGate.run(oauthToken: token) { _ in
                    await launches.record()
                    return "output"
                }
                XCTFail("Expected invalidOAuthToken for \(token.debugDescription)")
            } catch let error as ClaudeCodeUsageLaunchGateError {
                XCTAssertEqual(error, .invalidOAuthToken)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let launchCount = await launches.value
        XCTAssertEqual(launchCount, 0)
    }

    func testValidTokenLaunchesExactlyOnceAndIsForwarded() async throws {
        let launches = LaunchCounter()

        let output = try await ClaudeCodeUsageLaunchGate.run(oauthToken: "oauth-token") { token in
            await launches.record(token: token)
            return "usage-output"
        }

        XCTAssertEqual(output, "usage-output")
        let launchCount = await launches.value
        let lastToken = await launches.lastToken
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(lastToken, "oauth-token")
    }
}

private actor LaunchCounter {
    private(set) var value = 0
    private(set) var lastToken: String?

    func record(token: String? = nil) {
        value += 1
        lastToken = token
    }
}
