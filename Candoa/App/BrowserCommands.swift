import AppKit
import SwiftUI

internal struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Candoa") {
                // Safari-style panel: icon, name, "Version x.y (build)", and
                // the copyright lines only. Empty credits keep the standard
                // panel from inlining Credits.rtf, which stays reachable via
                // Help ▸ Acknowledgments.
                NSApplication.shared.orderFrontStandardAboutPanel(
                    options: [.credits: NSAttributedString(string: "")]
                )
            }
        }
    }
}

internal struct BrowserCommands: Commands {
    @FocusedValue(\.browserCommandActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var userStore: UserStore

    /// Safari titles the Develop menu's local-targets submenu with the
    /// device itself, name over OS version.
    private static let deviceMenuTitle = DeviceMenuPresentation.menuTitle

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
                .keyboardShortcut(ShortcutDefinition.newTab.currentKeyboardShortcut)
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
                .keyboardShortcut(ShortcutDefinition.closeCurrentTab.currentKeyboardShortcut)
                .disabled(actions == nil)

                Button(BrowserCommandTitles.closeOtherTabs) {
                    actions?.closeOtherTabs()
                }
                .keyboardShortcut(ShortcutDefinition.closeOtherTabs.currentKeyboardShortcut)
                .disabled(actions?.canCloseOtherTabs != true)

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
                .keyboardShortcut(ShortcutDefinition.findNext.currentKeyboardShortcut)
                .disabled(actions == nil)

                Button(BrowserCommandTitles.findPrevious) {
                    actions?.findPrevious()
                }
                .keyboardShortcut(ShortcutDefinition.findPrevious.currentKeyboardShortcut)
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
                .keyboardShortcut(ShortcutDefinition.stopLoading.currentKeyboardShortcut)
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
                .keyboardShortcut(ShortcutDefinition.resetZoom.currentKeyboardShortcut)
                .disabled(actions == nil)

                Button(BrowserCommandTitles.zoomIn) {
                    actions?.zoomIn()
                }
                .keyboardShortcut(ShortcutDefinition.zoomIn.currentKeyboardShortcut)
                .disabled(actions == nil)

                Button(BrowserCommandTitles.zoomOut) {
                    actions?.zoomOut()
                }
                .keyboardShortcut(ShortcutDefinition.zoomOut.currentKeyboardShortcut)
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

                    // Works from a single tab too: it starts the split.
                    Button(BrowserCommandTitles.splitWithTab) {
                        actions?.splitWithTab()
                    }
                    .keyboardShortcut(ShortcutDefinition.splitWithTab.currentKeyboardShortcut)
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

                    // One item for both directions, like the split toggle
                    // above: the same key gets you in and back out, and the
                    // title says which way it is about to go.
                    Button(
                        actions?.isSplitPaneZoomed == true
                            ? BrowserCommandTitles.showAllSplitPanes
                            : BrowserCommandTitles.zoomSplitPane
                    ) {
                        actions?.toggleSplitPaneZoom()
                    }
                    .keyboardShortcut(ShortcutDefinition.zoomSplitPane.currentKeyboardShortcut)
                    .disabled(actions?.isSplitDisplayed != true)

                    Divider()

                    Button(BrowserCommandTitles.focusNextSplitPane) {
                        actions?.focusSplitPane(1)
                    }
                    .keyboardShortcut(ShortcutDefinition.focusNextSplitPane.currentKeyboardShortcut)
                    .disabled(actions?.isSplitDisplayed != true)

                    Button(BrowserCommandTitles.focusPreviousSplitPane) {
                        actions?.focusSplitPane(-1)
                    }
                    .keyboardShortcut(ShortcutDefinition.focusPreviousSplitPane.currentKeyboardShortcut)
                    .disabled(actions?.isSplitDisplayed != true)

                    Button(BrowserCommandTitles.unsplitPane) {
                        actions?.unsplitPane()
                    }
                    .keyboardShortcut(ShortcutDefinition.unsplitPane.currentKeyboardShortcut)
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
                .keyboardShortcut(ShortcutDefinition.previousTab.currentKeyboardShortcut)
                .disabled(actions == nil)

                Button(BrowserCommandTitles.nextTab) {
                    actions?.nextTab()
                }
                .keyboardShortcut(ShortcutDefinition.nextTab.currentKeyboardShortcut)
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
                .keyboardShortcut(ShortcutDefinition.clearUnpinnedTabs.currentKeyboardShortcut)
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

            Button(BrowserCommandTitles.reportAProblem) {
                openWindow(id: AppConfiguration.reportProblemWindowSceneID)
            }

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
            .keyboardShortcut(ShortcutDefinition.goBack.menuKeyboardShortcut)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.forward) {
                actions?.goForward()
            }
            .keyboardShortcut(ShortcutDefinition.goForward.menuKeyboardShortcut)
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
            .keyboardShortcut(ShortcutDefinition.reopenClosedTab.currentKeyboardShortcut)
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
            .keyboardShortcut(ShortcutDefinition.previousSpace.currentKeyboardShortcut)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.nextSpace) {
                actions?.nextSpace()
            }
            .keyboardShortcut(ShortcutDefinition.nextSpace.currentKeyboardShortcut)
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
        // elsewhere and spoofing up top, developer mode, service workers,
        // then the inspector family, recording tools, caches, and the copy
        // commands.
        CommandMenu("Develop") {
            // Grouped to stay inside the commands builder's ten-element limit.
            Group {
                Menu(BrowserCommandTitles.openPageWith, systemImage: "arrow.up.forward.app") {
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

                Menu(BrowserCommandTitles.userAgent, systemImage: "globe") {
                    // Safari's layout: the default, then one group per
                    // browser family, then the free-form Other… sheet.
                    ForEach(UserAgentPreset.menuSections, id: \.self) { section in
                        ForEach(section) { preset in
                            Toggle(isOn: Binding(
                                get: { preset == actions?.activeUserAgentPreset },
                                set: { _ in actions?.setUserAgentPreset(preset) }
                            )) {
                                Text(preset.title)
                            }
                            .disabled(actions?.canUseDevelopTools != true)
                        }
                        Divider()
                    }

                    Toggle(isOn: Binding(
                        get: { actions?.isCustomUserAgentActive == true },
                        set: { _ in actions?.promptForCustomUserAgent() }
                    )) {
                        Text(BrowserCommandTitles.userAgentOther)
                    }
                    .disabled(actions?.canUseDevelopTools != true)
                }
                .disabled(actions?.canUseDevelopTools != true)

                Divider()

                // Safari's local-device targets, scoped to Candoa's own
                // pages: the submenu carries the Mac's name, an app header
                // row, and one entry per inspectable page.
                Menu {
                    if let pages = actions?.inspectablePages, !pages.isEmpty {
                        Button(action: {}) { Text(verbatim: "Candoa") }
                            .disabled(true)
                        ForEach(pages) { page in
                            Button(page.title) {
                                actions?.inspectPage(page.id)
                            }
                        }
                    } else {
                        Button(BrowserCommandTitles.noInspectablePages) {}
                            .disabled(true)
                    }
                } label: {
                    Text(verbatim: Self.deviceMenuTitle)
                }

                Divider()

                // Candoa's per-site Developer Mode deliberately has no row
                // here: the Develop menu mirrors Safari's, and Safari has no
                // such item. The toggle lives in the Command Palette and the
                // sidebar's site controls. Safari's Service Workers submenu
                // is also absent: its rows open per-worker inspectors, which
                // WebKit offers no entry point for, and a submenu of disabled
                // rows earns no place.
            }

            Group {
                Button(
                    actions?.isWebInspectorVisible == true
                        ? BrowserCommandTitles.closeWebInspector
                        : BrowserCommandTitles.showWebInspector,
                    systemImage: "macwindow.on.rectangle"
                ) {
                    actions?.toggleWebInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.connectWebInspector, systemImage: "rectangle.connected.to.line.below") {
                    actions?.connectWebInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option, .shift])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.showJavaScriptConsole, systemImage: "terminal") {
                    actions?.showJavaScriptConsole()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.showPageSource, systemImage: "chevron.left.forwardslash.chevron.right") {
                    actions?.showPageSource()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Button(BrowserCommandTitles.showPageResources, systemImage: "folder") {
                    actions?.showPageResources()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Divider()

                Button(
                    actions?.isRecordingTimeline == true
                        ? BrowserCommandTitles.stopTimelineRecording
                        : BrowserCommandTitles.startTimelineRecording,
                    systemImage: "record.circle"
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
                        : BrowserCommandTitles.startElementSelection,
                    systemImage: "cursorarrow.rays"
                ) {
                    actions?.toggleElementSelection()
                }
                .disabled(actions?.canUseDevelopTools != true)

                Divider()
            }

            Group {
                Button(BrowserCommandTitles.emptyCaches, systemImage: "xmark") {
                    actions?.emptyCaches()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(actions?.canUseDevelopTools != true)

                Divider()

                Button(BrowserCommandTitles.developerSettings, systemImage: "gearshape") {
                    SettingsPaneRequest.request(.advanced)
                    openSettings()
                }

                Button(BrowserCommandTitles.featureFlags, systemImage: "flag") {
                    openWindow(id: AppConfiguration.featureFlagsWindowSceneID)
                }

                Divider()

                Button(BrowserCommandTitles.copyURL, systemImage: "link") {
                    actions?.copyURL()
                }
                .disabled(actions == nil)

                Button(BrowserCommandTitles.copyURLAsMarkdown, systemImage: "doc.on.doc") {
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
