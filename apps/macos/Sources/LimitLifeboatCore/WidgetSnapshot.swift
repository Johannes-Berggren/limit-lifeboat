import Foundation

/// What the desktop widget shows: a read-only, display-ready projection of
/// every saved account. The app is the only writer; the sandboxed widget
/// extension only reads it. It deliberately carries no credentials, emails or
/// organization IDs beyond the label the menu shows, and lives in its own
/// `Widget/` directory so the widget's read-only sandbox exception never
/// covers `profiles.json`, backups or history.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let directoryName = "Widget"
    public static let fileName = "widget-snapshot.json"
    public static let currentVersion = 1
    /// The `Info.plist` key that tells the widget extension which
    /// Application Support directory its app variant uses.
    public static let applicationSupportNameInfoKey = "LimitLifeboatApplicationSupportDirectoryName"

    public var version: Int
    public var generatedAt: Date
    /// Grouped by provider (Claude first), the active account first within
    /// each provider, then the user's switch-priority order.
    public var accounts: [WidgetAccount]
    /// Mirrors the "Usage curves" setting: false draws plain bars.
    public var showsUsageCurves: Bool

    public init(
        version: Int = WidgetSnapshot.currentVersion,
        generatedAt: Date,
        accounts: [WidgetAccount],
        showsUsageCurves: Bool = true
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.showsUsageCurves = showsUsageCurves
    }

    public static let empty = WidgetSnapshot(generatedAt: .distantPast, accounts: [])

    public func accounts(for provider: Provider) -> [WidgetAccount] {
        accounts.filter { $0.provider == provider }
    }

    /// The account the small widget leads with: the active Claude account,
    /// else the active Codex account, else the first account.
    public var headlineAccount: WidgetAccount? {
        accounts.first { $0.isActive && $0.provider == .claude }
            ?? accounts.first { $0.isActive }
            ?? accounts.first
    }

    /// The advised switch target for the headline account's provider.
    public func bestNext(for provider: Provider) -> WidgetAccount? {
        accounts.first { $0.provider == provider && $0.isBestNext && !$0.isActive }
    }
}

public struct WidgetAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    /// Plan tier ("Max 20x"), when known.
    public var planLabel: String?
    public var isActive: Bool
    /// The app's current switch advice for this provider points here.
    public var isBestNext: Bool
    /// When the reading behind `windows` was taken; nil before the first one.
    public var lastRefreshed: Date?
    /// One short line for the account when something needs attention
    /// ("Sign in", "Reset passed — quota likely back", a pace forecast).
    public var note: WidgetNote?
    public var windows: [WidgetWindow]

    public init(
        id: UUID,
        provider: Provider,
        label: String,
        planLabel: String? = nil,
        isActive: Bool,
        isBestNext: Bool = false,
        lastRefreshed: Date? = nil,
        note: WidgetNote? = nil,
        windows: [WidgetWindow] = []
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.planLabel = planLabel
        self.isActive = isActive
        self.isBestNext = isBestNext
        self.lastRefreshed = lastRefreshed
        self.note = note
        self.windows = windows
    }

    public var sessionWindow: WidgetWindow? {
        windows.first { $0.kind == .session }
    }

    /// The all-models weekly window, or the first model-scoped one.
    public var weeklyWindow: WidgetWindow? {
        windows.first { $0.kind == .weekly } ?? windows.first { $0.kind == .weeklyScoped }
    }

    /// The window that best answers "how much can I use right now": the
    /// tighter of session and weekly once either is in the warning band,
    /// otherwise the session window.
    public var headlineWindow: WidgetWindow? {
        let primary = [sessionWindow, weeklyWindow].compactMap { $0 }
        let urgent = primary.filter { $0.usedPercent >= UsageThresholds.standard.warningUsedFraction * 100 }
        if let tightest = urgent.max(by: { $0.usedPercent < $1.usedPercent }) {
            return tightest
        }
        return primary.first ?? windows.first
    }

    /// Readings older than the app's stale threshold are shown greyed with
    /// their age instead of as live numbers.
    public func isStale(asOf now: Date) -> Bool {
        guard let lastRefreshed else { return true }
        return now.timeIntervalSince(lastRefreshed) > UsageThresholds.standard.staleAfter
    }
}

public struct WidgetWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: UsageWindowKind
    /// Short column label: "Session", "Week", or a model scope ("Fable").
    public var label: String
    public var usedPercent: Double
    public var resetDate: Date?
    public var riskLevel: RiskLevel
    /// The window's timeline for the large widget; nil draws a plain bar.
    public var runway: UsageRunway?

    public init(
        id: String,
        kind: UsageWindowKind,
        label: String,
        usedPercent: Double,
        resetDate: Date? = nil,
        riskLevel: RiskLevel,
        runway: UsageRunway? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetDate = resetDate
        self.riskLevel = riskLevel
        self.runway = runway
    }

    public var remainingPercent: Double {
        max(0, 100 - min(100, max(0, usedPercent)))
    }

    /// A window whose reset has passed since the reading has (most likely)
    /// refilled; the widget then stops drawing the old numbers as live.
    public func resetHasElapsed(asOf now: Date) -> Bool {
        guard let resetDate else { return false }
        return resetDate <= now
    }
}

public struct WidgetNote: Codable, Equatable, Sendable {
    public var text: String
    public var tone: PresentationTone

    public init(text: String, tone: PresentationTone) {
        self.text = text
        self.tone = tone
    }
}

