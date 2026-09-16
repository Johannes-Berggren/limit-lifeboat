import Foundation

/// Opinionated presets for Claude Code's token use, written to its user
/// settings. Every value here is a documented settings key; see
/// code.claude.com/docs/en/settings-reference and /advisor.
public enum BudgetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Leaves Claude Code's own settings alone.
    case quality
    /// Keeps the chosen main model but caps effort and runs subagents on Sonnet.
    case balanced
    /// Sonnet does the work and consults Opus at decision points; effort is
    /// capped at medium and subagents run on Haiku.
    case frugal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quality:
            return "Quality"
        case .balanced:
            return "Balanced"
        case .frugal:
            return "Frugal"
        }
    }

    public var summary: String {
        switch self {
        case .quality:
            return "Your Claude Code settings as they are."
        case .balanced:
            return "Keeps your model. Caps effort at high (no xhigh or max) and runs subagents on Sonnet."
        case .frugal:
            return "Sonnet as the main model with Opus as advisor at key decisions. Caps effort at medium and runs subagents on Haiku."
        }
    }

    public var values: [BudgetSettingKey: String] {
        switch self {
        case .quality:
            return [:]
        case .balanced:
            return [.maxEffortLevel: "high", .subagentModel: "sonnet"]
        case .frugal:
            return [.model: "sonnet", .advisorModel: "opus", .maxEffortLevel: "medium", .subagentModel: "haiku"]
        }
    }

    /// The next step down, or nil when already the cheapest.
    public var cheaper: BudgetMode? {
        switch self {
        case .quality:
            return .balanced
        case .balanced:
            return .frugal
        case .frugal:
            return nil
        }
    }
}

public enum BudgetSettingKey: String, Codable, CaseIterable, Sendable {
    case model
    case advisorModel
    case maxEffortLevel
    case subagentModel = "env.CLAUDE_CODE_SUBAGENT_MODEL"

    fileprivate var path: [String] {
        rawValue.split(separator: ".").map(String.init)
    }
}

/// What Limit Lifeboat changed, so it can be undone precisely.
public struct BudgetModeRecord: Codable, Equatable, Sendable {
    public let mode: BudgetMode
    /// Key raw value → the value Limit Lifeboat wrote.
    public let applied: [String: String]
    /// Key raw value → JSON of the value it replaced. Absent keys were unset.
    public let previous: [String: String]
}

public enum BudgetModeStatus: Equatable, Sendable {
    case active(BudgetMode)
    /// A mode was applied, but some of its values were changed since.
    case modified(BudgetMode)

    public var mode: BudgetMode {
        switch self {
        case .active(let mode), .modified(let mode):
            return mode
        }
    }
}

public struct BudgetModeApplier: Sendable {
    public init() {}

    public func status(settings: [String: Any], record: BudgetModeRecord?) -> BudgetModeStatus {
        guard let record else { return .active(.quality) }
        let intact = record.applied.allSatisfy { key, value in
            BudgetSettingKey(rawValue: key).map { get($0, in: settings) as? String == value } ?? false
        }
        return intact ? .active(record.mode) : .modified(record.mode)
    }

    /// Restores what the previous mode replaced — except values the user has
    /// changed since, which are theirs now — then applies `mode`.
    public func apply(
        _ mode: BudgetMode,
        to settings: inout [String: Any],
        replacing record: BudgetModeRecord?
    ) -> BudgetModeRecord? {
        if let record {
            for (rawKey, appliedValue) in record.applied {
                guard let key = BudgetSettingKey(rawValue: rawKey),
                      get(key, in: settings) as? String == appliedValue else {
                    continue
                }
                let previous = record.previous[rawKey].flatMap(decode)
                set(key, to: previous, in: &settings)
            }
        }

        let values = mode.values
        guard !values.isEmpty else { return nil }

        var applied: [String: String] = [:]
        var previous: [String: String] = [:]
        for (key, value) in values {
            if let existing = get(key, in: settings), let json = encode(existing) {
                previous[key.rawValue] = json
            }
            set(key, to: value, in: &settings)
            applied[key.rawValue] = value
        }
        return BudgetModeRecord(mode: mode, applied: applied, previous: previous)
    }

    private func get(_ key: BudgetSettingKey, in settings: [String: Any]) -> Any? {
        var current: Any? = settings
        for component in key.path {
            current = (current as? [String: Any])?[component]
        }
        return current
    }

    private func set(_ key: BudgetSettingKey, to value: Any?, in settings: inout [String: Any]) {
        let path = key.path
        guard path.count == 2 else {
            settings[path[0]] = value
            return
        }
        var parent = settings[path[0]] as? [String: Any] ?? [:]
        parent[path[1]] = value
        settings[path[0]] = parent.isEmpty ? nil : parent
    }

    private func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decode(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }
}

/// Applies budget modes to a Claude Code settings file and remembers what it
/// replaced in Limit Lifeboat's own store.
public struct BudgetModeController {
    public enum ControllerError: LocalizedError, Equatable {
        case unreadableRecord

        public var errorDescription: String? {
            switch self {
            case .unreadableRecord:
                return "Limit Lifeboat's record of your previous Claude Code settings could not be read, so budget modes were left unchanged rather than risk losing those settings."
            }
        }
    }

    public static let recordFileName = "budget-mode.json"

    private let file: ClaudeSettingsFile
    private let recordURL: URL
    private let applier = BudgetModeApplier()

    public init(file: ClaudeSettingsFile = ClaudeSettingsFile(), recordURL: URL) {
        self.file = file
        self.recordURL = recordURL
    }

    public func status() throws -> BudgetModeStatus {
        applier.status(settings: try file.read(), record: try loadRecord())
    }

    /// The record of what was replaced is the only way back to the user's own
    /// values, so it is written *before* the settings, and restored if the
    /// settings write then fails.
    public func apply(_ mode: BudgetMode) throws {
        var settings = try file.read()
        let previousRecordData = try? Data(contentsOf: recordURL)
        let record = applier.apply(mode, to: &settings, replacing: try loadRecord())

        if let record {
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        } else if previousRecordData != nil {
            try FileManager.default.removeItem(at: recordURL)
        }

        do {
            try file.write(settings)
        } catch {
            if let previousRecordData {
                try? previousRecordData.write(to: recordURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: recordURL)
            }
            throw error
        }
    }

    /// A missing record means no mode is applied. A record that exists but
    /// does not decode is an error: treating it as absent would make the next
    /// apply record the mode's own values as the user's originals.
    private func loadRecord() throws -> BudgetModeRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(BudgetModeRecord.self, from: Data(contentsOf: recordURL))
        } catch {
            throw ControllerError.unreadableRecord
        }
    }
}

public enum BudgetSuggestionPolicy {
    /// When the active Claude account is on pace to run out and no saved
    /// account has room to switch to, the next cheaper mode is the remaining
    /// lever. Nothing to suggest once already at the cheapest.
    public static func suggestion(
        provider: Provider,
        current: BudgetModeStatus,
        hasPaceAlert: Bool,
        hasSwitchCandidate: Bool
    ) -> BudgetMode? {
        guard provider == .claude, hasPaceAlert, !hasSwitchCandidate else { return nil }
        return current.mode.cheaper
    }
}
