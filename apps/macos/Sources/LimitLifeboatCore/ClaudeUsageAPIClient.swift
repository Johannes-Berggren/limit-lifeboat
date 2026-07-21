import Foundation

public enum ClaudeUsageAPIError: Error, LocalizedError {
    case unauthorized
    case forbidden
    case http(status: Int)
    case network(Error)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The Anthropic usage API rejected the access token; it needs a refresh or a new login."
        case .forbidden:
            return "The Anthropic usage API denied access to usage data. Renew the login or ask an organization administrator to allow usage access."
        case .http(let status):
            return "The Anthropic usage API responded with status \(status)."
        case .network(let underlying):
            return "Could not reach the Anthropic usage API (\(underlying.localizedDescription))."
        case .malformedResponse:
            return "The Anthropic usage API returned a response in an unexpected format."
        }
    }
}

/// One rate-limit window as the usage API reports it, before mapping onto the
/// app's `UsageWindow` model.
public struct ClaudeAPIUsageWindow: Equatable, Sendable {
    /// "session", "weekly_all", "weekly_scoped", or a legacy key like
    /// "five_hour"/"seven_day_opus".
    public var kindRaw: String
    /// The scope's model display name (e.g. "Fable") for scoped windows.
    public var scopeName: String?
    public var usedPercent: Double
    public var resetsAt: Date?
    /// The API's per-window severity ("normal", and — unconfirmed — an
    /// escalated value at limit); nil for the legacy objects that omit it.
    public var severityRaw: String?
    /// Whether this is the currently-binding window; nil for legacy objects.
    public var isActive: Bool?

    public init(
        kindRaw: String,
        scopeName: String? = nil,
        usedPercent: Double,
        resetsAt: Date? = nil,
        severityRaw: String? = nil,
        isActive: Bool? = nil
    ) {
        self.kindRaw = kindRaw
        self.scopeName = scopeName
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.severityRaw = severityRaw
        self.isActive = isActive
    }
}

/// The account's `extra_usage` block — the pay-as-you-go / usage-credit billing
/// state the usage API reports alongside the rate-limit windows.
public struct ClaudeAPIExtraUsage: Equatable, Sendable {
    /// Whether overage / usage-credit billing is turned on for the account.
    public var isEnabled: Bool
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var utilization: Double?

    public init(
        isEnabled: Bool,
        monthlyLimit: Double? = nil,
        usedCredits: Double? = nil,
        utilization: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
    }
}

public struct ClaudeAPIUsage: Equatable, Sendable {
    public var windows: [ClaudeAPIUsageWindow]
    /// The overage/credit block, when the response included it; nil for the
    /// older response shape and for directly-constructed usage.
    public var extraUsage: ClaudeAPIExtraUsage?

    public init(windows: [ClaudeAPIUsageWindow], extraUsage: ClaudeAPIExtraUsage? = nil) {
        self.windows = windows
        self.extraUsage = extraUsage
    }
}

/// Who an OAuth access token belongs to and which plan tier the organization
/// is on, as the api/oauth/profile endpoint reports it.
public struct ClaudeAPIAccountInfo: Equatable, Sendable {
    public var identity: AccountIdentity?
    /// Short human tier ("Max 20x", "Pro"); nil when the response carries no
    /// recognizable plan signal.
    public var planLabel: String?

    public init(identity: AccountIdentity? = nil, planLabel: String? = nil) {
        self.identity = identity
        self.planLabel = planLabel
    }
}

/// Fetches the account-wide usage view from api.anthropic.com with a Claude
/// Code OAuth access token. Unlike the local TUI scrape this covers every
/// device on the account, so its snapshots use the same window ids as the
/// parser to keep alert dedupe keys stable across the source flip.
public struct ClaudeUsageAPIClient: Sendable {
    public static let source = "Anthropic usage API"

    private let httpClient: HTTPClienting

