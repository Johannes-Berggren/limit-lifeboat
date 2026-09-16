import LimitLifeboatCore
import SwiftUI

/// Popover section listing running agent sessions with their memory, and a
/// banner when memory is too tight to start another one.
struct SessionsSectionView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var isExpanded = false

    private static let collapsedRowLimit = 3

    var body: some View {
        let assessment = monitor.assessment
        let rows = monitor.rows
        let visibleRows = isExpanded ? rows : Array(rows.prefix(Self.collapsedRowLimit))

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Label("Agent sessions", systemImage: "memorychip")
                    .font(.system(size: 14, weight: .semibold))

                Text(summary(assessment))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Badge(text: levelText(assessment.level), color: levelColor(assessment.level))
            }

            if assessment.level > .ok {
                StatusBanner(
                    text: bannerText(assessment),
                    systemImage: "exclamationmark.triangle.fill",
                    color: levelColor(assessment.level)
                )
            }

            if !rows.isEmpty {
                VStack(spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(spacing: 0) {
                            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 {
                                    Divider()
                                }
                                sessionRow(row, now: context.date)
                            }
                        }
                    }

                    if rows.count > Self.collapsedRowLimit {
                        Divider()
                        Button(isExpanded ? "Show fewer" : "Show all \(rows.count)") {
                            isExpanded.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.vertical, DS.Spacing.sm)
                    }
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, DS.Spacing.xs)
                .cardSurface()
            }
        }
    }

    private func sessionRow(_ row: AgentSessionRow, now: Date) -> some View {
        let session = row.session
        return HStack(spacing: DS.Spacing.md) {
            Image(systemName: DS.providerSymbol(session.provider))
                .foregroundStyle(DS.providerAccent(session.provider))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(row, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(session.workingDirectory ?? "")

            Spacer(minLength: DS.Spacing.sm)

            Text(MemoryFormatting.bytes(session.footprintBytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("\(session.processCount) processes, including tools and servers the session started")

            Menu {
                Button("Reveal in Finder") { monitor.revealInFinder(row) }
                    .disabled(session.workingDirectory == nil)
                Divider()
                Button("Quit Session…") { monitor.confirmAndQuit(row) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.Spacing.sm)
    }

    private func detail(_ row: AgentSessionRow, now: Date) -> String {
        var parts: [String] = []
        if let activity = row.activity {
            if let model = activity.model {
                parts.append(shortModelName(model))
            }
            if activity.contextTokens > 0 {
                parts.append("\(MemoryFormatting.tokens(activity.contextTokens)) context")
            }
            let idle = now.timeIntervalSince(activity.lastActivityAt)
            parts.append(idle < 120 ? "active" : "idle \(MemoryFormatting.duration(idle))")
        } else {
            parts.append(row.session.provider.displayName)
            parts.append("running \(MemoryFormatting.duration(now.timeIntervalSince(row.session.startedAt)))")
        }
        return parts.joined(separator: " · ")
    }

    /// "claude-opus-5" → "Opus 5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    private func shortModelName(_ model: String) -> String {
        var components = model.split(separator: "-").map(String.init)
        if components.first == "claude" {
            components.removeFirst()
        }
        components.removeAll { $0.count >= 8 && $0.allSatisfy(\.isNumber) }
        guard let family = components.first else { return model }
        let version = components.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    private func summary(_ assessment: MemoryGuardAssessment) -> String {
        let count = monitor.rows.count
        guard count > 0 else { return "none running" }
        return "\(count) · \(MemoryFormatting.bytes(assessment.sessionFootprintBytes))"
    }

    private func bannerText(_ assessment: MemoryGuardAssessment) -> String {
        var text = assessment.level == .critical
            ? "Memory is critically low. Close a session before starting another, or your Mac may freeze."
            : "Memory is tight. Starting another session may slow your Mac down."
        if let idle = assessment.heaviestIdleSession {
            text += " \(idle.projectName) is idle and uses \(MemoryFormatting.bytes(idle.footprintBytes))."
        }
        return text
    }

    private func levelText(_ level: MemoryGuardLevel) -> String {
        switch level {
        case .ok:
            guard let estimate = monitor.assessment.estimatedAdditionalSessions else {
                return "Memory OK"
            }
            return estimate >= 10 ? "Room for 10+" : "Room for ~\(estimate)"
        case .caution:
            return "Memory tight"
        case .critical:
            return "Memory critical"
        }
    }

    private func levelColor(_ level: MemoryGuardLevel) -> Color {
        switch level {
        case .ok:
            return DS.success
        case .caution:
            return DS.warning
        case .critical:
            return DS.danger
        }
    }
}
