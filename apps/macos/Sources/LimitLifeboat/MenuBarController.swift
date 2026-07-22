import AppKit
import Combine
import LimitLifeboatCore
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
        popover.contentSize = NSSize(width: DS.Popover.width, height: DS.Popover.height)
        popover.contentViewController = NSHostingController(
            rootView: MenuRootView(state: state, settings: state.settings, updater: state.updater)
        )

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
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// Opens the popover if it is not already shown — the landing spot for a
    /// tapped notification body.
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else {
            return
        }
        state.setAuthObservationInteractive(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        state.refreshIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        state.setAuthObservationInteractive(false)
    }

    private func updateStatusItem(summary: MenuBarSummary) {
        guard let button = statusItem.button else {
            return
        }

        var image = NSImage(
            systemSymbolName: "lifepreserver.fill",
            accessibilityDescription: summary.accessibilityText
        )
        // Keep the lifebuoy blue as a stable product mark. Each adjacent quota
        // value carries its own state color, so one exhausted scoped limit does
        // not recolor or obscure the other active limits.
        image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [.systemBlue])
        )
        image?.isTemplate = false
        button.image = image
        button.toolTip = "Limit Lifeboat\n\(summary.accessibilityText)"
        button.setAccessibilityLabel("Limit Lifeboat. \(summary.accessibilityText)")
        button.contentTintColor = nil
        button.attributedTitle = attributedTitle(summary: summary)
    }

    private func attributedTitle(summary: MenuBarSummary) -> NSAttributedString {
        let providerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.55
        ]
        let limitLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        guard !summary.activeProviderLimits.isEmpty else {
            let title = NSMutableAttributedString(string: " LIMIT ", attributes: providerAttributes)
            title.append(valueString(summary.compactValue, riskLevel: summary.riskLevel))
            return title
        }

        let title = NSMutableAttributedString()
        for (providerIndex, group) in summary.activeProviderLimits.enumerated() {
            if providerIndex > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: separatorAttributes))
            }
            title.append(providerMark(for: group.provider, textAttributes: providerAttributes))

            if group.limits.isEmpty {
                title.append(valueString("?", riskLevel: .unknown))
                continue
            }

            for (limitIndex, limit) in group.limits.enumerated() {
                if limitIndex > 0 {
                    title.append(NSAttributedString(string: "  ", attributes: separatorAttributes))
                }
                title.append(NSAttributedString(
                    string: "\(limit.label) ",
                    attributes: limitLabelAttributes
                ))
                title.append(valueString("\(limit.usedPercent)%", riskLevel: limit.riskLevel))
            }
        }
        return title
    }

    /// The provider's brand mark as an inline image, wrapped in the same spacing
    /// the provider text used. Falls back to the uppercased name when the asset
    /// is unavailable so the bar never renders blank.
    private func providerMark(
        for provider: Provider,
        textAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard let image = DS.providerMarkImage(provider) else {
            return NSAttributedString(
                string: " \(provider.displayName.uppercased()) ",
                attributes: textAttributes
            )
        }

        let markHeight: CGFloat = 13
        // Center the square mark on the cap band of the adjacent percentages.
        let referenceFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: referenceFont.capHeight / 2 - markHeight / 2,
            width: markHeight,
            height: markHeight
        )

        let markColor = (textAttributes[.foregroundColor] as? NSColor) ?? .labelColor
        let result = NSMutableAttributedString(string: " ")
        let markString = NSMutableAttributedString(attachment: attachment)
        // Tint the template mark to match the muted provider label it replaces;
        // labelColor variants resolve per menu-bar appearance (light/dark).
        markString.addAttribute(
            .foregroundColor,
            value: markColor,
            range: NSRange(location: 0, length: markString.length)
        )
        result.append(markString)
        result.append(NSAttributedString(string: " "))
        return result
    }

    private func valueString(_ value: String, riskLevel: RiskLevel) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: paletteColor(for: riskLevel) ?? NSColor.labelColor
            ]
        )
    }

    /// The status-item glyph tint for a risk level, or nil to stay monochrome
    /// (template) and follow the menu-bar appearance.
    private func paletteColor(for riskLevel: RiskLevel) -> NSColor? {
        switch riskLevel {
        case .depleted:
            return .systemRed
        case .warning:
            return .systemOrange
        case .healthy:
            return .systemBlue
        case .stale:
            return .systemYellow
        case .unknown:
            return nil
        }
    }

}
