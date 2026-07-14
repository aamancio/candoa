import AppKit
import SwiftUI

enum CandoaDockIconPreference: String, CaseIterable, Identifiable {
    static let storageKey = "Candoa.Settings.DockIconPreference"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    var imageName: NSImage.Name {
        switch self {
        case .system:
            return Self.resolvedSystemImageName
        case .light:
            return NSImage.Name("DockIconLight")
        case .dark:
            return NSImage.Name("DockIconDark")
        }
    }

    @MainActor
    static func updateApplicationIcon() {
        let storedValue = UserDefaults.standard.string(forKey: storageKey)
        let preference = CandoaDockIconPreference(rawValue: storedValue ?? "") ?? .system
        guard let image = NSImage(named: preference.imageName) else { return }

        image.isTemplate = false
        NSApplication.shared.applicationIconImage = image
    }

    @MainActor
    private static var resolvedSystemImageName: NSImage.Name {
        let appearance = NSApplication.shared.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSImage.Name(isDark ? "DockIconDark" : "DockIconLight")
    }
}

struct CandoaSettingsView: View {
    @State private var selectedTab = CandoaSettingsTab.general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.general.title, systemImage: CandoaSettingsTab.general.symbolName)
                }
                .tag(CandoaSettingsTab.general)

            SpacesSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.spaces.title, systemImage: CandoaSettingsTab.spaces.symbolName)
                }
                .tag(CandoaSettingsTab.spaces)

            LinksSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.links.title, systemImage: CandoaSettingsTab.links.symbolName)
                }
                .tag(CandoaSettingsTab.links)

            SearchSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.search.title, systemImage: CandoaSettingsTab.search.symbolName)
                }
                .tag(CandoaSettingsTab.search)

            PrivacySettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.privacy.title, systemImage: CandoaSettingsTab.privacy.symbolName)
                }
                .tag(CandoaSettingsTab.privacy)

            SyncSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.sync.title, systemImage: CandoaSettingsTab.sync.symbolName)
                }
                .tag(CandoaSettingsTab.sync)

            AskSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.ask.title, systemImage: CandoaSettingsTab.ask.symbolName)
                }
                .tag(CandoaSettingsTab.ask)

            ShortcutSettingsView()
                .tabItem {
                    Label(CandoaSettingsTab.shortcuts.title, systemImage: CandoaSettingsTab.shortcuts.symbolName)
                }
                .tag(CandoaSettingsTab.shortcuts)

            IconSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.icon.title, systemImage: CandoaSettingsTab.icon.symbolName)
                }
                .tag(CandoaSettingsTab.icon)

            AdvancedSettingsPane()
                .tabItem {
                    Label(CandoaSettingsTab.advanced.title, systemImage: CandoaSettingsTab.advanced.symbolName)
                }
                .tag(CandoaSettingsTab.advanced)
        }
        .tabViewStyle(.automatic)
        .frame(width: 780, height: 590)
    }
}

private enum CandoaSettingsTab: Hashable {
    case general
    case spaces
    case links
    case search
    case privacy
    case sync
    case ask
    case shortcuts
    case icon
    case advanced

