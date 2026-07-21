import Foundation

/// Provider-neutral metadata used to turn a parsed quota reading into the
/// stable `UsageWindow` shape consumed by history, alerts, and SwiftUI.
public struct UsageWindowDescriptor: Equatable, Sendable {
    public var id: String
    public var kind: UsageWindowKind
    public var label: String
    public var windowMinutes: Int?

    public init(id: String, kind: UsageWindowKind, label: String, windowMinutes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.windowMinutes = windowMinutes
    }
}

/// The single mapping from Claude's API/TUI names to stable window identity.
/// Labels may differ by source, but ids and kinds must not: alert dedupe and
/// history continuity depend on them surviving source fallback.
public enum ClaudeUsageWindowCatalog {
    public static func apiDescriptor(kindRaw: String, scopeName: String?) -> UsageWindowDescriptor {
        descriptor(for: apiIdentity(kindRaw: kindRaw, scopeName: scopeName), includesDuration: true)
    }

    public static func tuiDescriptor(name: String) -> UsageWindowDescriptor {
        let lower = name.lowercased()
        if lower == "current session" {
            return descriptor(for: .session, includesDuration: false)
        }
        if lower.contains("all models") {
            return descriptor(for: .weeklyAll, includesDuration: false)
        }
        if let open = name.firstIndex(of: "("),
           let close = name[open...].firstIndex(of: ")"),
           open < close {
            let value = String(name[name.index(after: open)..<close])
            return descriptor(for: .weeklyScoped(value), includesDuration: false)
        }
        return descriptor(for: .other(raw: name, label: name), includesDuration: false)
    }

    public static func apiMessageLabel(kindRaw: String, scopeName: String?) -> String {
        switch apiIdentity(kindRaw: kindRaw, scopeName: scopeName) {
        case .session:
            return "session"
        case .weeklyAll:
            return "weekly all models"
        case .weeklyScoped(let name):
            return "weekly \(name)"
        case .other(_, let label):
            return label.replacingOccurrences(of: "_", with: " ")
        }
    }

    private enum Identity {
        case session
        case weeklyAll
        case weeklyScoped(String)
        case other(raw: String, label: String)
    }

    private static func apiIdentity(kindRaw: String, scopeName: String?) -> Identity {
        switch kindRaw {
        case "session", "five_hour":
            return .session
        case "weekly_all", "seven_day":
            return .weeklyAll
        case "weekly_scoped":
            return .weeklyScoped(scopeName ?? "scoped")
        case "seven_day_opus":
            return .weeklyScoped("Opus")
        case "seven_day_sonnet":
            return .weeklyScoped("Sonnet")
        default:
            return .other(raw: kindRaw, label: kindRaw)
        }
    }

    private static func descriptor(for identity: Identity, includesDuration: Bool) -> UsageWindowDescriptor {
        switch identity {
        case .session:
            return UsageWindowDescriptor(
                id: "session",
                kind: .session,
                label: includesDuration ? "Session (5h)" : "Session",
                windowMinutes: includesDuration ? 300 : nil
            )
        case .weeklyAll:
            return UsageWindowDescriptor(
                id: "weekly-all",
                kind: .weekly,
                label: "Weekly (all models)",
                windowMinutes: includesDuration ? 10_080 : nil
            )
        case .weeklyScoped(let name):
            let isGeneric = name == "scoped"
            return UsageWindowDescriptor(
                id: isGeneric ? "weekly-scoped" : "weekly-\(UsageWindowID.slug(name))",
                kind: .weeklyScoped,
                label: isGeneric ? "Weekly (scoped)" : "Weekly (\(name))",
                windowMinutes: includesDuration ? 10_080 : nil
            )
        case .other(let raw, let label):
            return UsageWindowDescriptor(
                id: UsageWindowID.slug(raw),
                kind: .other,
                label: includesDuration
                    ? label.replacingOccurrences(of: "_", with: " ").capitalized
                    : label
            )
        }
    }
}

/// Stable identifiers and labels shared by Codex's app-server and local-log
/// fallback sources. Duration determines semantics because recent plans may
/// expose only a weekly primary window rather than a primary/secondary pair.
public enum CodexUsageWindowCatalog {
    public static func descriptor(name: String, windowMinutes: Int?) -> UsageWindowDescriptor {
        let kind: UsageWindowKind
        if let windowMinutes {
            kind = windowMinutes <= 60 * 24 ? .session : .weekly
        } else {
            kind = name == "secondary" ? .weekly : .session
        }
        let base = kind == .weekly ? "Weekly" : "Session"
        let label = windowMinutes.map { "\(base) (\(shortDuration(minutes: $0)))" } ?? base
        let id = windowMinutes.map { "codex-\($0)" } ?? "codex-\(name)"
        return UsageWindowDescriptor(id: id, kind: kind, label: label, windowMinutes: windowMinutes)
    }

    private static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// Centralizes the invariants shared by every usage source. Readers remain
/// responsible only for parsing and source-specific labels/messages.
public enum UsageSnapshotFactory {
    public static func normalizedUsedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    public static func window(
        descriptor: UsageWindowDescriptor,
        usedPercent: Double,
        resetDate: Date? = nil,
        resetDescription: String? = nil
    ) -> UsageWindow {
        let normalized = normalizedUsedPercent(usedPercent)
        return UsageWindow(
            id: descriptor.id,
            kind: descriptor.kind,
            label: descriptor.label,
            usedPercent: normalized,
            resetDate: resetDate,
            resetDescription: resetDescription,
            windowMinutes: descriptor.windowMinutes,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: normalized)
        )
    }

    public static func snapshot(
        accountID: UUID,
        provider: Provider,
        windows: [UsageWindow],
        creditStatus: String? = nil,
        codexRateLimitResetAvailability: CodexRateLimitResetAvailability? = nil,
        codexRateLimitReachedType: String? = nil,
        source: String,
        lastRefreshed: Date,
        parseConfidence: ParseConfidence = .high,
        message: String,
        payAsYouGoState: PayAsYouGoState? = nil,
        payAsYouGoSpend: PayAsYouGoSpend? = nil
    ) -> UsageSnapshot {
        guard let selected = windows.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return UsageSnapshot(
                accountID: accountID,
                provider: provider,
                windows: [],
                codexRateLimitResetAvailability: codexRateLimitResetAvailability,
                codexRateLimitReachedType: codexRateLimitReachedType,
                riskLevel: .unknown,
                source: source,
                lastRefreshed: lastRefreshed,
                parseConfidence: .none,
                message: message,
                payAsYouGoState: payAsYouGoState,
                payAsYouGoSpend: payAsYouGoSpend
            )
        }

        let usedPercent = normalizedUsedPercent(selected.usedPercent)
        return UsageSnapshot(
            accountID: accountID,
            provider: provider,
            windows: windows,
            includedRemaining: 100 - usedPercent,
            includedLimit: 100,
            resetDate: selected.resetDate,
            resetDescription: selected.resetDescription,
            creditStatus: creditStatus,
            codexRateLimitResetAvailability: codexRateLimitResetAvailability,
            codexRateLimitReachedType: codexRateLimitReachedType,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent),
            source: source,
            lastRefreshed: lastRefreshed,
            parseConfidence: parseConfidence,
            message: message,
            payAsYouGoState: payAsYouGoState,
            payAsYouGoSpend: payAsYouGoSpend
        )
    }
}