    public init(httpClient: HTTPClienting = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func fetchUsage(accessToken: String) async throws -> ClaudeAPIUsage {
        let object = try await fetchJSONObject(from: ClaudeOAuthConstants.usageEndpoint, accessToken: accessToken)
        return parseUsage(from: object)
    }

    /// Shared GET plumbing for the OAuth endpoints: same header set and the
    /// same error mapping everywhere (401 -> unauthorized, 403 -> forbidden,
    /// other non-2xx -> http, transport failures -> network, non-object JSON
    /// -> malformed). A forbidden response must not consume a refresh token.
    private func fetchJSONObject(from url: URL, accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeOAuthConstants.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LimitLifeboat", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.send(request)
        } catch {
            throw ClaudeUsageAPIError.network(error)
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            // Some OAuth resource servers report insufficient_scope with a
            // 401 even though RFC 6750 recommends 403. Never spend a rotating
            // refresh token on that exact structured policy response.
            if Self.oauthErrorCode(in: data) == "insufficient_scope" {
                throw ClaudeUsageAPIError.forbidden
            }
            throw ClaudeUsageAPIError.unauthorized
        case 403:
            throw ClaudeUsageAPIError.forbidden
        default:
            throw ClaudeUsageAPIError.http(status: response.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageAPIError.malformedResponse
        }
        return object
    }

    private static func oauthErrorCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = object["error"] as? String else {
            return nil
        }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty ? nil : code
    }

