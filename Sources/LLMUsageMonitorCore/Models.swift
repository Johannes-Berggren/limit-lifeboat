import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "ChatGPT/Codex"
        }
    }

    public var commandName: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        }
    }

    public var dashboardURL: URL {
        dashboardURLs[0]
    }

    public var dashboardURLs: [URL] {
        switch self {
        case .claude:
            return [
                URL(string: "https://claude.ai/settings/usage")!
            ]
        case .codex:
            return [
                URL(string: "https://chatgpt.com/codex/settings/usage")!,
                URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
            ]
        }
    }

    public var loginCommand: String {
        switch self {
        case .claude:
            return "claude auth login"
        case .codex:
            return "\(commandName) login"
        }
    }

    /// The command to run in the terminal to start a fresh CLI login.
    /// Codex multiplexes a single `~/.codex/auth.json`, so when a session
    /// already exists it must be logged out first or `codex login` runs
    /// against the existing session instead of starting a new one.
    ///
    /// The two commands are joined with `;`, not `&&`: `codex logout` can
    /// exit non-zero (e.g. no session it recognizes, or a changed CLI exit
    /// code), and with `&&` that would short-circuit and never run
    /// `codex login` — leaving the terminal looking like it did nothing.
    public func terminalLoginCommand(hasExistingSession: Bool) -> String {
        switch self {
        case .claude:
            return loginCommand
        case .codex:
            return hasExistingSession ? "\(commandName) logout; \(commandName) login" : loginCommand
        }
    }
}

public enum RiskLevel: String, Codable, Comparable, Sendable {
    case depleted
    case warning
    case healthy
    case stale
    case unknown

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ level: RiskLevel) -> Int {
        switch level {
        case .depleted:
            return 0
        case .warning:
            return 1
        case .healthy:
            return 2
        case .stale:
            return 3
        case .unknown:
            return 4
        }
    }
}

public enum ParseConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case none
}

/// The single home for the "how close to the limit is worrying" and "how old
/// is too old" numbers, so every reader and view agrees.
public struct UsageThresholds: Equatable, Sendable {
    public var warningUsedFraction: Double
    public var staleAfter: TimeInterval

    public static let standard = UsageThresholds()

    public init(warningUsedFraction: Double = 0.8, staleAfter: TimeInterval = 30 * 60) {
        self.warningUsedFraction = warningUsedFraction
        self.staleAfter = staleAfter
    }

    public func riskLevel(usedFraction: Double) -> RiskLevel {
        if usedFraction >= 1 {
            return .depleted
        }
        if usedFraction >= warningUsedFraction {
            return .warning
        }
        return .healthy
    }

    public func riskLevel(usedPercent: Double) -> RiskLevel {
        riskLevel(usedFraction: usedPercent / 100)
    }
}

public enum BillingUsageMode: String, Sendable {
    case includedSubscription
    case includedSubscriptionNearLimit
    case overLimitPayAsYouGo
    case payAsYouGoVisible
    case needsLogin
    case unknown
}

/// A first-class pay-as-you-go / usage-credit signal, set by sources that can
/// report it exactly (the Anthropic usage API's `extra_usage` block). nil for
/// the local TUI and web-dashboard sources, which can only be scanned for
/// keywords — those leave `billingUsageMode` on its string heuristics.
public enum PayAsYouGoState: String, Codable, Sendable {
    /// Overage / usage-credit billing is turned off for the account.
    case disabled
    /// Overage is enabled but included usage is not yet exhausted (a backstop).
    case enabledIdle
    /// Overage is enabled and included usage is exhausted — actively billing.
    case enabledActive
}

public enum WebDataStoreKind: String, Codable, Sendable {
    case appDefault
    case isolated
}

public enum AccountIdentitySource: String, Codable, Sendable {
    case dashboard
    case codexIDToken
    case claudeCodeUsage
    case manual
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public var email: String?
    public var displayName: String?
    public var organization: String?
    public var organizationID: String?
    public var accountID: String?
    public var source: AccountIdentitySource
    public var updatedAt: Date

    public init(
        email: String? = nil,
        displayName: String? = nil,
        organization: String? = nil,
        organizationID: String? = nil,
        accountID: String? = nil,
        source: AccountIdentitySource,
        updatedAt: Date = Date()
    ) {
        self.email = email
        self.displayName = displayName
        self.organization = organization
        self.organizationID = organizationID
        self.accountID = accountID
        self.source = source
        self.updatedAt = updatedAt
    }

    public var primaryLabel: String? {
        email ?? displayName ?? accountID
    }

    /// Two identities refer to the same account when their stable identifiers
    /// agree. Organization names are deliberately not compared: two different
    /// accounts can share an organization.
    public func matches(_ other: AccountIdentity) -> Bool {
        if let leftAccountID = accountID,
           let rightAccountID = other.accountID {
            guard leftAccountID == rightAccountID else {
                return false
            }
            if let leftOrganizationID = organizationID,
               let rightOrganizationID = other.organizationID {
                return leftOrganizationID == rightOrganizationID
            }
            if let leftOrganization = organization?.lowercased(),
               let rightOrganization = other.organization?.lowercased(),
               leftOrganization != rightOrganization {
                return false
            }
            return true
        }

        if let leftOrganizationID = organizationID,
           let rightOrganizationID = other.organizationID,
           leftOrganizationID != rightOrganizationID {
            return false
        }

        if let leftEmail = email?.lowercased(),
           let rightEmail = other.email?.lowercased(),
           leftEmail == rightEmail {
            return true
        }

        return false
    }

