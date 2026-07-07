import AppKit
import LLMUsageMonitorCore
import SwiftUI

enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let cardPadding: CGFloat = 10
    }

    enum Radius {
        static let small: CGFloat = 6
        static let card: CGFloat = 10
    }

    /// systemYellow is near-invisible on light backgrounds, so light mode gets a darker amber.
    static let staleAmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.70, green: 0.52, blue: 0.03, alpha: 1)
    })

    static func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .depleted:
            return .red
        case .stale:
            return staleAmber
        case .unknown:
            return .gray
        }
    }

    static func billingColor(_ mode: BillingUsageMode) -> Color {
        switch mode {
        case .includedSubscription:
            return .green
        case .includedSubscriptionNearLimit:
            return .orange
        case .overLimitPayAsYouGo:
            return .red
        case .payAsYouGoVisible:
            return .orange
        case .needsLogin:
            return staleAmber
        case .unknown:
            return .gray
        }
    }

    static func providerAccent(_ provider: Provider) -> Color {
        provider == .claude ? .purple : .blue
    }

    static func providerSymbol(_ provider: Provider) -> String {
        provider == .claude ? "sparkles" : "terminal"
    }
}

struct ProviderLabel: View {
    let text: String
    let provider: Provider

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: DS.providerSymbol(provider))
                .foregroundStyle(DS.providerAccent(provider))
        }
    }
}

struct Badge: View {
    let text: String
    var systemImage: String?
    let color: Color

    var body: some View {
        content
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if let systemImage {
            Label(text, systemImage: systemImage)
        } else {
            Text(text)
        }
    }
}

extension View {
    func cardSurface() -> some View {
        background(
            Color(nsColor: .quaternarySystemFill),
            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        )
    }
}
