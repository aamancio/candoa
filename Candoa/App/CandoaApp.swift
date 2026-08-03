import AppKit
import SwiftUI

@main
struct CandoaApp: App {
    @NSApplicationDelegateAdaptor(CandoaAppDelegate.self) private var appDelegate
    @StateObject private var userStore = UserStore()

    var body: some Scene {
        WindowGroup(id: AppConfiguration.browserWindowSceneID) {
            ContentView()
                .environmentObject(userStore)
                .tint(CandoaColor.accent)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .frame(
                    minWidth: AppConfiguration.minimumWindowWidth,
                    minHeight: AppConfiguration.minimumWindowHeight
                )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: Self.initialWindowSize.width,
            height: Self.initialWindowSize.height
        )
        .commands {
            BrowserCommands(userStore: userStore)
        }

        // Private windows: same interface, but the store persists nothing
        // and web content runs against a non-persistent data store. The
        // empty external-events set keeps URLs from other apps out of
        // private windows — they always open ordinarily unless the user
        // explicitly chooses otherwise.
        WindowGroup(id: AppConfiguration.privateBrowserWindowSceneID) {
            ContentView(isPrivate: true)
                .environmentObject(userStore)
                .tint(CandoaColor.accent)
                .frame(
                    minWidth: AppConfiguration.minimumWindowWidth,
                    minHeight: AppConfiguration.minimumWindowHeight
                )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: Self.initialWindowSize.width,
            height: Self.initialWindowSize.height
        )
        .handlesExternalEvents(matching: [])

        Settings {
            CandoaSettingsView()
                .environmentObject(userStore)
                .tint(CandoaColor.accent)
        }
    }

    private static var initialWindowSize: CGSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return CGSize(
                width: AppConfiguration.minimumWindowWidth,
                height: AppConfiguration.minimumWindowHeight
            )
        }

        return CGSize(width: visibleFrame.width, height: visibleFrame.height)
    }
}

