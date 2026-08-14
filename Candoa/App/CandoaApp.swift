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
            // Separate struct: BrowserCommands' builder is at the
            // ten-element limit. Declared last so the menu lands after
            // Develop, before Window.
            ExtensionsCommands()
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

        // Develop ▸ Feature Flags…, Safari's WebKit experimental-feature
        // panel.
        Window(
            BrowserCommandTitles.featureFlagsWindowTitle,
            id: AppConfiguration.featureFlagsWindowSceneID
        ) {
            FeatureFlagsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 620)
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
            // The General pane's behavior choices leak between runs the same
            // way, and tests assume the defaults (⌘T arms the palette,
            // download fixtures survive the popover's retention pass).
            for key in [
                SettingsOption.newTabsOpenWith,
                SettingsOption.historyRetention,
                SettingsOption.downloadLocationMode,
                SettingsOption.downloadListRetention,
                SettingsOption.openSafeDownloads
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // UI-test fixtures seed history with current timestamps; the prune
        // is skipped there anyway to keep launches deterministic.
        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" {
            HistoryRetentionService.shared.activate()
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
/// The Develop menu's device row, shared between the SwiftUI item that
/// declares it and the AppKit pass that styles it.
@MainActor
enum DeviceMenuPresentation {
    static let deviceName = Host.current().localizedName ?? "Mac"

    static let systemVersionLine: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 {
            version += ".\(os.patchVersion)"
        }
        return "macOS \(version)"
    }()

    static let menuTitle = "\(deviceName)\n\(systemVersionLine)"
}

/// Safari's Develop menu carries an icon on every row and renders the
/// device row as the machine's own icon beside its name over a smaller,
/// dimmed macOS version. SwiftUI's Commands drop Label images on the menu
/// bar and flatten the newline, so everything visual lands on the AppKit
/// items instead. Styling is wiped whenever SwiftUI rebuilds the items —
/// including the rebuild the tracking notification itself triggers through
/// the browser store — so it is re-applied in a short burst after each
/// menu-bar tracking session begins; every pass is idempotent.
@MainActor
private enum DevelopMenuStyler {
    private static var observer: NSObjectProtocol?

    /// SF Symbol per localized row title, mirroring Safari's roster.
    /// Toggling rows appear under both of their titles.
    private static let symbolsByTitle: [String: String] = [
        BrowserCommandTitles.openPageWith: "arrow.up.forward.app",
        BrowserCommandTitles.userAgent: "globe",
        BrowserCommandTitles.showWebInspector: "macwindow.on.rectangle",
        BrowserCommandTitles.closeWebInspector: "macwindow.on.rectangle",
        BrowserCommandTitles.connectWebInspector: "rectangle.connected.to.line.below",
        BrowserCommandTitles.showJavaScriptConsole: "terminal",
        BrowserCommandTitles.showPageSource: "chevron.left.forwardslash.chevron.right",
        BrowserCommandTitles.showPageResources: "folder",
        BrowserCommandTitles.startTimelineRecording: "record.circle",
        BrowserCommandTitles.stopTimelineRecording: "record.circle",
        BrowserCommandTitles.startElementSelection: "cursorarrow.rays",
        BrowserCommandTitles.stopElementSelection: "cursorarrow.rays",
        BrowserCommandTitles.emptyCaches: "xmark",
        BrowserCommandTitles.developerSettings: "gearshape",
        BrowserCommandTitles.featureFlags: "flag",
        BrowserCommandTitles.copyURL: "link",
        BrowserCommandTitles.copyURLAsMarkdown: "doc.on.doc"
    ]

