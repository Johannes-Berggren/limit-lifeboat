import AppKit
import LimitLifeboatCore
import SwiftUI

enum DS {
    static let accent = Color(nsColor: .systemBlue)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)

    enum Popover {
        static let width: CGFloat = 680
        static let height: CGFloat = 720
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let tight: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let cardPadding: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let card: CGFloat = 18
        static let panel: CGFloat = 22
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.spring(response: 0.32, dampingFraction: 0.88)
        static let progress = Animation.spring(response: 0.42, dampingFraction: 0.86)
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
            return accent
        case .warning:
            return warning
        case .depleted:
            return danger
        case .stale:
            return staleAmber
        case .unknown:
            return .gray
        }
    }

    static func billingColor(_ mode: BillingUsageMode) -> Color {
        switch mode {
        case .includedSubscription:
            return success
        case .includedSubscriptionNearLimit:
            return warning
        case .overLimitPayAsYouGo:
            return danger
        case .payAsYouGoVisible:
            return warning
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
            return warning
        case .stale:
            return staleAmber
        case .success:
            return success
        case .danger:
            return danger
        }
    }

    static func providerAccent(_ provider: Provider) -> Color {
        accent
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
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(color.opacity(0.14), lineWidth: 0.5)
            }
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .padding(.vertical, 10)
        .background(
            reduceTransparency ? Color(nsColor: .controlBackgroundColor) : color.opacity(0.07),
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(color.opacity(0.16), lineWidth: 0.5)
        }
    }
}

extension View {
    func cardSurface(
        tint: Color? = nil,
        isEmphasized: Bool = false,
        isHovered: Bool = false
    ) -> some View {
        modifier(CardSurfaceModifier(tint: tint))
            .modifier(ActiveCardEmphasisModifier(isEmphasized: isEmphasized, isHovered: isHovered))
    }

    func calmSurface(tint: Color? = nil) -> some View {
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

private struct ActiveCardEmphasisModifier: ViewModifier {
    let isEmphasized: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        content
            .overlay {
                shape
                    .strokeBorder(
                        isEmphasized
                            ? DS.accent.opacity(0.62)
                            : Color.primary.opacity(isHovered ? 0.13 : 0.075),
                        lineWidth: isEmphasized ? 1.25 : 0.5
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: isEmphasized
                    ? DS.accent.opacity(0.13)
                    : Color.black.opacity(isHovered ? 0.08 : 0.035),
                radius: isEmphasized ? 9 : (isHovered ? 7 : 3),
                y: isEmphasized || isHovered ? 2 : 1
            )
            .scaleEffect(isHovered ? 1.002 : 1)
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
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.045)).allowsHitTesting(false)
                    }
                }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.035)).allowsHitTesting(false)
                    }
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.035)).allowsHitTesting(false)
                    }
                }
        }
    }
}

struct CalmWindowBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Color.primary.opacity(0.012))
            .ignoresSafeArea()
    }
}
