import AppKit
import SwiftUI

internal struct GeneralSettingsPane: View {
    @AppStorage(CandoaSettingsOption.openPreviousWindowsAndTabs) private var openPreviousWindowsAndTabs = true
    @AppStorage(CandoaSettingsOption.continueWhereLeftOff) private var continueWhereLeftOff = false
    @AppStorage(CandoaSettingsOption.checkDefaultBrowser) private var checkDefaultBrowser = false
    @AppStorage(CandoaSettingsOption.askBeforeQuitting) private var askBeforeQuitting = true
    @AppStorage(CandoaSettingsOption.websiteAppearance) private var websiteAppearance = WebsiteAppearance.dark.rawValue
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
                        .candoaButton(.secondary)
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
                        title: "Sync Spaces and tabs with iCloud",
                        subtitle: CandoaCloudKitEntitlements.hasConfiguredContainer
                            ? "Keep them available on Macs using this Apple Account."
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
internal struct LookAndFeelSettingsPane: View {
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
                        subtitle: "Keep browser controls minimized until you need them.",
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

internal struct SpacesSettingsPane: View {
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

internal struct LinksSettingsPane: View {
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

internal struct IconSettingsPane: View {
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

internal struct TabManagementSettingsPane: View {
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

internal struct SearchSettingsPane: View {
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

internal struct PrivacySettingsPane: View {
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

internal struct SyncSettingsPane: View {
    @State private var syncsWorkspaceWithICloud = CandoaSyncPreferences.syncsWorkspaceWithICloud
    @State private var syncsHistoryWithICloud = CandoaSyncPreferences.syncsHistoryWithICloud
    @State private var syncMessage: String?

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("iCloud")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: "Workspace recovery",
                        subtitle: CandoaCloudKitEntitlements.hasConfiguredContainer
                            ? "Keep Spaces, tabs, pinned sites, and bookmarks available on your Macs."
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

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "person.crop.circle",
                        title: "Uses this Mac’s Apple Account",
                        subtitle: "Candoa subscription sign-in does not control or delete your browser workspace."
                    ) {
                        EmptyView()
                    }

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
                ? "Candoa will sync your workspace through the private iCloud database for this Apple Account after relaunch."
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

internal struct AdvancedSettingsPane: View {
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
                        subtitle: "Choose the interface layout for browsing.",
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
                        subtitle: "Keep browser controls minimized until you need them.",
                        isOn: $enableCompactMode
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "toolbar",
                        title: "Hide top toolbar in compact mode",
                        subtitle: "Use the sidebar as the primary navigation.",
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
