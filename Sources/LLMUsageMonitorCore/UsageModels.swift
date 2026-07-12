import Foundation

public enum UsageWindowKind: String, Codable, Sendable {
    case session        // Claude "current session" (~5h) / Codex primary (300 min)
    case weekly         // Claude "weekly all models" / Codex secondary (10080 min)
    case weeklyScoped   // Claude "current week (<org/model>)"
    case other

    /// Display order: the short session window first, then the broad weekly
    /// windows, with anything unrecognized last.
    public var sortRank: Int {
        switch self {
        case .session:
            return 0
        case .weekly:
            return 1
        case .weeklyScoped:
            return 2
        case .other:
            return 3
        }
    }
}

/// One rate-limit window a subscription reports (e.g. the ~5h session window
/// and the weekly window are two separate windows on the same account). A
/// snapshot carries all of them; the snapshot's scalar fields mirror the
/// most-constrained one for the menu bar and legacy call sites.
public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    /// Stable per-account key so per-window alert dedupe and SwiftUI diffing
    /// survive across refreshes, e.g. "session", "weekly-all", "weekly-fable",
    /// "codex-300".
    public var id: String
    public var kind: UsageWindowKind
    public var label: String
    public var usedPercent: Double
    public var resetDate: Date?
    public var resetDescription: String?
    public var windowMinutes: Int?
    public var riskLevel: RiskLevel

    public init(
        id: String,
        kind: UsageWindowKind,
        label: String,
        usedPercent: Double,
        resetDate: Date? = nil,
        resetDescription: String? = nil,
        windowMinutes: Int? = nil,
        riskLevel: RiskLevel = .unknown
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetDate = resetDate
        self.resetDescription = resetDescription
        self.windowMinutes = windowMinutes
        self.riskLevel = riskLevel
    }

    public var remainingPercent: Double {
        max(0, 100 - min(100, max(0, usedPercent)))
    }

    public var usedFraction: Double {
        min(1, max(0, usedPercent / 100))
    }

    /// True when this window's limit has rolled over since the reading, meaning
    /// the account likely has this window's quota back.
    public func resetHasElapsed(asOf now: Date = Date()) -> Bool {
        guard let resetDate else {
            return false
        }
        return resetDate < now
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var provider: Provider
    /// Every rate-limit window the provider reported. The scalar fields below
    /// mirror the most-constrained window for the menu bar and legacy readers.
    public var windows: [UsageWindow]
    public var includedRemaining: Double?
    public var includedLimit: Double?
    public var resetDate: Date?
    public var resetDescription: String?
    public var creditStatus: String?
    public var riskLevel: RiskLevel
    public var source: String
    public var lastRefreshed: Date
    public var parseConfidence: ParseConfidence
    public var message: String
    /// The exact overage state when the source can report it (the usage API);
    /// nil for TUI/dashboard snapshots and legacy files, which fall back to the
    /// keyword scan in `billingUsageMode`.
    public var payAsYouGoState: PayAsYouGoState?

    public init(
        accountID: UUID,
        provider: Provider,
        windows: [UsageWindow] = [],
        includedRemaining: Double? = nil,
        includedLimit: Double? = nil,
        resetDate: Date? = nil,
        resetDescription: String? = nil,
        creditStatus: String? = nil,
        riskLevel: RiskLevel = .unknown,
        source: String,
        lastRefreshed: Date = Date(),
        parseConfidence: ParseConfidence = .none,
        message: String = "",
        payAsYouGoState: PayAsYouGoState? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.windows = windows
        self.includedRemaining = includedRemaining
        self.includedLimit = includedLimit
        self.resetDate = resetDate
        self.resetDescription = resetDescription
        self.creditStatus = creditStatus
        self.riskLevel = riskLevel
        self.source = source
        self.lastRefreshed = lastRefreshed
        self.parseConfidence = parseConfidence
        self.message = message
        self.payAsYouGoState = payAsYouGoState
    }

    public var remainingFraction: Double? {
        guard let includedRemaining, let includedLimit, includedLimit > 0 else {
            return nil
        }
        return max(0, min(1, includedRemaining / includedLimit))
    }

    public var usedFraction: Double? {
        guard let remainingFraction else {
            return nil
        }
        return max(0, min(1, 1 - remainingFraction))
    }

    /// The windows to surface. Uses the parsed windows when present, otherwise
    /// synthesizes a single window from the scalar fields so snapshots that
    /// predate `windows` (legacy files, the web dashboard fallback) still show
    /// and alert on a quota.
    public var displayWindows: [UsageWindow] {
        if !windows.isEmpty {
            return windows
        }
        guard let usedFraction else {
            return []
        }
        return [
            UsageWindow(
                id: "primary",
                kind: .other,
                label: "Quota",
                usedPercent: usedFraction * 100,
                resetDate: resetDate,
                resetDescription: resetDescription,
                riskLevel: riskLevel
            )
        ]
    }

    /// `displayWindows` cleaned up for presentation: snapshots persisted from
    /// mangled captures can carry duplicate window ids, so duplicates collapse
    /// to the last occurrence (the freshest reading), then the result is
    /// stable-sorted session → weekly → weeklyScoped → other, tie-breaking
    /// on label.
    public var orderedDisplayWindows: [UsageWindow] {
        var deduped: [UsageWindow] = []
        for window in displayWindows {
            if let existing = deduped.firstIndex(where: { $0.id == window.id }) {
                deduped.remove(at: existing)
            }
            deduped.append(window)
        }
        return deduped.sorted { left, right in
            if left.kind.sortRank != right.kind.sortRank {
                return left.kind.sortRank < right.kind.sortRank
            }
            return left.label < right.label
        }
    }

    /// The first window of the given kind, in display order.
    public func window(ofKind kind: UsageWindowKind) -> UsageWindow? {
        orderedDisplayWindows.first { $0.kind == kind }
    }

    /// The weekly window to lead with: the all-models weekly when present,
    /// otherwise the first model-scoped weekly. The single home for the
    /// weekly-with-scoped-fallback policy.
    public var primaryWeeklyWindow: UsageWindow? {
        window(ofKind: .weekly) ?? window(ofKind: .weeklyScoped)
    }

    /// The window closest to (or past) its limit — the one the menu bar and
    /// alerts should lead with.
    public var mostConstrainedWindow: UsageWindow? {
        orderedDisplayWindows.max { $0.usedPercent < $1.usedPercent }
    }

    /// The most-constrained window the popover actually surfaces: session,
    /// all-models weekly, or a model-scoped weekly only when it is at risk.
    /// Healthy scoped weeklies are hidden in the card, so they must not
    /// silently drive the menu-bar/summary number.
    public var surfacedConstrainedWindow: UsageWindow? {
        orderedDisplayWindows
            .filter { $0.kind != .weeklyScoped
                || $0.riskLevel == .warning || $0.riskLevel == .depleted }
            .max { $0.usedPercent < $1.usedPercent }
    }

    public func isStale(asOf now: Date = Date(), maxAge: TimeInterval = UsageThresholds.standard.staleAfter) -> Bool {
        now.timeIntervalSince(lastRefreshed) > maxAge
    }

    /// True when the provider's limit window has rolled over since this
    /// snapshot was taken, meaning the account likely has its full quota back.
    public func resetHasElapsed(asOf now: Date = Date()) -> Bool {
        guard let resetDate else {
            return false
        }
        return resetDate < now
    }

    /// True only when *every* reported window has rolled over. The scalar
    /// `resetHasElapsed()` reflects just the most-constrained window, so a short
    /// window resetting while a weekly is still live would otherwise read as
    /// "full quota back" — the stricter condition SwitchAdvisor already uses.
    public func allWindowsResetElapsed(asOf now: Date = Date()) -> Bool {
        let windows = orderedDisplayWindows
        guard !windows.isEmpty else { return resetHasElapsed(asOf: now) }
        return windows.allSatisfy { $0.resetHasElapsed(asOf: now) }
    }

    public var billingUsageMode: BillingUsageMode {
        if riskLevel == .stale {
            return .needsLogin
        }

        // A first-class overage signal (from the usage API's `extra_usage`
        // block) is exact, so it wins over the string heuristics below. Only
        // `.enabledActive` — overage on AND included usage exhausted — raises
        // the PAYG warning. `.enabledIdle` means overage is merely enabled as a
        // backstop while included usage is fine, which is not noteworthy: it
        // falls through to the normal used-fraction bands so a healthy account
        // is not mislabelled as paying.
        switch payAsYouGoState {
        case .enabledActive:
            return .overLimitPayAsYouGo
        case .enabledIdle, .disabled, .none:
            break
        }

        if payAsYouGoLooksActive {
            return .overLimitPayAsYouGo
        }

        if let usedFraction {
            if usedFraction >= UsageThresholds.standard.warningUsedFraction {
                return .includedSubscriptionNearLimit
            }
            return .includedSubscription
        }

        if hasPayAsYouGoSignal {
            return .payAsYouGoVisible
        }

        return .unknown
    }

    public var hasPayAsYouGoSignal: Bool {
        let text = "\(creditStatus ?? "") \(message)".lowercased()
        return text.contains("pay-as-you-go")
            || text.contains("pay as you go")
            || text.contains("usage credit")
            || text.contains("credits")
            || text.contains("auto top-up")
            || text.contains("auto-reload")
            || text.contains("auto reload")
    }

    public var payAsYouGoLooksActive: Bool {
        guard hasPayAsYouGoSignal else {
            return false
        }

        if riskLevel == .depleted {
            return true
        }

        if let includedRemaining, includedRemaining <= 0 {
            return true
        }

        let text = "\(creditStatus ?? "") \(message)".lowercased()
        return text.contains("rate limit reached")
            || text.contains("included usage appears depleted")
            || text.contains("included usage exhausted")
            || text.contains("limit reached")
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case provider
        case windows
        case includedRemaining
        case includedLimit
        case resetDate
        case resetDescription
        case creditStatus
        case riskLevel
        case source
        case lastRefreshed
        case parseConfidence
        case message
        case payAsYouGoState
    }

    // Manual conformance so snapshots persisted before `windows` existed still
    // decode: the key is absent in legacy usage-snapshots.json, so it defaults
    // to [] and repopulates on the next refresh rather than throwing.
    // `payAsYouGoState` is likewise absent in files written before it existed
    // and decodes to nil, repopulating on the next API refresh.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountID = try container.decode(UUID.self, forKey: .accountID)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.windows = try container.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        self.includedRemaining = try container.decodeIfPresent(Double.self, forKey: .includedRemaining)
        self.includedLimit = try container.decodeIfPresent(Double.self, forKey: .includedLimit)
        self.resetDate = try container.decodeIfPresent(Date.self, forKey: .resetDate)
        self.resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
        self.creditStatus = try container.decodeIfPresent(String.self, forKey: .creditStatus)
        self.riskLevel = try container.decode(RiskLevel.self, forKey: .riskLevel)
        self.source = try container.decode(String.self, forKey: .source)
        self.lastRefreshed = try container.decode(Date.self, forKey: .lastRefreshed)
        self.parseConfidence = try container.decode(ParseConfidence.self, forKey: .parseConfidence)
        self.message = try container.decode(String.self, forKey: .message)
        self.payAsYouGoState = try container.decodeIfPresent(PayAsYouGoState.self, forKey: .payAsYouGoState)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(provider, forKey: .provider)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(includedRemaining, forKey: .includedRemaining)
        try container.encodeIfPresent(includedLimit, forKey: .includedLimit)
        try container.encodeIfPresent(resetDate, forKey: .resetDate)
        try container.encodeIfPresent(resetDescription, forKey: .resetDescription)
        try container.encodeIfPresent(creditStatus, forKey: .creditStatus)
        try container.encode(riskLevel, forKey: .riskLevel)
        try container.encode(source, forKey: .source)
        try container.encode(lastRefreshed, forKey: .lastRefreshed)
        try container.encode(parseConfidence, forKey: .parseConfidence)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(payAsYouGoState, forKey: .payAsYouGoState)
    }
}
