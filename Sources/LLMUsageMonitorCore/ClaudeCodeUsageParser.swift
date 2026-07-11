import Foundation

public struct ClaudeCodeUsageLimit: Equatable, Sendable {
    public var name: String
    public var usedPercent: Double
    public var resetDescription: String?

    public init(name: String, usedPercent: Double, resetDescription: String?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetDescription = resetDescription
    }
}

public struct ClaudeCodeUsageReport: Equatable, Sendable {
    public static let source = "local Claude Code /usage"

    public var identity: AccountIdentity?
    public var limits: [ClaudeCodeUsageLimit]
    public var usageCreditStatus: String?

    public init(identity: AccountIdentity?, limits: [ClaudeCodeUsageLimit], usageCreditStatus: String? = nil) {
        self.identity = identity
        self.limits = limits
        self.usageCreditStatus = usageCreditStatus
    }

    public func makeSnapshot(for account: AccountProfile, now: Date = Date()) -> UsageSnapshot {
        let windows = dedupeWindows(limits.map { makeWindow(from: $0, now: now) })
        return UsageSnapshotFactory.snapshot(
            accountID: account.id,
            provider: .claude,
            windows: windows,
            creditStatus: creditStatus,
            source: Self.source,
            lastRefreshed: now,
            message: limits.isEmpty
                ? "Claude Code /usage did not include a recognizable limit."
                : message
        )
    }

    private func makeWindow(from limit: ClaudeCodeUsageLimit, now: Date) -> UsageWindow {
        let descriptor = ClaudeUsageWindowCatalog.tuiDescriptor(name: limit.name)
        return UsageSnapshotFactory.window(
            descriptor: descriptor,
            usedPercent: limit.usedPercent,
            resetDate: limit.resetDescription.flatMap { ClaudeResetDateParser().parse($0, now: now) },
            resetDescription: limit.resetDescription
        )
    }

    /// Multi-frame TUI captures can repeat a section, so limits may map to the
    /// same window id. Keep the last occurrence per id so SwiftUI ForEach never
    /// sees duplicate identifiers.
    private func dedupeWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        var orderedIDs: [String] = []
        var lastByID: [String: UsageWindow] = [:]
        for window in windows {
            if lastByID[window.id] == nil {
                orderedIDs.append(window.id)
            }
            lastByID[window.id] = window
        }
        return orderedIDs.compactMap { lastByID[$0] }
    }

    private var creditStatus: String {
        let localNote = "Local Claude Code view; excludes other devices and claude.ai."
        guard let usageCreditStatus, !usageCreditStatus.isEmpty else {
            return localNote
        }
        return "\(usageCreditStatus). \(localNote)"
    }

    private var message: String {
        let parts = limits.map { limit in
            "\(messageLabel(for: limit.name)) \(Int(limit.usedPercent.rounded()))%"
        }
        return "Claude Code /usage reports " + parts.joined(separator: " - ")
    }

    private func messageLabel(for name: String) -> String {
        let lower = name.lowercased()
        if lower == "current session" {
            return "current session"
        }
        if lower.contains("all models") {
            return "weekly all models"
        }
        if let organization = firstCapture(#"\(([^)]+)\)"#, in: name) {
            return "weekly \(organization)"
        }
        return name
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: 1))
    }
}

public struct ClaudeCodeUsageOutputParser: Sendable {
    public init() {}

    public func parse(text rawText: String, now: Date = Date()) -> ClaudeCodeUsageReport? {
        let lines = normalizedLines(from: rawText)
        guard !lines.isEmpty else {
            return nil
        }

        let limits = parseLimits(from: lines)
        guard !limits.isEmpty else {
            return nil
        }

        return ClaudeCodeUsageReport(
            identity: parseIdentity(from: lines, limits: limits, now: now),
            limits: limits,
            usageCreditStatus: parseUsageCreditStatus(from: lines)
        )
    }

    private func parseLimits(from lines: [String]) -> [ClaudeCodeUsageLimit] {
        var limits: [ClaudeCodeUsageLimit] = []
        var currentName: String?
        var currentLines: [String] = []

        func flushCurrent() {
            guard let currentName,
                  let limit = parseLimit(name: currentName, lines: currentLines) else {
                return
            }
            limits.append(limit)
        }

        for line in lines {
            if let sectionName = usageSectionName(in: line) {
                flushCurrent()
                currentName = sectionName
                currentLines = [line]
            } else if currentName != nil {
                currentLines.append(line)
            }
        }
        flushCurrent()

        return dedupeLimits(limits)
    }

    /// The expect probe captures the /usage TUI across progressive redraw
    /// frames, so the same section can be parsed several times. Keep one limit
    /// per section: later frames are usually more complete, but never trade a
    /// reset description away for an occurrence without one.
    private func dedupeLimits(_ limits: [ClaudeCodeUsageLimit]) -> [ClaudeCodeUsageLimit] {
        var orderedKeys: [String] = []
        var bestByKey: [String: ClaudeCodeUsageLimit] = [:]

        for limit in limits {
            let key = canonicalize(limit.name).lowercased()
            guard let existing = bestByKey[key] else {
                orderedKeys.append(key)
                bestByKey[key] = limit
                continue
            }
            if limit.resetDescription != nil || existing.resetDescription == nil {
                bestByKey[key] = limit
            }
        }

        return orderedKeys.compactMap { bestByKey[$0] }
    }

