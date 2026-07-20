import AppKit
import Combine
import Foundation
import LimitLifeboatCore
@preconcurrency import Sparkle

enum AppInfo {
    /// "dev" for unbundled `swift run` builds.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

/// Owns Sparkle's updater and adapts its standard UI to a dockless menu-bar app.
/// Scheduled checks only reveal the app's existing update affordance; an update
/// window is shown after an explicit user action.
@MainActor
final class AppUpdater: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    let isEnabled: Bool

    private var cancellables: Set<AnyCancellable> = []
    private var updateUIIsActive = false
    private var controller: SPUStandardUpdaterController?

    override init() {
        self.isEnabled = ApplicationVariant.current.supportsUpdates
        super.init()

        guard isEnabled else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.controller = controller
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates, options: [.new])
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates, options: [.new])
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else {
            return
        }

        updateUIIsActive = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        isEnabled
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            availableVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        if updateUIIsActive {
            updateUIIsActive = false
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
