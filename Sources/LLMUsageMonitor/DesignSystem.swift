import AppKit
import LLMUsageMonitorCore
import SwiftUI

enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let tight: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let cardPadding: CGFloat = 8
    }

    enum Radius {
        static let small: CGFloat = 6
        static let card: CGFloat = 14
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

    static func presentationColor(_ tone: PresentationTone) -> Color {
        switch tone {
        case .secondary:
            return .secondary
        case .warning:
            return .orange
        case .stale:
            return staleAmber
        case .success:
            return .green
        case .danger:
            return .red
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
    func cardSurface(tint: Color? = nil) -> some View {
        modifier(CardSurfaceModifier(tint: tint))
    }

    @ViewBuilder
    func compactGlassButton(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(.small)
                .tint(tint)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(tint)
        }
    }
}

private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(borderGradient, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint?.opacity(0.10)), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(borderGradient, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
        }
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(0.34),
                (tint ?? .white).opacity(0.13),
                .black.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