    var title: String {
        switch self {
        case .general: return "General"
        case .spaces: return "Spaces"
        case .links: return "Links"
        case .search: return "Search"
        case .privacy: return "Privacy"
        case .sync: return "Sync"
        case .ask: return "Ask"
        case .shortcuts: return "Shortcuts"
        case .icon: return "Icon"
        case .advanced: return "Advanced"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .spaces: return "square.grid.2x2"
        case .links: return "rectangle.on.rectangle"
        case .search: return "magnifyingglass"
        case .privacy: return "hand.raised"
        case .sync: return "icloud"
        case .ask: return "sparkles"
        case .shortcuts: return "keyboard"
        case .icon: return "app.dashed"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

enum CandoaSettingsOption {
    static let prefix = "Candoa.Settings.ZenOption."

    static let openPreviousWindowsAndTabs = prefix + "OpenPreviousWindowsAndTabs"
    static let continueWhereLeftOff = prefix + "ContinueWhereLeftOff"
    static let checkDefaultBrowser = prefix + "CheckDefaultBrowser"
    static let openLinksInTabs = prefix + "OpenLinksInTabs"
    static let switchToOpenedTabImmediately = prefix + "SwitchToOpenedTabImmediately"
    static let openExternalLinksNextToActiveTab = prefix + "OpenExternalLinksNextToActiveTab"
    static let ctrlTabRecentlyUsedOrder = prefix + "CtrlTabRecentlyUsedOrder"
    static let dragTabsIntoGroups = prefix + "DragTabsIntoGroups"
    static let enableContainerTabs = prefix + "EnableContainerTabs"
    static let askBeforeClosingMultipleTabs = prefix + "AskBeforeClosingMultipleTabs"
    static let askBeforeQuitting = prefix + "AskBeforeQuitting"
    static let askModel = prefix + "AskModel"
    static let askUsesPersonalOpenAIKey = prefix + "AskUsesPersonalOpenAIKey"

    static let browserLayout = prefix + "BrowserLayout"
    static let showNewTabButtonOnTabList = prefix + "ShowNewTabButtonOnTabList"
    static let moveNewTabButtonToTop = prefix + "MoveNewTabButtonToTop"
    static let enableCompactMode = prefix + "EnableCompactMode"
    static let hideTopToolbarInCompactMode = prefix + "HideTopToolbarInCompactMode"
    static let compactToolbarFlashPopup = prefix + "CompactToolbarFlashPopup"
    static let enableGlance = prefix + "EnableGlance"
    static let glanceTrigger = prefix + "GlanceTrigger"
    static let urlBarBehavior = prefix + "URLBarBehavior"
    static let websiteAppearance = prefix + "WebsiteAppearance"
    static let darkThemeStyle = prefix + "DarkThemeStyle"

    static let syncOnlyPinnedTabs = prefix + "SyncOnlyPinnedTabs"
    static let hideDefaultContainerIndicator = prefix + "HideDefaultContainerIndicator"
    static let forceContainerTabsToWorkspace = prefix + "ForceContainerTabsToWorkspace"
    static let closeOnBackWithNoHistory = prefix + "CloseOnBackWithNoHistory"
    static let ignorePendingTabsWhenCycling = prefix + "IgnorePendingTabsWhenCycling"
    static let ctrlTabCyclesWithinScope = prefix + "CtrlTabCyclesWithinScope"
    static let selectRecentlyUsedOnClose = prefix + "SelectRecentlyUsedOnClose"
    static let restorePinnedTabsToPinnedURL = prefix + "RestorePinnedTabsToPinnedURL"
    static let containerSpecificEssentials = prefix + "ContainerSpecificEssentials"
    static let pinnedCloseShortcutBehavior = prefix + "PinnedCloseShortcutBehavior"

    static let disableDefaultShortcuts = prefix + "DisableDefaultShortcuts"
    static let defaultSearchProvider = prefix + "DefaultSearchProvider"
    static let showSearchSuggestions = prefix + "ShowSearchSuggestions"
    static let showQuickActions = prefix + "ShowQuickActions"
    static let strictTrackingProtection = prefix + "StrictTrackingProtection"
    static let clearCookiesOnQuit = prefix + "ClearCookiesOnQuit"
    static let blockPopups = prefix + "BlockPopups"
}

private struct GeneralSettingsPane: View {
    @AppStorage(CandoaSettingsOption.openPreviousWindowsAndTabs) private var openPreviousWindowsAndTabs = true
    @AppStorage(CandoaSettingsOption.continueWhereLeftOff) private var continueWhereLeftOff = false
    @AppStorage(CandoaSettingsOption.checkDefaultBrowser) private var checkDefaultBrowser = false
    @AppStorage(CandoaSettingsOption.askBeforeQuitting) private var askBeforeQuitting = true
    @AppStorage(CandoaSettingsOption.websiteAppearance) private var websiteAppearance = "dark"
    @AppStorage(CandoaSettingsOption.defaultSearchProvider) private var defaultSearchProvider = NavigationService.searchProviders.first?.id ?? "google"
    @AppStorage(CandoaSettingsOption.showSearchSuggestions) private var showSearchSuggestions = true
    @State private var syncsWorkspaceWithICloud = CandoaSyncPreferences.syncsWorkspaceWithICloud
    @State private var syncsHistoryWithICloud = CandoaSyncPreferences.syncsHistoryWithICloud

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    SettingsRow(
                        systemImage: "app.badge",
                        title: "Default browser",
                        subtitle: "Set Candoa as the default browser in macOS."
                    ) {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "macwindow.on.rectangle",
                        title: "Open previous windows and tabs",
                        subtitle: "Restore the browser window state at launch.",
                        isOn: $openPreviousWindowsAndTabs
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.clockwise",
                        title: "Continue where you left off",
                        subtitle: "Use the active workspace and tab from the last session.",
                        isOn: $continueWhereLeftOff
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "checkmark.seal",
                        title: "Always check if Candoa is your default browser",
                        subtitle: "Show a default-browser reminder at startup.",
                        isOn: $checkDefaultBrowser
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "command",
                        title: "Ask before quitting with Command-Q",
                        subtitle: "Confirm before quitting the app from the keyboard.",
                        isOn: $askBeforeQuitting
                    )
                }

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "macwindow",
                        title: "Website appearance",
                        subtitle: "Choose which color scheme sites should use.",
                        selection: $websiteAppearance,
                        options: [
                            SettingsPickerOption(id: "automatic", title: "Automatic"),
                            SettingsPickerOption(id: "light", title: "Light"),
                            SettingsPickerOption(id: "dark", title: "Dark")
                        ]
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "magnifyingglass",
                        title: "Search engine",
                        subtitle: "Used by the command bar and address field.",
                        selection: $defaultSearchProvider,
                        options: NavigationService.defaultSearchProviders.map {
                            SettingsPickerOption(id: $0.id, title: defaultSearchEngineTitle(for: $0))
                        }
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "lightbulb",
                        title: "Include search suggestions",
                        subtitle: "Show search completions in the command surface.",
                        isOn: $showSearchSuggestions
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: "Sync Spaces with iCloud",
                        subtitle: CandoaCloudKitEntitlements.hasConfiguredContainer
                            ? "Keep Spaces and tabs available on your Macs."
                            : "This build is missing the CloudKit entitlement.",
                        isOn: workspaceSyncBinding
                    )
                    .disabled(!CandoaCloudKitEntitlements.hasConfiguredContainer)

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.arrow.circlepath",
                        title: "Sync history",
                        subtitle: "Requires Spaces sync.",
                        isOn: historySyncBinding
                    )
                    .disabled(!CandoaCloudKitEntitlements.hasConfiguredContainer || !syncsWorkspaceWithICloud)
                }
            }
        }
        .onAppear(perform: normalizeDefaultSearchProvider)
    }

    private func normalizeDefaultSearchProvider() {
        let normalizedProvider = NavigationService.defaultSearchProvider(for: defaultSearchProvider)
        if normalizedProvider.id != defaultSearchProvider {
            defaultSearchProvider = normalizedProvider.id
        }
    }

    private func defaultSearchEngineTitle(for provider: SearchProvider) -> String {
        switch provider.id {
        case "bing":
            return "Microsoft Bing"
        case "yahoo":
            return "Yahoo!"
        default:
            return provider.name
        }
    }

    private var workspaceSyncBinding: Binding<Bool> {
        Binding {
            syncsWorkspaceWithICloud
        } set: { newValue in
            syncsWorkspaceWithICloud = newValue
            CandoaSyncPreferences.syncsWorkspaceWithICloud = newValue
            if !newValue {
                syncsHistoryWithICloud = false
                CandoaSyncPreferences.syncsHistoryWithICloud = false
            }
        }
    }

    private var historySyncBinding: Binding<Bool> {
        Binding {
            syncsHistoryWithICloud
        } set: { newValue in
            if newValue, !syncsWorkspaceWithICloud {
                syncsWorkspaceWithICloud = true
                CandoaSyncPreferences.syncsWorkspaceWithICloud = true
            }
            syncsHistoryWithICloud = newValue
            CandoaSyncPreferences.syncsHistoryWithICloud = newValue
        }
    }
}

