import AppKit
import SwiftUI

internal struct GeneralSettingsPane: View {
    @AppStorage(SettingsOption.checkDefaultBrowser) private var checkDefaultBrowser = false
    @AppStorage(SettingsOption.askBeforeQuitting) private var askBeforeQuitting = true
    @AppStorage(SettingsOption.websiteAppearance) private var websiteAppearance = WebsiteAppearance.automatic.rawValue
    @AppStorage(SettingsOption.addressBarPlacement) private var addressBarPlacement = AddressBarPlacement.default.rawValue
    @AppStorage(SettingsOption.homepage) private var homepage = ""
    @AppStorage(SettingsOption.newTabsOpenWith) private var newTabsOpenWith = NewTabPreference.commandBar.rawValue
    @AppStorage(SettingsOption.historyRetention) private var historyRetention = HistoryRetentionPreference.afterOneYear.rawValue
    @AppStorage(SettingsOption.downloadLocationMode) private var downloadLocationMode = DownloadLocationPreference.Mode.downloads.rawValue
    @AppStorage(SettingsOption.downloadListRetention) private var downloadListRetention = DownloadListRetentionPreference.afterOneDay.rawValue
    @AppStorage(SettingsOption.openSafeDownloads) private var openSafeDownloads = true
    @AppStorage(SettingsOption.floatingMiniPlayer) private var floatingMiniPlayer = true
    @State private var customDownloadFolderName: String?
    @FocusState private var homepageFieldFocused: Bool
    @StateObject private var defaultBrowserService = DefaultBrowserService()

    /// Sentinel picker tag: choosing it opens the folder panel instead of
    /// becoming a stored mode.
    private static let otherFolderTag = "other"

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
                    SettingsPickerRow(
                        systemImage: "plus.square.on.square",
                        title: String(localized: "New tabs open with"),
                        subtitle: String(localized: "What Command-T and the sidebar's New Tab button show."),
                        selection: $newTabsOpenWith,
                        options: [
                            SettingsPickerOption(
                                id: NewTabPreference.commandBar.rawValue,
                                title: String(localized: "Command Bar")
                            ),
                            SettingsPickerOption(
                                id: NewTabPreference.homepage.rawValue,
                                title: String(localized: "Homepage")
                            ),
                            SettingsPickerOption(
                                id: NewTabPreference.emptyPage.rawValue,
                                title: String(localized: "Empty Page")
                            )
                        ]
                    )

                    SettingsDivider()

