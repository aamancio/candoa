import AppKit
import SwiftUI

@MainActor
internal final class AppDelegate: NSObject, NSApplicationDelegate {
    private let browserPasskeyAuthorizationService = BrowserPasskeyAuthorizationService()
    private let defaultBrowserService = DefaultBrowserService()
    private let webAuthenticationHostService = WebAuthenticationSessionHostService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // UI-test launches share the real defaults domain, so a prior run's
        // per-site permission decisions would leak into the next one. Tests
        // that need pre-set decisions seed them through launch arguments,
        // which read from the argument domain and survive this reset.
        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1" {
            UserDefaults.standard.removeObject(forKey: SitePermissionConfiguration.storageKey)
            // Command bar learning would carry a prior run's picks into the
            // next one's suggestion order.
            UserDefaults.standard.removeObject(forKey: CommandBarSelectionMemory.storageKey)
            // The General pane's behavior choices leak between runs the same
            // way, and tests assume the defaults (⌘T arms the palette,
            // download fixtures survive the popover's retention pass).
            for key in [
                SettingsOption.newTabsOpenWith,
                SettingsOption.historyRetention,
                SettingsOption.downloadLocationMode,
                SettingsOption.downloadListRetention,
                SettingsOption.openSafeDownloads,
                SettingsOption.addressBarPlacement
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // UI-test fixtures seed history with current timestamps; the prune
        // is skipped there anyway to keep launches deterministic.
        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" {
            HistoryRetentionService.shared.activate()
        }

        // Subscribed unconditionally; the submitter drops everything unless
        // someone has turned sharing on. Subscribing later, only once consent
        // exists, would miss the payload the system had already queued.
        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" {
            CrashDiagnosticReporter.shared.start()
        }

        MenuAlternateInstaller.install()
        DevelopMenuStyler.install()
        webAuthenticationHostService.activate()
        requestDefaultBrowserRoleIfWanted()
    }

    /// The opt-in startup check goes straight to the system's own consent
    /// dialog — it already is the "use Candoa as your default browser?"
    /// prompt, so a custom alert in front of it would just double-ask.
    private func requestDefaultBrowserRoleIfWanted() {
        guard
            ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1",
            UserDefaults.standard.bool(forKey: SettingsOption.checkDefaultBrowser),
            !defaultBrowserService.isDefaultBrowser
        else { return }

        Task { [defaultBrowserService] in
            // One beat so the dialog lands over the restored window rather
            // than ahead of it.
            try? await Task.sleep(nanoseconds: 800_000_000)
            await defaultBrowserService.requestDefaultBrowserRole()
        }
    }

    /// Guards only keyboard-initiated quits: a menu click or a programmatic
    /// terminate (Sparkle installing an update) is deliberate enough already.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard
            ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1",
            SettingsOption.bool(SettingsOption.askBeforeQuitting, default: true),
            let event = sender.currentEvent,
            event.type == .keyDown,
            event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "q"
        else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Candoa?")
        alert.informativeText = String(
            localized: "Your Spaces and tabs are saved and will be restored on the next launch."
        )
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        browserPasskeyAuthorizationService.requestAuthorizationIfNeeded()
    }

    // URL opens are routed solely through .onOpenURL (Apple sign-in
    // callbacks first, every other URL into a browser tab). A delegate
    // application(_:open:) would deliver each URL a second time — and on
    // macOS versions where it preempts .onOpenURL, swallow them entirely.

}
