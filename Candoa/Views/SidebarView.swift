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
        // The tab rows' 16pt icon column, so folder names share the tabs'
        // text edge.
        Image(systemName: "folder")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct SidebarView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let availableUpdate: AppUpdate?
    let isInstallingUpdate: Bool
    let automaticUpdatesEnabled: Binding<Bool>
    let onUpdateBannerTapped: () -> Void
    let isWhatsNewVisible: Bool
    let onWhatsNewTapped: () -> Void
    let onWhatsNewDismissed: () -> Void
    let onToggleSidebar: () -> Void
    let isSidebarPinned: Bool
    let onRevealSidebar: () -> Void

    @State private var isHoveringNewTab = false
    @State private var isHoveringAddressPill = false
    @State private var addressPillSharePicker = SharePickerCoordinator()
    @State private var isSpaceSwipePrepared = false
    @State private var isSettlingSpaceSwipe = false
    @State private var spaceSwipeSourceID: UUID?
    @State private var spaceSwipeSettleRequest: SpaceSwipeSettleRequest?
    @State private var selectedSpaceTransitionID: UUID?
    @State private var selectedSpaceTransitionDirection: Int?
    @State private var favoritesSectionHeight: CGFloat = 0
    @State private var spaceLabelHeight: CGFloat = 0
    @StateObject private var swipeTranslationRelay = SpaceSwipeTranslationRelay()
    @StateObject private var spaceHeaderHover = SpaceSwipeCompanionHover()
    @State private var scrollEdges = SpaceScrollEdges()
    @StateObject private var windowControlsGeometry = WindowControlsGeometry()
    @AppStorage("Candoa.FavoritesDropZoneDismissed") private var isFavoritesDropZoneDismissed = false
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""
    @AppStorage(SettingsOption.addressBarPlacement)
    private var addressBarPlacement = AddressBarPlacement.default.rawValue

    // Zen's sidebar geometry: rows sit 8px off the lane edge (6px toolbox
    // padding on macOS plus the 2px tab margin), with 8px inline padding
    // inside each row.
    private let leadingInset: CGFloat = 8
    /// Docked, the 8pt gutter between the lane and the page surface already is
    /// the trailing margin — reserving another 8pt here made every row sit 8pt
    /// off the window edge but 16pt off the page. Only the hover overlay, whose
    /// lane ends in its own shadowed edge over the page, keeps the inset.
    private var trailingInset: CGFloat { isSidebarPinned ? 0 : 8 }
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

    /// Rows making room during a drag use the system's own snappy spring —
    /// quick, a hair of overshoot, settled — rather than a hand-rolled one.
    /// Shorter than `.snappy`'s half-second default: a row slides one row's
    /// height, so the move should be over before the pointer has moved on.
    private static let rowReorder: Animation = .snappy(duration: 0.24)

    /// How long the Space slide waits after a hidden sidebar is revealed, so
    /// the two reads as open-then-slide rather than one blurred move.
    private static let revealBeforeSlideDelay: TimeInterval = 0.2

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
        guard isSetupThemePreviewActive else { return InterfaceStyle.sidebarIcon }

        let usesDarkForeground = InterfaceStyle.prefersDarkForeground(
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
        .onChange(of: store.spaceSelectionRequest) { _, request in
            guard let request else { return }
            store.spaceSelectionRequest = nil
            animateSpaceSelection(request.spaceID)
        }
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
        // Favorites are global the same way: the shared grid is hoisted out
        // of the swiping pages so it stays put while Spaces slide beneath it.
        spaceSwipeContent
            // Arc's window controls, navigation, and address bar are fixed
            // furniture, and so is Zen's bottom bar: only the tab list moves,
            // clipped at both bands with Zen's scrolled-edge rules over it.
            .mask { scrollClipMask }
            .overlay { scrollEdgeRules }
            .overlay(alignment: .top) {
                topChrome
            }
            .overlay(alignment: .top) {
                // Private tabs never join the workspace, so the shared
                // favorites grid (and its drag-here hint) has no place here.
                if !store.isPrivate {
                    hoistedFavoritesSection
                        .padding(.leading, leadingInset)
                        .padding(.trailing, trailingInset)
                        .padding(.top, spaceSwipeTopInset + 1)
                }
            }
            .overlay(alignment: .top) {
                // Arc and Zen keep the Space's name in view however far the
                // list scrolls: the label is a fixed header for the scrolling
                // list beneath it (Zen's `.zen-current-workspace-indicator`
                // sits outside the arrowscrollbox), and the scrolled-edge rule
                // draws directly under it. Per-Space, so it switches on
                // commit like the address pill rather than sliding.
                hoistedSpaceLabel
                    .padding(.top, favoritesBandBottom + 1)
            }
            .overlay(alignment: .bottom) {
                // The banners are app-level, not per-Space: hoisted here they
                // stay put through a swipe and stay on screen at any scroll
                // position, the way the strip below them does.
                VStack(spacing: sidebarVerticalSpacing) {
                    updateBanner

                    if showsSpaceSwitcher {
                        HoistedSpaceSwitcherStrip(
                            store: store,
                            onSelectSpace: animateSpaceSelection
                        )
                    }
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.bottom, sidebarBottomPadding)
            }
    }

    /// Zen's list is clipped hard at the fixed chrome on either end — no
    /// fade — and instead draws a hairline along whichever edge content has
    /// scrolled past (`.workspace-arrowscrollbox[overflowing]`: a 1px
    /// `light-dark(rgba(0,0,0,.08), rgba(255,255,255,.08))` `::before` while
    /// not `[scrolledtostart]`, an `::after` twin while not `[scrolledtoend]`,
    /// each fading over 0.1s).
    private var scrollClipMask: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: spaceContentTopInset)

            Rectangle()
                .fill(Color.black)

            Color.clear
                .frame(height: spaceSwipeBottomInset)
        }
    }

    private var scrollEdgeRules: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: spaceContentTopInset)

            scrollEdgeRule(isVisible: scrollEdges.showsTopRule)

            Spacer(minLength: 0)

            scrollEdgeRule(isVisible: scrollEdges.showsBottomRule)

            Color.clear
                .frame(height: spaceSwipeBottomInset)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .allowsHitTesting(false)
    }

    private func scrollEdgeRule(isVisible: Bool) -> some View {
        Rectangle()
            .fill(InterfaceStyle.zenScrollEdgeRule)
            .frame(height: 1)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: isVisible)
    }

    /// Arc's fixed top: the window controls, navigation, address pill, and the
    /// favorites grid below them stay put while the tab list scrolls under.
    /// The pill shows the active Space — a swipe slides only the list, so it
    /// switches on commit rather than sliding with the page.
    private var topChrome: some View {
        VStack(alignment: .leading, spacing: sidebarVerticalSpacing) {
            sidebarHeader(showsWindowControls: true)

            if showsAddressPill {
                addressPill(for: store.activeSpaceID)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, sidebarTopPadding)
    }

    private var hoistedFavoritesSection: some View {
        // The grid's measured height tells the swiping per-Space pages where
        // their content starts (tile rows come and go with the shared set).
        favoritesSection
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                favoritesSectionHeight = height
            }
    }

    /// Pinned vertically, but not to one Space: the label rides the swipe
    /// carousel's translation through the relay, laid out as the same three
    /// Space-wide slots the pages use, so it slides in lockstep with the list
    /// under it instead of cutting to the destination on commit.
    private var hoistedSpaceLabel: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            SpaceSwipeCompanionView(relay: swipeTranslationRelay, hover: spaceHeaderHover) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach([-1, 0, 1], id: \.self) { slot in
                        Group {
                            if let spaceID = spaceID(forSwipeSlot: slot) {
                                spaceLabel(for: spaceID)
                            } else {
                                Color.clear.frame(height: 0)
                            }
                        }
                        .padding(.leading, leadingInset)
                        .padding(.trailing, trailingInset)
                        .frame(width: width, alignment: .topLeading)
                        .allowsHitTesting(slot == 0)
                        .accessibilityHidden(slot != 0)
                    }
                }
                .offset(x: -width)
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                spaceLabelHeight = height
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                isInstalling: isInstallingUpdate,
                automaticUpdatesEnabled: automaticUpdatesEnabled,
                action: onUpdateBannerTapped
            )
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if isWhatsNewVisible {
            WhatsNewBanner(
                action: onWhatsNewTapped,
                dismiss: onWhatsNewDismissed
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
            // The list scrolls behind the fixed chrome at both ends; edge
            // auto-scrolling during a drag needs to know where it really ends.
            let _ = SidebarDragAutoScroll.shared.updateChromeInsets(
                top: spaceContentTopInset,
                bottom: spaceSwipeBottomInset
            )

            SpaceSwipeTrackingView(
                isEnabled: canSwipeSpaces,
                contentID: store.activeSpaceID,
                settleRequest: spaceSwipeSettleRequest,
                reduceMotion: accessibilityReduceMotion,
                onGestureBegan: beginSpaceSwipeGesture,
                onSwipeProgress: updateSpaceSwipeThemeProgress,
                onSettleBegan: settleSpaceSwipeTheme,
                onCompletion: completeSpaceSwipe,
                onScrollEdgesChanged: { scrollEdges = $0 },
                translationRelay: swipeTranslationRelay
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

    /// The pill moves to a strip above the page under the "Top" placement;
    /// the sidebar then closes the gap it would have occupied.
    private var showsAddressPill: Bool {
        addressBarPlacement != AddressBarPlacement.top.rawValue
    }

    private var spaceSwipeTopInset: CGFloat {
        sidebarTopPadding +
            sidebarHeaderHeight +
            sidebarVerticalSpacing +
            (showsAddressPill ? sidebarAddressHeight + sidebarVerticalSpacing : 0)
    }

    /// Where the hoisted favorites grid ends and the Space label begins; the
    /// grid's height is measured live (tile rows come and go with the set).
    private var favoritesBandBottom: CGFloat {
        spaceSwipeTopInset + (favoritesSectionHeight > 0 ? favoritesSectionHeight + 10 : 0)
    }

    /// The scrolling list starts below the fixed Space label. The label's
    /// height is measured too: it collapses to nothing for an unnamed Space
    /// and grows with the Private Browsing row.
    private var spaceContentTopInset: CGFloat {
        favoritesBandBottom + (spaceLabelHeight > 0 ? spaceLabelHeight + spaceLabelToPinnedGap : 0)
    }

    private var spaceSwipeBottomInset: CGFloat {
        var inset = sidebarBottomPadding

        if showsSpaceSwitcher {
            inset += spaceSwitcherHeight + sidebarVerticalSpacing
        }

        // Both banners ride the same slot above the switcher and can stack, so
        // each reserves its own gap. Miss one and the tab list keeps scrolling
        // under it — the last rows read as struck through by the pill.
        if availableUpdate != nil {
            inset += updateBannerHeight + sidebarVerticalSpacing
        }

        if isWhatsNewVisible {
            inset += updateBannerHeight + sidebarVerticalSpacing
        }

        return inset
    }

    @ViewBuilder
    private func spaceSwipePage(slot: Int, minimumHeight: CGFloat) -> some View {
        if let spaceID = spaceID(forSwipeSlot: slot) {
            let contentHeight = max(
                minimumHeight - spaceContentTopInset - spaceSwipeBottomInset,
                1
            )

            Group {
                if slot == 0 || isSpaceSwipePrepared || selectedSpaceTransitionID != nil {
                    spaceScrollContent(for: spaceID)
                } else {
                    Color.clear
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(
                minHeight: contentHeight,
                alignment: .top
            )
            .padding(.top, spaceContentTopInset)
            .padding(.bottom, spaceSwipeBottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
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

        guard isSidebarPinned else {
            // The transition is the sidebar sliding from one Space to the
            // next, so a hidden sidebar would play it off-screen. The reveal
            // snaps in a single frame, so the slide waits a beat behind it:
            // long enough to read the sidebar as open and the slide as the
            // separate move it is, short enough to stay one gesture.
            onRevealSidebar()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealBeforeSlideDelay) {
                slideToSpace(spaceID)
            }
            return
        }

        slideToSpace(spaceID)
    }

    private func slideToSpace(_ spaceID: UUID) {
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
        // The favorites grid is not part of this page: it is global and
        // hoisted above the swipe carousel in browsingSidebar.
        VStack(alignment: .leading, spacing: 10) {
            spaceAndPinnedSection(for: spaceID)

            // Zen's row rhythm: 4pt between rows (2px block margin per side).
            VStack(alignment: .leading, spacing: 4) {
                newTabButton
                tabsSection(for: spaceID)
            }
        }
        .id(spaceID)
    }

    // MARK: - Header

    // The header no longer rides the swipe carousel, so the faux traffic
    // lights a sliding page needed are gone with it: the real controls stay
    // where AppKit put them through a Space switch.
    private func sidebarHeader(showsWindowControls: Bool) -> some View {
        // Every width here is part of a budget: with the extensions button
        // loaded this row carries five 24pt buttons beside the 70pt window
        // controls, and its fixed members must never exceed the 218pt the
        // chrome's padding leaves in the 234pt lane — an over-wide header
        // pushes the whole Space page off the window edge.
        HStack(alignment: .center, spacing: 4) {
            Group {
                if showsWindowControls {
                    WindowControlsView(
                        isSuppressed: false,
                        geometry: windowControlsGeometry
                    )
                } else {
                    Color.clear
                }
            }
            .frame(width: windowControlsWidth, height: 24)

            // The badge overlays the flexible gap instead of joining the
            // HStack: this row's fixed members already nearly fill the
            // 234pt sidebar, and any added layout width overflows the
            // frame and shifts the whole sidebar's content off-edge.
            Spacer(minLength: 4)

            // Under the "Above the Page" placement this whole cluster rides
            // the strip beside the address instead, the way Dia lays its
            // toolbar out — the toggle included, so it keeps one home whether
            // the sidebar it opens is showing or not. Never both, or the
            // window shows two Back buttons and two toggles.
            if showsAddressPill {
                HStack(spacing: 4) {
                    navigationControls
                        .opacity(hidesNavigationControlsForAddressPalette ? 0 : 1)
                        .allowsHitTesting(!hidesNavigationControlsForAddressPalette)

                    Button {
                        onToggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .toolbarIconButton()
                    .shortcutTooltip(
                        isSidebarPinned ? "Hide Sidebar" : "Show Sidebar",
                        shortcut: .toggleSidebar
                    )
                    .accessibilityIdentifier("sidebar-toggle-button")
                }
                // Sit the icons on the measured centerline of the native
                // window buttons, wherever AppKit put them.
                .offset(y: windowControlsGeometry.controlsCenterOffsetY)
            }
        }
        .buttonTreatment(.content)
        .foregroundStyle(sidebarIconColor)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    private var hidesNavigationControlsForAddressPalette: Bool {
        store.isInitialOnboardingPresented
            || (store.isCommandPalettePresented && store.commandPaletteWasOpenedFromSidebarAddress)
    }

    private var navigationControls: some View {
        BrowserNavigationControls(store: store)
    }

    private func addressPill(for spaceID: UUID) -> some View {
        let url = displayedURL(for: spaceID)
        let developerModeEnabled = isDeveloperModeEnabled(for: url)

        return HStack(spacing: 0) {
            if let url {
                siteInfoButton(for: url, spaceID: spaceID, developerModeEnabled: developerModeEnabled)
            }

            Button {
                store.focusSidebarAddressBar()
            } label: {
                HStack(spacing: 10) {
                    if url == nil {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(InterfaceStyle.sidebarIcon)
                    }

                    Text(sidebarAddressText(for: url))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(
                            developerModeEnabled
                                ? .system(size: 13, weight: .medium, design: .monospaced)
                                : .system(size: 14, weight: .semibold)
                        )
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)

                    Spacer(minLength: 0)
                }
                .padding(.leading, url == nil ? 11 : 10)
                .padding(.trailing, 11)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .help(developerModeEnabled ? "Developer Mode" : BrowserDefaults.addressPlaceholder)
            .accessibilityLabel("Address")
            .accessibilityIdentifier("sidebar-address-button")

            if let url {
                // Share rather than a bare copy: the sheet's first row is
                // Copy, so nothing is lost, and the pill matches the
                // developer bar's control.
                Button {
                    let tab = displayedActiveTab(for: spaceID)
                    addressPillSharePicker.present(
                        url: url,
                        title: tab?.title,
                        faviconData: tab?.faviconData
                    ) {}
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(InterfaceStyle.sidebarIcon)
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonTreatment(.content)
                .background(SharePickerAnchor(coordinator: addressPillSharePicker))
                .shortcutTooltip("Share", shortcut: .sharePage)
                .accessibilityIdentifier("sidebar-share-url-button")
                // Not 0: fully transparent views stop hit-testing, and the
                // button must keep its click footprint while visually absent.
                .opacity(isHoveringAddressPill ? 1 : 0.02)
                .animation(.easeOut(duration: 0.10), value: isHoveringAddressPill)
                .padding(.trailing, 3)
            }
        }
        .frame(height: 40)
        .background(InterfaceStyle.sidebarControlFill)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(isHoveringAddressPill ? 0.07 : 0))
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { isHoveringAddressPill = $0 }
        // The routed Share command (menu, shortcut, palette). Only the active
        // Space's pill answers, so paged sidebar copies can never co-present,
        // and only while the pill is the address surface at all.
        .onChange(of: store.sharePickerPresentationID) { _, _ in
            guard showsAddressPill, spaceID == store.activeSpaceID, let url else { return }
            let tab = displayedActiveTab(for: spaceID)
            addressPillSharePicker.present(
                url: url,
                title: tab?.title,
                faviconData: tab?.faviconData
            ) {}
        }
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
    }

    /// The pill's leading icon doubles as the Site Info trigger: the glyph
    /// reflects what the URL alone can claim (the popover shows the verified
    /// state), and the popover only binds on the active space so paged
    /// sidebar copies can never co-present it.
    private func siteInfoButton(
        for url: URL,
        spaceID: UUID,
        developerModeEnabled: Bool
    ) -> some View {
        Button {
            store.isSiteInfoPopoverPresented.toggle()
        } label: {
            Image(systemName: siteInfoSymbol(for: url, developerModeEnabled: developerModeEnabled))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(InterfaceStyle.sidebarIcon)
                .padding(.leading, 11)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .help("Site Info")
        .accessibilityLabel("Site Info")
        .accessibilityIdentifier("sidebar-site-info-button")
        .popover(
            isPresented: Binding(
                get: { store.isSiteInfoPopoverPresented && spaceID == store.activeSpaceID },
                set: { store.isSiteInfoPopoverPresented = $0 }
            ),
            arrowEdge: .bottom
        ) {
            SiteInfoPopoverView(
                store: store,
                url: url,
                tabID: displayedActiveTabID(for: spaceID),
                onShowPrivacyReport: {
                    // Popover teardown and sheet presentation must not share
                    // a transaction (two-beat handoff): presenting while the
                    // popover is still dismissing detaches the sheet.
                    store.isSiteInfoPopoverPresented = false
                    CATransaction.setCompletionBlock { [weak store] in
                        store?.isPrivacyReportPresented = true
                    }
                }
            )
        }
    }

    private func siteInfoSymbol(for url: URL, developerModeEnabled: Bool) -> String {
        if developerModeEnabled {
            return "info.circle"
        }
        if url.isFileURL {
            return "doc"
        }
        return url.scheme?.lowercased() == "https" ? "lock" : "lock.slash"
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
        displayedActiveTab(for: spaceID)?.url
    }

    private func displayedActiveTab(for spaceID: UUID) -> BrowserTab? {
        guard let tabID = displayedActiveTabID(for: spaceID) else { return nil }
        return store.tabs.first(where: { $0.id == tabID })
    }

    // Developer pages read the same way as any other: the domain, with the
    // port that tells two local servers apart. Only the monospaced face marks
    // them out, and the full URL lives in the developer toolbar above.
    private func sidebarAddressText(for url: URL?) -> String {
        url?.displayDomainText ?? "Search..."
    }

    // MARK: - Favorites

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = store.favoriteTabs

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
    }

    private func favoriteTile(
        for tab: BrowserTab,
        favorites: [BrowserTab]
    ) -> some View {
        EssentialTileView(
            tab: tab,
            isActive: tab.id == store.activeTabID &&
                !store.isNewTabPaletteActive,
            accentColor: AppColor.accent,
            placement: .favorite,
            onSelect: { store.activateFavorite(tab.id) },
            onClose: { store.closeTab(tab.id) },
            onDuplicate: { store.duplicateTab(tab.id) },
            onOpenInSplit: { store.openSplitView(with: tab.id) },
            onToggleFavorite: { store.toggleFavorite(tab.id) },
            onTogglePin: { store.togglePin(tab.id) }
        )
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
            tint: InterfaceStyle.sidebarDropIndicator
        )
        .background(TabDragSourceBackground(store: store, tabID: tab.id))
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
        // The Space label is not part of this page: it is hoisted above the
        // swipe carousel as a fixed header, the way the favorites grid is.
        VStack(alignment: .leading, spacing: spaceLabelToPinnedGap) {
            pinnedAndFoldersSection(for: spaceID)

            // Zen's rule lives in the pinned section's markup but is gated on
            // the *unpinned* list (`updateShouldHideSeparator`: hidden only
            // when the Space has no regular tabs) — it draws whether or not
            // anything is pinned, and its Clear closes what sits below it.
            if !store.regularTabs(in: spaceID).isEmpty {
                PinnedSeparatorRow(
                    showsClear: spaceID == store.activeSpaceID,
                    onClear: store.clearUnpinnedTabs
                )
                // Zen's row is the spacing: 22px between the last pinned row
                // and New Tab with nothing else added, so the 10pt section
                // gap below it collapses to a hair.
                .padding(.bottom, -8)
            }
        }
    }

    @ViewBuilder
    private func pinnedAndFoldersSection(for spaceID: UUID) -> some View {
        let splitTabIDs = spaceID == store.activeSpaceID ? store.activeSplitGroupTabIDs : []
        let pinned = store.pinnedTabs(in: spaceID).filter { !splitTabIDs.contains($0.id) }
        let folders = store.rootFolders(in: spaceID)

        // Arc folds the pinned area away behind the Space title; the header's
        // chevron is the only trace. A live drag still needs the drop targets.
        let isCollapsed = store.isPinnedAreaCollapsed(in: spaceID) && store.draggedTabID == nil

        if !isCollapsed, !pinned.isEmpty || !folders.isEmpty || store.draggedTabID != nil {
            VStack(alignment: .leading, spacing: pinnedSectionSpacing) {
                if !pinned.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(pinned) { tab in
                            pinnedTabRow(for: tab, pinned: pinned, spaceID: spaceID)
                        }
                    }
                }

                if store.draggedTabID != nil, spaceID == store.activeSpaceID {
                    pinnedAppendDropTarget
                }

                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(folders) { folder in
                            FolderSectionView(
                                store: store,
                                folder: folder,
                                editingFolderID: $store.editingFolderID,
                                accentColor: AppColor.accent,
                                nestingLevel: 0
                            )
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.text],
                delegate: PinnedTabSectionDropDelegate(store: store)
            )
            // Pin, folder, and close settle the section instead of popping; the
            // per-space identity keeps space switches an instant context cut.
            .animation(Self.rowReorder, value: pinned.map(\.id) + folders.map(\.id))
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
                SidebarHorizontalDropLine(tint: InterfaceStyle.sidebarDropIndicator)
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
            accentColor: AppColor.accent,
            mediaState: store.mediaStates[tab.id],
            onSelect: { store.switchTab(to: tab.id) },
            onClose: { store.closeTab(tab.id) },
            onDuplicate: { store.duplicateTab(tab.id) },
            onOpenInSplit: { store.openSplitView(with: tab.id) },
            onToggleFavorite: { store.toggleFavorite(tab.id) },
            onTogglePin: { store.togglePin(tab.id) },
            onToggleMute: { store.toggleMediaMute(tabID: tab.id) },
                            suppressesHover: store.draggedTabID != nil
        )
        // The system drag image is the only visible copy while dragging; the
        // source row leaves a gap that doubles as the insertion indicator.
        .sidebarRowDropIndicator(
            showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: tab.id,
                edge: .before
            ),
            splitSide: store.sidebarSplitDropSide(for: tab.id, placement: .pinned),
            showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                placement: .pinned,
                targetTabID: tab.id,
                edge: .after
            ),
            tint: InterfaceStyle.sidebarDropIndicator
        )
        .background(TabDragSourceBackground(store: store, tabID: tab.id))
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
        if store.isPrivate {
            // Zen/Arc-style static label in place of the space name. It is
            // not a space: no editing, no drops, no context menu.
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16, height: 16)

                Text("Private")
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 36)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Private Browsing")
            .accessibilityIdentifier("private-browsing-label")
        } else if let space = store.spaces.first(where: { $0.id == spaceID }),
           !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Drops on the header are targeted from the drag source by
            // geometry (SpaceHeaderDropZones); the row paints that state.
            SpaceHeaderRow(
                store: store,
                space: space,
                isDropTargeted: store.isSpaceHeaderDropTargeted,
                hasCollapsibleContent: !store.pinnedTabs(in: spaceID).isEmpty
                    || !store.rootFolders(in: spaceID).isEmpty,
                hover: spaceHeaderHover
            )
        }
    }

    /// A row of the regular list: a tab, or the two tabs of a split sharing
    /// one row side by side.
    ///
    /// The pair sits at the position of whichever member comes first, so a
    /// split changes nothing about where the tabs are in the list — the pill
    /// used to be hoisted to the very top, which read as the tabs being
    /// re-sorted the moment you split them.
    private enum SidebarTabListItem: Identifiable {
        case tab(BrowserTab)
        case split([BrowserTab])

        var id: UUID {
            switch self {
            case let .tab(tab): return tab.id
            case let .split(tabs): return tabs.first?.id ?? UUID()
            }
        }
    }

    private func tabListItems(for spaceID: UUID, tabs: [BrowserTab]) -> [SidebarTabListItem] {
        let members = spaceID == store.activeSpaceID ? store.activeSplitGroupTabs : []
        guard members.count >= 2 else { return tabs.map(SidebarTabListItem.tab) }

        let memberIDs = Set(members.map(\.id))
        var items: [SidebarTabListItem] = []
        var placedPair = false
        for tab in tabs where !memberIDs.contains(tab.id) || !placedPair {
            if memberIDs.contains(tab.id) {
                items.append(.split(members))
                placedPair = true
            } else {
                items.append(.tab(tab))
            }
        }
        return items
    }

    @ViewBuilder
    private func tabsSection(for spaceID: UUID) -> some View {
        let tabs = store.regularTabs(in: spaceID)
        let items = tabListItems(for: spaceID, tabs: tabs)

        VStack(alignment: .leading, spacing: 0) {
            // Private windows open empty by design; announcing "No tabs"
            // under the New Tab row is just noise there.
            if tabs.isEmpty && !store.isPrivate {
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
                    SidebarHorizontalDropLine(tint: InterfaceStyle.sidebarDropIndicator)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        switch item {
                        case let .split(members):
                            SidebarSplitGroupView(
                                store: store,
                                tabs: members,
                                accentColor: AppColor.accent
                            )
                            // The pair's row was drawn and nothing else: no
                            // indicator, no delegate. It read as a hole in
                            // the list — a drag over it showed no line and a
                            // release did nothing. It anchors on whichever
                            // member comes first, which is where the row is.
                            .sidebarRowDropIndicator(
                                showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                    placement: .regular,
                                    targetTabID: members[0].id,
                                    edge: .before
                                ),
                                showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                    placement: .regular,
                                    targetTabID: members[0].id,
                                    edge: .after
                                ),
                                tint: InterfaceStyle.sidebarDropIndicator
                            )
                            .onDrop(
                                of: [UTType.text],
                                delegate: TabReorderDropDelegate(
                                    targetTab: members[0],
                                    tabs: tabs,
                                    isFavorite: false,
                                    pinned: false,
                                    folderID: nil,
                                    store: store,
                                    allowsSplit: false
                                )
                            )
                        case let .tab(tab):
                        TabRowView(
                            tab: tab,
                            isActive: tab.id == displayedActiveTabID(for: spaceID) && !store.isNewTabPaletteActive,
                            accentColor: AppColor.accent,
                            mediaState: store.mediaStates[tab.id],
                            onSelect: { store.switchTab(to: tab.id) },
                            onClose: { store.closeTab(tab.id) },
                            onDuplicate: { store.duplicateTab(tab.id) },
                            onOpenInSplit: { store.openSplitView(with: tab.id) },
                            onRemoveFromSplit: { store.removeTabFromSplit(tab.id) },
                            onToggleFavorite: { store.toggleFavorite(tab.id) },
                            onTogglePin: { store.togglePin(tab.id) },
                            onToggleMute: { store.toggleMediaMute(tabID: tab.id) },
                            suppressesHover: store.draggedTabID != nil
                        )
                        // Rows hold still through a drag — Arc moves nothing
                        // until the drop — so the line in the gap is what
                        // says where the tab lands. Split keeps its ring, and
                        // the two never show together.
                        .sidebarRowDropIndicator(
                            showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                placement: .regular,
                                targetTabID: tab.id,
                                edge: .before
                            ),
                            splitSide: store.sidebarSplitDropSide(for: tab.id, placement: .regular),
                            showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                                placement: .regular,
                                targetTabID: tab.id,
                                edge: .after
                            ),
                            tint: InterfaceStyle.sidebarDropIndicator
                        )
                        .background(TabDragSourceBackground(store: store, tabID: tab.id))
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
                    }

                    if store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                        placement: .regular,
                        targetTabID: nil,
                        edge: .after
                    ) {
                        SidebarHorizontalDropLine(tint: InterfaceStyle.sidebarDropIndicator)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                // Rows settle rather than pop — closing, opening, reordering,
                // and the live gap that travels with a drag; the spring is
                // Arc's make-room feel. The per-space identity keeps space
                // switches an instant cut.
                .animation(Self.rowReorder, value: tabs.map(\.id))
                .id(spaceID)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.text],
            delegate: RegularTabSectionDropDelegate(store: store)
        )
    }

    /// Arc reorders live: while a tab is dragged, the rows around it move
    /// out of the way and the gap travels with the pointer, so what you see
    /// mid-drag is exactly what you get on release. This is the order a
    /// vertical list draws in during a drag — the dragged tab pulled out of
    /// wherever it lives and reinserted at the current indicator, or gone
    /// from this list entirely while the pointer is over another one. The
    /// model does not change until the drop, so an abandoned drag springs
    /// back to the original order.
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
            store.openNewTab()
        } label: {
            // contentShape must live inside the label: applied outside the
            // Button it doesn't extend the clickable area, leaving only the
            // glyphs hit-testable. The layout mirrors TabRowView so the
            // button reads as one of the tab rows.
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isArmed ? InterfaceStyle.sidebarText : InterfaceStyle.sidebarIcon)
                    .frame(width: 16, height: 16)

                Text(BrowserCommandTitles.newTab)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: isArmed ? .medium : .regular))
                    .foregroundStyle(isArmed ? InterfaceStyle.sidebarText : InterfaceStyle.sidebarTextSecondary)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .background(newTabButtonBackground(isArmed: isArmed))
        .clipShape(RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous))
        .onHover { isHoveringNewTab = $0 }
        .accessibilityIdentifier("sidebar-new-tab-button")
        .initialTourPopover(.commandBar, store: store, arrowEdge: .leading)
        .overlay {
            if isHoveringNewTab && !isArmed && store.draggedTabID == nil {
                RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous)
                    .stroke(InterfaceStyle.sidebarControlStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.10), value: isHoveringNewTab)
        .animation(.easeOut(duration: 0.12), value: isArmed)
    }

    private func newTabButtonBackground(isArmed: Bool) -> Color {
        if isArmed {
            return InterfaceStyle.sidebarControlFillActive
        }
        if isHoveringNewTab && store.draggedTabID == nil {
            return InterfaceStyle.sidebarControlFillHover
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
