import AppKit
import SwiftUI
import UniformTypeIdentifiers

internal func sidebarAccessibilitySlug(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let parts = value
        .lowercased()
        .unicodeScalars
        .map { allowed.contains($0) ? Character($0) : "-" }
    let slug = String(parts)
        .split(separator: "-")
        .joined(separator: "-")
    return slug.isEmpty ? "item" : slug
}
internal struct SidebarDisclosureChevron: View {
    let isExpanded: Bool
    let isVisible: Bool
    let opacity: Double

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .opacity(isVisible ? opacity : 0)
            .frame(width: 9, height: 18)
            .animation(.easeOut(duration: 0.14), value: isExpanded)
            .accessibilityHidden(true)
    }
}

internal struct SidebarFolderIcon: View {
    var body: some View {
        Image(systemName: "folder")
            .font(.system(size: 15, weight: .medium))
            .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

struct SidebarView: View {
    @ObservedObject var store: BrowserStore
    let availableUpdate: AppUpdate?
    let automaticUpdatesEnabled: Binding<Bool>
    let windowControlsHiddenOffset: CGFloat
    let onUpdateBannerTapped: () -> Void
    let onToggleSidebar: () -> Void

    @State private var isHoveringNewTab = false
    @State private var isHoveringAddressPill = false
    @State private var isSpaceDropTargeted = false
    @AppStorage("Candoa.FavoritesDropZoneDismissed") private var isFavoritesDropZoneDismissed = false
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""

    private let leadingInset: CGFloat = 9
    private let trailingInset: CGFloat = 9
    private let windowControlsWidth: CGFloat = 70
    private let spaceLabelToPinnedGap: CGFloat = 3
    private let pinnedSectionSpacing: CGFloat = 10

    /// Zen-style Essentials collapse unused grid tracks, so one or two tiles
    /// still consume the full row instead of leaving empty reserved slots.
    private func essentialColumns(for itemCount: Int) -> [GridItem] {
        let visibleColumns = min(max(itemCount, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: visibleColumns)
    }

    private var activeSpaceTint: Color {
        Color(spaceHex: store.activeThemeColorHexes.first ?? "#8A8F98")
    }

    private var hasActiveThemeTint: Bool {
        !store.activeThemeColorHexes.isEmpty
    }

    private var isSetupThemePreviewActive: Bool {
        store.isSpaceSetupPresented && store.editingSpaceID == nil && hasActiveThemeTint
    }

    private var sidebarIconColor: Color {
        guard isSetupThemePreviewActive else { return CandoaInterfaceStyle.sidebarIcon }

        let usesDarkForeground = CandoaInterfaceStyle.prefersDarkForeground(
            forSpaceHexes: store.activeThemeColorHexes
        )
        return (usesDarkForeground ? Color.black : Color.white).opacity(0.42)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sidebarHeader

            if store.isInitialAccountSetupPresented {
                Spacer(minLength: 0)
            } else if store.isSpaceSetupPresented {
                UpsertSpaceSidebarComposer(
                    store: store,
                    mode: store.isInitialSpaceSetupPresented
                        ? .initial
                        : (store.editingSpaceID != nil ? .edit : .create)
                )
                .id(store.editingSpaceID)
            } else {
                addressPill

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        favoritesSection
                        spaceAndPinnedSection

                        VStack(alignment: .leading, spacing: 2) {
                            newTabButton
                            tabsSection
                        }
                    }
                    .padding(.top, 1)
                }

                Spacer(minLength: 6)
            }

            if let availableUpdate {
                AppUpdateBanner(
                    update: availableUpdate,
                    automaticUpdatesEnabled: automaticUpdatesEnabled,
                    action: onUpdateBannerTapped
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !store.isInitialOnboardingPresented || store.initialOnboardingStep == .tour {
                SpaceSwitcherView(store: store)
            }
        }
        .animation(.easeOut(duration: 0.16), value: availableUpdate)
        .animation(.easeOut(duration: 0.16), value: store.mediaControllerTabID)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(alignment: .top, spacing: 6) {
            WindowControlsView(
                hiddenOffset: windowControlsHiddenOffset
            )
                .frame(width: windowControlsWidth, height: 24)

            Spacer(minLength: 8)

            navigationControls
                .offset(y: -5)
                .opacity(hidesNavigationControlsForAddressPalette ? 0 : 1)
                .allowsHitTesting(!hidesNavigationControlsForAddressPalette)

            Button {
                onToggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .toolbarIconButton()
            .offset(y: -5)
            .help("Hide Sidebar")
            .accessibilityIdentifier("sidebar-toggle-button")
        }
        .buttonStyle(.plain)
        .foregroundStyle(sidebarIconColor)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    private var hidesNavigationControlsForAddressPalette: Bool {
        store.isInitialOnboardingPresented
            || (store.isCommandPalettePresented && store.commandPaletteWasOpenedFromSidebarAddress)
    }

    private var navigationControls: some View {
        HStack(spacing: 6) {
            Button(action: store.goBack) {
                Image(systemName: "arrow.left")
            }
            .disabled(!store.canGoBack)
            .toolbarIconButton()
            .help("Back")

            Button(action: store.goForward) {
                Image(systemName: "arrow.right")
            }
            .disabled(!store.canGoForward)
            .toolbarIconButton()
            .help("Forward")

            if store.activeTab?.isLoading == true {
                Button(action: store.stopLoadingActiveTab) {
                    Image(systemName: "xmark")
                }
                .toolbarIconButton()
                .help("Stop")
            } else {
                Button(action: store.reloadActiveTab) {
                    Image(systemName: "arrow.clockwise")
                }
                .toolbarIconButton()
                .help("Reload")
            }
        }
    }

    private var addressPill: some View {
        Button {
            store.focusSidebarAddressBar()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDeveloperModeEnabled ? "info.circle" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)

                Text(sidebarAddressText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(
                        isDeveloperModeEnabled
                            ? .system(size: 13, weight: .medium, design: .monospaced)
                            : .system(size: 14, weight: .semibold)
                    )
                    .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(CandoaInterfaceStyle.sidebarControlFill)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(isHoveringAddressPill ? 0.07 : 0))
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHoveringAddressPill = $0 }
        .help(isDeveloperModeEnabled ? "Developer Mode" : BrowserDefaults.addressPlaceholder)
        .contextMenu {
            if let url = store.activeTab?.url,
               let host = DeveloperModeConfiguration.displayHost(for: url) {
                Toggle(
                    "Developer Mode",
                    isOn: Binding(
                        get: {
                            DeveloperModeConfiguration.isEnabled(
                                for: url,
                                storedOverrides: developerModeOverrides
                            )
                        },
                        set: { store.setDeveloperMode($0, for: url) }
                    )
                )

                Text(host)
            }
        }
        .accessibilityLabel("Address")
        .accessibilityIdentifier("sidebar-address-button")
    }

    // Arc's Developer Mode shows the full URL for local servers by default
    // and for any site the user has enabled through site controls.
    private var isDeveloperModeEnabled: Bool {
        guard let url = store.activeTab?.url else { return false }
        return DeveloperModeConfiguration.isEnabled(
            for: url,
            storedOverrides: developerModeOverrides
        )
    }

    private var sidebarAddressText: String {
        guard let url = store.activeTab?.url else {
            return "Search..."
        }

        if isDeveloperModeEnabled {
            return url.localDevelopmentDisplayText
        }

        if let host = url.host(percentEncoded: false) {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        return url.absoluteString
    }

    // MARK: - Favorites

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = store.favoriteTabsForActiveSpace

        VStack(alignment: .leading, spacing: 6) {
            if favorites.isEmpty && !isFavoritesDropZoneDismissed {
                FavoriteDropZone {
                    isFavoritesDropZoneDismissed = true
                }
                    .onDrop(
                        of: [UTType.text],
                        delegate: FavoriteTabDropDelegate(
                            targetTab: nil,
                            favoriteTabs: favorites,
                            store: store
                        )
                    )
            } else {
                LazyVGrid(columns: essentialColumns(for: favorites.count), spacing: 6) {
                    ForEach(favorites) { tab in
                        favoriteTile(for: tab, favorites: favorites)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: favorites.map(\.id))
        .id(store.activeSpaceID)
    }

    private func favoriteTile(for tab: BrowserTab, favorites: [BrowserTab]) -> some View {
        EssentialTileView(
            tab: tab,
            isActive: tab.id == store.activeTabID &&
                !store.isNewTabPaletteActive,
            accentColor: activeSpaceTint,
            placement: .favorite,
            onSelect: { store.activateFavorite(tab.id) },
            onClose: { store.closeTab(tab.id) },
            onDuplicate: { store.duplicateTab(tab.id) },
            onOpenInSplit: { store.openSplitView(with: tab.id) },
            onToggleFavorite: { store.toggleFavorite(tab.id) },
            onTogglePin: { store.togglePin(tab.id) }
        )
        .opacity(store.shouldHideSidebarTab(tab.id, placement: .favorites) ? 0 : 1)
        .sidebarEssentialDropIndicator(
            showsLeading: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .favorites,
                targetTabID: tab.id,
                edge: .before
            ),
            showsTrailing: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .favorites,
                targetTabID: tab.id,
                edge: .after
            ),
            tint: activeSpaceTint
        )
        .onDrag {
            store.beginTabDrag(tab.id)
        }
        .onDrop(
            of: [UTType.text],
            delegate: FavoriteTabDropDelegate(
                targetTab: tab,
                favoriteTabs: favorites,
                store: store
            )
        )
    }

    // MARK: - Pinned Items

    private var spaceAndPinnedSection: some View {
        VStack(alignment: .leading, spacing: spaceLabelToPinnedGap) {
            spaceLabel
            pinnedAndFoldersSection
        }
    }

    @ViewBuilder
    private var pinnedAndFoldersSection: some View {
        let splitTabIDs = store.activeSplitGroupTabIDs
        let pinned = store.pinnedTabsForActiveSpace.filter { !splitTabIDs.contains($0.id) }
        let folders = store.foldersForActiveSpace

        if !pinned.isEmpty || !folders.isEmpty || store.draggedTabID != nil {
            let showsPinnedAreaDivider = !pinned.isEmpty || !folders.isEmpty

            VStack(alignment: .leading, spacing: pinnedSectionSpacing) {
                if !pinned.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(pinned) { tab in
                            pinnedTabRow(for: tab, pinned: pinned)
                        }
                    }
                }

                if store.draggedTabID != nil {
                    pinnedAppendDropTarget
                }

                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(folders) { folder in
                            FolderSectionView(
                                store: store,
                                folder: folder,
                                editingFolderID: $store.editingFolderID,
                                accentColor: activeSpaceTint,
                                nestingLevel: 0
                            )
                        }
                    }
                }

                if showsPinnedAreaDivider {
                    Rectangle()
                        .fill(CandoaInterfaceStyle.sidebarSeparator)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.text],
                delegate: PinnedTabSectionDropDelegate(store: store)
            )
            // Pin, folder, and close settle the section instead of popping; the
            // per-space identity keeps space switches an instant context cut.
            .animation(.easeOut(duration: 0.18), value: pinned.map(\.id) + folders.map(\.id))
            .id(store.activeSpaceID)
        }
    }

