import AppKit
import SwiftUI

enum DockIconPreference: String, CaseIterable, Identifiable {
    static let storageKey = "Candoa.Settings.DockIconPreference"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Follow System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
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
        let preference = DockIconPreference(rawValue: storedValue ?? "") ?? .system
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
struct SettingsView: View {
    @EnvironmentObject private var userStore: UserStore
    @State private var selectedTab = SettingsTab.general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsPane()
                .tabItem {
                    Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbolName)
                }
                .tag(SettingsTab.general)

            SpacesSettingsPane()
                .tabItem {
                    Label(SettingsTab.spaces.title, systemImage: SettingsTab.spaces.symbolName)
                }
                .tag(SettingsTab.spaces)

            SearchSettingsPane()
                .tabItem {
                    Label(SettingsTab.search.title, systemImage: SettingsTab.search.symbolName)
                }
                .tag(SettingsTab.search)

            PrivacySettingsPane()
                .tabItem {
                    Label(SettingsTab.privacy.title, systemImage: SettingsTab.privacy.symbolName)
                }
                .tag(SettingsTab.privacy)

            SyncSettingsPane()
                .tabItem {
                    Label(SettingsTab.sync.title, systemImage: SettingsTab.sync.symbolName)
                }
                .tag(SettingsTab.sync)

            EliSettingsPane()
                .tabItem {
                    Label(SettingsTab.ask.title, systemImage: SettingsTab.ask.symbolName)
                }
                .tag(SettingsTab.ask)

            ShortcutSettingsView()
                .tabItem {
                    Label(SettingsTab.shortcuts.title, systemImage: SettingsTab.shortcuts.symbolName)
                }
                .tag(SettingsTab.shortcuts)

            IconSettingsPane()
                .tabItem {
                    Label(SettingsTab.icon.title, systemImage: SettingsTab.icon.symbolName)
                }
                .tag(SettingsTab.icon)

            AdvancedSettingsPane()
                .tabItem {
                    Label(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.symbolName)
                }
                .tag(SettingsTab.advanced)
        }
        .tabViewStyle(.automatic)
        .frame(width: 780, height: 590)
        .onAppear {
            if let requested = SettingsPaneRequest.pending {
                selectedTab = requested
                SettingsPaneRequest.pending = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: SettingsPaneRequest.notification)
        ) { _ in
            if let requested = SettingsPaneRequest.pending {
                selectedTab = requested
                SettingsPaneRequest.pending = nil
            }
        }
        .onOpenURL { url in
            _ = userStore.handleAppleSignInCallback(url)
        }
    }
}

/// Routes the Settings window to a specific pane when it is opened from
/// outside the Settings scene (Develop ▸ Developer Settings…, which pairs
/// this with SwiftUI's openSettings action). The pending value covers a
/// cold window (consumed in onAppear); the notification covers one already
/// open.
@MainActor
internal enum SettingsPaneRequest {
    static var pending: SettingsTab?
    static let notification = Notification.Name("CandoaOpenSettingsPane")

    static func request(_ tab: SettingsTab) {
        pending = tab
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

internal enum SettingsTab: Hashable {
    case general
    case spaces
    case search
    case privacy
    case sync
    case ask
    case shortcuts
    case icon
    case advanced

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .spaces: return String(localized: "Spaces")
        case .search: return String(localized: "Search")
        case .privacy: return String(localized: "Privacy")
        case .sync: return String(localized: "Sync")
        case .ask: return "Eli"
        case .shortcuts: return String(localized: "Shortcuts")
        case .icon: return String(localized: "Icon")
        case .advanced: return String(localized: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .spaces: return "square.grid.2x2"
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

/// Every key listed here is read somewhere at runtime — settings that only
/// persisted unused UI state were removed for the MVP (issue #20). Add a key
/// back only together with the behavior it controls.
enum SettingsOption {
    static let prefix = "Candoa.Settings.ZenOption."

    static let checkDefaultBrowser = prefix + "CheckDefaultBrowser"
    static let askBeforeQuitting = prefix + "AskBeforeQuitting"
    static let askConnection = prefix + "AskConnection"
    static let askHostedModel = prefix + "AskHostedModel"
    static let askDirectModel = prefix + "AskDirectModel"
    static let askDirectModelInfo = prefix + "AskDirectModelInfo"
    static let askReasoningEffort = prefix + "AskReasoningEffort"

    static let websiteAppearance = prefix + "WebsiteAppearance"

    static let ignorePendingTabsWhenCycling = prefix + "IgnorePendingTabsWhenCycling"
    static let ctrlTabCyclesWithinScope = prefix + "CtrlTabCyclesWithinScope"
    static let selectRecentlyUsedOnClose = prefix + "SelectRecentlyUsedOnClose"
    static let pinnedCloseShortcutBehavior = prefix + "PinnedCloseShortcutBehavior"

    static let homepage = prefix + "Homepage"
    static let newTabsOpenWith = prefix + "NewTabsOpenWith"
    static let historyRetention = prefix + "HistoryRetention"
    static let downloadLocationMode = prefix + "DownloadLocationMode"
    static let downloadLocationBookmark = prefix + "DownloadLocationBookmark"
    static let downloadListRetention = prefix + "DownloadListRetention"
    static let openSafeDownloads = prefix + "OpenSafeDownloads"

    static let defaultSearchProvider = prefix + "DefaultSearchProvider"
    static let showSearchSuggestions = prefix + "ShowSearchSuggestions"
    static let strictTrackingProtection = prefix + "StrictTrackingProtection"

    /// Bool settings default to their pane's initial value, not `false`, so
    /// runtime reads must distinguish "never set" from "switched off".
    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }
}
