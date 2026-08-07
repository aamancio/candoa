import Combine
import Foundation
import Sparkle

struct AppUpdate: Equatable {
    let version: String
}

/// Drives Sparkle with a custom user driver so the sidebar banner is the whole
/// update UI: scheduled checks surface the pill quietly, and activating it
/// downloads, installs, and relaunches in one click — no Sparkle alerts.
@MainActor
final class AppUpdateService: NSObject, ObservableObject {
    static let shared = AppUpdateService()

    @Published private(set) var availableUpdate: AppUpdate?
    @Published private(set) var isInstallingUpdate = false
    @Published private(set) var automaticUpdatesEnabled: Bool

    /// Reply Sparkle is waiting on for an update it surfaced. Holding it keeps
    /// the session resumable, so the banner can answer `.install` later
    /// without a second appcast round-trip.
    private var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    private var installOnNextUpdateFound = false
    private let isUITestingFixture: Bool
    /// Development builds carry the repo's placeholder version stamp (CI
    /// writes the real one at release), so the production appcast always
    /// looks newer than a local build. Debug runs the updater only against
    /// an explicit feed override (the localhost E2E recipe's `-SUFeedURL`).
    private let isUpdaterActive: Bool

    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: self,
        delegate: nil
    )

    private override init() {
        let environment = ProcessInfo.processInfo.environment
        isUITestingFixture = environment["CANDOA_UI_TESTING"] == "1"
#if DEBUG
        isUpdaterActive = !isUITestingFixture
            && UserDefaults.standard.string(forKey: "SUFeedURL") != nil
#else
        isUpdaterActive = !isUITestingFixture
#endif
        automaticUpdatesEnabled = true
        super.init()

        if isUITestingFixture {
            // Keep UI-test runs hermetic: the fixture below fakes the banner
            // and the updater never touches the network.
            if let version = environment["CANDOA_UI_TESTING_UPDATE_VERSION"] {
                availableUpdate = AppUpdate(version: version)
            }
        } else if isUpdaterActive {
            do {
                try updater.start()
            } catch {
                NSLog("Sparkle updater failed to start: \(error.localizedDescription)")
            }
            automaticUpdatesEnabled = updater.automaticallyChecksForUpdates
        }
    }

    func startCheckingForUpdates() {
        // Sparkle owns its automatic check schedule via Info.plist settings.
    }

    func stopCheckingForUpdates() {
        // Keep Sparkle's updater alive for the process lifetime.
    }

    /// One-click Arc-style flow for the banner: resume the pending Sparkle
    /// session (or start a user check) and answer every prompt with
    /// "install", ending in a relaunch.
    func openAvailableUpdate() {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true

        if isUITestingFixture {
            return
        }
        guard isUpdaterActive else {
            isInstallingUpdate = false
            return
        }

        if let reply = pendingUpdateReply {
            pendingUpdateReply = nil
            reply(.install)
        } else {
            installOnNextUpdateFound = true
            if !updater.sessionInProgress {
                updater.checkForUpdates()
            }
        }
    }

    func setAutomaticUpdatesEnabled(_ isEnabled: Bool) {
        if isUpdaterActive {
            updater.automaticallyChecksForUpdates = isEnabled
            updater.automaticallyDownloadsUpdates = isEnabled
        }
        automaticUpdatesEnabled = isEnabled
    }
}

// MARK: - SPUUserDriver

extension AppUpdateService: SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        availableUpdate = AppUpdate(version: appcastItem.displayVersionString)

        if installOnNextUpdateFound || isInstallingUpdate {
            installOnNextUpdateFound = false
            reply(.install)
        } else {
            pendingUpdateReply = reply
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        isInstallingUpdate = false
        installOnNextUpdateFound = false
        availableUpdate = nil
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Keep `availableUpdate` set so the banner survives a failed attempt
        // and the user can retry.
        NSLog("Sparkle update failed: \(error.localizedDescription)")
        isInstallingUpdate = false
        installOnNextUpdateFound = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // Sparkle tears the session down (completion or abort). Keep
        // `availableUpdate`: the update stays pending until it installs and
        // the app relaunches.
        pendingUpdateReply = nil
    }
}