@MainActor
private final class CandoaAppDelegate: NSObject, NSApplicationDelegate {
    private let appearanceChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
    private let browserPasskeyAuthorizationService = BrowserPasskeyAuthorizationService()
    private let defaultBrowserService = DefaultBrowserService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockIcon()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: appearanceChangedNotification,
            object: nil
        )
        requestDefaultBrowserRoleIfWanted()
    }

    /// The opt-in startup check goes straight to the system's own consent
    /// dialog — it already is the "use Candoa as your default browser?"
    /// prompt, so a custom alert in front of it would just double-ask.
    private func requestDefaultBrowserRoleIfWanted() {
        guard
            ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1",
            UserDefaults.standard.bool(forKey: CandoaSettingsOption.checkDefaultBrowser),
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
            CandoaSettingsOption.bool(CandoaSettingsOption.askBeforeQuitting, default: true),
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

    @objc private func systemAppearanceDidChange(_ notification: Notification) {
        updateDockIcon()
    }

    private func updateDockIcon() {
        CandoaDockIconPreference.updateApplicationIcon()
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserCommandActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var userStore: UserStore

    var body: some Commands {
        CommandGroup(before: .appTermination) {
            Button("Sign Out") {
                userStore.signOut()
            }
            .disabled(!userStore.hasCloudSession || userStore.isWorking)

            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: AppConfiguration.browserWindowSceneID)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Private Window") {
                openWindow(id: AppConfiguration.privateBrowserWindowSceneID)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(BrowserCommandTitles.newTab) {
                actions?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(actions?.isHistoryVisible == true ? "Close History" : "Close Tab") {
                actions?.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions == nil)
        }

        // Grouped with the pasteboard commands to stay inside the commands
        // builder's ten-element limit.
        Group {
            CommandGroup(replacing: .printItem) {
                Button(BrowserCommandTitles.printPage) {
                    actions?.printPage()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.canPrintActiveTab != true)
            }

            CommandGroup(after: .pasteboard) {
                Button(BrowserCommandTitles.copyURL) {
                    actions?.copyURL()
                }
                .disabled(actions == nil)

                Button(BrowserCommandTitles.copyURLAsMarkdown) {
                    actions?.copyURLAsMarkdown()
                }
                .disabled(actions == nil)
            }
        }

        CommandGroup(after: .textEditing) {
            Button(BrowserCommandTitles.findInPage) {
                actions?.findInPage()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.findNext) {
                actions?.findNext()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.findPrevious) {
                actions?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(actions?.isSidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                actions?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(actions == nil)

            Button(actions?.isAISidebarVisible == true ? "Hide Eli Sidebar" : "Show Eli Sidebar") {
                actions?.toggleAISidebar()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.focusAddressBar) {
                actions?.focusAddressBar()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.commandBar) {
                actions?.openCommandPalette()
            }
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.stopLoading) {
                actions?.stopLoading()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(actions?.isActiveTabLoading != true)

            Button(BrowserCommandTitles.reloadTab) {
                actions?.reloadTab()
            }
            .disabled(actions?.canReloadActiveTab != true)

            Button(BrowserCommandTitles.reloadTabFromOrigin) {
                actions?.reloadTabFromOrigin()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(actions?.canReloadActiveTab != true)

            Divider()

            Button(BrowserCommandTitles.resetZoom) {
                actions?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.zoomIn) {
                actions?.zoomIn()
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.zoomOut) {
                actions?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            // The split shortcuts are handled by KeyboardShortcutMonitor (it
            // consumes matching key events before menu dispatch); attaching
            // the person's configured equivalents here surfaces them in the
            // menu instead of leaving the items looking shortcut-less.
            Button(BrowserCommandTitles.addSplitView) {
                actions?.addSplitView()
            }
            .keyboardShortcut(CandoaShortcutDefinition.addSplitView.currentKeyboardShortcut)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.closeSplitView) {
                actions?.closeSplitView()
            }
            .keyboardShortcut(CandoaShortcutDefinition.closeSplitView.currentKeyboardShortcut)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.splitLayoutHorizontal) {
                actions?.setSplitLayout(.horizontal)
            }
            .keyboardShortcut(CandoaShortcutDefinition.splitLayoutHorizontal.currentKeyboardShortcut)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.splitLayoutVertical) {
                actions?.setSplitLayout(.vertical)
            }
            .keyboardShortcut(CandoaShortcutDefinition.splitLayoutVertical.currentKeyboardShortcut)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.splitLayoutGrid) {
                actions?.setSplitLayout(.grid)
            }
            .keyboardShortcut(CandoaShortcutDefinition.splitLayoutGrid.currentKeyboardShortcut)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.nextTab) {
                actions?.nextTab()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.previousTab) {
                actions?.previousTab()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.nextSpace) {
                actions?.nextSpace()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.previousSpace) {
                actions?.previousSpace()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(actions == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button(actions?.isActiveTabPinned == true ? "Unpin Tab" : "Pin Tab") {
                actions?.pinOrUnpinTab()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.duplicateTab) {
                actions?.duplicateTab()
            }
            .disabled(actions == nil)
        }

        CommandGroup(after: .help) {
            Button(String(localized: "Quick Tour…")) {
                actions?.showQuickTour()
            }
            .disabled(actions == nil)
        }

        CommandMenu("History") {
            Button(actions?.isHistoryVisible == true ? "Hide History" : "Show History") {
                actions?.showHistory()
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.back) {
                actions?.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.forward) {
                actions?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.reopenClosedTab) {
                actions?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandMenu("Bookmarks") {
            Button(actions?.isActiveTabPinned == true ? "Unpin Tab" : "Add Bookmark…") {
                actions?.pinOrUnpinTab()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.clearUnpinnedTabs) {
                actions?.clearUnpinnedTabs()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Menu("iCloud Sync") {
                Button(
                    actions?.isWorkspaceICloudSyncEnabled == true
                        ? BrowserCommandTitles.disableWorkspaceICloudSync
                        : BrowserCommandTitles.enableWorkspaceICloudSync
                ) {
                    guard let actions else { return }
                    actions.setWorkspaceICloudSyncEnabled(!actions.isWorkspaceICloudSyncEnabled)
                }
                .disabled(actions == nil)

                Button(
                    actions?.isHistoryICloudSyncEnabled == true
                        ? BrowserCommandTitles.disableHistoryICloudSync
                        : BrowserCommandTitles.enableHistoryICloudSync
                ) {
                    guard let actions else { return }
                    actions.setHistoryICloudSyncEnabled(!actions.isHistoryICloudSyncEnabled)
                }
                .disabled(actions == nil || actions?.isWorkspaceICloudSyncEnabled != true)
            }
        }

        CommandMenu("Develop") {
            Button(
                actions?.isDeveloperModeEnabled == true
                    ? BrowserCommandTitles.turnOffDeveloperMode
                    : BrowserCommandTitles.turnOnDeveloperMode
            ) {
                guard let actions else { return }
                actions.setDeveloperMode(!actions.isDeveloperModeEnabled)
            }
            .disabled(actions?.isDeveloperModeAvailable != true)

            Divider()

            Button(BrowserCommandTitles.copyURL) {
                actions?.copyURL()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.copyURLAsMarkdown) {
                actions?.copyURLAsMarkdown()
            }
            .disabled(actions == nil)
        }
    }
}

struct BrowserCommandActions {
    var newTab: () -> Void
    var focusAddressBar: () -> Void
    var openCommandPalette: () -> Void
    var toggleSidebar: () -> Void
    var isSidebarVisible: Bool
    var toggleAISidebar: () -> Void
    var isAISidebarVisible: Bool
    var showHistory: () -> Void
    var isHistoryVisible: Bool
    var showQuickTour: () -> Void
    var reloadTab: () -> Void
    var reloadTabFromOrigin: () -> Void
    var printPage: () -> Void
    var canPrintActiveTab: Bool
    var stopLoading: () -> Void
    var isActiveTabLoading: Bool
    var canReloadActiveTab: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    var closeCurrentTab: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var nextSpace: () -> Void
    var previousSpace: () -> Void
    var reopenClosedTab: () -> Void
    var pinOrUnpinTab: () -> Void
    var isActiveTabPinned: Bool
    var duplicateTab: () -> Void
    var clearUnpinnedTabs: () -> Void
    var copyURL: () -> Void
    var copyURLAsMarkdown: () -> Void
    var findInPage: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var resetZoom: () -> Void
    var addSplitView: () -> Void
    var closeSplitView: () -> Void
    var setSplitLayout: (SplitViewLayout) -> Void
    var isWorkspaceICloudSyncEnabled: Bool
    var isHistoryICloudSyncEnabled: Bool
    var setWorkspaceICloudSyncEnabled: (Bool) -> Void
    var setHistoryICloudSyncEnabled: (Bool) -> Void
    var isDeveloperModeAvailable: Bool
    var isDeveloperModeEnabled: Bool
    var setDeveloperMode: (Bool) -> Void
}

private struct BrowserCommandActionsKey: FocusedValueKey {
    typealias Value = BrowserCommandActions
}

extension FocusedValues {
    var browserCommandActions: BrowserCommandActions? {
        get { self[BrowserCommandActionsKey.self] }
        set { self[BrowserCommandActionsKey.self] = newValue }
    }
}