                    SettingsRow(
                        systemImage: "house",
                        title: String(localized: "Homepage"),
                        subtitle: String(localized: "Where Shift-Command-H goes. Leave empty for your search engine's home page.")
                    ) {
                        VStack(alignment: .trailing, spacing: 8) {
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

                            Button(String(localized: "Set to Current Page")) {
                                setHomepageToCurrentPage()
                            }
                            .buttonTreatment(.secondary)
                            .controlSize(.small)
                        }
                    }

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "pip",
                        title: String(localized: "Show floating video player"),
                        subtitle: String(localized: "A playing video keeps playing in a small floating player when you leave its tab."),
                        isOn: $floatingMiniPlayer
                    )
                }

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "clock.arrow.circlepath",
                        title: String(localized: "Remove history items"),
                        subtitle: String(localized: "Older visits are removed automatically."),
                        selection: $historyRetention,
                        options: [
                            SettingsPickerOption(
                                id: HistoryRetentionPreference.afterOneDay.rawValue,
                                title: String(localized: "After one day")
                            ),
                            SettingsPickerOption(
                                id: HistoryRetentionPreference.afterOneWeek.rawValue,
                                title: String(localized: "After one week")
                            ),
                            SettingsPickerOption(
                                id: HistoryRetentionPreference.afterTwoWeeks.rawValue,
                                title: String(localized: "After two weeks")
                            ),
                            SettingsPickerOption(
                                id: HistoryRetentionPreference.afterOneMonth.rawValue,
                                title: String(localized: "After one month")
                            ),
                            SettingsPickerOption(
                                id: HistoryRetentionPreference.afterOneYear.rawValue,
                                title: String(localized: "After one year")
                            ),
                            SettingsPickerOption(
                                id: HistoryRetentionPreference.manually.rawValue,
                                title: String(localized: "Manually")
                            )
                        ]
                    )
                    .onChange(of: historyRetention) { _, _ in
                        HistoryRetentionService.shared.prune()
                    }
                }

                SettingsCard {
                    SettingsRow(
                        systemImage: "arrow.down.circle",
                        title: String(localized: "File download location"),
                        subtitle: String(localized: "Where downloaded files are saved.")
                    ) {
                        Picker("", selection: downloadLocationSelection) {
                            Text(String(localized: "Downloads")).tag(DownloadLocationPreference.Mode.downloads.rawValue)
                            if let customDownloadFolderName {
                                Text(customDownloadFolderName).tag(DownloadLocationPreference.Mode.custom.rawValue)
                            }
                            Text(String(localized: "Ask for each download")).tag(DownloadLocationPreference.Mode.ask.rawValue)
                            Divider()
                            Text(String(localized: "Other…")).tag(Self.otherFolderTag)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        // Fills the shared 190pt column like every
                        // SettingsPickerRow (see FlexibleControlSizing).
                        .flexibleControlSizing()
                        .frame(width: 190)
                    }

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "list.bullet.circle",
                        title: String(localized: "Remove download list items"),
                        subtitle: String(localized: "Only the list is cleaned up. Files stay on disk."),
                        selection: $downloadListRetention,
                        options: [
                            SettingsPickerOption(
                                id: DownloadListRetentionPreference.afterOneDay.rawValue,
                                title: String(localized: "After one day")
                            ),
                            SettingsPickerOption(
                                id: DownloadListRetentionPreference.whenQuitting.rawValue,
                                title: String(localized: "When quitting Candoa")
                            ),
                            SettingsPickerOption(
                                id: DownloadListRetentionPreference.uponSuccess.rawValue,
                                title: String(localized: "Upon successful download")
                            ),
                            SettingsPickerOption(
                                id: DownloadListRetentionPreference.manually.rawValue,
                                title: String(localized: "Manually")
                            )
                        ]
                    )
                    .onChange(of: downloadListRetention) { _, _ in
                        DownloadsStore.shared.applyListRetention()
                    }

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "arrow.down.doc",
                        title: String(localized: "Open \"safe\" files after downloading"),
                        subtitle: String(localized: "\"Safe\" files include movies, pictures, sounds, PDFs, and text documents."),
                        isOn: $openSafeDownloads
                    )
                }

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "rectangle.topthird.inset.filled",
                        title: String(localized: "Toolbar"),
                        subtitle: String(localized: "Keep the address and its controls in the sidebar, or show them above the page."),
                        selection: $addressBarPlacement,
                        options: [
                            SettingsPickerOption(id: AddressBarPlacement.sidebar.rawValue, title: String(localized: "In the Sidebar")),
                            SettingsPickerOption(id: AddressBarPlacement.top.rawValue, title: String(localized: "Above the Page"))
                        ]
                    )

                    SettingsDivider()

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

                    SettingsToggleRow(
                        systemImage: "command",
                        title: String(localized: "Ask before quitting with Command-Q"),
                        subtitle: String(localized: "Confirm before quitting the app from the keyboard."),
                        isOn: $askBeforeQuitting
                    )
                }

            }
        }
        .onAppear {
            customDownloadFolderName = DownloadLocationPreference.customFolderName
        }
        // Reactivation is the moment the status can have changed behind our
        // back (the user flipped it in System Settings or another browser).
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            defaultBrowserService.refresh()
        }
    }

    /// The stored mode, except that a custom folder whose bookmark no longer
    /// resolves falls back to showing Downloads — matching where downloads
    /// actually land in that state.
    private var downloadLocationSelection: Binding<String> {
        Binding(
            get: {
                if downloadLocationMode == DownloadLocationPreference.Mode.custom.rawValue,
                   customDownloadFolderName == nil {
                    return DownloadLocationPreference.Mode.downloads.rawValue
                }
                return downloadLocationMode
            },
            set: { newValue in
                if newValue == Self.otherFolderTag {
                    // Deferred: presenting a panel from inside the Binding
                    // write would nest a run loop in the picker's own
                    // selection commit.
                    DispatchQueue.main.async { chooseDownloadFolder() }
                } else {
                    downloadLocationMode = newValue
                }
            }
        )
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let adopt: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK,
                  let url = panel.url,
                  DownloadLocationPreference.adoptCustomFolder(url) else { return }
            customDownloadFolderName = DownloadLocationPreference.customFolderName
            downloadLocationMode = DownloadLocationPreference.Mode.custom.rawValue
        }

        // Sheeted on the Settings window so the rest of the app stays
        // usable while the chooser is up.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: adopt)
        } else {
            adopt(panel.runModal())
        }
    }

    private func setHomepageToCurrentPage() {
        guard let url = BrowserMenuController.shared.frontmostStore?.activeTab?.url,
              let normalized = HomepagePreference.normalized(url.absoluteString) else { return }
        homepage = normalized.absoluteString
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
                        subtitle: String(localized: "Background tabs stay loaded. When your Mac runs low on memory, the ones you haven't used in a while are put to sleep until you return.")
                    ) {
                        SettingsStatusPill(text: String(localized: "Automatic"))
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

/// Safari-style Feature Flags: WebKit's experimental features with per-flag
/// overrides. Hosted in its own window (Develop menu), not a Settings tab.
internal struct FeatureFlagsView: View {
    @State private var searchText = ""
    @State private var flags: [WebKitFeatureFlags.Flag] = []
    /// Local mirror of the persisted overrides so toggles refresh; the
    /// engine's UserDefaults dictionary stays the source of truth.
    @State private var overrides: [String: Bool] = [:]
    @State private var hasLoadedFlags = false

    private var filteredFlags: [WebKitFeatureFlags.Flag] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return flags }
        return flags.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.key.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if hasLoadedFlags, flags.isEmpty {
                emptyState(String(localized: "Feature flags are unavailable in this build of WebKit."))
            } else if filteredFlags.isEmpty, hasLoadedFlags {
                emptyState(String(localized: "No Matching Features"))
            } else {
                List(filteredFlags) { flag in
                    flagRow(flag)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 16) {
                Text(String(localized: "Changes take effect for newly loaded pages."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)

                Button(String(localized: "Reset All")) {
                    WebKitFeatureFlags.resetAll()
                    overrides = [:]
                }
                .disabled(overrides.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 600)
        .navigationTitle(String(localized: "Feature Flags"))
        .onAppear(perform: loadFlags)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.42),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
    }

    private func flagRow(_ flag: WebKitFeatureFlags.Flag) -> some View {
        Toggle(isOn: overrideBinding(for: flag)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                if let details = flag.details {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(flag.key)
        .padding(.vertical, 2)
    }

    private func overrideBinding(for flag: WebKitFeatureFlags.Flag) -> Binding<Bool> {
        Binding {
            overrides[flag.key] ?? flag.defaultValue
        } set: { newValue in
            // Choosing the default clears the override, so untouched flags
            // keep tracking WebKit's defaults across SDK updates.
            let stored: Bool? = (newValue == flag.defaultValue) ? nil : newValue
            WebKitFeatureFlags.setOverride(stored, for: flag.key)
            overrides[flag.key] = stored
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func loadFlags() {
        flags = WebKitFeatureFlags.allFlags()
        overrides = Dictionary(
            uniqueKeysWithValues: flags.compactMap { flag in
                WebKitFeatureFlags.override(for: flag.key).map { (flag.key, $0) }
            }
        )
        hasLoadedFlags = true
    }
}
