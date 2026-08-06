import AppKit
import SwiftUI

internal struct GeneralSettingsPane: View {
    @AppStorage(SettingsOption.checkDefaultBrowser) private var checkDefaultBrowser = false
    @AppStorage(SettingsOption.askBeforeQuitting) private var askBeforeQuitting = true
    @AppStorage(SettingsOption.websiteAppearance) private var websiteAppearance = WebsiteAppearance.dark.rawValue
    @AppStorage(SettingsOption.defaultSearchProvider) private var defaultSearchProvider = NavigationService.searchProviders.first?.id ?? "google"
    @AppStorage(SettingsOption.showSearchSuggestions) private var showSearchSuggestions = true
    @State private var syncsWorkspaceWithICloud = SyncPreferences.syncsWorkspaceWithICloud
    @State private var syncsHistoryWithICloud = SyncPreferences.syncsHistoryWithICloud
    @StateObject private var defaultBrowserService = DefaultBrowserService()

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    SettingsRow(
                        systemImage: "app.badge",
                        title: "Default browser",
                        subtitle: defaultBrowserService.isDefaultBrowser
                            ? "Candoa is the default browser in macOS."
                            : "Set Candoa as the default browser in macOS."
                    ) {
                        if defaultBrowserService.isDefaultBrowser {
                            SettingsStatusPill(text: "Default")
                        } else {
                            Button("Set as Default…") {
                                Task {
                                    await defaultBrowserService.requestDefaultBrowserRole()
                                }
                            }
                            .buttonTreatment(.secondary)
                            .controlSize(.small)
                        }
                    }

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
                        subtitle: CloudKitEntitlements.hasConfiguredContainer
                            ? "Keep them available on Macs using this Apple Account."
                            : "This build is missing the CloudKit entitlement.",
                        isOn: workspaceSyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer)

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.arrow.circlepath",
                        title: "Sync history",
                        subtitle: "Requires Spaces sync.",
                        isOn: historySyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer || !syncsWorkspaceWithICloud)
                }
            }
        }
        .onAppear(perform: normalizeDefaultSearchProvider)
        // Reactivation is the moment the status can have changed behind our
        // back (the user flipped it in System Settings or another browser).
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            defaultBrowserService.refresh()
        }
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
            SyncPreferences.syncsWorkspaceWithICloud = newValue
            if !newValue {
                syncsHistoryWithICloud = false
                SyncPreferences.syncsHistoryWithICloud = false
            }
        }
    }

    private var historySyncBinding: Binding<Bool> {
        Binding {
            syncsHistoryWithICloud
        } set: { newValue in
            if newValue, !syncsWorkspaceWithICloud {
                syncsWorkspaceWithICloud = true
                SyncPreferences.syncsWorkspaceWithICloud = true
            }
            syncsHistoryWithICloud = newValue
            SyncPreferences.syncsHistoryWithICloud = newValue
        }
    }
}

internal struct SpacesSettingsPane: View {
    @AppStorage(SettingsOption.ignorePendingTabsWhenCycling) private var ignorePendingTabsWhenCycling = false
    @AppStorage(SettingsOption.ctrlTabCyclesWithinScope) private var ctrlTabCyclesWithinScope = false
    @AppStorage(SettingsOption.selectRecentlyUsedOnClose) private var selectRecentlyUsedOnClose = true
    @AppStorage(SettingsOption.pinnedCloseShortcutBehavior) private var pinnedCloseShortcutBehavior = "reset-unload-switch"

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
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

internal struct IconSettingsPane: View {
    @AppStorage(DockIconPreference.storageKey) private var selectedIconPreference = DockIconPreference.system.rawValue

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(DockIconPreference.allCases) { preference in
                            DockIconChoice(
                                preference: preference,
                                isSelected: selectedIconPreference == preference.rawValue
                            ) {
                                selectedIconPreference = preference.rawValue
                                DockIconPreference.updateApplicationIcon()
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

internal struct SearchSettingsPane: View {
    private let providers = NavigationService.searchProviders
    private let defaultSearchProviders = NavigationService.defaultSearchProviders
    @AppStorage(SettingsOption.defaultSearchProvider) private var defaultSearchProvider = NavigationService.searchProviders.first?.id ?? "google"
    @AppStorage(SettingsOption.showSearchSuggestions) private var showSearchSuggestions = true

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
    @AppStorage(SettingsOption.strictTrackingProtection) private var strictTrackingProtection = true

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Privacy and Security")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "hand.raised",
                        title: "Strict tracking protection",
                        subtitle: "Block trackers and ads with WebKit content rules. Pages already open apply the change when they reload.",
                        isOn: $strictTrackingProtection
                    )
                }
            }
        }
    }
}

internal struct SyncSettingsPane: View {
    @State private var syncsWorkspaceWithICloud = SyncPreferences.syncsWorkspaceWithICloud
    @State private var syncsHistoryWithICloud = SyncPreferences.syncsHistoryWithICloud
    @State private var syncMessage: String?

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("iCloud")

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: "Workspace recovery",
                        subtitle: CloudKitEntitlements.hasConfiguredContainer
                            ? "Keep Spaces, tabs, pinned sites, and bookmarks available on your Macs."
                            : "This build is missing the CloudKit entitlement.",
                        isOn: workspaceSyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer)

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.arrow.circlepath",
                        title: "History",
                        subtitle: "History sync depends on workspace sync.",
                        isOn: historySyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer || !syncsWorkspaceWithICloud)

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
            SyncPreferences.syncsWorkspaceWithICloud = newValue
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
                SyncPreferences.syncsWorkspaceWithICloud = true
            }
            syncsHistoryWithICloud = newValue
            SyncPreferences.syncsHistoryWithICloud = newValue
            syncMessage = newValue
                ? "Candoa will sync history through your private iCloud database after relaunch."
                : "Candoa will keep history local-only after relaunch."
        }
    }
}

internal struct AdvancedSettingsPane: View {
    @AppStorage("CandoaEnableWebInspector") private var isWebInspectorEnabled = false

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
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