    static func install() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply() }
            // SwiftUI rebuilds triggered by the same notification (the
            // store nudge, the service-worker refresh) land on later
            // run-loop turns and hand back plain items; sweep behind them
            // while the menu is likely still open.
            for delay in [0.05, 0.15, 0.35, 0.7, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { apply() }
                }
            }
        }
    }

    private static func apply() {
        guard let mainMenu = NSApp.mainMenu,
              let developMenu = mainMenu.items.first(where: {
                  $0.submenu?.items.contains(where: isDeviceItem) == true
              })?.submenu
        else { return }

        for item in developMenu.items {
            if isDeviceItem(item) {
                styleDeviceItem(item)
            } else if item.image == nil,
                      let symbol = symbolsByTitle[item.title],
                      let icon = NSImage(
                          systemSymbolName: symbol,
                          accessibilityDescription: nil
                      ) {
                item.image = icon
            }
        }
    }

    private static func isDeviceItem(_ item: NSMenuItem) -> Bool {
        item.title == DeviceMenuPresentation.menuTitle
    }

    private static let iconSide: CGFloat = 24
    /// Canvas geometry picks the menu's layout mode: at 28pt and wider the
    /// device row gets the independent layout Safari's has (icon flush
    /// with the glyph column, text indented past it); narrower canvases
    /// join the shared icon column and poke left of the small glyphs. The
    /// trailing pad keeps the width above the threshold, the half-point
    /// leading pad lands the art on Safari's exact column position.
    private static let iconLeadingPad: CGFloat = 0.5
    private static let iconTrailingPad: CGFloat = 4

    /// NSImage.computerName carries transparent padding around the device
    /// art, which reads as an indent beside the menu's edge-to-edge SF
    /// Symbols. Crop to the art's alpha bounding box and draw it flush
    /// left, vertically centered, at Safari's proportions.
    private static func machineIcon() -> NSImage? {
        guard let machine = NSImage(named: NSImage.computerName) else { return nil }

        let probe = 64
        var buffer = [UInt8](repeating: 0, count: probe * probe * 4)
        guard let context = CGContext(
            data: &buffer, width: probe, height: probe,
            bitsPerComponent: 8, bytesPerRow: probe * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        machine.draw(in: NSRect(x: 0, y: 0, width: probe, height: probe))
        NSGraphicsContext.restoreGraphicsState()

        var minX = probe, maxX = -1, minY = probe, maxY = -1
        for y in 0..<probe {
            for x in 0..<probe where buffer[(y * probe + x) * 4 + 3] > 16 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Buffer rows run top-down while the image's coordinate space is
        // bottom-up, so the y range flips.
        let unit = machine.size.width / CGFloat(probe)
        let art = NSRect(
            x: CGFloat(minX) * unit,
            y: CGFloat(probe - 1 - maxY) * unit,
            width: CGFloat(maxX - minX + 1) * unit,
            height: CGFloat(maxY - minY + 1) * unit
        )

        let height = iconSide * art.height / art.width
        let canvasHeight = max(height, iconSide)
        let canvas = NSImage(
            size: NSSize(
                width: iconLeadingPad + iconSide + iconTrailingPad,
                height: canvasHeight
            ),
            flipped: false
        ) { _ in
            machine.draw(
                in: NSRect(
                    x: iconLeadingPad,
                    y: (canvasHeight - height) / 2,
                    width: iconSide,
                    height: height
                ),
                from: art,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        return canvas
    }

    /// Safari's device row: name over a dimmed subtitle with the machine's
    /// icon centered across both lines. The subtitled item is the system's
    /// own two-line layout; the icon then needs the private
    /// `-[NSMenuItem _setImageSize:]`, because item images are otherwise
    /// clamped to standard glyph size no matter the image's own size —
    /// probed with respondsToSelector, so a removed SPI just leaves the
    /// standard small icon. Pre-14.4 the two lines come from an attributed
    /// title with the small icon.
    private static func styleDeviceItem(_ item: NSMenuItem) {
        if item.attributedTitle == nil {
            let title = NSMutableAttributedString(
                string: DeviceMenuPresentation.deviceName + "\n",
                attributes: [.font: NSFont.menuFont(ofSize: 0)]
            )
            title.append(NSAttributedString(
                string: DeviceMenuPresentation.systemVersionLine,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            item.attributedTitle = title
        }

        let hasActionImageSelector = NSSelectorFromString("_hasActionImage")
        let alreadyStyled = item.image != nil
            || (item.responds(to: hasActionImageSelector)
                && item.method(for: hasActionImageSelector).map {
                    unsafeBitCast($0, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(item, hasActionImageSelector)
                } == true)
        if !alreadyStyled, let icon = machineIcon() {
            // The action-image slot is the leading icon column (where the
            // menu also places SF-symbol images); a plain item.image is a
            // content image with its own, more inset placement.
            let actionSelector = NSSelectorFromString("_setActionImage:")
            if item.responds(to: actionSelector) {
                _ = item.perform(actionSelector, with: icon)
                // The private setter posts no item-changed notification, so
                // whether the menu's column layout includes the icon was a
                // race against first layout; announce the change so the
                // geometry is recomputed deterministically.
                item.menu?.itemChanged(item)
            } else {
                item.image = icon
            }
            // Lifts the standard glyph-size clamp; a removed SPI just
            // leaves the standard small icon.
            let selector = NSSelectorFromString("_setImageSize:")
            if item.responds(to: selector), let method = item.method(for: selector) {
                let setImageSize = unsafeBitCast(
                    method,
                    to: (@convention(c) (AnyObject, Selector, NSSize) -> Void).self
                )
                setImageSize(item, selector, icon.size)
            }
        }

        guard let deviceSubmenu = item.submenu else { return }
        for row in deviceSubmenu.items {
            if row.title == "Candoa" {
                if row.image == nil,
                   let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
                    appIcon.size = NSSize(width: 16, height: 16)
                    row.image = appIcon
                }
            } else if row.isEnabled {
                row.indentationLevel = 1
            }
        }
    }
}

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

private struct BrowserCommands: Commands {
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
    var installedBrowsers: [ExternalBrowserService.Browser]
    var openPageWith: (ExternalBrowserService.Browser) -> Void
    var canUseDevelopTools: Bool
    /// nil while a custom (Other…) user agent is active.
    var activeUserAgentPreset: UserAgentPreset?
    var setUserAgentPreset: (UserAgentPreset) -> Void
    var isCustomUserAgentActive: Bool
    var promptForCustomUserAgent: () -> Void
    var inspectablePages: [BrowserStore.InspectablePage]
    var inspectPage: (UUID) -> Void
    var isWebInspectorVisible: Bool
    var toggleWebInspector: () -> Void
    var connectWebInspector: () -> Void
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