    private func parseLimit(name: String, lines: [String]) -> ClaudeCodeUsageLimit? {
        let segment = lines.joined(separator: " ")
        guard let usedText = firstCapture(
            #"(?i)\b([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used\b"#,
            in: segment
        ),
            let usedPercent = Double(usedText) else {
            return nil
        }

        return ClaudeCodeUsageLimit(
            name: name,
            usedPercent: usedPercent,
            resetDescription: resetDescription(from: lines)
        )
    }

    private func usageSectionName(in line: String) -> String? {
        if let name = firstMatch(#"(?i)\bCurrent session\b"#, in: line) {
            return canonicalize(name)
        }
        if let name = firstMatch(#"(?i)\bCurrent week\s*\([^)]+\)"#, in: line) {
            return canonicalize(name)
        }
        return nil
    }

    private func resetDescription(from lines: [String]) -> String? {
        for line in lines {
            guard let value = firstCapture(#"(?i)\bResets?\s+(.+)"#, in: line) else {
                continue
            }
            let cleaned = cleanResetDescription(value)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private func cleanResetDescription(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let stopPatterns = [
            #"(?i)\bCurrent session\b"#,
            #"(?i)\bCurrent week\b"#,
            #"(?i)\bApproximate\b"#,
            #"(?i)\bbased on\b"#,
            #"(?i)\bdoes not include\b"#,
            #"(?i)Esc to cancel"#,
            #"(?i)\bLast 24h\b"#,
            #"(?i)\bScanning local sessions\b"#
        ]
        for pattern in stopPatterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }

    private func parseIdentity(from lines: [String], limits: [ClaudeCodeUsageLimit], now: Date) -> AccountIdentity? {
        let text = lines.joined(separator: " ")
        let email = firstMatch(
            #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#,
            in: text
        )
        let organization = possessiveOrganization(in: text)

        guard email != nil || organization != nil else {
            return nil
        }

        let identity = AccountIdentity(
            email: email,
            displayName: nil,
            organization: organization,
            accountID: nil,
            source: .claudeCodeUsage,
            updatedAt: now
        )
        return identity.isLikelyValid ? identity : nil
    }

    private func parseUsageCreditStatus(from lines: [String]) -> String? {
        guard let startIndex = lines.firstIndex(where: { $0.lowercased() == "usage credits" }) else {
            return nil
        }

        let endIndex = min(lines.count, startIndex + 5)
        let segment = lines[startIndex..<endIndex].joined(separator: " ")
        var parts: [String] = []

        if let percentText = firstCapture(#"(?i)\b([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used\b"#, in: segment) {
            parts.append("Usage credits \(percentText)% used")
        }

        if let spendText = firstMatch(#"\$[0-9][0-9,.]*\s*/\s*\$[0-9][0-9,.]*\s*spent"#, in: segment) {
            parts.append(spendText)
        }

        if let reset = firstCapture(#"(?i)\bResets?\s+(.+)"#, in: segment) {
            let cleaned = cleanResetDescription(reset)
            if !cleaned.isEmpty {
                parts.append("resets \(cleaned)")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    private func possessiveOrganization(in text: String) -> String? {
        guard let value = firstCapture(
            #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}'s\s+([A-Za-z0-9][A-Za-z0-9 ._&+\-]{1,80})"#,
            in: text
        ) else {
            return nil
        }

        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerBeforeStop = cleaned.lowercased()
        for stopWord in [" usage", " current", " claude", " try"] {
            if let range = lowerBeforeStop.range(of: stopWord) {
                cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !cleaned.isEmpty, cleaned.lowercased() != "organization" else {
            return nil
        }
        return cleaned
    }

    private func normalizedLines(from rawText: String) -> [String] {
        let noControlSequences = stripControlSequences(from: rawText)
        let noBoxDrawing = replaceBoxDrawingCharacters(in: noControlSequences)
        return noBoxDrawing
            .components(separatedBy: .newlines)
            .map(collapseWhitespace)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func stripControlSequences(from text: String) -> String {
        let escape = "\u{001B}"
        let bell = "\u{0007}"
        let patterns = [
            "\(escape)\\][^\(bell)\(escape)]*(?:\(bell)|\(escape)\\\\)",
            "\(escape)\\[[0-?]*[ -/]*[@-~]"
        ]

        return patterns.reduce(text.replacingOccurrences(of: "\r", with: "\n")) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private func replaceBoxDrawingCharacters(in text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2500...0x257F:
                output.append(" ")
            case 0..<32 where scalar.value != 10 && scalar.value != 9:
                continue
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func canonicalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return (text as NSString).substring(with: match.range)
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (text as NSString)
            .substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