    private var pinnedAppendDropTarget: some View {
        VStack(spacing: 0) {
            if store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: nil,
                edge: .after
            ) {
                SidebarHorizontalDropLine(tint: activeSpaceTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            } else {
                Color.clear
                    .frame(height: 10)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.text],
            delegate: PinnedTabSectionDropDelegate(store: store)
        )
    }

    private func pinnedTabRow(for tab: BrowserTab, pinned: [BrowserTab]) -> some View {
        TabRowView(
            tab: tab,
            isActive: tab.id == store.activeTabID && !store.isNewTabPaletteActive,
            isSplit: store.activeSplitGroupTabIDs.contains(tab.id),
            accentColor: activeSpaceTint,
            mediaState: store.mediaStates[tab.id],
            onSelect: { store.switchTab(to: tab.id) },
            onClose: { store.closeTab(tab.id) },
            onDuplicate: { store.duplicateTab(tab.id) },
            onOpenInSplit: { store.openSplitView(with: tab.id) },
            onToggleFavorite: { store.toggleFavorite(tab.id) },
            onTogglePin: { store.togglePin(tab.id) },
            onToggleMute: { store.toggleMediaMute(tabID: tab.id) }
        )
        // The system drag image is the only visible copy while dragging; the
        // source row leaves a gap that doubles as the insertion indicator.
        .opacity(store.shouldHideSidebarTab(tab.id, placement: .pinned) ? 0 : 1)
        .sidebarRowDropIndicator(
            showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: tab.id,
                edge: .before
            ),
            showsSplit: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: tab.id,
                edge: .split
            ),
            showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: tab.id,
                edge: .after
            ),
            tint: activeSpaceTint
        )
        .onDrag {
            store.beginTabDrag(tab.id)
        }
        .onDrop(
            of: [UTType.text],
            delegate: TabReorderDropDelegate(
                targetTab: tab,
                tabs: pinned,
                isFavorite: false,
                pinned: true,
                folderID: nil,
                store: store
            )
        )
    }

    // MARK: - Tabs

    @ViewBuilder
    private var spaceLabel: some View {
        if let space = store.activeSpace,
           !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 8) {
                if space.symbolName != "square.dashed" {
                    if let emoji = space.iconEmoji {
                        Text(emoji)
                            .font(.system(size: 15))
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: space.symbolName)
                            .font(.system(size: 15, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 18, height: 18)
                    }
                }

                Text(space.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13.5, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(
                isSpaceDropTargeted
                    ? CandoaInterfaceStyle.sidebarControlFillDropTarget
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.text],
                delegate: SpaceLabelDropDelegate(
                    isTargeted: $isSpaceDropTargeted,
                    store: store
                )
            )
            .onChange(of: store.draggedTabID) { _, newValue in
                if newValue == nil {
                    isSpaceDropTargeted = false
                }
            }
            .animation(.easeOut(duration: 0.10), value: isSpaceDropTargeted)
        }
    }

    @ViewBuilder
    private var tabsSection: some View {
        let splitTabs = store.activeSplitGroupTabs
        let splitTabIDs = Set(splitTabs.map(\.id))
        let tabs = store.regularTabsForActiveSpace.filter { !splitTabIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 0) {
            if tabs.isEmpty && splitTabs.isEmpty {
                Text("No tabs")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                    placement: .regular,
                    targetTabID: nil,
                    edge: .after
                ) {
                    SidebarHorizontalDropLine(tint: activeSpaceTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
            } else {
                VStack(spacing: 2) {
                    if splitTabs.count >= 2 {
                        SidebarSplitGroupView(
                            store: store,
                            tabs: splitTabs,
                            accentColor: activeSpaceTint
                        )
                    }

                    ForEach(tabs) { tab in
                        TabRowView(
                            tab: tab,
                            isActive: tab.id == store.activeTabID && !store.isNewTabPaletteActive,
                            isSplit: store.activeSplitGroupTabIDs.contains(tab.id),
                            accentColor: activeSpaceTint,
                            mediaState: store.mediaStates[tab.id],
                            onSelect: { store.switchTab(to: tab.id) },
                            onClose: { store.closeTab(tab.id) },
                            onDuplicate: { store.duplicateTab(tab.id) },
                            onOpenInSplit: { store.openSplitView(with: tab.id) },
                            onToggleFavorite: { store.toggleFavorite(tab.id) },
                            onTogglePin: { store.togglePin(tab.id) },
                            onToggleMute: { store.toggleMediaMute(tabID: tab.id) }
                        )
                        // Hide the source row while its drag session is live so
                        // the cursor ghost isn't doubled by the in-list row; the
                        // gap it leaves is the insertion indicator.
                        .opacity(store.shouldHideSidebarTab(tab.id, placement: .regular) ? 0 : 1)
                        .sidebarRowDropIndicator(
                            showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                placement: .regular,
                                targetTabID: tab.id,
                                edge: .before
                            ),
                            showsSplit: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                placement: .regular,
                                targetTabID: tab.id,
                                edge: .split
                            ),
                            showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                placement: .regular,
                                targetTabID: tab.id,
                                edge: .after
                            ),
                            tint: activeSpaceTint
                        )
                        .onDrag {
                            store.beginTabDrag(tab.id)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: TabReorderDropDelegate(
                                targetTab: tab,
                                tabs: tabs,
                                isFavorite: false,
                                pinned: false,
                                folderID: nil,
                                store: store
                            )
                        )
                    }

                    if store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                        placement: .regular,
                        targetTabID: nil,
                        edge: .after
                    ) {
                        SidebarHorizontalDropLine(tint: activeSpaceTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                // Closing, opening, and reordering settle the list the way
                // Safari's sidebar does instead of rows popping in place; the
                // per-space identity keeps space switches an instant cut.
                .animation(.easeOut(duration: 0.18), value: tabs.map(\.id))
                .id(store.activeSpaceID)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.text],
            delegate: RegularTabSectionDropDelegate(store: store)
        )
    }

    private var newTabButton: some View {
        // While the ⌘T palette is open this button wears the active-tab
        // highlight — Arc's "selected without navigating" new-tab state.
        let isArmed = store.isNewTabPaletteActive

        return Button {
            store.openNewTabCommandPalette()
        } label: {
            // contentShape must live inside the label: applied outside the
            // Button it doesn't extend the clickable area, leaving only the
            // glyphs hit-testable. The layout mirrors TabRowView so the
            // button reads as one of the tab rows.
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isArmed ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarIcon)
                    .frame(width: 16, height: 16)

                Text(BrowserCommandTitles.newTab)
                    .lineLimit(1)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isArmed ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarTextSecondary)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(newTabButtonBackground(isArmed: isArmed))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHoveringNewTab = $0 }
        .accessibilityIdentifier("sidebar-new-tab-button")
        .initialTourPopover(.commandBar, store: store, arrowEdge: .leading)
        .overlay {
            if isHoveringNewTab && !isArmed && store.draggedTabID == nil {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CandoaInterfaceStyle.sidebarControlStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.10), value: isHoveringNewTab)
        .animation(.easeOut(duration: 0.12), value: isArmed)
    }

    private func newTabButtonBackground(isArmed: Bool) -> Color {
        if isArmed {
            return activeSpaceTint.opacity(0.18)
        }
        if isHoveringNewTab && store.draggedTabID == nil {
            return CandoaInterfaceStyle.sidebarControlFillHover
        }
        return Color.clear
    }
}
