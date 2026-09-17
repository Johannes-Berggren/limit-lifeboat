import Foundation
import LimitLifeboatCore

/// App-side state for Claude Code budget modes. The settings file is the
/// source of truth, so status is re-read rather than cached across edits.
@MainActor
final class BudgetModeModel: ObservableObject {
    @Published private(set) var status: BudgetModeStatus = .active(.quality)
    @Published private(set) var error: String?
    /// Set when the stored record is unreadable — the one failure the user
    /// can clear themselves.
    @Published private(set) var canForgetRecord = false

    private let controller: BudgetModeController

    init(applicationSupportDirectory: URL) {
        controller = BudgetModeController(
            recordURL: applicationSupportDirectory.appendingPathComponent(BudgetModeController.recordFileName)
        )
        reload()
    }

    var recordPath: String { controller.recordPath }

    func reload() {
        do {
            status = try controller.status()
            error = nil
            canForgetRecord = false
        } catch {
            self.error = error.localizedDescription
            canForgetRecord = error is BudgetModeController.ControllerError
        }
    }

    func forgetRecord() {
        do {
            try controller.forgetRecord()
            canForgetRecord = false
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func apply(_ mode: BudgetMode) -> Bool {
        do {
            try controller.apply(mode)
            status = try controller.status()
            error = nil
            return true
        } catch {
            // Refresh what is shown without clearing the failure just set.
            if let current = try? controller.status() {
                status = current
            }
            self.error = error.localizedDescription
            canForgetRecord = error is BudgetModeController.ControllerError
            return false
        }
    }
}
