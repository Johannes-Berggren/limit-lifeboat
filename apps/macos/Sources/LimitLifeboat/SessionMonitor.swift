import AppKit
import Foundation
import LimitLifeboatCore

/// A census row: the process-tree view of a session plus, for Claude, what its
/// transcript says about model, context size and last activity.
struct AgentSessionRow: Identifiable, Equatable {
    let session: AgentSession
    let activity: ClaudeSessionActivity?

    var id: Int32 { session.id }
}

/// Watches running Claude Code / Codex sessions and system memory, and warns
/// before starting another session is likely to exhaust the Mac's memory.
@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var rows: [AgentSessionRow] = []
    @Published private(set) var memory: SystemMemoryStatus?
    @Published private(set) var assessment: MemoryGuardAssessment = .empty

    private let settings: SettingsStore
    private let notify: (MemoryGuardAssessment) -> Void
    private let policy = MemoryGuardPolicy()
    private let planner = MemoryGuardAlertPlanner()
    private var lastNotified: MemoryGuardAlertPlanner.Record?
    private var scanTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isScanning = false

    init(settings: SettingsStore, notify: @escaping (MemoryGuardAssessment) -> Void) {
        self.settings = settings
        self.notify = notify
    }

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                // Cheap enough to watch closely while agents run; otherwise
                // only a slow heartbeat until the next session appears.
                let busy = self.map { !$0.rows.isEmpty || $0.assessment.level > .ok } ?? false
                try? await Task.sleep(nanoseconds: UInt64(busy ? 20 : 90) * 1_000_000_000)
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
        source.resume()
        pressureSource = source
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let (rows, memory) = await Task.detached(priority: .utility) {
            Self.readCensus(excluding: ownPID)
        }.value

        let now = Date()
        self.rows = rows
        self.memory = memory
        guard let memory else { return }

        var lastActivity: [Int32: Date] = [:]
        for row in rows {
            if let activity = row.activity {
                lastActivity[row.id] = activity.lastActivityAt
            }
        }
        let assessment = policy.assess(
            memory: memory,
            sessions: rows.map(\.session),
            lastActivity: lastActivity,
            now: now
        )
        self.assessment = assessment

        if assessment.level == .ok {
            lastNotified = nil
        } else if settings.memoryGuardAlertsEnabled,
                  planner.shouldNotify(assessment, lastNotified: lastNotified, now: now) {
            lastNotified = .init(level: assessment.level, notifiedAt: now)
            notify(assessment)
        }
    }

    func revealInFinder(_ row: AgentSessionRow) {
        guard let directory = row.session.workingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    /// SIGTERM lets the CLI shut down its children and flush the transcript,
    /// so the conversation can be resumed later. Never automatic.
    func confirmAndQuit(_ row: AgentSessionRow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(row.session.provider.displayName) session in \(row.session.projectName)?"
        alert.informativeText = "This frees about \(MemoryFormatting.bytes(row.session.footprintBytes)). Any work in progress in that session stops; the conversation can be resumed later with --resume."
        alert.addButton(withTitle: "Quit Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModalActivating() == .alertFirstButtonReturn else { return }
        kill(row.session.pid, SIGTERM)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await scan()
        }
    }

    nonisolated private static func readCensus(excluding ownPID: Int32) -> ([AgentSessionRow], SystemMemoryStatus?) {
        let table = SystemProcessTable()
        let sessions = AgentSessionCensusBuilder().sessions(
            from: table.records(),
            excludingDescendantsOf: ownPID,
            workingDirectory: table.workingDirectory(pid:)
        )
        return (attachActivity(to: sessions), SystemMemoryReader().read())
    }

    /// Sessions sharing a working directory also share a transcript folder;
    /// pair each with the newest unclaimed transcript touched since it started,
    /// newest session first.
    nonisolated private static func attachActivity(to sessions: [AgentSession]) -> [AgentSessionRow] {
        let reader = ClaudeTranscriptReader()
        var claimed: Set<URL> = []
        var activity: [Int32: ClaudeSessionActivity] = [:]
        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard session.provider == .claude, let directory = session.workingDirectory else { continue }
            let transcript = reader
                .recentTranscripts(workingDirectory: directory, since: session.startedAt)
                .first { !claimed.contains($0) }
            if let transcript {
                claimed.insert(transcript)
                activity[session.pid] = reader.activity(transcript: transcript)
            }
        }
        return sessions.map { AgentSessionRow(session: $0, activity: activity[$0.pid]) }
    }
}
