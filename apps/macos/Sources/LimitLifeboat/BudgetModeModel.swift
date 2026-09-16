import Foundation
import LimitLifeboatCore

/// App-side state for Claude Code budget modes. The settings file is the
/// source of truth, so status is re-read rather than cached across edits.
@MainActor
final class BudgetModeModel: ObservableObject {
    @Published private(set) var status: BudgetModeStatus = .active(.quality)
    @Published private(set) var error: String?

    private let controller: BudgetModeController

    init(applicationSupportDirectory: URL) {
        controller = BudgetModeController(
            recordURL: applicationSupportDirectory.appendingPathComponent(BudgetModeController.recordFileName)
        )
        reload()
    }

    func reload() {
        do {
            status = try controller.status()
            error = nil
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
            self.error = error.localizedDescription
            reload()
            return false
        }
    }
}
