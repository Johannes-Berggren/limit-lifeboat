import Foundation

public enum ClaudeUsageAPIError: Error, LocalizedError {
    case unauthorized
    case http(status: Int)
    case network(Error)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The Anthropic usage API rejected the access token; it needs a refresh or a new login."
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

    public init(kindRaw: String, scopeName: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.kindRaw = kindRaw
        self.scopeName = scopeName
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ClaudeAPIUsage: Equatable, Sendable {
    public var windows: [ClaudeAPIUsageWindow]

    public init(windows: [ClaudeAPIUsageWindow]) {
        self.windows = windows
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
    /// same error mapping everywhere (401/403 -> unauthorized, other non-2xx
    /// -> http, transport failures -> network, non-object JSON -> malformed).
    private func fetchJSONObject(from url: URL, accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeOAuthConstants.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LLMUsageMonitor", forHTTPHeaderField: "User-Agent")

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
        case 401, 403:
            throw ClaudeUsageAPIError.unauthorized
        default:
            throw ClaudeUsageAPIError.http(status: response.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageAPIError.malformedResponse
        }
        return object
    }

    public func makeSnapshot(for profile: AccountProfile, usage: ClaudeAPIUsage, now: Date = Date()) -> UsageSnapshot {
        guard let selectedWindow = usage.windows.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return UsageSnapshot(
                accountID: profile.id,
                provider: .claude,
                riskLevel: .unknown,
                source: Self.source,
                lastRefreshed: now,
                parseConfidence: .none,
                message: "Anthropic usage API did not include a recognizable limit."
            )
        }

        let windows = usage.windows.map(makeWindow(from:))
        let usedPercent = min(100, max(0, selectedWindow.usedPercent))
        return UsageSnapshot(
            accountID: profile.id,
            provider: .claude,
            windows: windows,
            includedRemaining: max(0, 100 - usedPercent),
            includedLimit: 100,
            resetDate: selectedWindow.resetsAt,
            resetDescription: resetDescription(for: selectedWindow.resetsAt),
            creditStatus: "Live Anthropic account view across devices.",
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent),
            source: Self.source,
            lastRefreshed: now,
            parseConfidence: .high,
            message: message(for: usage.windows)
        )
    }

    // MARK: - Response parsing

    /// The response carries both a "limits" array (preferred; one entry per
    /// window, scoped entries included) and legacy "five_hour"/"seven_day_*"
    /// objects. All other keys are ignored.
    private func parseUsage(from object: [String: Any]) -> ClaudeAPIUsage {
        if let limits = object["limits"] as? [[String: Any]] {
            let windows = limits.compactMap(parseLimitEntry(_:))
            if !windows.isEmpty {
                return ClaudeAPIUsage(windows: windows)
            }
        }
        return ClaudeAPIUsage(windows: parseLegacyWindows(from: object))
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
            resetsAt: parseResetDate(entry["resets_at"] as? String)
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
        let usedPercent = min(100, max(0, window.usedPercent))
        let descriptor = windowDescriptor(for: window)
        return UsageWindow(
            id: descriptor.id,
            kind: descriptor.kind,
            label: descriptor.label,
            usedPercent: usedPercent,
            resetDate: window.resetsAt,
            resetDescription: resetDescription(for: window.resetsAt),
            windowMinutes: descriptor.windowMinutes,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent)
        )
    }

    /// Ids deliberately mirror `ClaudeCodeUsageReport`'s windowDescriptor so
    /// per-window alert dedupe keys survive switching between sources.
    private func windowDescriptor(
        for window: ClaudeAPIUsageWindow
    ) -> (id: String, kind: UsageWindowKind, label: String, windowMinutes: Int?) {
        switch window.kindRaw {
        case "session", "five_hour":
            return ("session", .session, "Session (5h)", 300)
        case "weekly_all", "seven_day":
            return ("weekly-all", .weekly, "Weekly (all models)", 10080)
        case "weekly_scoped":
            guard let scopeName = window.scopeName else {
                return ("weekly-scoped", .weeklyScoped, "Weekly (scoped)", 10080)
            }
            return ("weekly-\(UsageWindowID.slug(scopeName))", .weeklyScoped, "Weekly (\(scopeName))", 10080)
        case "seven_day_opus":
            return ("weekly-opus", .weeklyScoped, "Weekly (Opus)", 10080)
        case "seven_day_sonnet":
            return ("weekly-sonnet", .weeklyScoped, "Weekly (Sonnet)", 10080)
        default:
            return (UsageWindowID.slug(window.kindRaw), .other, humanized(window.kindRaw).capitalized, nil)
        }
    }

    private func message(for windows: [ClaudeAPIUsageWindow]) -> String {
        let parts = windows.map { window in
            "\(messageLabel(for: window)) \(Int(window.usedPercent.rounded()))%"
        }
        return "Anthropic usage API reports " + parts.joined(separator: " - ")
    }

    private func messageLabel(for window: ClaudeAPIUsageWindow) -> String {
        switch window.kindRaw {
        case "session", "five_hour":
            return "session"
        case "weekly_all", "seven_day":
            return "weekly all models"
        case "weekly_scoped":
            return window.scopeName.map { "weekly \($0)" } ?? "weekly scoped"
        case "seven_day_opus":
            return "weekly Opus"
        case "seven_day_sonnet":
            return "weekly Sonnet"
        default:
            return humanized(window.kindRaw)
        }
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

    private func humanized(_ kindRaw: String) -> String {
        kindRaw.replacingOccurrences(of: "_", with: " ")
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
