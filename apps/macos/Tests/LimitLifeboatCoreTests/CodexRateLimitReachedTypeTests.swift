import XCTest
@testable import LimitLifeboatCore

final class CodexRateLimitReachedTypeTests: XCTestCase {
    func testWorkspaceStatesGetActionableText() {
        XCTAssertEqual(CodexRateLimitReachedType.statusText("rate_limit_reached"), "Rate limit reached.")
        XCTAssertEqual(
            CodexRateLimitReachedType.statusText("workspace_member_credits_depleted"),
            "Workspace credits are used up; ask a workspace owner to add more."
        )
        XCTAssertEqual(
            CodexRateLimitReachedType.statusText("WorkspaceOwnerUsageLimitReached"),
            "The workspace usage limit is reached; raise it in the workspace settings."
        )
    }

    func testUnknownValuesPassThrough() {
        XCTAssertEqual(CodexRateLimitReachedType.statusText("future_limit"), "Rate limit reached: future_limit.")
    }

    func testClassifiesPlainLimitAndWorkspaceCreditsInEitherSpelling() {
        XCTAssertTrue(CodexRateLimitReachedType.isPlainRateLimit("rate_limit_reached"))
        XCTAssertTrue(CodexRateLimitReachedType.isPlainRateLimit("RateLimitReached"))
        XCTAssertFalse(CodexRateLimitReachedType.isPlainRateLimit("workspace_owner_usage_limit_reached"))
        XCTAssertFalse(CodexRateLimitReachedType.isPlainRateLimit(nil))
        XCTAssertTrue(CodexRateLimitReachedType.isWorkspaceCreditsDepleted("WorkspaceOwnerCreditsDepleted"))
        XCTAssertFalse(CodexRateLimitReachedType.isWorkspaceCreditsDepleted("workspace_member_usage_limit_reached"))
    }
}
