import AppKit
@testable import LimitLifeboat
import LimitLifeboatCore
import XCTest

final class MenuBarTitleFormatterTests: XCTestCase {
    func testFormatsClaudeOnlyTitle() {
        let title = MenuBarTitleFormatter.attributedTitle(
            summary: makeSummary(
                groups: [
                    MenuBarProviderLimits(
                        provider: .claude,
                        limits: [
                            MenuBarLimitValue(label: "S", usedPercent: 25, riskLevel: .healthy),
                            MenuBarLimitValue(label: "W", usedPercent: 85, riskLevel: .warning)
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(title.string, "CL S 25% W 85%")
    }

    func testFormatsCodexOnlyTitle() {
        let title = MenuBarTitleFormatter.attributedTitle(
            summary: makeSummary(
                groups: [
                    MenuBarProviderLimits(
                        provider: .codex,
                        limits: [
                            MenuBarLimitValue(label: "S", usedPercent: 41, riskLevel: .healthy)
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(title.string, "CX S 41%")
    }

    func testFormatsDualProviderTitleWithCompactSpacing() {
        let title = MenuBarTitleFormatter.attributedTitle(
            summary: makeSummary(
                groups: [
                    MenuBarProviderLimits(
                        provider: .claude,
                        limits: [
                            MenuBarLimitValue(label: "S", usedPercent: 25, riskLevel: .healthy),
                            MenuBarLimitValue(label: "W", usedPercent: 85, riskLevel: .warning)
                        ]
                    ),
                    MenuBarProviderLimits(
                        provider: .codex,
                        limits: [
                            MenuBarLimitValue(label: "S", usedPercent: 91, riskLevel: .warning),
                            MenuBarLimitValue(label: "W", usedPercent: 20, riskLevel: .healthy)
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(title.string, "CL S 25% W 85% · CX S 91% W 20%")
    }

    func testFormatsUnavailableProviderUsage() {
        let title = MenuBarTitleFormatter.attributedTitle(
            summary: makeSummary(
                groups: [
                    MenuBarProviderLimits(provider: .claude, limits: [])
                ]
            )
        )

        XCTAssertEqual(title.string, "CL ?")
    }

    func testFormatsNoActiveProviderFallback() {
        let title = MenuBarTitleFormatter.attributedTitle(
            summary: makeSummary(groups: [], compactValue: "85%", riskLevel: .warning)
        )

        XCTAssertEqual(title.string, "LIMIT 85%")
    }

    func testProviderLabelsAreBoldUnkernedTextWithoutAttachments() throws {
        let title = MenuBarTitleFormatter.attributedTitle(
            summary: makeSummary(
                groups: [
                    MenuBarProviderLimits(
                        provider: .claude,
                        limits: [
                            MenuBarLimitValue(label: "S", usedPercent: 25, riskLevel: .healthy)
                        ]
                    ),
                    MenuBarProviderLimits(
                        provider: .codex,
                        limits: [
                            MenuBarLimitValue(label: "W", usedPercent: 85, riskLevel: .warning)
                        ]
                    )
                ]
            )
        )

        for abbreviation in ["CL", "CX"] {
            let range = (title.string as NSString).range(of: abbreviation)
            XCTAssertNotEqual(range.location, NSNotFound)
            let font = try XCTUnwrap(title.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 9)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertNil(title.attribute(.kern, at: range.location, effectiveRange: nil))
        }

        var containsAttachment = false
        title.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: title.length)
        ) { value, _, _ in
            containsAttachment = containsAttachment || value != nil
        }
        XCTAssertFalse(containsAttachment)
    }

    private func makeSummary(
        groups: [MenuBarProviderLimits],
        compactValue: String = "–",
        riskLevel: RiskLevel = .unknown
    ) -> MenuBarSummary {
        MenuBarSummary(
            claudeValue: "–",
            codexValue: "–",
            accessibilityText: "Test usage",
            riskLevel: riskLevel,
            compactValue: compactValue,
            activeProviderLimits: groups
        )
    }
}