/// Builds the widget snapshot from what the menu already shows, so the widget
/// can never disagree with the account cards about status or advice.
public enum WidgetSnapshotBuilder {
    public struct AccountInput: Sendable {
        public var profile: AccountProfile
        public var snapshot: UsageSnapshot?
        public var presentation: AccountRowPresentation
        public var readings: [String: [BurnRateEstimator.Reading]]
        public var estimates: [String: BurnRateEstimate]

        public init(
            profile: AccountProfile,
            snapshot: UsageSnapshot?,
            presentation: AccountRowPresentation,
            readings: [String: [BurnRateEstimator.Reading]] = [:],
            estimates: [String: BurnRateEstimate] = [:]
        ) {
            self.profile = profile
            self.snapshot = snapshot
            self.presentation = presentation
            self.readings = readings
            self.estimates = estimates
        }
    }

    /// - Parameters:
    ///   - accounts: In repository (switch-priority) order.
    ///   - bestNextIDs: The advised switch target per provider.
    public static func build(
        accounts: [AccountInput],
        bestNextIDs: [Provider: UUID],
        showsUsageCurves: Bool,
        now: Date = Date()
    ) -> WidgetSnapshot {
        var ordered: [WidgetAccount] = []
        for provider in Provider.allCases {
            let providerAccounts = accounts.filter { $0.profile.provider == provider }
            let activeFirst = providerAccounts.filter(\.profile.isActiveCLI)
                + providerAccounts.filter { !$0.profile.isActiveCLI }
            ordered += activeFirst.map {
                account($0, isBestNext: bestNextIDs[provider] == $0.profile.id, showsUsageCurves: showsUsageCurves, now: now)
            }
        }
        return WidgetSnapshot(generatedAt: now, accounts: ordered, showsUsageCurves: showsUsageCurves)
    }

    static func account(
        _ input: AccountInput,
        isBestNext: Bool,
        showsUsageCurves: Bool,
        now: Date
    ) -> WidgetAccount {
        let presentation = input.presentation
        let isStale = input.snapshot.map { $0.isStale(asOf: now) } ?? true
        let windows = presentation.gauges.visible.map { window -> WidgetWindow in
            let depletesAt: Date?
            if case .depletesAt(let date)? = input.estimates[window.id] {
                depletesAt = date
            } else {
                depletesAt = nil
            }
            let runway = showsUsageCurves
                ? input.readings[window.id].flatMap {
                    UsageRunwayBuilder(maximumPoints: 32).runway(
                        window: window,
                        readings: $0,
                        depletesAt: depletesAt,
                        showsPace: presentation.showsPace,
                        now: now
                    )
                }
                : nil
            return WidgetWindow(
                id: window.id,
                kind: window.kind,
                label: shortLabel(for: window),
                usedPercent: window.usedPercent,
                resetDate: window.resetDate,
                riskLevel: isStale
                    ? .stale
                    : min(window.riskLevel, UsageThresholds.standard.riskLevel(usedPercent: window.usedPercent)),
                runway: runway
            )
        }
        return WidgetAccount(
            id: input.profile.id,
            provider: input.profile.provider,
            label: input.profile.label,
            planLabel: input.profile.planLabel,
            isActive: input.profile.isActiveCLI,
            isBestNext: isBestNext,
            lastRefreshed: input.snapshot?.lastRefreshed,
            note: note(for: presentation, now: now),
            windows: windows
        )
    }

    /// The most important single line from the account card: a login or
    /// refresh problem first, then a billing badge, then the pace forecast,
    /// then the footer note (reset passed, link this account).
    static func note(for presentation: AccountRowPresentation, now: Date) -> WidgetNote? {
        if let problem = presentation.rowMessages.first {
            return WidgetNote(text: problem.text, tone: problem.tone)
        }
        if let badge = presentation.billingBadge {
            return WidgetNote(text: badge.text == "PAYG" ? "Pay-as-you-go billing" : badge.text, tone: badge.tone)
        }
        if let forecast = presentation.paceForecast,
           let pace = UsageResetTiming.compactPaceText(depletesAt: forecast.depletesAt, now: now) {
            let label = presentation.gauges.visible
                .first { $0.id == forecast.windowID }
                .map(shortLabel(for:)) ?? forecast.windowLabel
            return WidgetNote(text: "\(label) \(pace)", tone: .warning)
        }
        if let footer = presentation.footerNote, footer.tone != .secondary || footer.text.hasPrefix("Log in") {
            return WidgetNote(text: footer.text, tone: footer.tone)
        }
        return nil
    }

    static func shortLabel(for window: UsageWindow) -> String {
        switch window.kind {
        case .session:
            return "Session"
        case .weekly:
            return "Week"
        case .weeklyScoped:
            let label = window.label
            if let opening = label.firstIndex(of: "("),
               label.last == ")",
               opening < label.index(before: label.endIndex) {
                let scope = label[label.index(after: opening)..<label.index(before: label.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                if !scope.isEmpty {
                    return scope.prefix(1).uppercased() + scope.dropFirst()
                }
            }
            return label
        case .other:
            return window.label
        }
    }
}

/// Reads and writes `Widget/widget-snapshot.json` under the app variant's
/// Application Support directory.
public struct WidgetSnapshotStore: Sendable {
    public let url: URL

    public init(applicationSupportDirectory: URL) {
        self.url = applicationSupportDirectory
            .appendingPathComponent(WidgetSnapshot.directoryName, isDirectory: true)
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    /// The real `~/Library/Application Support/<name>` even inside the
    /// widget's sandbox, where `FileManager` would return the container.
    public static func realApplicationSupportDirectory(named name: String) -> URL? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.appDecoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version <= WidgetSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.appEncoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
