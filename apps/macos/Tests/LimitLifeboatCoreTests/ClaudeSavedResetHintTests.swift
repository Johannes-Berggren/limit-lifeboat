import XCTest
@testable import LimitLifeboatCore

final class ClaudeSavedResetHintTests: XCTestCase {
    func testOnlyForTheActiveClaudeAccountAtItsLimit() {
        XCTAssertNotNil(ClaudeSavedResetHint.text(provider: .claude, riskLevel: .depleted, isActiveCLI: true))
        XCTAssertNil(ClaudeSavedResetHint.text(provider: .claude, riskLevel: .depleted, isActiveCLI: false))
        XCTAssertNil(ClaudeSavedResetHint.text(provider: .claude, riskLevel: .warning, isActiveCLI: true))
        XCTAssertNil(ClaudeSavedResetHint.text(provider: .codex, riskLevel: .depleted, isActiveCLI: true))
    }
}