    public var isLikelyValid: Bool {
        if email != nil || displayName != nil || accountID != nil {
            return true
        }

        guard let organization else {
            return false
        }

        let lower = organization.lowercased()
        let invalidFragments = [
            "try claude",
            "individual team",
            "team and enterprise",
            "free ",
            "pricing",
            "log in",
            "sign up"
        ]
        return organization.count <= 50 && !invalidFragments.contains(where: lower.contains)
    }
}

public struct AccountProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    /// Human plan tier ("Max 20x", "Pro") from the provider's profile
    /// endpoint; nil until fetched, and in profiles.json written before the
    /// field existed.
    public var planLabel: String?
    public var webDataStoreKind: WebDataStoreKind
    public var webDataStoreID: UUID
    public var identity: AccountIdentity?
    public var isActiveCLI: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        label: String,
        planLabel: String? = nil,
        webDataStoreKind: WebDataStoreKind = .isolated,
        webDataStoreID: UUID = UUID(),
        identity: AccountIdentity? = nil,
        isActiveCLI: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.planLabel = planLabel
        self.webDataStoreKind = webDataStoreKind
        self.webDataStoreID = webDataStoreID
        self.identity = identity
        self.isActiveCLI = isActiveCLI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case planLabel
        case webDataStoreKind
        case webDataStoreID
        case identity
        case isActiveCLI
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.label = try container.decode(String.self, forKey: .label)
        // Absent in profiles.json written before plan labels existed; one
        // interim build persisted an empty-string default, which must decode
        // as "unknown" or the plan-tier fetch never runs for those profiles.
        let decodedPlanLabel = try container.decodeIfPresent(String.self, forKey: .planLabel)
        self.planLabel = (decodedPlanLabel?.isEmpty == true) ? nil : decodedPlanLabel
        self.webDataStoreKind = try container.decodeIfPresent(WebDataStoreKind.self, forKey: .webDataStoreKind) ?? .isolated
        self.webDataStoreID = try container.decode(UUID.self, forKey: .webDataStoreID)
        self.identity = try container.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        self.isActiveCLI = try container.decode(Bool.self, forKey: .isActiveCLI)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(planLabel, forKey: .planLabel)
        try container.encode(webDataStoreKind, forKey: .webDataStoreKind)
        try container.encode(webDataStoreID, forKey: .webDataStoreID)
        try container.encodeIfPresent(identity, forKey: .identity)
        try container.encode(isActiveCLI, forKey: .isActiveCLI)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

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

public struct CredentialSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var capturedAt: Date
    public var items: [CredentialSnapshotItem]

    public init(provider: Provider, capturedAt: Date = Date(), items: [CredentialSnapshotItem]) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.items = items
    }
}

public struct CredentialSnapshotItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fullFile
        case jsonFields
        /// JSON fields merged into a login-keychain generic password instead
        /// of a file; `relativePath` carries a "keychain/<service>" marker.
        /// Older builds cannot decode this case — their `decodeFailed`
        /// recovery clears the snapshot and re-captures.
        case keychainJSONFields
    }

    public var relativePath: String
    public var kind: Kind
    public var contents: Data
    public var posixPermissions: Int?

    public init(relativePath: String, kind: Kind, contents: Data, posixPermissions: Int?) {
        self.relativePath = relativePath
        self.kind = kind
        self.contents = contents
        self.posixPermissions = posixPermissions
    }
}

public struct RestoreResult: Equatable, Sendable {
    public var touchedPaths: [URL]
    public var backupURLs: [URL]

    public init(touchedPaths: [URL], backupURLs: [URL]) {
        self.touchedPaths = touchedPaths
        self.backupURLs = backupURLs
    }
}

/// Shared window-id slugging. Window ids are a contract between the local
/// Claude Code TUI parser and the Anthropic usage API client: per-window alert
/// dedupe keys must survive flipping between the two sources, so both must
/// slug scope names identically.
public enum UsageWindowID {
    /// Lowercase alphanumerics joined by dashes; "window" when nothing
    /// survives.
    public static func slug(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "window" : collapsed
    }
}

/// ISO8601 parsing that tolerates both timestamp shapes providers emit:
/// with fractional seconds ("2026-07-08T00:49:59.940321+00:00") and without
/// ("2026-07-13T06:00:00Z").
public enum FlexibleISO8601 {
    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Shared "how long until" phrasing so every surface rounds the same way.
public enum DurationPhrase {
    /// A compact single-unit duration ("3m", "5h", "2d") rounded up so a
    /// reset is never promised earlier than it happens: minutes under an
    /// hour, hours under two days, whole days beyond. Never less than "1m",
    /// and negative intervals clamp to it. Call sites add their own prefix
    /// ("in 3h", "resets in 3h").
    public static func short(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return "\(max(1, minutes))m"
        }

        let hours = Int((Double(minutes) / 60).rounded(.up))
        if hours < 48 {
            return "\(hours)h"
        }

        let days = Int((Double(hours) / 24).rounded(.up))
        return "\(days)d"
    }
}
