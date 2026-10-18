import Foundation

/// The read commands of the `limit-lifeboat` CLI whose output is a rendering
/// of `CLIStatusReport`.
public enum CLIReadCommand: String, CaseIterable, Sendable {
    /// Every saved account with its most recent reading.
    case status
    /// Saved accounts, without usage.
    case list
    /// Only the account each provider's CLI is logged into.
    case active
}

/// Renders `status`, `list` and `active`, in text or JSON.
///
/// Lives in Core rather than in the CLI's `main.swift` so it can be tested
/// directly: 1.1.18 shipped with this code dropped from `main.swift`, and the
/// three commands exited 0 having printed nothing. Always returns non-empty
/// text, so the caller prints exactly one thing.
public enum CLIReadCommandOutput {
    public enum RenderError: Error, Equatable {
        case encodingFailed
    }

    public static func render(
        _ command: CLIReadCommand,
        report: CLIStatusReport,
        json: Bool,
        now: Date = Date()
    ) throws -> String {
        let accounts = command == .active ? report.accounts.filter(\.isActive) : report.accounts

        if json {
            let filtered = CLIStatusReport(generatedAt: report.generatedAt, accounts: accounts)
            guard let data = try? JSONEncoder.appEncoder.encode(filtered),
                  let text = String(data: data, encoding: .utf8) else {
                throw RenderError.encodingFailed
            }
            return text
        }

        guard !accounts.isEmpty else {
            // Not an error: a fresh install with no accounts yet is a normal
            // state, and a script calling this should not see a failure.
            return report.accounts.isEmpty
                ? "No accounts saved yet. Log in with `claude` or `codex login`, then open Limit Lifeboat."
                : "No account is currently active."
        }

        var lines: [String] = []
        for account in accounts {
            let marker = account.isActive ? "*" : " "
            let identity = account.email ?? account.organization ?? account.plan ?? ""
            let name = identity.isEmpty ? account.label : "\(account.label) (\(identity))"
            lines.append("\(marker) [\(account.provider)] \(name)")

            guard command != .list else { continue }

            guard let reading = account.reading else {
                lines.append("      no reading yet")
                continue
            }

            for window in reading.windows {
                let resets = window.resetsAt.map {
                    " · \(UsageResetTiming.compactText(resetDate: $0, resetDescription: nil, now: now) ?? "")"
                } ?? ""
                lines.append("      \(window.label): \(window.usedPercent)% used [\(window.risk)]\(resets)")
            }
            if let extra = reading.extraUsage {
                lines.append("      \(extra)")
            }
            lines.append("      updated \(DurationPhrase.short(TimeInterval(reading.ageSeconds))) ago via \(reading.source)")
        }
        return lines.joined(separator: "\n")
    }
}