private struct LookAndFeelSettingsPane: View {
    @AppStorage(CandoaSettingsOption.browserLayout) private var browserLayout = "single"
    @AppStorage(CandoaSettingsOption.showNewTabButtonOnTabList) private var showNewTabButtonOnTabList = true
    @AppStorage(CandoaSettingsOption.moveNewTabButtonToTop) private var moveNewTabButtonToTop = true
    @AppStorage(CandoaSettingsOption.enableCompactMode) private var enableCompactMode = false
    @AppStorage(CandoaSettingsOption.hideTopToolbarInCompactMode) private var hideTopToolbarInCompactMode = false
    @AppStorage(CandoaSettingsOption.compactToolbarFlashPopup) private var compactToolbarFlashPopup = true
    @AppStorage(CandoaSettingsOption.enableGlance) private var enableGlance = true
    @AppStorage(CandoaSettingsOption.glanceTrigger) private var glanceTrigger = "meta"
    @AppStorage(CandoaSettingsOption.urlBarBehavior) private var urlBarBehavior = "floating-on-type"
    @AppStorage(CandoaSettingsOption.darkThemeStyle) private var darkThemeStyle = "default"
    @AppStorage(CandoaDockIconPreference.storageKey) private var selectedIconPreference = CandoaDockIconPreference.system.rawValue

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Browser Layout")

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "sidebar.left",
                        title: "Layout",
                        subtitle: "Choose the layout that suits you best.",
                        selection: $browserLayout,
                        options: [
                            SettingsPickerOption(id: "single", title: "Only Sidebar"),
                            SettingsPickerOption(id: "multiple", title: "Sidebar and Top Toolbar"),
                            SettingsPickerOption(id: "collapsed", title: "Collapsed Sidebar")
                        ]
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "plus.rectangle.on.rectangle",
                        title: "Show New Tab Button on Tab List",
                        subtitle: "Display a new-tab affordance inside the vertical tab list.",
                        isOn: $showNewTabButtonOnTabList
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.up.to.line.compact",
                        title: "Move the new tab button to the top",
                        subtitle: "Place the new-tab button above tab rows.",
                        isOn: $moveNewTabButtonToTop
                    )
                }

                SettingsSectionTitle("Compact View")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "rectangle.compress.vertical",
                        title: "Enable Candoa's compact mode",
                        subtitle: "Only show the toolbars you use.",
                        isOn: $enableCompactMode
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "toolbar",
                        title: "Hide the top toolbar as well in compact mode",
                        subtitle: "Keep browser chrome minimized until you need it.",
                        isOn: $hideTopToolbarInCompactMode
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "bolt",
                        title: "Briefly make the toolbar popup when switching or opening new tabs in compact mode",
                        subtitle: "Use a short native reveal for orientation.",
                        isOn: $compactToolbarFlashPopup
                    )
                }

                SettingsSectionTitle("Glance")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "eye",
                        title: "Enable Glance",
                        subtitle: "Get a quick overview of links without opening them in a new tab.",
                        isOn: $enableGlance
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "cursorarrow.click",
                        title: "Trigger method",
                        subtitle: "Choose the modifier used to open Glance.",
                        selection: $glanceTrigger,
                        options: [
                            SettingsPickerOption(id: "ctrl", title: "Control + Click"),
                            SettingsPickerOption(id: "alt", title: "Option + Click"),
                            SettingsPickerOption(id: "shift", title: "Shift + Click"),
                            SettingsPickerOption(id: "meta", title: "Command + Click")
                        ]
                    )
                }

                SettingsSectionTitle("URL Bar")

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "text.cursor",
                        title: "Behavior",
                        subtitle: "Customize how the address and command surface appears.",
                        selection: $urlBarBehavior,
                        options: [
                            SettingsPickerOption(id: "normal", title: "Normal"),
                            SettingsPickerOption(id: "floating-on-type", title: "Floating only when typing"),
                            SettingsPickerOption(id: "float", title: "Always floating")
                        ]
                    )
                }

                SettingsSectionTitle("Dark Theme Styles")

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "moon",
                        title: "Dark Theme Style",
                        subtitle: "Customize the dark theme to your liking.",
                        selection: $darkThemeStyle,
                        options: [
                            SettingsPickerOption(id: "night", title: "Night Theme"),
                            SettingsPickerOption(id: "default", title: "Default Dark Theme"),
                            SettingsPickerOption(id: "colorful", title: "Colorful Dark Theme")
                        ]
                    )
                }

                SettingsSectionTitle("App Icon")

                SettingsCard {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(CandoaDockIconPreference.allCases) { preference in
                            DockIconChoice(
                                preference: preference,
                                isSelected: selectedIconPreference == preference.rawValue
                            ) {
                                selectedIconPreference = preference.rawValue
                                CandoaDockIconPreference.updateApplicationIcon()
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

private struct SpacesSettingsPane: View {
    @AppStorage(CandoaSettingsOption.dragTabsIntoGroups) private var dragTabsIntoGroups = true
    @AppStorage(CandoaSettingsOption.enableContainerTabs) private var enableContainerTabs = true
    @AppStorage(CandoaSettingsOption.syncOnlyPinnedTabs) private var syncOnlyPinnedTabs = false
    @AppStorage(CandoaSettingsOption.ignorePendingTabsWhenCycling) private var ignorePendingTabsWhenCycling = false
    @AppStorage(CandoaSettingsOption.ctrlTabCyclesWithinScope) private var ctrlTabCyclesWithinScope = false
    @AppStorage(CandoaSettingsOption.selectRecentlyUsedOnClose) private var selectRecentlyUsedOnClose = true
    @AppStorage(CandoaSettingsOption.restorePinnedTabsToPinnedURL) private var restorePinnedTabsToPinnedURL = false
    @AppStorage(CandoaSettingsOption.containerSpecificEssentials) private var containerSpecificEssentials = true
    @AppStorage(CandoaSettingsOption.pinnedCloseShortcutBehavior) private var pinnedCloseShortcutBehavior = "reset-unload-switch"

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "rectangle.stack.badge.plus",
                        title: "Drag tabs together to create groups",
                        subtitle: "Enable grouping gestures in the sidebar.",
                        isOn: $dragTabsIntoGroups
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "shippingbox",
                        title: "Container tabs",
                        subtitle: "Keep separate sessions available for Spaces.",
                        isOn: $enableContainerTabs
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "pin",
                        title: "Sync only pinned tabs",
                        subtitle: "Keep workspace sync focused on pinned tabs.",
                        isOn: $syncOnlyPinnedTabs
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "clock.badge.xmark",
                        title: "Ignore pending tabs when cycling",
                        subtitle: "Skip unloaded tabs with Ctrl-Tab.",
                        isOn: $ignorePendingTabsWhenCycling
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "rectangle.3.group",
                        title: "Cycle within the current scope",
                        subtitle: "Keep Ctrl-Tab inside the current tab group.",
                        isOn: $ctrlTabCyclesWithinScope
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.left.arrow.right",
                        title: "Select recently used tab on close",
                        subtitle: "Return to the tab you used most recently.",
                        isOn: $selectRecentlyUsedOnClose
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "pin.circle",
                        title: "Restore pinned tabs to pinned URL",
                        subtitle: "Reset pinned tabs to their saved URL on launch.",
                        isOn: $restorePinnedTabsToPinnedURL
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: "Container-specific essentials",
                        subtitle: "Separate essential tabs by container.",
                        isOn: $containerSpecificEssentials
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "keyboard",
                        title: "Pinned tab close shortcut",
                        subtitle: "Choose what Command-W does on pinned tabs.",
                        selection: $pinnedCloseShortcutBehavior,
                        options: [
                            SettingsPickerOption(id: "reset-unload-switch", title: "Reset, unload, switch"),
                            SettingsPickerOption(id: "unload-switch", title: "Unload and switch"),
                            SettingsPickerOption(id: "reset-switch", title: "Reset and switch"),
                            SettingsPickerOption(id: "switch", title: "Switch"),
                            SettingsPickerOption(id: "reset", title: "Reset"),
                            SettingsPickerOption(id: "close", title: "Close")
                        ]
                    )
                }
            }
        }
    }
}

