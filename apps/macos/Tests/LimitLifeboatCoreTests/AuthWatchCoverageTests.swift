import Foundation
import XCTest
@testable import LimitLifeboatCore

final class AuthWatchCoverageTests: XCTestCase {
    func testMissingCodexDirectoryFallsBackToHome() {
        let home = URL(fileURLWithPath: "/Users/test")
        let target = home.appendingPathComponent(".codex/auth.json")
        let existing: Set<URL> = [home]

        let result = AuthWatchCoverage.directories(
            for: [target],
            homeDirectory: home,
            directoryExists: { existing.contains($0) }
        )

        XCTAssertEqual(result, [home])
    }

    func testWatchMovesToNewlyCreatedTargetParent() {
        let home = URL(fileURLWithPath: "/Users/test")
        let parent = home.appendingPathComponent(".codex", isDirectory: true)
        let target = parent.appendingPathComponent("auth.json")
        let existing: Set<URL> = [home, parent]

        let result = AuthWatchCoverage.directories(
            for: [target],
            homeDirectory: home,
            directoryExists: { existing.contains($0) }
        )

        XCTAssertEqual(result, [home, parent])
    }

    func testNestedClaudeTargetUsesClosestExistingAncestor() {
        let home = URL(fileURLWithPath: "/Users/test")
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let target = support
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        let existing: Set<URL> = [home, support]

        let result = AuthWatchCoverage.directories(
            for: [target],
            homeDirectory: home,
            directoryExists: { existing.contains($0) }
        )

        XCTAssertEqual(result, [home, support])
    }
}
