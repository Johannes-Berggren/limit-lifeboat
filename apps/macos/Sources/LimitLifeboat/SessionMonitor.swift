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
    @Published private(set) var isPromptHookInstalled = false
    @Published private(set) var promptHookError: String?

    private let settings: SettingsStore
    private let stateDirectory: URL
    private let hookInstaller = ClaudeHookInstaller()
    private let notify: (MemoryGuardAssessment) -> Void
    private let policy = MemoryGuardPolicy()
    private let planner = MemoryGuardAlertPlanner()
    private var lastNotified: MemoryGuardAlertPlanner.Record?
    private var scanTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isScanning = false
    /// A scan requested while one is running — above all a memory-pressure
    /// event — runs as soon as it finishes instead of being dropped.
    private var rescanRequested = false

    init(
        settings: SettingsStore,
        stateDirectory: URL,
        notify: @escaping (MemoryGuardAssessment) -> Void
    ) {
        self.settings = settings
        self.stateDirectory = stateDirectory
        self.notify = notify
    }

    private var stateFileURL: URL {
        stateDirectory.appendingPathComponent(MemoryGuardState.fileName)
    }

    private var hookScriptURL: URL {
        stateDirectory.appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(MemoryGuardHookScript.fileName)
    }

    func start() {
        guard scanTask == nil else { return }
        isPromptHookInstalled = hookInstaller.isInstalled()
        if isPromptHookInstalled {
            // Keep an installed script current with this build's version.
            try? writeHookScript()
        }
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
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }

        repeat {
            rescanRequested = false
            await performScan()
        } while rescanRequested
    }

    private func performScan() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let (rows, memory) = await Task.detached(priority: .utility) {
            Self.readCensus(excluding: ownPID)
        }.value

        let now = Date()
        // Publish rows and assessment together: fresh rows beside a stale or
        // empty assessment would read as "11 sessions · 0 MB · Memory OK".
        guard let memory else { return }
        self.rows = rows
        self.memory = memory

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
        try? MemoryGuardState(assessment: assessment, now: now).write(to: stateFileURL)

        if assessment.level == .ok {
            lastNotified = nil
        } else if settings.memoryGuardAlertsEnabled,
                  planner.shouldNotify(assessment, lastNotified: lastNotified, now: now) {
            lastNotified = .init(level: assessment.level, notifiedAt: now)
            notify(assessment)
        }
    }

    /// Adds or removes the Claude Code hook that holds new sessions while
    /// memory is critical. Touches only Limit Lifeboat's own hook entry.
    func setPromptHookInstalled(_ installed: Bool) {
        promptHookError = nil
        do {
            if installed {
                try writeHookScript()
                try hookInstaller.install(scriptPath: hookScriptURL.path)
            } else {
                try hookInstaller.uninstall()
            }
        } catch {
            promptHookError = error.localizedDescription
        }
        isPromptHookInstalled = hookInstaller.isInstalled()
    }

    private func writeHookScript() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: hookScriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = MemoryGuardHookScript.contents(
            stateFile: stateFileURL,
            heldDirectory: stateDirectory.appendingPathComponent("hooks/held", isDirectory: true)
        )
        try Data(script.utf8).write(to: hookScriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
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
        // The row can be a scan old and the dialog sat open; never signal a
        // pid that has since exited and been reused by something else.
        guard SystemProcessTable().isStillRunning(row.session) else {
            Task { await scan() }
            return
        }
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
        let activities = ClaudeTranscriptReader().activities(for: sessions)
        let rows = sessions.map { AgentSessionRow(session: $0, activity: activities[$0.pid]) }
        return (rows, SystemMemoryReader().read())
    }
}