private struct LinksSettingsPane: View {
    @AppStorage(CandoaSettingsOption.openLinksInTabs) private var openLinksInTabs = true
    @AppStorage(CandoaSettingsOption.switchToOpenedTabImmediately) private var switchToOpenedTabImmediately = false
    @AppStorage(CandoaSettingsOption.openExternalLinksNextToActiveTab) private var openExternalLinksNextToActiveTab = false
    @AppStorage(CandoaSettingsOption.enableGlance) private var enableGlance = true
    @AppStorage(CandoaSettingsOption.glanceTrigger) private var glanceTrigger = "meta"
    @AppStorage(CandoaSettingsOption.urlBarBehavior) private var urlBarBehavior = "floating-on-type"

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "rectangle.on.rectangle",
                        title: "Open links in tabs",
                        subtitle: "Prefer tabs for links that request a new window.",
                        isOn: $openLinksInTabs
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrowshape.turn.up.right",
                        title: "Switch to newly opened tabs",
                        subtitle: "Bring new tabs forward as they open.",
                        isOn: $switchToOpenedTabImmediately
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.right.to.line.compact",
                        title: "Open external links next to active tab",
                        subtitle: "Place links from other apps near your current tab.",
                        isOn: $openExternalLinksNextToActiveTab
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "eye",
                        title: "Glance",
                        subtitle: "Preview a link without opening a new tab.",
                        isOn: $enableGlance
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "cursorarrow.click",
                        title: "Glance trigger",
                        subtitle: "Choose the modifier used while clicking links.",
                        selection: $glanceTrigger,
                        options: [
                            SettingsPickerOption(id: "ctrl", title: "Control + Click"),
                            SettingsPickerOption(id: "alt", title: "Option + Click"),
                            SettingsPickerOption(id: "shift", title: "Shift + Click"),
                            SettingsPickerOption(id: "meta", title: "Command + Click")
                        ]
                    )
                }

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "text.cursor",
                        title: "URL bar",
                        subtitle: "Choose how the address surface appears.",
                        selection: $urlBarBehavior,
                        options: [
                            SettingsPickerOption(id: "normal", title: "Normal"),
                            SettingsPickerOption(id: "floating-on-type", title: "Floating while typing"),
                            SettingsPickerOption(id: "float", title: "Always floating")
                        ]
                    )
                }
            }
        }
    }
}

private struct IconSettingsPane: View {
    @AppStorage(CandoaDockIconPreference.storageKey) private var selectedIconPreference = CandoaDockIconPreference.system.rawValue

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(CandoaDockIconPreference.allCases) { preference in
                            DockIconChoice(
                                preference: preference,
                                isSelected: selectedIconPreference == preference.rawValue
                            ) {
                                selectedIconPreference = preference.rawValue
                                CandoaDockIconPreference.updateApplicationIcon()
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                SettingsCard {
                    SettingsRow(
                        systemImage: "paintbrush",
                        title: "Website appearance",
                        subtitle: "Website theme controls are in General."
                    ) {
                        SettingsStatusPill(text: "General")
                    }
                }
            }
        }
    }
}

