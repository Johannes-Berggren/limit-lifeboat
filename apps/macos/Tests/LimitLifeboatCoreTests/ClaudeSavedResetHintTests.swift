import XCTest
@testable import LimitLifeboatCore

final class ClaudeSavedResetHintTests: XCTestCase {
    func testOnlyForTheActiveClaudeAccountAtItsLimit() {
        XCTAssertNotNil(ClaudeSavedResetHint.text(provider: .claude, windowID: "session", riskLevel: .depleted, isActiveCLI: true))
        XCTAssertNotNil(ClaudeSavedResetHint.text(provider: .claude, windowID: "weekly-all", riskLevel: .depleted, isActiveCLI: true))
        XCTAssertNil(ClaudeSavedResetHint.text(provider: .claude, windowID: "session", riskLevel: .depleted, isActiveCLI: false))
        XCTAssertNil(ClaudeSavedResetHint.text(provider: .claude, windowID: "session", riskLevel: .warning, isActiveCLI: true))
        XCTAssertNil(ClaudeSavedResetHint.text(provider: .codex, windowID: "session", riskLevel: .depleted, isActiveCLI: true))
    }

    func testSkipsPerModelAndScopedWeeklyLimits() {
        for windowID in ["weekly-opus", "weekly-fable", "weekly-scoped", "seven_day_cowork"] {
            XCTAssertNil(
                ClaudeSavedResetHint.text(provider: .claude, windowID: windowID, riskLevel: .depleted, isActiveCLI: true),
                windowID
            )
        }
    }
}
