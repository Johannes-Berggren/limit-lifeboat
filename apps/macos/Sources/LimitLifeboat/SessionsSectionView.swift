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

                if !monitor.parked.isEmpty {
                    Button {
                        monitor.resumeAll()
                    } label: {
                        Label("\(monitor.parked.count) parked · Resume all", systemImage: "play.circle")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.warning)
                    .help("Let every parked session continue")
                    .transition(.opacity)
                }

                // Without agents running, tight memory is not this section's
                // concern; say nothing rather than urge closing a session.
                let shownLevel: MemoryGuardLevel = assessment.isActionable ? assessment.level : .ok
                Badge(text: levelText(shownLevel), color: levelColor(shownLevel))
            }

            if assessment.isActionable {
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
        let isParked = monitor.parked[row.id] != nil
        let isStarred = monitor.isStarred(row)
        return HStack(spacing: DS.Spacing.md) {
            Image(systemName: DS.providerSymbol(session.provider))
                .foregroundStyle(DS.providerAccent(session.provider))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    starButton(row, isStarred: isStarred)
                }
                Text(isParked ? parkedDetail(row, now: now) : detail(row, now: now))
                    .font(.caption2)
                    .foregroundStyle(isParked ? AnyShapeStyle(DS.warning) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .help(session.workingDirectory ?? "")

            Spacer(minLength: DS.Spacing.sm)

            if isParked {
                Button("Resume") { monitor.resume(row.id) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .help("Let this session continue")
                    .transition(.opacity)
            }

            Text(MemoryFormatting.bytes(session.footprintBytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("\(session.processCount) processes, including tools and servers the session started")

            Menu {
                if monitor.canPark(row) {
                    if isParked {
                        Button("Resume Session") { monitor.resume(row.id) }
                    } else {
                        Button("Park at Next Step") { monitor.park(pids: [row.id], reason: .manual) }
                            .disabled(isStarred)
                    }
                }
                Button(isStarred ? "Unmark as Important" : "Mark as Important") {
                    monitor.setStarred(!isStarred, for: row)
                }
                .disabled(session.workingDirectory == nil)
                Divider()
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
        .opacity(isParked ? 0.72 : 1)
        .animation(DS.Motion.quick, value: isParked)
    }

    /// Important projects keep going when quota runs short; everything else
    /// may be parked. A faint outline until set, so it reads as optional.
    private func starButton(_ row: AgentSessionRow, isStarred: Bool) -> some View {
        Button {
            monitor.setStarred(!isStarred, for: row)
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isStarred ? AnyShapeStyle(DS.warning) : AnyShapeStyle(.quaternary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(row.session.workingDirectory == nil)
        .help(isStarred
            ? "Important: never parked to save quota. Click to unmark."
            : "Mark as important: never parked to save quota")
        .accessibilityLabel(isStarred ? "Unmark as important" : "Mark as important")
    }

    private func parkedDetail(_ row: AgentSessionRow, now: Date) -> String {
        var text = monitor.waitingPIDs.contains(row.id)
            ? "Parked · waiting to resume"
            : "Parked · stops at its next step"
        if let releaseAt = monitor.parked[row.id]?.releaseAt, releaseAt > now {
            text += " · resumes in \(DurationPhrase.short(releaseAt.timeIntervalSince(now)))"
        }
        return text
    }

    private func detail(_ row: AgentSessionRow, now: Date) -> String {
        var parts: [String] = []
        if let activity = row.activity {
            if let model = activity.model {
                parts.append(ModelNaming.short(model))
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