private struct TabManagementSettingsPane: View {
    @AppStorage(CandoaSettingsOption.syncOnlyPinnedTabs) private var syncOnlyPinnedTabs = false
    @AppStorage(CandoaSettingsOption.hideDefaultContainerIndicator) private var hideDefaultContainerIndicator = true
    @AppStorage(CandoaSettingsOption.forceContainerTabsToWorkspace) private var forceContainerTabsToWorkspace = false
    @AppStorage(CandoaSettingsOption.closeOnBackWithNoHistory) private var closeOnBackWithNoHistory = true
    @AppStorage(CandoaSettingsOption.ignorePendingTabsWhenCycling) private var ignorePendingTabsWhenCycling = false
    @AppStorage(CandoaSettingsOption.ctrlTabCyclesWithinScope) private var ctrlTabCyclesWithinScope = false
    @AppStorage(CandoaSettingsOption.selectRecentlyUsedOnClose) private var selectRecentlyUsedOnClose = true
    @AppStorage(CandoaSettingsOption.restorePinnedTabsToPinnedURL) private var restorePinnedTabsToPinnedURL = false
    @AppStorage(CandoaSettingsOption.containerSpecificEssentials) private var containerSpecificEssentials = true
    @AppStorage(CandoaSettingsOption.pinnedCloseShortcutBehavior) private var pinnedCloseShortcutBehavior = "reset-unload-switch"

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Workspaces")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "pin",
                        title: "Sync only pinned tabs in workspaces",
                        subtitle: "Limit workspace sync to pinned tabs.",
                        isOn: $syncOnlyPinnedTabs
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "shippingbox",
                        title: "Hide the default container indicator in the tab bar",
                        subtitle: "Reduce visual noise when a tab uses the default container.",
                        isOn: $hideDefaultContainerIndicator
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrowshape.turn.up.right.circle",
                        title: "Switch to workspace where container is set as default when opening container tabs",
                        subtitle: "Route container tabs into their matching workspace.",
                        isOn: $forceContainerTabsToWorkspace
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.uturn.backward",
                        title: "Close tab and switch to its owner tab when going back with no history",
                        subtitle: "Use the owner tab, or the most recently used tab, as the fallback.",
                        isOn: $closeOnBackWithNoHistory
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.badge.xmark",
                        title: "Ignore pending tabs when cycling with Ctrl-Tab",
                        subtitle: "Skip tabs that have not loaded yet.",
                        isOn: $ignorePendingTabsWhenCycling
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "rectangle.3.group",
                        title: "Ctrl-Tab cycles within Essential or Workspace tabs only",
                        subtitle: "Keep tab switching scoped to the current tab group.",
                        isOn: $ctrlTabCyclesWithinScope
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.left.arrow.right",
                        title: "When closing a tab, switch to the most recently used tab instead of the next tab",
                        subtitle: "Use recent tab order for close behavior.",
                        isOn: $selectRecentlyUsedOnClose
                    )
                }

                SettingsSectionTitle("Pinned Tabs")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "pin.circle",
                        title: "Restore pinned tabs to their originally pinned URL on startup",
                        subtitle: "Reset pinned tabs back to their saved URL after relaunch.",
                        isOn: $restorePinnedTabsToPinnedURL
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: "Enable container-specific essentials",
                        subtitle: "Keep essential tabs separated per container/workspace.",
                        isOn: $containerSpecificEssentials
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "keyboard",
                        title: "Close Tab Shortcut Behavior",
                        subtitle: "Choose what the close shortcut does on pinned tabs.",
                        selection: $pinnedCloseShortcutBehavior,
                        options: [
                            SettingsPickerOption(id: "reset-unload-switch", title: "Reset URL, unload and switch to next tab"),
                            SettingsPickerOption(id: "unload-switch", title: "Unload and switch to next tab"),
                            SettingsPickerOption(id: "reset-switch", title: "Reset URL and switch to next tab"),
                            SettingsPickerOption(id: "switch", title: "Switch to next tab"),
                            SettingsPickerOption(id: "reset", title: "Reset URL"),
                            SettingsPickerOption(id: "close", title: "Close tab")
                        ]
                    )
                }
            }
        }
    }
}

private struct SearchSettingsPane: View {
    private let providers = NavigationService.searchProviders
    private let defaultSearchProviders = NavigationService.defaultSearchProviders
    @AppStorage(CandoaSettingsOption.defaultSearchProvider) private var defaultSearchProvider = NavigationService.searchProviders.first?.id ?? "google"
    @AppStorage(CandoaSettingsOption.showSearchSuggestions) private var showSearchSuggestions = true
    @AppStorage(CandoaSettingsOption.showQuickActions) private var showQuickActions = true

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Search")

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "magnifyingglass",
                        title: "Default Search Engine",
                        subtitle: "Choose the search provider shown first in the command surface.",
                        selection: $defaultSearchProvider,
                        options: defaultSearchProviders.map {
                            SettingsPickerOption(id: $0.id, title: defaultSearchEngineTitle(for: $0))
                        }
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "lightbulb",
                        title: "Show search suggestions",
                        subtitle: "Allow the command surface to suggest search completions.",
                        isOn: $showSearchSuggestions
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "command",
                        title: "Show quick actions",
                        subtitle: "Include workspace and browser actions in URL bar suggestions.",
                        isOn: $showQuickActions
                    )
                }

                SettingsSectionTitle("Search Shortcuts")

                SettingsCard {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        SearchProviderSettingsRow(provider: provider)

                        if index < providers.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
        .onAppear(perform: normalizeDefaultSearchProvider)
    }

    private func normalizeDefaultSearchProvider() {
        let normalizedProvider = NavigationService.defaultSearchProvider(for: defaultSearchProvider)
        if normalizedProvider.id != defaultSearchProvider {
            defaultSearchProvider = normalizedProvider.id
        }
    }

    private func defaultSearchEngineTitle(for provider: SearchProvider) -> String {
        switch provider.id {
        case "bing":
            return "Microsoft Bing"
        case "yahoo":
            return "Yahoo!"
        default:
            return provider.name
        }
    }
}

private struct PrivacySettingsPane: View {
    @AppStorage(CandoaSettingsOption.strictTrackingProtection) private var strictTrackingProtection = true
    @AppStorage(CandoaSettingsOption.clearCookiesOnQuit) private var clearCookiesOnQuit = false
    @AppStorage(CandoaSettingsOption.blockPopups) private var blockPopups = true

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Privacy and Security")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "hand.raised",
                        title: "Strict tracking protection",
                        subtitle: "Keep tracker and ad blocking in WebKit's content rule list.",
                        isOn: $strictTrackingProtection
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "trash",
                        title: "Clear cookies and site data when Candoa quits",
                        subtitle: "Reserve a local privacy option for session cleanup.",
                        isOn: $clearCookiesOnQuit
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "macwindow.badge.xmark",
                        title: "Block pop-up windows",
                        subtitle: "Prevent pages from opening unwanted windows.",
                        isOn: $blockPopups
                    )
                }
            }
        }
    }
}