    public func makeSnapshot(for profile: AccountProfile, usage: ClaudeAPIUsage, now: Date = Date()) -> UsageSnapshot {
        let windows = usage.windows.map(makeWindow(from:))
        let mostConstrained = windows.map(\.usedPercent).max() ?? 0
        let payAsYouGoState = payAsYouGoState(for: usage, mostConstrainedUsedPercent: mostConstrained)
        return UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: windows,
            creditStatus: creditStatus(for: payAsYouGoState),
            source: Self.source,
            lastRefreshed: now,
            message: usage.windows.isEmpty
                ? "Anthropic usage API did not include a recognizable limit."
                : message(for: usage.windows),
            payAsYouGoState: payAsYouGoState,
            payAsYouGoSpend: payAsYouGoSpend(for: usage)
        )
    }

    /// The display-only spend figures. Carried whenever overage is enabled —
    /// including `.enabledIdle`, so the popover can show the month's spend
    /// even while included usage is fine; the UI gates visibility.
    private func payAsYouGoSpend(for usage: ClaudeAPIUsage) -> PayAsYouGoSpend? {
        guard let extra = usage.extraUsage, extra.isEnabled else {
            return nil
        }
        return PayAsYouGoSpend(
            monthlyLimit: extra.monthlyLimit,
            usedCredits: extra.usedCredits,
            utilization: extra.utilization
        )
    }

    /// Maps the `extra_usage` block onto the app's overage state. nil when the
    /// response carried no `extra_usage` (older shape / directly-constructed
    /// usage) so `billingUsageMode` falls back to its string heuristics.
    ///
    /// `.enabledActive` (the only state that raises a PAYG warning) requires
    /// included usage to actually be exhausted — the most-constrained window at
    /// or over its limit. Merely having overage *enabled* is a common backstop
    /// and is `.enabledIdle`, which does not alarm. `used_credits` is
    /// deliberately NOT used as the trigger: it is a cumulative figure that
    /// stays non-zero after a window resets, so it would flag a healthy account
    /// as "paying" when it is not. `severity`/`utilization` are likewise not
    /// trusted until a real over-limit response confirms their shape.
    private func payAsYouGoState(
        for usage: ClaudeAPIUsage,
        mostConstrainedUsedPercent: Double
    ) -> PayAsYouGoState? {
        guard let extra = usage.extraUsage else {
            return nil
        }
        guard extra.isEnabled else {
            return .disabled
        }
        return mostConstrainedUsedPercent >= 100 ? .enabledActive : .enabledIdle
    }

    /// The human credit line. When overage is active/enabled it embeds keywords
    /// `UsageSnapshot`'s string scan recognizes, so notification text and the
    /// TUI/dashboard fallback stay consistent with the structured state. The
    /// disabled/unknown case keeps the original cross-device phrasing.
    private func creditStatus(for state: PayAsYouGoState?) -> String {
        switch state {
        case .enabledActive:
            return "Included usage exhausted — now on pay-as-you-go credits."
        case .enabledIdle:
            return "Pay-as-you-go credits are enabled as a backstop."
        case .disabled, .none:
            return "Live Anthropic account view across devices."
        }
    }

    // MARK: - Response parsing

    /// The response carries both a "limits" array (preferred; one entry per
    /// window, scoped entries included) and legacy "five_hour"/"seven_day_*"
    /// objects, plus an `extra_usage` overage block. All other keys are ignored.
    private func parseUsage(from object: [String: Any]) -> ClaudeAPIUsage {
        let extraUsage = parseExtraUsage(from: object)
        if let limits = object["limits"] as? [[String: Any]] {
            let windows = limits.compactMap(parseLimitEntry(_:))
            if !windows.isEmpty {
                return ClaudeAPIUsage(windows: windows, extraUsage: extraUsage)
            }
        }
        return ClaudeAPIUsage(windows: parseLegacyWindows(from: object), extraUsage: extraUsage)
    }

    private func parseLimitEntry(_ entry: [String: Any]) -> ClaudeAPIUsageWindow? {
        guard let kindRaw = entry["kind"] as? String,
              let percent = number(entry["percent"]) ?? number(entry["utilization"]) else {
            return nil
        }

        var scopeName: String?
        if let scope = entry["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any] {
            scopeName = model["display_name"] as? String
        }

        return ClaudeAPIUsageWindow(
            kindRaw: kindRaw,
            scopeName: scopeName,
            usedPercent: percent,
            resetsAt: parseResetDate(entry["resets_at"] as? String),
            severityRaw: entry["severity"] as? String,
            isActive: entry["is_active"] as? Bool
        )
    }

    /// The `extra_usage` block; nil when the key is absent (older shape).
    /// Tolerant like the rest of parsing: a missing `is_enabled` reads as off.
    private func parseExtraUsage(from object: [String: Any]) -> ClaudeAPIExtraUsage? {
        guard let extra = object["extra_usage"] as? [String: Any] else {
            return nil
        }
        return ClaudeAPIExtraUsage(
            isEnabled: (extra["is_enabled"] as? Bool) ?? false,
            monthlyLimit: number(extra["monthly_limit"]),
            usedCredits: number(extra["used_credits"]),
            utilization: number(extra["utilization"])
        )
    }

    private func parseLegacyWindows(from object: [String: Any]) -> [ClaudeAPIUsageWindow] {
        let legacyKeys = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return legacyKeys.compactMap { key in
            guard let value = object[key] as? [String: Any],
                  let percent = number(value["utilization"]) ?? number(value["percent"]) else {
                return nil
            }
            return ClaudeAPIUsageWindow(
                kindRaw: key,
                scopeName: nil,
                usedPercent: percent,
                resetsAt: parseResetDate(value["resets_at"] as? String)
            )
        }
    }

    private func parseResetDate(_ value: String?) -> Date? {
        value.flatMap(FlexibleISO8601.date(from:))
    }

    /// Accepts numeric and string-typed numbers: the API has been seen
    /// emitting both, and the Codex log reader coerces the same way.
    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    // MARK: - Snapshot mapping

    private func makeWindow(from window: ClaudeAPIUsageWindow) -> UsageWindow {
        let descriptor = ClaudeUsageWindowCatalog.apiDescriptor(
            kindRaw: window.kindRaw,
            scopeName: window.scopeName
        )
        return UsageSnapshotFactory.window(
            descriptor: descriptor,
            usedPercent: window.usedPercent,
            resetDate: window.resetsAt,
            resetDescription: resetDescription(for: window.resetsAt)
        )
    }

    private func message(for windows: [ClaudeAPIUsageWindow]) -> String {
        let parts = windows.map { window in
            "\(messageLabel(for: window)) \(Int(window.usedPercent.rounded()))%"
        }
        return "Anthropic usage API reports " + parts.joined(separator: " - ")
    }

    private func messageLabel(for window: ClaudeAPIUsageWindow) -> String {
        ClaudeUsageWindowCatalog.apiMessageLabel(kindRaw: window.kindRaw, scopeName: window.scopeName)
    }

    /// A short absolute local time ("Jul 8, 2026 at 1:49 AM"); the API gives
    /// only instants, never the TUI's relative phrases.
    private func resetDescription(for date: Date?) -> String? {
        guard let date else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}

// MARK: - Account info (api/oauth/profile)

