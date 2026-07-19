import Foundation

/// Serializes usage history to CSV for analysis outside the app. Deliberately
/// excludes identity fields (emails, organizations) — the export carries the
/// user-chosen account label only, matching the diagnostics privacy stance.
public struct UsageHistoryCSVExporter: Sendable {
    public struct AccountDescriptor: Equatable, Sendable {
        public var label: String
        public var provider: Provider

        public init(label: String, provider: Provider) {
            self.label = label
            self.provider = provider
        }
    }

    public static let header = "timestamp,account_id,account_label,provider,window_id,window_kind,used_percent,reset_at,window_minutes"

    public init() {}

    /// One row per (record, window). Deterministic ordering: accounts by
    /// uuidString (mirroring the history store's rewrite order), records
    /// chronological within an account.
    public func csv(
        records: [UUID: [UsageHistoryRecord]],
        accounts: [UUID: AccountDescriptor]
    ) -> String {
        var lines = [Self.header]
        let orderedAccountIDs = records.keys.sorted { $0.uuidString < $1.uuidString }
        for accountID in orderedAccountIDs {
            let descriptor = accounts[accountID]
            let ordered = (records[accountID] ?? []).sorted { $0.timestamp < $1.timestamp }
            for record in ordered {
                for window in record.windows {
                    lines.append(row(record: record, window: window, accountID: accountID, descriptor: descriptor))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func row(
        record: UsageHistoryRecord,
        window: UsageWindowReading,
        accountID: UUID,
        descriptor: AccountDescriptor?
    ) -> String {
        [
            Self.timestampFormatter.string(from: record.timestamp),
            accountID.uuidString,
            escaped(descriptor?.label ?? "unknown"),
            descriptor?.provider.rawValue ?? "unknown",
            escaped(window.id),
            window.kind.rawValue,
            formatNumber(window.usedPercent),
            window.resetDate.map(Self.timestampFormatter.string(from:)) ?? "",
            window.windowMinutes.map(String.init) ?? ""
        ].joined(separator: ",")
    }

    /// Minimal RFC-4180 quoting: labels are user-editable and may contain
    /// commas, quotes, or newlines.
    private func escaped(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static let timestampFormatter = ISO8601DateFormatter()
}
