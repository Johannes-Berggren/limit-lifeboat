import AppKit
import Combine
import LLMUsageMonitorCore
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 660)
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem(summary: MenuBarSummary) {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(
            systemSymbolName: imageName(for: summary.riskLevel),
            accessibilityDescription: summary.accessibilityText
        )
        button.image?.isTemplate = true
        button.toolTip = summary.accessibilityText
        button.contentTintColor = nil
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        button.title = " \(titlePrefix(for: summary.riskLevel))\(summary.title)"
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

    private func titlePrefix(for riskLevel: RiskLevel) -> String {
        switch riskLevel {
        case .depleted:
            return "!! "
        case .warning:
            return "! "
        case .stale:
            return "? "
        case .healthy, .unknown:
            return ""
        }
    }
}