extension ClaudeUsageAPIClient {
    /// GET api/oauth/profile — who the token belongs to plus the plan tier.
    /// `ClaudeOAuthConstants` (ClaudeOAuthCredentials.swift) is owned by the
    /// credential layer, so the profile URL lives here with its only caller.
    public static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Fetches the account identity and plan label behind an access token.
    /// Field mapping mirrors `ClaudeIdentityReader`'s ~/.claude.json read:
    /// `accountID` carries the account uuid and `organizationID` carries the
    /// organization uuid, so same-email Claude accounts in different orgs stay
    /// distinct.
    public func fetchAccountInfo(accessToken: String, now: Date = Date()) async throws -> ClaudeAPIAccountInfo {
        let object = try await fetchJSONObject(from: Self.profileEndpoint, accessToken: accessToken)
        return parseAccountInfo(from: object, now: now)
    }

    /// Tolerant by design: missing or oddly-typed keys degrade to nil fields,
    /// never a throw, matching how the usage response is parsed.
    private func parseAccountInfo(from object: [String: Any], now: Date) -> ClaudeAPIAccountInfo {
        let account = object["account"] as? [String: Any] ?? [:]
        let organization = object["organization"] as? [String: Any] ?? [:]

        let email = account["email"] as? String
        let displayName = (account["full_name"] as? String) ?? (account["display_name"] as? String)
        let organizationName = organization["name"] as? String
        let organizationID = organization["uuid"] as? String
        // The account uuid, never organization.uuid — see fetchAccountInfo.
        let accountID = account["uuid"] as? String

        var identity: AccountIdentity?
        if email != nil || displayName != nil || organizationName != nil || accountID != nil {
            identity = AccountIdentity(
                email: email,
                displayName: displayName,
                organization: organizationName,
                organizationID: organizationID,
                accountID: accountID,
                source: .claudeCodeUsage,
                updatedAt: now
            )
        }

        let planLabel = Self.planLabel(
            accountRateLimitTier: (account["user_rate_limit_tier"] as? String) ?? (account["rate_limit_tier"] as? String),
            organizationRateLimitTier: organization["rate_limit_tier"] as? String,
            organizationType: organization["organization_type"] as? String,
            billingType: organization["billing_type"] as? String,
            seatTier: organization["seat_tier"] as? String,
            hasClaudeMax: (account["has_claude_max"] as? Bool) ?? false,
            hasClaudePro: (account["has_claude_pro"] as? Bool) ?? false
        )

        return ClaudeAPIAccountInfo(identity: identity, planLabel: planLabel)
    }

    /// Maps the profile endpoint's plan fields onto a short human tier label.
    /// The rate-limit tier is the most specific signal; when it is absent or
    /// unrecognized the organization type, then the account flags, decide.
    /// Pure so the mapping table is directly testable.
    static func planLabel(
        accountRateLimitTier: String?,
        organizationRateLimitTier: String?,
        organizationType: String?,
        billingType: String?,
        seatTier: String?,
        hasClaudeMax: Bool,
        hasClaudePro: Bool
    ) -> String? {
        if organizationType?.lowercased() == "claude_team" {
            switch seatTier?.lowercased() {
            case "team_tier_1", "premium":
                return "Team Premium"
            case "team_tier_0", "standard":
                return "Team Standard"
            default:
                return billingType == nil ? "Team" : "Team"
            }
        }

        if let tier = accountRateLimitTier?.lowercased() {
            if let multiplier = maxTierMultiplier(in: tier) {
                return "Max \(multiplier)x"
            }
            if tier.contains("pro") {
                return "Pro"
            }
        }

        if let tier = organizationRateLimitTier?.lowercased() {
            if let multiplier = maxTierMultiplier(in: tier) {
                return "Max \(multiplier)x"
            }
            if tier.contains("pro") {
                return "Pro"
            }
        }
        if organizationType?.lowercased() == "claude_max" {
            return "Max"
        }
        // Max outranks Pro when both flags are set — an upgraded account
        // keeps has_claude_pro true.
        if hasClaudeMax {
            return "Max"
        }
        if hasClaudePro {
            return "Pro"
        }
        return nil
    }

    /// The <N> in "default_claude_max_<N>x", so multipliers Anthropic ships
    /// later ("7x") still label correctly without a table update.
    private static func maxTierMultiplier(in tier: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"default_claude_max_(\d+)x"#),
              let match = regex.firstMatch(in: tier, range: NSRange(tier.startIndex..<tier.endIndex, in: tier)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: tier) else {
            return nil
        }
        return String(tier[range])
    }
}
