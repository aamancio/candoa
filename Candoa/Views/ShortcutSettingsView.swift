import AppKit
import SwiftUI

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

            ExtensionsSettingsPane()
                .tabItem {
                    Label(SettingsTab.extensions.title, systemImage: SettingsTab.extensions.symbolName)
                }
                .tag(SettingsTab.extensions)

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
    case search
    case privacy
    case extensions
    case ask
    case shortcuts
    case advanced

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .search: return String(localized: "Search")
        case .privacy: return String(localized: "Privacy")
        case .extensions: return String(localized: "Extensions")
        case .ask: return "Eli"
        case .shortcuts: return String(localized: "Shortcuts")
        case .advanced: return String(localized: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .search: return "magnifyingglass"
        case .privacy: return "hand.raised"
        case .extensions: return "puzzlepiece.extension"
        case .ask: return "sparkles"
        case .shortcuts: return "keyboard"
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
    /// Off until someone turns it on: nothing about a failure leaves this Mac
    /// by default, not even an anonymous crash.
    static let shareProblemReports = prefix + "ShareProblemReports"
    static let askBeforeQuitting = prefix + "AskBeforeQuitting"
    static let askConnection = prefix + "AskConnection"
    static let askHostedModel = prefix + "AskHostedModel"
    static let askDirectModel = prefix + "AskDirectModel"
    static let askDirectModelInfo = prefix + "AskDirectModelInfo"
    static let askReasoningEffort = prefix + "AskReasoningEffort"
    /// JSON `UserProfile`: the details Eli may type into a form. Local to this
    /// Mac and global to the app.
    static let userProfile = prefix + "UserProfile"
    /// JSON array of `UserProfile.Field` raw values: the fields whose value
    /// Eli learned from a conversation rather than the user typing it.
    /// Editing a field in Settings removes it from this set.
    static let userProfileLearnedFields = prefix + "UserProfileLearnedFields"

    static let websiteAppearance = prefix + "WebsiteAppearance"
    static let addressBarPlacement = prefix + "AddressBarPlacement"

    /// Whether a playing video floats in the mini player when its tab is
    /// left. Off, the tab just plays on in the background.
    static let floatingMiniPlayer = prefix + "FloatingMiniPlayer"

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
