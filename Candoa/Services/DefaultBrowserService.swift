import AppKit
import Foundation

/// Detects and requests Candoa's default-browser role.
///
/// Detection resolves the system's handler for an HTTPS URL and compares
/// bundle identifiers, so any installed copy of Candoa counts only when it
/// is the copy LaunchServices actually registered. The setup action uses
/// the modern NSWorkspace API, which presents the system's own consent
/// dialog — no Settings deep link, no custom UI. Status is refreshed only
/// on explicit events (a request finishing, app activation); there is no
/// polling.
@MainActor
final class DefaultBrowserService: ObservableObject {
    @Published private(set) var isDefaultBrowser: Bool

    init() {
        isDefaultBrowser = Self.currentStatus()
    }

    func refresh() {
        isDefaultBrowser = Self.currentStatus()
    }

    /// Presents the system's "change your default web browser" consent
    /// dialog. Registering the HTTP scheme flips the browser role as a
    /// whole — HTTPS follows with it.
    func requestDefaultBrowserRole() async {
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL,
                toOpenURLsWithScheme: "http"
            )
        } catch {
            // Declining the system dialog lands here; the refresh below
            // reports whichever choice the user made.
        }
        refresh()
    }

    private static func currentStatus() -> Bool {
        guard
            let probeURL = URL(string: "https://candoa.app"),
            let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL),
            let handlerBundleID = Bundle(url: handlerURL)?.bundleIdentifier,
            let ownBundleID = Bundle.main.bundleIdentifier
        else {
            return false
        }

        return handlerBundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame
    }
}
