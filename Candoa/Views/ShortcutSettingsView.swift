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

internal enum CandoaSettingsTab: Hashable {
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