private struct SyncSettingsPane: View {
    @State private var syncsWorkspaceWithICloud = CandoaSyncPreferences.syncsWorkspaceWithICloud
    @State private var syncsHistoryWithICloud = CandoaSyncPreferences.syncsHistoryWithICloud
    @State private var syncMessage: String?

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Sync")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: "Workspaces",
                        subtitle: CandoaCloudKitEntitlements.hasConfiguredContainer
                            ? "Sync workspaces, Spaces, and tabs through iCloud after relaunch."
                            : "This build is missing the CloudKit entitlement.",
                        isOn: workspaceSyncBinding
                    )
                    .disabled(!CandoaCloudKitEntitlements.hasConfiguredContainer)

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.arrow.circlepath",
                        title: "History",
                        subtitle: "History sync depends on workspace sync.",
                        isOn: historySyncBinding
                    )
                    .disabled(!CandoaCloudKitEntitlements.hasConfiguredContainer || !syncsWorkspaceWithICloud)

                    if let syncMessage {
                        SettingsDivider()

                        Text(syncMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var workspaceSyncBinding: Binding<Bool> {
        Binding {
            syncsWorkspaceWithICloud
        } set: { newValue in
            syncsWorkspaceWithICloud = newValue
            CandoaSyncPreferences.syncsWorkspaceWithICloud = newValue
            if !newValue {
                syncsHistoryWithICloud = false
            }
            syncMessage = newValue
                ? "Candoa will sync Spaces and tabs through your private iCloud database after relaunch."
                : "Candoa will keep Spaces and tabs local-only after relaunch."
        }
    }

    private var historySyncBinding: Binding<Bool> {
        Binding {
            syncsHistoryWithICloud
        } set: { newValue in
            if newValue, !syncsWorkspaceWithICloud {
                syncsWorkspaceWithICloud = true
                CandoaSyncPreferences.syncsWorkspaceWithICloud = true
            }
            syncsHistoryWithICloud = newValue
            CandoaSyncPreferences.syncsHistoryWithICloud = newValue
            syncMessage = newValue
                ? "Candoa will sync history through your private iCloud database after relaunch."
                : "Candoa will keep history local-only after relaunch."
        }
    }
}

private struct AdvancedSettingsPane: View {
    @AppStorage("CandoaEnableWebInspector") private var isWebInspectorEnabled = false
    @AppStorage(CandoaSettingsOption.disableDefaultShortcuts) private var disableDefaultShortcuts = false
    @AppStorage(CandoaSettingsOption.strictTrackingProtection) private var strictTrackingProtection = true
    @AppStorage(CandoaSettingsOption.clearCookiesOnQuit) private var clearCookiesOnQuit = false
    @AppStorage(CandoaSettingsOption.blockPopups) private var blockPopups = true
    @AppStorage(CandoaSettingsOption.askBeforeClosingMultipleTabs) private var askBeforeClosingMultipleTabs = false
    @AppStorage(CandoaSettingsOption.browserLayout) private var browserLayout = "single"
    @AppStorage(CandoaSettingsOption.enableCompactMode) private var enableCompactMode = false
    @AppStorage(CandoaSettingsOption.hideTopToolbarInCompactMode) private var hideTopToolbarInCompactMode = false

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "sidebar.left",
                        title: "Browser layout",
                        subtitle: "Choose the chrome layout for browsing.",
                        selection: $browserLayout,
                        options: [
                            SettingsPickerOption(id: "single", title: "Only Sidebar"),
                            SettingsPickerOption(id: "multiple", title: "Sidebar and Top Toolbar"),
                            SettingsPickerOption(id: "collapsed", title: "Collapsed Sidebar")
                        ]
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "rectangle.compress.vertical",
                        title: "Compact mode",
                        subtitle: "Keep browser chrome minimized until you need it.",
                        isOn: $enableCompactMode
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "toolbar",
                        title: "Hide top toolbar in compact mode",
                        subtitle: "Use the sidebar as the primary chrome.",
                        isOn: $hideTopToolbarInCompactMode
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "exclamationmark.triangle",
                        title: "Ask before closing multiple tabs",
                        subtitle: "Confirm before closing several active tabs.",
                        isOn: $askBeforeClosingMultipleTabs
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "keyboard.badge.ellipsis",
                        title: "Disable Candoa's default keyboard shortcuts",
                        subtitle: "Reserve the default shortcut set for custom bindings.",
                        isOn: $disableDefaultShortcuts
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "hand.raised",
                        title: "Strict tracking protection",
                        subtitle: "Use WebKit content rules for tracker blocking.",
                        isOn: $strictTrackingProtection
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "macwindow.badge.xmark",
                        title: "Block pop-up windows",
                        subtitle: "Prevent pages from opening unwanted windows.",
                        isOn: $blockPopups
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "trash",
                        title: "Clear cookies on quit",
                        subtitle: "Remove site cookies and data when Candoa exits.",
                        isOn: $clearCookiesOnQuit
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "ladybug",
                        title: "Web Inspector",
                        subtitle: "In Debug builds this is always available; Release builds read this preference.",
                        isOn: $isWebInspectorEnabled
                    )

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "snowflake",
                        title: "Tab Hibernation",
                        subtitle: "Idle background tabs release their web view after \(Int(TabHibernationConfiguration.idleInterval / 60)) minutes."
                    ) {
                        SettingsStatusPill(text: "On")
                    }

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "arrow.triangle.2.circlepath",
                        title: "Update Checks",
                        subtitle: "Sparkle manages update checks using the app bundle configuration."
                    ) {
                        SettingsStatusPill(text: "Automatic")
                    }
                }
            }
        }
    }
}

private struct AskSettingsPane: View {
    @AppStorage(CandoaSettingsOption.askModel) private var model = CandoaAskPreferences.defaultModel
    @AppStorage(CandoaSettingsOption.askUsesPersonalOpenAIKey) private var usesPersonalOpenAIKey = false
    @State private var apiKey = ""
    @State private var hasSavedKey = CandoaAskKeychain.hasAPIKey
    @State private var keychainError: String?

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Ask")

                SettingsCard {
                    SettingsRow(
                        systemImage: "cpu",
                        title: "Model",
                        subtitle: "Use this model with your own OpenAI key. Candoa's hosted service manages its model on the server."
                    ) {
                        TextField("Model ID", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                    }

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "key.horizontal",
                        title: "Use your own OpenAI API key",
                        subtitle: "Keep your key in Keychain and send requests directly to OpenAI.",
                        isOn: $usesPersonalOpenAIKey
                    )
                }

                SettingsSectionTitle("Personal API Key")

