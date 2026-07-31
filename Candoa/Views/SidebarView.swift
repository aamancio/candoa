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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let availableUpdate: AppUpdate?
    let automaticUpdatesEnabled: Binding<Bool>
    let onUpdateBannerTapped: () -> Void
    let onToggleSidebar: () -> Void

    @State private var isHoveringNewTab = false
    @State private var isHoveringAddressPill = false
    @State private var isSpaceDropTargeted = false
    @State private var isSpaceSwipePrepared = false
    @State private var isSettlingSpaceSwipe = false
    @State private var spaceSwipeSourceID: UUID?
    @State private var spaceSwipeSettleRequest: SpaceSwipeSettleRequest?
    @State private var selectedSpaceTransitionID: UUID?
    @State private var selectedSpaceTransitionDirection: Int?
    @StateObject private var windowControlsGeometry = WindowControlsGeometry()
    @AppStorage("Candoa.FavoritesDropZoneDismissed") private var isFavoritesDropZoneDismissed = false
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""

    private let leadingInset: CGFloat = 9
    private let trailingInset: CGFloat = 9
    private let windowControlsWidth: CGFloat = 70
    private let spaceLabelToPinnedGap: CGFloat = 3
    private let pinnedSectionSpacing: CGFloat = 8
    private let sidebarTopPadding: CGFloat = 8
    private let sidebarBottomPadding: CGFloat = 10
    private let sidebarVerticalSpacing: CGFloat = 12
    private let sidebarHeaderHeight: CGFloat = 34
    private let sidebarAddressHeight: CGFloat = 40
    private let spaceSwitcherHeight: CGFloat = 32
    private let updateBannerHeight: CGFloat = 38

    /// Zen-style Essentials collapse unused grid tracks, so one or two tiles
    /// still consume the full row instead of leaving empty reserved slots.
    private func essentialColumns(for itemCount: Int) -> [GridItem] {
        let visibleColumns = min(max(itemCount, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: visibleColumns)
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
        Group {
            if usesBrowsingSidebarLayout {
                browsingSidebar
            } else {
                setupSidebar
            }
        }
        .animation(.easeOut(duration: 0.16), value: availableUpdate)
        .animation(.easeOut(duration: 0.16), value: store.mediaControllerTabID)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: store.activeSpaceID) { _, _ in
            resetSpaceSwipeProgress()
        }
        .onChange(of: store.spaces.map(\.id)) { _, _ in
            resetSpaceSwipeProgress()
        }
        .onDisappear {
            resetSpaceSwipeProgress()
        }
    }

    private var usesBrowsingSidebarLayout: Bool {
        !store.isInitialAccountSetupPresented && !store.isSpaceSetupPresented
    }

    private var showsSpaceSwitcher: Bool {
        !store.isInitialOnboardingPresented || store.initialOnboardingStep == .tour
    }

    private var browsingSidebar: some View {
        // Zen/Arc pin the space switcher while workspaces page horizontally.
        // The strip is a sibling of the swipe carousel — never a child of the
        // translated hosting view — so gestures slide only the space content
        // and the strip stays put as persistent navigation chrome.
        spaceSwipeContent
            .overlay(alignment: .bottom) {
                if showsSpaceSwitcher {
                    HoistedSpaceSwitcherStrip(
                        store: store,
                        onSelectSpace: animateSpaceSelection
                    )
                    .padding(.horizontal, leadingInset)
                    .padding(.bottom, sidebarBottomPadding)
                }
            }
    }

    private var setupSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            sidebarHeader(showsWindowControls: true)

            if store.isInitialAccountSetupPresented {
                Spacer(minLength: 0)
            } else {
                UpsertSpaceSidebarComposer(
                    store: store,
                    mode: store.isInitialSpaceSetupPresented
                        ? .initial
                        : (store.editingSpaceID != nil ? .edit : .create)
                )
                .id(store.editingSpaceID)
            }

            updateBanner

            if showsSpaceSwitcher {
                spaceSwitcher(displaying: store.activeSpaceID)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, sidebarTopPadding)
        .padding(.bottom, sidebarBottomPadding)
    }

    @ViewBuilder
    private var updateBanner: some View {
        if let availableUpdate {
            AppUpdateBanner(
                update: availableUpdate,
                automaticUpdatesEnabled: automaticUpdatesEnabled,
                action: onUpdateBannerTapped
            )
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func spaceSwitcher(displaying activeSpaceID: UUID) -> some View {
        SpaceSwitcherView(
            store: store,
            displayedActiveSpaceID: activeSpaceID,
            onSelectSpace: animateSpaceSelection
        )
    }

    private func sidebarChrome(
        for spaceID: UUID,
        showsWindowControls: Bool,
        isSwipingSpaces: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: sidebarVerticalSpacing) {
            sidebarHeader(
                showsWindowControls: showsWindowControls,
                isSwipingSpaces: isSwipingSpaces
            )
            addressPill(for: spaceID)

            Spacer(minLength: 0)

            updateBanner
        }
        .padding(.horizontal, leadingInset)
        .padding(.top, sidebarTopPadding)
        .padding(.bottom, swipeChromeBottomPadding)
    }

    /// The hoisted switcher still occupies the bottom strip, so the per-page
    /// chrome must end above it — the banner keeps its resting position.
    private var swipeChromeBottomPadding: CGFloat {
        var padding = sidebarBottomPadding

        if showsSpaceSwitcher {
            padding += spaceSwitcherHeight + sidebarVerticalSpacing
        }

        return padding
    }

    private var canSwipeSpaces: Bool {
        store.spaces.count > 1 &&
            !store.isInitialAccountSetupPresented &&
            !store.isInitialOnboardingPresented &&
            !store.isSpaceSetupPresented &&
            !store.isCommandPalettePresented &&
            store.draggedTabID == nil
    }

    private var spaceSwipeContent: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            SpaceSwipeTrackingView(
                isEnabled: canSwipeSpaces,
                contentID: store.activeSpaceID,
                settleRequest: spaceSwipeSettleRequest,
                reduceMotion: accessibilityReduceMotion,
                onGestureBegan: beginSpaceSwipeGesture,
                onSwipeProgress: updateSpaceSwipeThemeProgress,
                onSettleBegan: settleSpaceSwipeTheme,
                onCompletion: completeSpaceSwipe
            ) {
                ZStack(alignment: .leading) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach([-1, 0, 1], id: \.self) { slot in
                            spaceSwipePage(
                                slot: slot,
                                minimumHeight: proxy.size.height
                            )
                                .frame(width: width)
                        }
                    }
                    .offset(x: -width)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .clipped()
        .accessibilityIdentifier("sidebar-space-swipe-area")
    }

    private var spaceSwipeTopInset: CGFloat {
        sidebarTopPadding +
            sidebarHeaderHeight +
            sidebarVerticalSpacing +
            sidebarAddressHeight +
            sidebarVerticalSpacing
    }

    private var spaceSwipeBottomInset: CGFloat {
        var inset = sidebarBottomPadding

        if showsSpaceSwitcher {
            inset += spaceSwitcherHeight + sidebarVerticalSpacing
        }

        if availableUpdate != nil {
            inset += updateBannerHeight + sidebarVerticalSpacing
        }

        return inset
    }

    @ViewBuilder
    private func spaceSwipePage(slot: Int, minimumHeight: CGFloat) -> some View {
        if let spaceID = spaceID(forSwipeSlot: slot) {
            let contentHeight = max(
                minimumHeight - spaceSwipeTopInset - spaceSwipeBottomInset,
                1
            )

            ZStack {
                Group {
                    if slot == 0 || isSpaceSwipePrepared || selectedSpaceTransitionID != nil {
                        spaceScrollContent(for: spaceID)
                    } else {
                        Color.clear
                    }
                }
                .padding(.horizontal, leadingInset)
                .frame(
                    minHeight: contentHeight,
                    alignment: .top
                )
                .padding(.top, spaceSwipeTopInset)
                .padding(.bottom, spaceSwipeBottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                if slot == 0 || isSpaceSwipePrepared {
                    sidebarChrome(
                        for: spaceID,
                        showsWindowControls: slot == 0,
                        isSwipingSpaces: isSpaceSwipePrepared
                    )
                }
            }
            .allowsHitTesting(slot == 0)
            .accessibilityHidden(slot != 0)
        } else {
            Color.clear
        }
    }

    private func spaceID(forSwipeSlot slot: Int) -> UUID? {
        guard
            !store.spaces.isEmpty,
            let activeIndex = store.spaces.firstIndex(where: { $0.id == store.activeSpaceID })
        else {
            return nil
        }

        if slot != 0,
           slot == selectedSpaceTransitionDirection,
           let selectedSpaceTransitionID {
            return selectedSpaceTransitionID
        }

        let destinationIndex = (activeIndex + slot + store.spaces.count) % store.spaces.count
        return store.spaces[destinationIndex].id
    }

    private func beginSpaceSwipeGesture(_ direction: Int) {
        guard !isSettlingSpaceSwipe else { return }
        selectedSpaceTransitionID = nil
        selectedSpaceTransitionDirection = direction
        spaceSwipeSettleRequest = nil
        spaceSwipeSourceID = store.activeSpaceID
        isSpaceSwipePrepared = true
        isSettlingSpaceSwipe = true
        store.chromeTransition.update(
            fraction: 0,
            toward: spaceID(forSwipeSlot: direction)
        )
    }

    /// The chrome tint follows the finger: blend toward the revealed Space's
    /// theme in proportion to how far the pages have slid.
    private func updateSpaceSwipeThemeProgress(_ gestureAmount: CGFloat) {
        guard isSpaceSwipePrepared else { return }

        let direction = gestureAmount > 0 ? -1 : 1
        let destinationID = gestureAmount == 0
            ? store.chromeTransition.destinationSpaceID
            : spaceID(forSwipeSlot: direction)
        store.chromeTransition.update(
            fraction: min(1, abs(gestureAmount)),
            toward: destinationID
        )
    }

    /// Non-tracked settles (discrete scrolls, Space-switcher clicks) get no
    /// per-frame gesture updates, so ease the tint alongside the page spring.
    private func settleSpaceSwipeTheme(_ destination: Int) {
        let destinationID = spaceID(forSwipeSlot: destination)
        if accessibilityReduceMotion {
            store.chromeTransition.update(fraction: 1, toward: destinationID)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                store.chromeTransition.update(fraction: 1, toward: destinationID)
            }
        }
    }

    private func animateSpaceSelection(_ spaceID: UUID) {
        guard
            spaceID != store.activeSpaceID,
            store.spaces.contains(where: { $0.id == spaceID })
        else {
            return
        }

        guard
            canSwipeSpaces,
            !isSettlingSpaceSwipe,
            let activeIndex = store.spaces.firstIndex(where: { $0.id == store.activeSpaceID }),
            let destinationIndex = store.spaces.firstIndex(where: { $0.id == spaceID })
        else {
            // The animated transition is unavailable (a settle is in flight,
            // or the switcher is visible outside plain browsing). The click
            // must still switch Spaces rather than being dropped.
            selectSpaceWithoutAnimation(spaceID)
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let direction = destinationIndex > activeIndex ? 1 : -1
            selectedSpaceTransitionID = spaceID
            selectedSpaceTransitionDirection = direction
            spaceSwipeSourceID = store.activeSpaceID
            isSpaceSwipePrepared = true
            isSettlingSpaceSwipe = true
            spaceSwipeSettleRequest = SpaceSwipeSettleRequest(destination: direction)
        }
    }

    private func selectSpaceWithoutAnimation(_ spaceID: UUID) {
        if store.editingSpaceID != nil || store.isCreateSpacePresented {
            store.clearSpaceThemePreview()
            store.editingSpaceID = nil
            store.isCreateSpacePresented = false
        }
        store.dismissCommandPalette()
        resetSpaceSwipeProgress()
        store.switchSpace(to: spaceID)
    }

    private func completeSpaceSwipe(_ destinationOffset: Int) {
        guard let sourceSpaceID = spaceSwipeSourceID else {
            resetSpaceSwipeProgress()
            return
        }
        commitSpaceSwipe(destinationOffset, from: sourceSpaceID)
    }

    private func commitSpaceSwipe(_ destinationOffset: Int, from sourceSpaceID: UUID) {
        defer { isSettlingSpaceSwipe = false }

        guard
            store.activeSpaceID == sourceSpaceID,
            destinationOffset != 0,
            let destinationSpaceID = spaceID(forSwipeSlot: destinationOffset),
            let destination = store.spaces.first(where: { $0.id == destinationSpaceID })
        else {
            resetSpaceSwipeProgress()
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.switchSpace(to: destinationSpaceID)
        }

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(destination.name) Space",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func resetSpaceSwipeProgress() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSpaceSwipePrepared = false
            isSettlingSpaceSwipe = false
            spaceSwipeSourceID = nil
            spaceSwipeSettleRequest = nil
            selectedSpaceTransitionID = nil
            selectedSpaceTransitionDirection = nil
            store.chromeTransition.reset()
        }
    }

    private func spaceScrollContent(for spaceID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            favoritesSection(for: spaceID)
            spaceAndPinnedSection(for: spaceID)

            VStack(alignment: .leading, spacing: 2) {
                newTabButton
                tabsSection(for: spaceID)
            }
        }
        .padding(.top, 1)
        .id(spaceID)
    }

    // MARK: - Header

    private func sidebarHeader(
        showsWindowControls: Bool,
        isSwipingSpaces: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                if showsWindowControls {
                    WindowControlsView(
                        isSuppressed: isSwipingSpaces,
                        geometry: windowControlsGeometry
                    )
                } else {
                    Color.clear
                }
            }
            .frame(width: windowControlsWidth, height: 24)
            .overlay(alignment: .topLeading) {
                if isSwipingSpaces {
                    FauxWindowControlsView(geometry: windowControlsGeometry)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                navigationControls
                    .opacity(hidesNavigationControlsForAddressPalette ? 0 : 1)
                    .allowsHitTesting(!hidesNavigationControlsForAddressPalette)

                Button {
                    onToggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .toolbarIconButton()
                .help("Hide Sidebar")
                .accessibilityIdentifier("sidebar-toggle-button")
            }
            // Sit the icons on the measured centerline of the native window
            // buttons, wherever AppKit put them.
            .offset(y: windowControlsGeometry.controlsCenterOffsetY)
        }
        .candoaButton(.content)
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

    private func addressPill(for spaceID: UUID) -> some View {
        let url = displayedURL(for: spaceID)
        let developerModeEnabled = isDeveloperModeEnabled(for: url)

        return Button {
            store.focusSidebarAddressBar()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: developerModeEnabled ? "info.circle" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)

                Text(sidebarAddressText(for: url, developerModeEnabled: developerModeEnabled))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(
                        developerModeEnabled
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
        .candoaButton(.content)
        .onHover { isHoveringAddressPill = $0 }
        .help(developerModeEnabled ? "Developer Mode" : BrowserDefaults.addressPlaceholder)
        .contextMenu {
            if let url,
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
    private func isDeveloperModeEnabled(for url: URL?) -> Bool {
        guard let url else { return false }
        return DeveloperModeConfiguration.isEnabled(
            for: url,
            storedOverrides: developerModeOverrides
        )
    }

    private func displayedURL(for spaceID: UUID) -> URL? {
        guard let tabID = displayedActiveTabID(for: spaceID) else { return nil }
        return store.tabs.first(where: { $0.id == tabID })?.url
    }

    private func sidebarAddressText(
        for url: URL?,
        developerModeEnabled: Bool
    ) -> String {
        guard let url else {
            return "Search..."
        }

        if developerModeEnabled {
            return url.localDevelopmentDisplayText
        }

        if let host = url.host(percentEncoded: false) {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        return url.absoluteString
    }

    // MARK: - Favorites

    @ViewBuilder
    private func favoritesSection(for spaceID: UUID) -> some View {
        let favorites = store.favoriteTabs(in: spaceID)

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
                        favoriteTile(for: tab, favorites: favorites, spaceID: spaceID)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: favorites.map(\.id))
        .id(spaceID)
    }

    private func favoriteTile(
        for tab: BrowserTab,
        favorites: [BrowserTab],
        spaceID: UUID
    ) -> some View {
        EssentialTileView(
            tab: tab,
            isActive: tab.id == displayedActiveTabID(for: spaceID) &&
                !store.isNewTabPaletteActive,
            accentColor: CandoaColor.accent,
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
            tint: CandoaColor.accent
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

    private func spaceAndPinnedSection(for spaceID: UUID) -> some View {
        VStack(alignment: .leading, spacing: spaceLabelToPinnedGap) {
            spaceLabel(for: spaceID)
            pinnedAndFoldersSection(for: spaceID)
        }
    }

    @ViewBuilder
    private func pinnedAndFoldersSection(for spaceID: UUID) -> some View {
        let splitTabIDs = spaceID == store.activeSpaceID ? store.activeSplitGroupTabIDs : []
        let pinned = store.pinnedTabs(in: spaceID).filter { !splitTabIDs.contains($0.id) }
        let folders = store.rootFolders(in: spaceID)

        if !pinned.isEmpty || !folders.isEmpty || store.draggedTabID != nil {
            let showsPinnedAreaDivider = !pinned.isEmpty || !folders.isEmpty

            VStack(alignment: .leading, spacing: pinnedSectionSpacing) {
                if !pinned.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(pinned) { tab in
                            pinnedTabRow(for: tab, pinned: pinned, spaceID: spaceID)
                        }
                    }
                }

                if store.draggedTabID != nil, spaceID == store.activeSpaceID {
                    pinnedAppendDropTarget
                }

                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(folders) { folder in
                            FolderSectionView(
                                store: store,
                                folder: folder,
                                editingFolderID: $store.editingFolderID,
                                accentColor: CandoaColor.accent,
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
            .id(spaceID)
        }
    }

    private var pinnedAppendDropTarget: some View {
        VStack(spacing: 0) {
            if store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: nil,
                edge: .after
            ) {
                SidebarHorizontalDropLine(tint: CandoaColor.accent)
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

    private func pinnedTabRow(
        for tab: BrowserTab,
        pinned: [BrowserTab],
        spaceID: UUID
    ) -> some View {
        TabRowView(
            tab: tab,
            isActive: tab.id == displayedActiveTabID(for: spaceID) && !store.isNewTabPaletteActive,
            isSplit: spaceID == store.activeSpaceID && store.activeSplitGroupTabIDs.contains(tab.id),
            accentColor: CandoaColor.accent,
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
            tint: CandoaColor.accent
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
    private func spaceLabel(for spaceID: UUID) -> some View {
        if let space = store.spaces.first(where: { $0.id == spaceID }),
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
                    .font(.system(size: 13, weight: .medium))

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
    private func tabsSection(for spaceID: UUID) -> some View {
        let splitTabs = spaceID == store.activeSpaceID ? store.activeSplitGroupTabs : []
        let splitTabIDs = Set(splitTabs.map(\.id))
        let tabs = store.regularTabs(in: spaceID).filter { !splitTabIDs.contains($0.id) }

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
                    SidebarHorizontalDropLine(tint: CandoaColor.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
            } else {
                VStack(spacing: 2) {
                    if splitTabs.count >= 2 {
                        SidebarSplitGroupView(
                            store: store,
                            tabs: splitTabs,
                            accentColor: CandoaColor.accent
                        )
                    }

                    ForEach(tabs) { tab in
                        TabRowView(
                            tab: tab,
                            isActive: tab.id == displayedActiveTabID(for: spaceID) && !store.isNewTabPaletteActive,
                            isSplit: spaceID == store.activeSpaceID && store.activeSplitGroupTabIDs.contains(tab.id),
                            accentColor: CandoaColor.accent,
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
                            tint: CandoaColor.accent
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
                        SidebarHorizontalDropLine(tint: CandoaColor.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                // Closing, opening, and reordering settle the list the way
                // Safari's sidebar does instead of rows popping in place; the
                // per-space identity keeps space switches an instant cut.
                .animation(.easeOut(duration: 0.18), value: tabs.map(\.id))
                .id(spaceID)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.text],
            delegate: RegularTabSectionDropDelegate(store: store)
        )
    }

    private func displayedActiveTabID(for spaceID: UUID) -> UUID? {
        if spaceID == store.activeSpaceID {
            return store.activeTabID
        }

        return store.tabs
            .filter { $0.spaceID == spaceID }
            .max(by: { $0.lastAccessedAt < $1.lastAccessedAt })?
            .id
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
                    .font(.system(size: 13, weight: isArmed ? .medium : .regular))
                    .foregroundStyle(isArmed ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarTextSecondary)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .candoaButton(.content)
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
            return CandoaInterfaceStyle.sidebarControlFillActive
        }
        if isHoveringNewTab && store.draggedTabID == nil {
            return CandoaInterfaceStyle.sidebarControlFillHover
        }
        return Color.clear
    }
}

/// The pinned strip's active indicator tracks an in-flight space swipe the
/// way Zen's workspace indicator does: the strip itself never moves, and the
/// highlight hands off to the destination once the gesture passes halfway.
private struct HoistedSpaceSwitcherStrip: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var chromeTransition: SpaceChromeTransition
    let onSelectSpace: (UUID) -> Void

    init(store: BrowserStore, onSelectSpace: @escaping (UUID) -> Void) {
        self._store = ObservedObject(wrappedValue: store)
        self._chromeTransition = ObservedObject(wrappedValue: store.chromeTransition)
        self.onSelectSpace = onSelectSpace
    }

    var body: some View {
        SpaceSwitcherView(
            store: store,
            displayedActiveSpaceID: displayedActiveSpaceID,
            onSelectSpace: onSelectSpace
        )
    }

    private var displayedActiveSpaceID: UUID {
        guard
            chromeTransition.fraction > 0.5,
            let destinationID = chromeTransition.destinationSpaceID,
            store.spaces.contains(where: { $0.id == destinationID })
        else {
            return store.activeSpaceID
        }

        return destinationID
    }
}
