import Combine
import Foundation
import Sparkle

struct AppUpdate: Equatable {
    let version: String
}

@MainActor
final class AppUpdateService: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdateService()

    @Published private(set) var availableUpdate: AppUpdate?
    @Published private(set) var automaticUpdatesEnabled: Bool

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    private override init() {
        automaticUpdatesEnabled = true
        super.init()

        // Creating the controller starts Sparkle and resolves the persisted
        // preference that takes precedence over the Info.plist default.
        _ = updaterController
        automaticUpdatesEnabled = updaterController.updater.automaticallyChecksForUpdates

        let environment = ProcessInfo.processInfo.environment
        if environment["CANDOA_UI_TESTING"] == "1",
           let version = environment["CANDOA_UI_TESTING_UPDATE_VERSION"] {
            availableUpdate = AppUpdate(version: version)
        }
    }

    func startCheckingForUpdates() {
        // Sparkle owns its automatic check schedule via Info.plist settings.
    }

    func stopCheckingForUpdates() {
        // Keep Sparkle's updater alive for the process lifetime.
    }

    func openAvailableUpdate() {
        checkForUpdates()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticUpdatesEnabled(_ isEnabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = isEnabled
        updaterController.updater.automaticallyDownloadsUpdates = isEnabled
        automaticUpdatesEnabled = isEnabled
    }

    // MARK: - Sparkle gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool {
        true
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
        availableUpdate = AppUpdate(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // Deliberately keep `availableUpdate` set: the update is still
        // pending, so the banner must survive a dismissed or postponed
        // Sparkle dialog. It only leaves the sidebar when the update
        // installs (the app relaunches) or the process ends.
    }
}
