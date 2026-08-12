import AppKit
import SwiftUI

@main
struct CandoaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var userStore = UserStore()

    init() {
        // Candoa has no tab bar — tabs live in the sidebar. Left on, AppKit's
        // automatic window tabbing injects "Hide Tab Bar" and "Show All Tabs"
        // into View and "Merge All Windows" into Window, all advertising a
        // surface the app doesn't have. Set before any scene is built.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(id: AppConfiguration.browserWindowSceneID) {
            ContentView()
                .environmentObject(userStore)
                .tint(AppColor.accent)
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
            AboutCommands()
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
                .tint(AppColor.accent)
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
            SettingsView()
                .environmentObject(userStore)
                .tint(AppColor.accent)
        }

        // Help ▸ Acknowledgments. The same Credits.rtf also feeds the
        // standard About panel, which picks it up from the bundle on its own.
        Window(
            BrowserCommandTitles.acknowledgments,
            id: AppConfiguration.acknowledgmentsWindowSceneID
        ) {
            AcknowledgmentsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 380)
        // Without this, the scene injects its own "Acknowledgments" row into
        // the Window menu, duplicating the Help menu entry.
        .commandsRemoved()
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
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appearanceChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
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
        }

        updateDockIcon()
        MenuAlternateInstaller.install()
        webAuthenticationHostService.activate()
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

    @objc private func systemAppearanceDidChange(_ notification: Notification) {
        updateDockIcon()
    }

    private func updateDockIcon() {
        DockIconPreference.updateApplicationIcon()
    }
}

/// Safari shows "Reload Page From Origin" only while Option is held: it is an
/// alternate of "Reload Page" rather than a line of its own. SwiftUI has no
/// modifier for `NSMenuItem.isAlternate`, so the flag is set on the menu
/// AppKit built — and re-set whenever the menu bar begins tracking, because
/// SwiftUI rebuilds these items as the focused browser state changes and a
/// rebuilt item comes back ordinary.
///
/// AppKit only honours the flag when the alternate directly follows its base
/// item and carries the same key equivalent with a different modifier mask,
/// which is how the two are declared in the View menu.
@MainActor
private enum MenuAlternateInstaller {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { applyReloadAlternate() }
        }
    }

    private static func applyReloadAlternate() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu,
                  let index = submenu.items.firstIndex(where: {
                      $0.title == BrowserCommandTitles.reloadTabFromOrigin
                  }),
                  index > 0,
                  submenu.items[index - 1].title == BrowserCommandTitles.reloadTab
            else { continue }

            let alternate = submenu.items[index]
            guard !alternate.isAlternate else { return }

            alternate.keyEquivalent = "r"
            alternate.keyEquivalentModifierMask = [.command, .option]
            alternate.isAlternate = true
            return
        }
    }
}

private struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Candoa") {
                // The standard panel appends the build number in parentheses;
                // that counter is Sparkle plumbing, not something people
                // should read. An empty version hides the parenthetical.
                NSApplication.shared.orderFrontStandardAboutPanel(
                    options: [.version: ""]
                )
            }
        }
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserCommandActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var userStore: UserStore

    var body: some Commands {
        // Grouped to stay inside the commands builder's ten-element limit.
        Group {
            CommandGroup(before: .appTermination) {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    userStore.signOut()
                }
                .disabled(!userStore.hasCloudSession || userStore.isWorking)

                Divider()
            }

            // Safari keeps both of these in its app menu just below Settings —
            // the report as "Privacy Report…", the per-page entry as "Settings
            // for <site>…" — not in View. The address pill remains the
            // everyday way in to Site Info.
            CommandGroup(after: .appSettings) {
                // The report describes global protection, so it needs no page.
                Button(BrowserCommandTitles.privacyReport, systemImage: "shield.fill") {
                    actions?.showPrivacyReport()
                }
                .disabled(actions == nil)

                Button(BrowserCommandTitles.siteInfo, systemImage: "info.circle") {
                    actions?.showSiteInfo()
                }
                .disabled(actions?.canShowSiteInfo != true)
            }
        }

        CommandGroup(replacing: .newItem) {
            // Grouped to stay inside the commands builder's ten-element limit.
            Group {
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

                Button(BrowserCommandTitles.openFile) {
                    actions?.openLocalFile()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil)

                // Safari's home for focusing the address bar, under the name
                // it uses there. The shortcut is dispatched by
                // KeyboardShortcutMonitor; attaching it here only draws the
                // equivalent beside the item.
                Button(BrowserCommandTitles.openLocation) {
                    actions?.focusAddressBar()
                }
                .keyboardShortcut(ShortcutDefinition.focusAddressBar.currentKeyboardShortcut)
                .disabled(actions == nil)
            }

            Group {
                Divider()

                Button(actions?.isHistoryVisible == true ? "Close History" : "Close Tab") {
                    actions?.closeCurrentTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(actions == nil)

                Divider()

                Button(BrowserCommandTitles.saveAs) {
                    actions?.saveActiveTabAs()
                }
                // Command-S is the sidebar toggle — the one documented exception
                // to Safari's mapping — so Save As takes the shifted variant.
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions?.canSaveActiveTab != true)

                Button(BrowserCommandTitles.exportAsPDF) {
                    actions?.exportActiveTabAsPDF()
                }
                .disabled(actions?.canSaveActiveTab != true)
            }
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

        // Safari nests the find commands one level down rather than spending
        // three lines of the Edit menu on them.
        CommandGroup(after: .textEditing) {
            Menu(BrowserCommandTitles.findMenu) {
                Button(BrowserCommandTitles.findInPage) {
                    actions?.findInPage()
                }
                .keyboardShortcut(ShortcutDefinition.findInPage.currentKeyboardShortcut)
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
        }

        CommandGroup(replacing: .sidebar) {
            Button(actions?.isSidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                actions?.toggleSidebar()
            }
            .keyboardShortcut(ShortcutDefinition.toggleSidebar.currentKeyboardShortcut)
            .disabled(actions == nil)

            Button(actions?.isAISidebarVisible == true ? "Hide Eli Sidebar" : "Show Eli Sidebar") {
                actions?.toggleAISidebar()
            }
            .keyboardShortcut(ShortcutDefinition.toggleAISidebar.currentKeyboardShortcut)
            .disabled(actions == nil)

            Divider()

            Group {
                // Safari groups the page-level views together below the
                // sidebars — Reader, then Downloads — with Candoa's own
                // Command Bar folded in at the end. Reader is enabled while
                // the active page qualifies or reader is already showing (so
                // it always exits).
                Button(
                    actions?.isReaderActive == true
                        ? BrowserCommandTitles.hideReader
                        : BrowserCommandTitles.showReader
                ) {
                    actions?.toggleReader()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canToggleReader != true)

                Button(actions?.isDownloadsVisible == true ? "Hide Downloads" : "Show Downloads") {
                    actions?.showDownloads()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(actions == nil)

                // Option-Command-K, not Command-K: web apps bind Command-K for
                // their own palettes (Slack, Linear, GitHub) and chrome would
                // swallow it before the page ever saw it. Option-Command is
                // where browsers keep their own commands, so nothing collides.
                Button(BrowserCommandTitles.commandBar) {
                    actions?.openCommandPalette()
                }
                .keyboardShortcut(ShortcutDefinition.commandBar.currentKeyboardShortcut)
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
                .keyboardShortcut(ShortcutDefinition.reloadTab.currentKeyboardShortcut)
                .disabled(actions?.canReloadActiveTab != true)

                // Kept directly after Reload Page, sharing its key equivalent:
                // MenuAlternateInstaller turns this into the Option-held
                // alternate of the item above, the way Safari hides it.
                Button(BrowserCommandTitles.reloadTabFromOrigin) {
                    actions?.reloadTabFromOrigin()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(actions?.canReloadActiveTab != true)
            }

            Divider()

            Group {
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

                // Four split commands would outweigh everything else in the
                // menu, so they sit one level down. The shortcuts are handled
                // by KeyboardShortcutMonitor (it consumes matching key events
                // before menu dispatch); attaching the person's configured
                // equivalents here surfaces them in the menu instead of
                // leaving the items looking shortcut-less.
                Menu(BrowserCommandTitles.splitViewMenu) {
                    // One item, not an add/close pair: the keyboard could only
                    // ever open or close the split anyway (a third pane comes
                    // from a drag), so the second command bought a second key
                    // for nothing. Title flips the way the sidebar items do.
                    Button(
                        actions?.isSplitDisplayed == true
                            ? BrowserCommandTitles.closeSplitView
                            : BrowserCommandTitles.addSplitView
                    ) {
                        actions?.toggleSplitView()
                    }
                    .keyboardShortcut(ShortcutDefinition.toggleSplitView.currentKeyboardShortcut)
                    .disabled(actions == nil)

                    // Rearranging only means something while a split is on
                    // screen, so these grey out instead of silently doing
                    // nothing.
                    Button(BrowserCommandTitles.splitLayoutHorizontal) {
                        actions?.setSplitLayout(.horizontal)
                    }
                    .keyboardShortcut(ShortcutDefinition.splitLayoutHorizontal.currentKeyboardShortcut)
                    .disabled(actions?.isSplitDisplayed != true)

                    Button(BrowserCommandTitles.splitLayoutVertical) {
                        actions?.setSplitLayout(.vertical)
                    }
                    .keyboardShortcut(ShortcutDefinition.splitLayoutVertical.currentKeyboardShortcut)
                    .disabled(actions?.isSplitDisplayed != true)
                }

                // AppKit appends its Enter Full Screen item after this group;
                // the divider sets it apart the way Safari's View menu does.
                Divider()
            }
        }

        // Safari's Window menu is where tab navigation lives — Show Next Tab
        // and Show Previous Tab, then Go To Next/Previous Tab Group above Pin
        // Tab and Duplicate Tab. Spaces are Candoa's tab groups, so they take
        // the tab-group slot rather than a line in the View menu.
        CommandGroup(after: .windowArrangement) {
            // Grouped to stay inside the commands builder's ten-element limit.
            Group {
                // Safari heads its tab section with Arrange Tabs By; the
                // items ship without shortcuts because Safari's do too.
                // AppKit auto-enables submenu parents, so the child items
                // carry the disabled state as well.
                Menu(BrowserCommandTitles.arrangeTabsBy) {
                    Button(BrowserCommandTitles.arrangeTabsByTitle) {
                        actions?.arrangeTabsByTitle()
                    }
                    .disabled(actions?.canArrangeTabs != true)

                    Button(BrowserCommandTitles.arrangeTabsByWebsite) {
                        actions?.arrangeTabsByWebsite()
                    }
                    .disabled(actions?.canArrangeTabs != true)
                }
                .disabled(actions?.canArrangeTabs != true)

                Button(BrowserCommandTitles.previousTab) {
                    actions?.previousTab()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions == nil)

                Button(BrowserCommandTitles.nextTab) {
                    actions?.nextTab()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions == nil)

                Button(actions?.isActiveTabPinned == true ? "Unpin Tab" : "Pin Tab") {
                    actions?.pinOrUnpinTab()
                }
                .disabled(actions == nil)

                Button(
                    actions?.isActiveTabFavorite == true
                        ? BrowserCommandTitles.removeFromFavorites
                        : BrowserCommandTitles.addToFavorites
                ) {
                    actions?.toggleFavoriteForActiveTab()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions?.canToggleFavorite != true)

                Button(BrowserCommandTitles.duplicateTab) {
                    actions?.duplicateTab()
                }
                .disabled(actions == nil)

                Button(BrowserCommandTitles.clearUnpinnedTabs) {
                    actions?.clearUnpinnedTabs()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions == nil)
            }

            Group {
                Divider()

                Button(
                    actions?.isActiveTabMuted == true
                        ? BrowserCommandTitles.unmuteThisTab
                        : BrowserCommandTitles.muteThisTab
                ) {
                    actions?.toggleActiveTabMute()
                }
                .disabled(actions?.canMuteActiveTab != true)

                Button(BrowserCommandTitles.muteOtherTabs) {
                    actions?.muteOtherTabs()
                }
                .disabled(actions?.canMuteOtherTabs != true)
            }
        }

        CommandGroup(after: .help) {
            Button(String(localized: "Quick Tour…")) {
                actions?.showQuickTour()
            }
            .disabled(actions == nil)

            Divider()

            // The acknowledgments window is its own scene, so it opens with
            // no browser window key — help stays reachable from anywhere.
            Button(BrowserCommandTitles.acknowledgments) {
                openWindow(id: AppConfiguration.acknowledgmentsWindowSceneID)
            }
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

            Button(BrowserCommandTitles.home) {
                actions?.goHome()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.returnToSearchResults) {
                actions?.returnToSearchResults()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(actions?.canReturnToSearchResults != true)

            Divider()

            // The Recently Closed submenu is inserted here at runtime by
            // BrowserMenuController, which also appends the visited pages
            // below — both are built only when the menu opens.
            Button(BrowserCommandTitles.reopenClosedTab) {
                actions?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            // Private windows keep no persistent history or website data,
            // so the clear command only targets ordinary windows.
            Button(BrowserCommandTitles.clearHistory) {
                actions?.clearBrowsingData()
            }
            .disabled(actions?.canClearBrowsingData != true)
        }

        // Spaces are what Candoa is organized around, so they get the menu
        // Safari spends on bookmarks — the shape Arc, Dia and Zen all use:
        // the commands that act on the current Space, then the Spaces
        // themselves.
        CommandMenu("Spaces") {
            Button(BrowserCommandTitles.newSpace) {
                actions?.createSpace()
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.editSpace) {
                actions?.editActiveSpace()
            }
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.previousSpace) {
                actions?.previousSpace()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.nextSpace) {
                actions?.nextSpace()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            if let actions, !actions.spaces.isEmpty {
                Divider()

                // The active Space is checked, the way a menu marks the one
                // of a set that is current, and each row carries the
                // Control-number shortcut that already switches to it.
                ForEach(Array(actions.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceCommandItem(
                        space: space,
                        isActive: space.id == actions.activeSpaceID,
                        index: index,
                        select: actions.selectSpace
                    )
                }
            }
        }

        // Safari's Develop menu order, keeping Candoa's own items: opening
        // elsewhere and spoofing up top, developer mode, then the inspector
        // family, recording tools, caches, and the copy commands.
        CommandMenu("Develop") {
            // Grouped to stay inside the commands builder's ten-element limit.
            Group {
                Menu(BrowserCommandTitles.openPageWith) {
                    ForEach(actions?.installedBrowsers ?? []) { browser in
                        Button(browser.name) {
                            actions?.openPageWith(browser)
                        }
                        // AppKit auto-enables submenu parents, so children
                        // carry the disabled state.
                        .disabled(actions?.canUseDevelopTools != true)
                    }
                }
                .disabled(
                    actions?.canUseDevelopTools != true
                        || actions?.installedBrowsers.isEmpty != false
                )

                Menu(BrowserCommandTitles.userAgent) {
                    ForEach(UserAgentPreset.allCases) { preset in
                        Toggle(isOn: Binding(
                            get: { preset == actions?.activeUserAgentPreset },
                            set: { _ in actions?.setUserAgentPreset(preset) }
                        )) {
                            Text(preset.title)
                        }
                        .disabled(actions?.canUseDevelopTools != true)

                        // Safari separates the default from the spoofs.
                        if preset == .standard {
                            Divider()
                        }
                    }
                }
                .disabled(actions?.canUseDevelopTools != true)

                Divider()

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

                Button(BrowserCommandTitles.connectWebInspector) {
                    actions?.showWebInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option, .shift])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.showJavaScriptConsole) {
                    actions?.showJavaScriptConsole()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.showPageSource) {
                    actions?.showPageSource()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.showPageResources) {
                    actions?.showPageResources()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)
            }

            Group {
                Divider()

                Button(
                    actions?.isRecordingTimeline == true
                        ? BrowserCommandTitles.stopTimelineRecording
                        : BrowserCommandTitles.startTimelineRecording
                ) {
                    actions?.toggleTimelineRecording()
                }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
                .disabled(actions?.canUseDevelopTools != true)

                // Safari's Shift-Command-C belongs to Candoa's Copy URL, so
                // element selection ships without a shortcut.
                Button(
                    actions?.isSelectingElement == true
                        ? BrowserCommandTitles.stopElementSelection
                        : BrowserCommandTitles.startElementSelection
                ) {
                    actions?.toggleElementSelection()
                }
                .disabled(actions?.canUseDevelopTools != true)

                Divider()

                Button(BrowserCommandTitles.emptyCaches) {
                    actions?.emptyCaches()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

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
}

/// One Space in the Spaces menu. `Toggle` is how a menu marks the current one
/// of a set, so the active Space carries the checkmark; choosing it again is a
/// no-op, the same as clicking the Space you are already in.
private struct SpaceCommandItem: View {
    let space: BrowserSpace
    let isActive: Bool
    let index: Int
    let select: (UUID) -> Void

    var body: some View {
        let item = Toggle(isOn: Binding(get: { isActive }, set: { _ in select(space.id) })) {
            label
        }

        if index < 9 {
            item.keyboardShortcut(
                KeyEquivalent(Character("\(index + 1)")),
                modifiers: .control
            )
        } else {
            item
        }
    }

    /// The Space's own icon, so the menu reads like the Space switcher. Spaces
    /// carry either an SF Symbol or an emoji, and an emoji has to be drawn.
    @ViewBuilder
    private var label: some View {
        if let emoji = space.iconEmoji {
            Label { Text(space.name) } icon: { Image(nsImage: Self.emojiIcon(emoji)) }
        } else if space.symbolName != BrowserSpace.noIconSymbolName {
            // A Space that never picked an icon carries the picker's
            // placeholder; drawing it would put an empty dashed box beside
            // the name.
            Label(space.name, systemImage: space.symbolName)
        } else {
            Text(space.name)
        }
    }

    /// Drawn emoji are cached: the menu is rebuilt whenever a focused value
    /// changes, and redrawing an image per Space per rebuild is steady-state
    /// work for a menu nobody has opened.
    @MainActor private static var emojiIcons: [String: NSImage] = [:]

    @MainActor
    private static func emojiIcon(_ emoji: String) -> NSImage {
        if let cached = emojiIcons[emoji] { return cached }

        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        (emoji as NSString).draw(
            in: NSRect(origin: .zero, size: size),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        image.unlockFocus()
        emojiIcons[emoji] = image
        return image
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
    var clearBrowsingData: () -> Void
    var canClearBrowsingData: Bool
    var showDownloads: () -> Void
    var isDownloadsVisible: Bool
    var showSiteInfo: () -> Void
    var canShowSiteInfo: Bool
    var showPrivacyReport: () -> Void
    var toggleReader: () -> Void
    var canToggleReader: Bool
    var isReaderActive: Bool
    var showQuickTour: () -> Void
    var reloadTab: () -> Void
    var reloadTabFromOrigin: () -> Void
    var printPage: () -> Void
    var canPrintActiveTab: Bool
    var openLocalFile: () -> Void
    var saveActiveTabAs: () -> Void
    var exportActiveTabAsPDF: () -> Void
    var canSaveActiveTab: Bool
    var stopLoading: () -> Void
    var isActiveTabLoading: Bool
    var canReloadActiveTab: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    var goHome: () -> Void
    var returnToSearchResults: () -> Void
    var canReturnToSearchResults: Bool
    var closeCurrentTab: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var nextSpace: () -> Void
    var previousSpace: () -> Void
    var reopenClosedTab: () -> Void
    var pinOrUnpinTab: () -> Void
    var isActiveTabPinned: Bool
    var isActiveTabFavorite: Bool
    var createSpace: () -> Void
    var editActiveSpace: () -> Void
    var spaces: [BrowserSpace]
    var activeSpaceID: UUID
    var selectSpace: (UUID) -> Void
    var canToggleFavorite: Bool
    var toggleFavoriteForActiveTab: () -> Void
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
    var toggleSplitView: () -> Void
    var setSplitLayout: (SplitViewLayout) -> Void
    var isSplitDisplayed: Bool
    var isDeveloperModeAvailable: Bool
    var isDeveloperModeEnabled: Bool
    var setDeveloperMode: (Bool) -> Void
    var installedBrowsers: [ExternalBrowserService.Browser]
    var openPageWith: (ExternalBrowserService.Browser) -> Void
    var canUseDevelopTools: Bool
    var activeUserAgentPreset: UserAgentPreset
    var setUserAgentPreset: (UserAgentPreset) -> Void
    var showWebInspector: () -> Void
    var showJavaScriptConsole: () -> Void
    var showPageSource: () -> Void
    var showPageResources: () -> Void
    var isRecordingTimeline: Bool
    var toggleTimelineRecording: () -> Void
    var isSelectingElement: Bool
    var toggleElementSelection: () -> Void
    var emptyCaches: () -> Void
    var arrangeTabsByTitle: () -> Void
    var arrangeTabsByWebsite: () -> Void
    var canArrangeTabs: Bool
    var canMuteActiveTab: Bool
    var isActiveTabMuted: Bool
    var toggleActiveTabMute: () -> Void
    var canMuteOtherTabs: Bool
    var muteOtherTabs: () -> Void
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
