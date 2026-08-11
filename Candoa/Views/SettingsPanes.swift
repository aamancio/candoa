import AppKit
import SwiftUI

internal struct GeneralSettingsPane: View {
    @AppStorage(SettingsOption.checkDefaultBrowser) private var checkDefaultBrowser = false
    @AppStorage(SettingsOption.askBeforeQuitting) private var askBeforeQuitting = true
    @AppStorage(SettingsOption.websiteAppearance) private var websiteAppearance = WebsiteAppearance.dark.rawValue
    @AppStorage(SettingsOption.defaultSearchProvider) private var defaultSearchProvider = NavigationService.searchProviders.first?.id ?? "google"
    @AppStorage(SettingsOption.showSearchSuggestions) private var showSearchSuggestions = true
    @AppStorage(SettingsOption.homepage) private var homepage = ""
    @FocusState private var homepageFieldFocused: Bool
    @State private var syncsWorkspaceWithICloud = SyncPreferences.syncsWorkspaceWithICloud
    @State private var syncsHistoryWithICloud = SyncPreferences.syncsHistoryWithICloud
    @StateObject private var defaultBrowserService = DefaultBrowserService()

    /// Stores what was typed as a real address, so "example.com" is saved the
    /// way it will be opened. Anything that is not a web address is discarded
    /// rather than saved as a Home that cannot load.
    private func normalizeHomepage() {
        let trimmed = homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            homepage = ""
            return
        }
        homepage = HomepagePreference.normalized(trimmed)?.absoluteString ?? ""
    }

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    SettingsRow(
                        systemImage: "app.badge",
                        title: String(localized: "Default browser"),
                        subtitle: defaultBrowserService.isDefaultBrowser
                            ? String(localized: "Candoa is the default browser in macOS.")
                            : String(localized: "Set Candoa as the default browser in macOS.")
                    ) {
                        if defaultBrowserService.isDefaultBrowser {
                            SettingsStatusPill(text: String(localized: "Default"))
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
                        title: String(localized: "Always check if Candoa is your default browser"),
                        subtitle: String(localized: "Show a default-browser reminder at startup."),
                        isOn: $checkDefaultBrowser
                    )
                }

                SettingsCard {
                    SettingsRow(
                        systemImage: "house",
                        title: String(localized: "Homepage"),
                        subtitle: String(localized: "Where Shift-Command-H goes. Leave empty for your search engine's home page.")
                    ) {
                        TextField(
                            HomepagePreference.defaultURL?.absoluteString ?? "",
                            text: $homepage
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit { normalizeHomepage() }
                        .onChange(of: homepageFieldFocused) { _, focused in
                            if !focused { normalizeHomepage() }
                        }
                        .focused($homepageFieldFocused)
                    }
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "command",
                        title: String(localized: "Ask before quitting with Command-Q"),
                        subtitle: String(localized: "Confirm before quitting the app from the keyboard."),
                        isOn: $askBeforeQuitting
                    )
                }

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "macwindow",
                        title: String(localized: "Website appearance"),
                        subtitle: String(localized: "Choose which color scheme sites should use."),
                        selection: $websiteAppearance,
                        options: [
                            SettingsPickerOption(id: "automatic", title: String(localized: "Automatic")),
                            SettingsPickerOption(id: "light", title: String(localized: "Light")),
                            SettingsPickerOption(id: "dark", title: String(localized: "Dark"))
                        ]
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "magnifyingglass",
                        title: String(localized: "Search engine"),
                        subtitle: String(localized: "Used by the command bar and address field."),
                        selection: $defaultSearchProvider,
                        options: NavigationService.defaultSearchProviders.map {
                            SettingsPickerOption(id: $0.id, title: defaultSearchEngineTitle(for: $0))
                        }
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "lightbulb",
                        title: String(localized: "Include search suggestions"),
                        subtitle: String(localized: "Show search completions in the command surface."),
                        isOn: $showSearchSuggestions
                    )
                }

                SettingsCard {
                    SettingsToggleRow(
                        systemImage: "square.grid.2x2",
                        title: String(localized: "Sync Spaces and tabs with iCloud"),
                        subtitle: CloudKitEntitlements.hasConfiguredContainer
                            ? String(localized: "Keep them available on Macs using this Apple Account.")
                            : String(localized: "This build is missing the CloudKit entitlement."),
                        isOn: workspaceSyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer)

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.arrow.circlepath",
                        title: String(localized: "Sync history"),
                        subtitle: String(localized: "Requires Spaces sync."),
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
                        title: String(localized: "Ignore pending tabs when cycling"),
                        subtitle: String(localized: "Skip unloaded tabs with Ctrl-Tab."),
                        isOn: $ignorePendingTabsWhenCycling
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "rectangle.3.group",
                        title: String(localized: "Cycle within the current scope"),
                        subtitle: String(localized: "Keep Ctrl-Tab inside the current tab group."),
                        isOn: $ctrlTabCyclesWithinScope
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.left.arrow.right",
                        title: String(localized: "Select recently used tab on close"),
                        subtitle: String(localized: "Return to the tab you used most recently."),
                        isOn: $selectRecentlyUsedOnClose
                    )
                }

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "keyboard",
                        title: String(localized: "Pinned tab close shortcut"),
                        subtitle: String(localized: "Choose what Command-W does on pinned tabs."),
                        selection: $pinnedCloseShortcutBehavior,
                        options: [
                            SettingsPickerOption(id: "reset-unload-switch", title: String(localized: "Reset, unload, switch")),
                            SettingsPickerOption(id: "unload-switch", title: String(localized: "Unload and switch")),
                            SettingsPickerOption(id: "reset-switch", title: String(localized: "Reset and switch")),
                            SettingsPickerOption(id: "switch", title: String(localized: "Switch")),
                            SettingsPickerOption(id: "reset", title: String(localized: "Reset")),
                            SettingsPickerOption(id: "close", title: String(localized: "Close"))
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
                        title: String(localized: "Default Search Engine"),
                        subtitle: String(localized: "Choose the search provider shown first in the command surface."),
                        selection: $defaultSearchProvider,
                        options: defaultSearchProviders.map {
                            SettingsPickerOption(id: $0.id, title: defaultSearchEngineTitle(for: $0))
                        }
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "lightbulb",
                        title: String(localized: "Show search suggestions"),
                        subtitle: String(localized: "Allow the command surface to suggest search completions."),
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
                        title: String(localized: "Strict tracking protection"),
                        subtitle: String(localized: "Block trackers and ads with WebKit content rules. Pages already open apply the change when they reload."),
                        isOn: $strictTrackingProtection
                    )

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "trash",
                        title: String(localized: "Browsing data"),
                        subtitle: String(localized: "Clear history, cookies, caches, and other website data across all Spaces. Private windows keep nothing to clear.")
                    ) {
                        Button("Clear Browsing Data…") {
                            ClearBrowsingDataPrompt.present(currentSpace: nil)
                        }
                        .accessibilityIdentifier("settings-clear-browsing-data")
                    }
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
                        title: String(localized: "Workspace recovery"),
                        subtitle: CloudKitEntitlements.hasConfiguredContainer
                            ? String(localized: "Keep Spaces, tabs, pinned sites, and bookmarks available on your Macs.")
                            : String(localized: "This build is missing the CloudKit entitlement."),
                        isOn: workspaceSyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer)

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "clock.arrow.circlepath",
                        title: String(localized: "History"),
                        subtitle: String(localized: "History sync depends on workspace sync."),
                        isOn: historySyncBinding
                    )
                    .disabled(!CloudKitEntitlements.hasConfiguredContainer || !syncsWorkspaceWithICloud)

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "person.crop.circle",
                        title: String(localized: "Uses this Mac’s Apple Account"),
                        subtitle: String(localized: "Candoa subscription sign-in does not control or delete your browser workspace.")
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
                ? String(localized: "Candoa will sync your workspace through the private iCloud database for this Apple Account after relaunch.")
                : String(localized: "Candoa will keep Spaces and tabs local-only after relaunch.")
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
                ? String(localized: "Candoa will sync history through your private iCloud database after relaunch.")
                : String(localized: "Candoa will keep history local-only after relaunch.")
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
                        title: String(localized: "Web Inspector"),
                        subtitle: String(localized: "In Debug builds this is always available; Release builds read this preference."),
                        isOn: $isWebInspectorEnabled
                    )

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "snowflake",
                        title: String(localized: "Tab Hibernation"),
                        subtitle: String(localized: "Idle background tabs release their web view after \(Int(TabHibernationConfiguration.idleInterval / 60)) minutes.")
                    ) {
                        SettingsStatusPill(text: String(localized: "On"))
                    }

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "arrow.triangle.2.circlepath",
                        title: String(localized: "Update Checks"),
                        subtitle: String(localized: "Sparkle manages update checks using the app bundle configuration.")
                    ) {
                        SettingsStatusPill(text: String(localized: "Automatic"))
                    }
                }
            }
        }
    }
}
