import AppKit
import Combine
import LLMUsageMonitorCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 560)
        popover.contentViewController = NSHostingController(rootView: MenuRootView(state: state))

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        updateStatusItem(summary: state.menuBarSummary)
        state.$menuBarSummary
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                self?.updateStatusItem(summary: summary)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.setAuthObservationInteractive(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            state.refreshIfStale()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        state.setAuthObservationInteractive(false)
    }

    private func updateStatusItem(summary: MenuBarSummary) {
        guard let button = statusItem.button else {
            return
        }

        var image = NSImage(
            systemSymbolName: imageName(for: summary.riskLevel),
            accessibilityDescription: summary.accessibilityText
        )
        // Depleted and warning both get color so the two most important states
        // read at a glance; everything else follows the menu-bar tint. A
        // monochrome warning glyph (the old behavior) was effectively invisible.
        if let paletteColor = paletteColor(for: summary.riskLevel) {
            image = image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [paletteColor])
            )
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.toolTip = summary.accessibilityText
        button.contentTintColor = nil
        button.attributedTitle = attributedTitle(claude: summary.claudeValue, codex: summary.codexValue)
    }

    private func attributedTitle(claude: String, codex: String) -> NSAttributedString {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: " Claude ", attributes: labelAttributes))
        title.append(NSAttributedString(string: claude, attributes: valueAttributes))
        title.append(NSAttributedString(string: " · Codex ", attributes: labelAttributes))
        title.append(NSAttributedString(string: codex, attributes: valueAttributes))
        return title
    }

    /// The status-item glyph tint for a risk level, or nil to stay monochrome
    /// (template) and follow the menu-bar appearance.
    private func paletteColor(for riskLevel: RiskLevel) -> NSColor? {
        switch riskLevel {
        case .depleted:
            return .systemRed
        case .warning:
            return .systemOrange
        case .healthy, .stale, .unknown:
            return nil
        }
    }

    private func imageName(for riskLevel: RiskLevel) -> String {
        switch riskLevel {
        case .depleted:
            return "exclamationmark.octagon.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .healthy:
            return "gauge.with.dots.needle.67percent"
        case .stale:
            return "clock.badge.exclamationmark"
        case .unknown:
            return "gauge.with.dots.needle.33percent"
        }
    }

}
