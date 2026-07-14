import AppKit
import LimitLifeboatCore
import SwiftUI

enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let tight: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let cardPadding: CGFloat = 12
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
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

struct StatusBanner: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            color.opacity(0.09),
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(color.opacity(0.16), lineWidth: 0.5)
        }
    }
}

extension View {
    func cardSurface(tint: Color? = nil, isEmphasized: Bool = false) -> some View {
        modifier(CardSurfaceModifier(tint: tint))
            .modifier(ActiveCardEmphasisModifier(isEmphasized: isEmphasized))
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

private struct ActiveCardEmphasisModifier: ViewModifier {
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        content
            .overlay {
                if isEmphasized {
                    shape
                        .strokeBorder(Color.green.opacity(0.72), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: isEmphasized ? Color.green.opacity(0.16) : .clear,
                radius: isEmphasized ? 5 : 0,
                y: isEmphasized ? 1 : 0
            )
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
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint?.opacity(0.06)), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(borderGradient, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        }
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(0.24),
                (tint ?? .white).opacity(0.09),
                .black.opacity(0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
