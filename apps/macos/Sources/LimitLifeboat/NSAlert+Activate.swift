import AppKit

extension NSAlert {
    /// Runs the alert app-modally after bringing this menu-bar (`.accessory`) app
    /// to the front, so the dialog is guaranteed to appear above the popover and
    /// other apps rather than behind them.
    @discardableResult
    func runModalActivating() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}
