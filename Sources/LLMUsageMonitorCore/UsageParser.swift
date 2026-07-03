import Foundation

public struct UsageTextParser: Sendable {
    public init() {}

    public func parse(text rawText: String, account: AccountProfile, source: String? = nil, now: Date = Date()) -> UsageSnapshot {
        let text = normalize(rawText)
        let lower = text.lowercased()
        let source = source ?? account.provider.dashboardURL.absoluteString

        if text.isEmpty {
            return UsageSnapshot(
                accountID: account.id,
                provider: account.provider,
                riskLevel: .stale,
                source: source,
                lastRefreshed: now,
                parseConfidence: .none,
                message: "No dashboard text was available."
            )
        }

        if looksLoggedOut(lower) {
            return UsageSnapshot(
                accountID: account.id,
                provider: account.provider,
                riskLevel: .stale,
                source: source,
                lastRefreshed: now,
                parseConfidence: .low,
                message: "Dashboard needs login."
            )
        }

        var remaining: Double?
        var limit: Double?
        var confidence: ParseConfidence = .none

        if let ratio = firstRatio(in: text) {
            limit = ratio.limit
            if ratio.context.contains("remaining") || ratio.context.contains("left") {
                remaining = ratio.first
            } else {
                remaining = max(0, ratio.limit - ratio.first)
            }
            confidence = .high
        } else if let percentage = firstPercentage(in: text) {
            limit = 100
            if percentage.context.contains("remaining") || percentage.context.contains("left") {
                remaining = percentage.value
            } else if percentage.context.contains("used") || percentage.context.contains("usage") || percentage.context.contains("consumed") {
                remaining = max(0, 100 - percentage.value)
            } else {
                remaining = percentage.value
            }
            confidence = .medium
        } else if let explicit = firstExplicitRemaining(in: text) {
            remaining = explicit
            confidence = .medium
        }

        let creditStatus = extractCreditStatus(from: text)
        let resetDescription = extractResetDescription(from: text)
        let risk = riskLevel(from: lower, remaining: remaining, limit: limit)
        let message = messageFor(risk: risk, confidence: confidence, creditStatus: creditStatus)

        return UsageSnapshot(
            accountID: account.id,
            provider: account.provider,
            includedRemaining: remaining,
            includedLimit: limit,
            resetDate: nil,
            resetDescription: resetDescription,
            creditStatus: creditStatus,
            riskLevel: confidence == .none ? .unknown : risk,
            source: source,
            lastRefreshed: now,
            parseConfidence: confidence,
            message: confidence == .none ? unknownUsageMessage(lower: lower) : message
        )
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLoggedOut(_ lower: String) -> Bool {
        if lower.contains("log in")
            && lower.contains("sign up")
            && !lower.contains("log out")
            && firstMatch(#"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, in: lower) == nil {
            return true
        }

        let loginPhrases = [
            "log in",
            "sign in",
            "continue with google",
            "continue with microsoft",
            "continue with apple"
        ]
        guard loginPhrases.contains(where: { lower.contains($0) }) else {
            return false
        }
        return !lower.contains("usage") && !lower.contains("remaining") && !lower.contains("limit")
    }

    private func unknownUsageMessage(lower: String) -> String {
        if lower.contains("usage limit") || lower.contains("current limits") || lower.contains("analytics") {
            return "Dashboard loaded, but current remaining usage was not found."
        }

        if lower.contains("settings") || lower.contains("account") || lower.contains("profile") {
            return "Account page loaded, but usage limits are not visible."
        }

        return "Dashboard loaded, but usage data was not recognized."
    }

    private func riskLevel(from lower: String, remaining: Double?, limit: Double?) -> RiskLevel {
        if lower.contains("limit reached")
            || lower.contains("usage limit reached")
            || lower.contains("included usage exhausted")
            || lower.contains("no remaining") {
            return .depleted
        }

        guard let remaining else {
            return .unknown
        }

        if remaining <= 0 {
            return .depleted
        }

        if let limit, limit > 0 {
            let fraction = remaining / limit
            if fraction <= 0.20 {
                return .warning
            }
            return .healthy
        }

        return remaining <= 5 ? .warning : .healthy
    }

    private func messageFor(risk: RiskLevel, confidence: ParseConfidence, creditStatus: String?) -> String {
        switch risk {
        case .depleted:
            return creditStatus == nil ? "Included usage appears depleted." : "Included usage appears depleted; credits may apply."
        case .warning:
            return "Included usage is running low."
        case .healthy:
            return "Included usage is available."
        case .stale:
            return "Dashboard needs attention."
        case .unknown:
            return confidence == .none ? "Usage data was not recognized." : "Usage status is unclear."
        }
    }

    private struct RatioMatch {
        var first: Double
        var limit: Double
        var context: String
    }

    private struct PercentageMatch {
        var value: Double
        var context: String
    }

    private func firstRatio(in text: String) -> RatioMatch? {
        let pattern = #"(?i)([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:/|of)\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let match = firstMatch(pattern, in: text),
              let first = number(from: text, range: match.range(at: 1)),
              let limit = number(from: text, range: match.range(at: 2)) else {
            return nil
        }
        return RatioMatch(first: first, limit: limit, context: context(around: match.range, in: text))
    }

    private func firstPercentage(in text: String) -> PercentageMatch? {
        let pattern = #"(?i)([0-9](?:[0-9])?(?:\.[0-9]+)?|100(?:\.0+)?)\s*%"#
        guard let match = firstMatch(pattern, in: text),
              let value = number(from: text, range: match.range(at: 1)) else {
            return nil
        }
        return PercentageMatch(value: value, context: context(around: match.range, in: text))
    }

    private func firstExplicitRemaining(in text: String) -> Double? {
        let pattern = #"(?i)([0-9][0-9,]*(?:\.[0-9]+)?)\s+(?:messages?|credits?|tokens?)?\s*(?:remaining|left)"#
        guard let match = firstMatch(pattern, in: text) else {
            return nil
        }
        return number(from: text, range: match.range(at: 1))
    }

    private func extractCreditStatus(from text: String) -> String? {
        let lower = text.lowercased()
        guard lower.contains("credit") || lower.contains("pay-as-you-go") || lower.contains("pay as you go") else {
            return nil
        }

        if lower.contains("auto top-up") || lower.contains("auto-reload") || lower.contains("auto reload") {
            return "Credits enabled; auto top-up may apply."
        }

        if lower.contains("pay-as-you-go") || lower.contains("pay as you go") {
            return "Pay-as-you-go credits may apply."
        }

        return "Usage credits mentioned."
    }

    private func extractResetDescription(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:resets?|reset)\s+(?:at|in|on)?\s*([A-Za-z0-9:./,\-\s]{2,70})"#,
            #"(?i)(?:available again|try again)\s+(?:at|in|on)\s*([A-Za-z0-9:./,\-\s]{2,70})"#
        ]

        for pattern in patterns {
            guard let match = firstMatch(pattern, in: text) else {
                continue
            }
            let nsText = text as NSString
            var value = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let stop = value.range(of: #"(?i)\s(?:usage|credits|settings|dashboard|model)\b"#, options: .regularExpression) {
                value = String(value[..<stop.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }

    private func number(from text: String, range: NSRange) -> Double? {
        guard range.location != NSNotFound else {
            return nil
        }
        let value = (text as NSString)
            .substring(with: range)
            .replacingOccurrences(of: ",", with: "")
        return Double(value)
    }

    private func context(around range: NSRange, in text: String) -> String {
        let nsText = text as NSString
        let start = max(0, range.location - 80)
        let end = min(nsText.length, range.location + range.length + 80)
        return nsText.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }
}