                SettingsCard {
                    SettingsRow(
                        systemImage: "lock",
                        title: hasSavedKey ? "Replace saved key" : "Save an OpenAI API key",
                        subtitle: "Candoa stores only the key in this Mac's Keychain. It is never sent to Candoa."
                    ) {
                        HStack(spacing: 8) {
                            SecureField("sk-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)

                            Button(hasSavedKey ? "Replace" : "Save", action: saveAPIKey)
                                .controlSize(.small)
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if hasSavedKey {
                        SettingsDivider()

                        SettingsRow(
                            systemImage: "checkmark.shield",
                            title: "Personal key saved",
                            subtitle: "Ask can use your direct OpenAI connection whenever the option above is enabled."
                        ) {
                            Button("Remove", role: .destructive, action: removeAPIKey)
                                .controlSize(.small)
                        }
                    }

                    if let keychainError {
                        SettingsDivider()

                        Text(keychainError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func saveAPIKey() {
        do {
            try CandoaAskKeychain.save(apiKey)
            apiKey = ""
            hasSavedKey = true
            usesPersonalOpenAIKey = true
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try CandoaAskKeychain.remove()
            hasSavedKey = false
            usesPersonalOpenAIKey = false
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }
}

struct ShortcutSettingsView: View {
    @State private var searchText = ""

    private var filteredDefinitions: [CandoaShortcutDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return CandoaShortcutDefinition.allCases }
        return CandoaShortcutDefinition.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                $0.category.localizedCaseInsensitiveContains(query) ||
                $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("Type a feature name or shortcut", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }

                SettingsCard {
                    if filteredDefinitions.isEmpty {
                        Text("No shortcuts found.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ForEach(Array(filteredDefinitions.enumerated()), id: \.element.id) { index, definition in
                            ShortcutSettingsRow(definition: definition)

                            if index < filteredDefinitions.count - 1 {
                                SettingsDivider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }

                Text("Custom shortcut capture is local to this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
        }
    }
}

private struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 640)
                .padding(.horizontal, 48)
                .padding(.top, 28)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let accessory: Accessory

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
    }
}

private struct SettingsToggleRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(systemImage: systemImage, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

private struct SettingsPickerOption: Identifiable {
    let id: String
    let title: String
}

private struct SettingsPickerRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @Binding var selection: String
    let options: [SettingsPickerOption]

    var body: some View {
        SettingsRow(systemImage: systemImage, title: title, subtitle: subtitle) {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 190)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.primary.opacity(0.10))
    }
}

private struct SettingsStatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

private struct SettingsShortcutPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SettingsIdentityCard: View {
    let displayName: String
    let emailAddress: String
    let initials: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.04, green: 0.68, blue: 0.64),
                                Color(red: 0.15, green: 0.50, blue: 0.84),
                                Color(red: 0.44, green: 0.25, blue: 0.70)
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
                    .frame(height: 210)
                    .overlay(alignment: .bottomLeading) {
                        Circle()
                            .fill(.regularMaterial)
                            .frame(width: 86, height: 86)
                            .overlay {
                                Text(initials)
                                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                            }
                            .padding(18)
                    }

                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(displayName.isEmpty ? "Candoa User" : displayName)
                    .font(.system(size: 28, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(emailAddress.isEmpty ? "Local profile" : emailAddress)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(20)
        }
        .frame(height: 392)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct SearchProviderSettingsRow: View {
    let provider: SearchProvider

    private var aliasText: String {
        provider.aliases.prefix(4).joined(separator: ", ")
    }

    var body: some View {
        SettingsRow(
            systemImage: provider.symbolName,
            title: provider.name,
            subtitle: aliasText
        ) {
            Text(provider.homeURL.host ?? provider.homeURL.absoluteString)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .trailing)
        }
    }
}

private struct DockIconChoice: View {
    let preference: CandoaDockIconPreference
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(nsImage: NSImage(named: preference.imageName) ?? NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                Text(preference.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .padding(10)
            .frame(width: 124)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(preference.title)
    }
}

private struct ShortcutSettingsRow: View {
    let definition: CandoaShortcutDefinition

    @AppStorage private var storedShortcut: String
    @State private var isRecording = false

    private var displayShortcut: String {
        if storedShortcut == CandoaShortcutDefinition.removedValue {
            return "None"
        }

        return storedShortcut.isEmpty ? definition.defaultShortcut : storedShortcut
    }

    private var isRemoved: Bool {
        storedShortcut == CandoaShortcutDefinition.removedValue
    }

    init(definition: CandoaShortcutDefinition) {
        self.definition = definition
        _storedShortcut = AppStorage(wrappedValue: "", definition.storageKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: definition.symbolName)
                .foregroundStyle(.secondary)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(definition.title)
                    .font(.system(size: 13))

                Text(definition.category)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isRecording = true
            } label: {
                Text(isRecording ? "Press Keys" : displayShortcut)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 132)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Set Shortcut")

            Button {
                storedShortcut = isRemoved ? "" : CandoaShortcutDefinition.removedValue
            } label: {
                Image(systemName: isRemoved ? "plus" : "minus")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(isRemoved ? "Restore Shortcut" : "Remove Shortcut")

            Button {
                storedShortcut = ""
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(storedShortcut.isEmpty)
            .help("Reset to Default")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if isRecording {
                ShortcutCaptureView { shortcut in
                    storedShortcut = shortcut
                    isRecording = false
                } onCancel: {
                    isRecording = false
                }
            }
        }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private let onCapture: (String) -> Void
        private let onCancel: () -> Void
        private var monitor: Any?

        init(onCapture: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func install() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                if event.keyCode == 53 {
                    onCancel()
                    return nil
                }

                guard let shortcut = Self.shortcutString(for: event) else {
                    NSSound.beep()
                    return nil
                }

                onCapture(shortcut)
                return nil
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func shortcutString(for event: NSEvent) -> String? {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])

            guard !modifiers.isEmpty else { return nil }

            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Control") }
            if modifiers.contains(.option) { parts.append("Option") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Command") }

            let key = keyString(for: event)
            guard !key.isEmpty else { return nil }
            parts.append(key)
            return parts.joined(separator: "-")
        }

        private static func keyString(for event: NSEvent) -> String {
            switch event.keyCode {
            case 48: return "Tab"
            case 123: return "Left"
            case 124: return "Right"
            case 125: return "Down"
            case 126: return "Up"
            default:
                return event.charactersIgnoringModifiers?.uppercased() ?? ""
            }
        }
    }
}

enum CandoaShortcutDefinition: String, CaseIterable, Identifiable {
    static let removedValue = "none"

    case newTab
    case closeCurrentTab
    case reopenClosedTab
    case focusAddressBar
    case copyURL
    case copyURLAsMarkdown
    case captureFullPage
    case pinOrUnpinTab
    case toggleSidebar
    case toggleAISidebar
    case clearUnpinnedTabs
    case goBack
    case goForward
    case nextRecentTab
    case previousRecentTab
    case nextTab
    case previousTab
    case nextSpace
    case previousSpace
    case addSplitView
    case closeSplitView
    case findInPage
    case findNext
    case findPrevious
    case reloadTab
    case zoomIn
    case zoomOut
    case resetZoom

    var id: String { rawValue }
    var storageKey: String { "CandoaShortcut.\(rawValue)" }

    var title: String {
        switch self {
        case .newTab: return BrowserCommandTitles.newTab
        case .closeCurrentTab: return BrowserCommandTitles.closeCurrentTab
        case .reopenClosedTab: return BrowserCommandTitles.reopenClosedTab
        case .focusAddressBar: return BrowserCommandTitles.focusAddressBar
        case .copyURL: return BrowserCommandTitles.copyURL
        case .copyURLAsMarkdown: return BrowserCommandTitles.copyURLAsMarkdown
        case .captureFullPage: return "Capture Page"
        case .pinOrUnpinTab: return BrowserCommandTitles.pinOrUnpinTab
        case .toggleSidebar: return BrowserCommandTitles.toggleSidebar
        case .toggleAISidebar: return BrowserCommandTitles.toggleAISidebar
        case .clearUnpinnedTabs: return BrowserCommandTitles.clearUnpinnedTabs
        case .goBack: return BrowserCommandTitles.back
        case .goForward: return BrowserCommandTitles.forward
        case .nextRecentTab: return "Next Recent Tab"
        case .previousRecentTab: return "Previous Recent Tab"
        case .nextTab: return BrowserCommandTitles.nextTab
        case .previousTab: return BrowserCommandTitles.previousTab
        case .nextSpace: return BrowserCommandTitles.nextSpace
        case .previousSpace: return BrowserCommandTitles.previousSpace
        case .addSplitView: return BrowserCommandTitles.addSplitView
        case .closeSplitView: return BrowserCommandTitles.closeSplitView
        case .findInPage: return BrowserCommandTitles.findInPage
        case .findNext: return BrowserCommandTitles.findNext
        case .findPrevious: return BrowserCommandTitles.findPrevious
        case .reloadTab: return BrowserCommandTitles.reloadTab
        case .zoomIn: return BrowserCommandTitles.zoomIn
        case .zoomOut: return BrowserCommandTitles.zoomOut
        case .resetZoom: return BrowserCommandTitles.resetZoom
        }
    }

    var category: String {
        switch self {
        case .captureFullPage:
            return "Capture"
        case .toggleAISidebar:
            return "AI"
        case .addSplitView, .closeSplitView:
            return "Split View"
        case .goBack, .goForward, .nextRecentTab, .previousRecentTab, .nextTab, .previousTab, .nextSpace, .previousSpace:
            return "Navigation"
        case .findInPage, .findNext, .findPrevious:
            return "Search & Find"
        case .zoomIn, .zoomOut, .resetZoom:
            return "Media & Display"
        default:
            return "Browser"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .newTab: return "Command-T"
        case .closeCurrentTab: return "Command-W"
        case .reopenClosedTab: return "Shift-Command-T"
        case .focusAddressBar: return "Command-L"
        case .copyURL: return "Shift-Command-C"
        case .copyURLAsMarkdown: return "Option-Shift-Command-C"
        case .captureFullPage: return "None"
        case .pinOrUnpinTab: return "Command-D"
        case .toggleSidebar: return "Command-S"
        case .toggleAISidebar: return "Command-E"
        case .clearUnpinnedTabs: return "Shift-Command-K"
        case .goBack: return "Command-Left"
        case .goForward: return "Command-Right"
        case .nextRecentTab: return "Control-Tab"
        case .previousRecentTab: return "Control-Shift-Tab"
        case .nextTab: return "Option-Command-Down"
        case .previousTab: return "Option-Command-Up"
        case .nextSpace: return "Option-Command-Right"
        case .previousSpace: return "Option-Command-Left"
        case .addSplitView: return "Control-Shift-="
        case .closeSplitView: return "Control-Shift--"
        case .findInPage: return "Command-F"
        case .findNext: return "Command-G"
        case .findPrevious: return "Shift-Command-G"
        case .reloadTab: return "Command-R"
        case .zoomIn: return "Command-="
        case .zoomOut: return "Command--"
        case .resetZoom: return "Command-0"
        }
    }

    var alternateDefaultShortcuts: [String] {
        switch self {
        case .goBack:
            return ["Command-["]
        case .goForward:
            return ["Command-]"]
        case .zoomIn:
            return ["Shift-Command-="]
        default:
            return []
        }
    }

    var symbolName: String {
        switch self {
        case .closeCurrentTab: return "xmark"
        case .reopenClosedTab: return "arrow.uturn.backward"
        case .captureFullPage: return "camera"
        case .addSplitView, .closeSplitView: return "rectangle.split.1x2"
        case .copyURL, .copyURLAsMarkdown: return "link"
        case .findInPage, .findNext, .findPrevious: return "magnifyingglass"
        case .reloadTab: return "arrow.clockwise"
        case .pinOrUnpinTab: return "pin"
        case .toggleSidebar: return "sidebar.left"
        case .toggleAISidebar: return "sidebar.right"
        case .focusAddressBar: return "text.cursor"
        case .newTab: return "plus"
        case .clearUnpinnedTabs: return "clear"
        case .goBack: return "chevron.left"
        case .goForward: return "chevron.right"
        case .nextRecentTab, .previousRecentTab: return "control"
        case .nextTab, .previousTab: return "arrow.up.arrow.down"
        case .nextSpace, .previousSpace: return "square.grid.2x2"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .resetZoom: return "1.magnifyingglass"
        }
    }

    var searchText: String {
        "\(title) \(category) \(defaultShortcut)"
    }
}
