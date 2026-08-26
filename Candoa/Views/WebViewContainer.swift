import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserInterfaceInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

struct WebViewContainer: View {
    @ObservedObject var store: BrowserStore
    let visibleInterfaceInsets: BrowserInterfaceInsets
    let attachesToTrailingPanel: Bool
    /// The strip above the page takes over the sidebar's toggle while the
    /// sidebar is away, so it needs the same action the sidebar header uses.
    let onToggleSidebar: () -> Void
    /// Extra trailing clip while Eli covers the page beyond the reserved web
    /// layout (widening resize drags, and the close paint-fence hold).
    /// Mask-only: it never reaches the WKWebView's obscured content insets
    /// or frame.
    let slideOverTrailingInset: CGFloat
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""
    @AppStorage(SettingsOption.addressBarPlacement)
    private var addressBarPlacement = AddressBarPlacement.default.rawValue
    /// In-flight divider drag. Panes keep their committed widths while it
    /// exists — only the preview line follows the pointer — so the live
    /// WKWebViews never relayout mid-drag; the single web layout happens at
    /// release, when the new ratios commit.
    @State private var splitDividerDrag: SplitDividerDragState?
    /// In-flight pane-handle drag (reordering). Same rule: only the target
    /// highlight tracks the pointer, the panes exchange places on release.
    @State private var splitPaneReorder: SplitPaneReorderState?
    /// The pane the pointer is over, reported by the pane host's tracking
    /// area (web views swallow SwiftUI hover). Reveals that pane's control
    /// pill.
    @State private var hoveredSplitPaneIndex: Int?
    private let surfaceCornerRadius: CGFloat = 12
    private let surfacePadding: CGFloat = 8
    private static let splitPaneMinimumWidth: CGFloat = 160

    var body: some View {
        ZStack {
            if store.isInitialSpaceSetupPresented || store.isCreateSpacePresented {
                browserSurface(drawsBorder: false) {
                    SpaceSetupCanvas(
                        hexes: store.activeThemeColorHexes,
                        intensity: store.activeThemeIntensityMultiplier,
                        texture: store.activeThemeTexture
                    )
                }
                .padding(containedSurfaceInsets)
                .transition(.opacity)
            } else if let tab = store.activeTab {
                let splitTabs = store.displayedSplitTabs
                if splitTabs.count >= 2 {
                    splitPaneRow(for: splitTabs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(containedSurfaceInsets)
                } else {
                    browserSurface(drawsBorder: false) {
                        singleTabContent(for: tab)
                    }
                    .padding(containedSurfaceInsets)
                }
            } else {
                browserSurface(drawsBorder: false) {
                    ZStack {
                        SpaceSetupCanvas(
                            hexes: store.activeThemeColorHexes,
                            intensity: store.activeThemeIntensityMultiplier,
                            texture: store.activeThemeTexture
                        )

                        if store.isPrivate {
                            PrivateBrowsingExplainer()
                        }
                    }
                }
                .padding(containedSurfaceInsets)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            splitDropSurfaceOverlay
        }
        .overlay(alignment: .topTrailing) {
            if store.isFindBarPresented {
                FindBarView(store: store)
                    .padding(.top, surfacePadding + 10)
                    .padding(.trailing, visibleInterfaceInsets.trailing + surfacePadding + 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: store.isFindBarPresented)
        .modifier(
            BrowserInterfaceMaskModifier(
                insets: visibleInterfaceInsets,
                slideOverTrailingInset: slideOverTrailingInset,
                surfaceCornerRadius: surfaceCornerRadius,
                surfacePadding: surfacePadding,
                trailingSurfacePadding: attachesToTrailingPanel ? 0 : surfacePadding,
                drawsFullSurfaceBorder: store.displayedSplitTabs.count < 2
            )
        )
    }

    @ViewBuilder
    private var splitDropSurfaceOverlay: some View {
        if store.draggedTabID != nil, store.activeTab != nil, !store.isSpaceSetupPresented {
            GeometryReader { proxy in
                let laneInsets = BrowserInterfaceInsets(
                    leading: visibleInterfaceInsets.leading,
                    trailing: visibleInterfaceInsets.trailing + slideOverTrailingInset
                )
                let pageSize = CGSize(
                    width: max(proxy.size.width - laneInsets.leading - laneInsets.trailing, 1),
                    height: proxy.size.height
                )

                ZStack {
                    // The drop surface covers the visible page only. It used to
                    // span the container, lanes included, and guard the lanes
                    // in its zone math — but AppKit hands the drag to whichever
                    // registered view is topmost under the pointer, and this
                    // one, created at drag start, sits above the sidebar's own
                    // targets: a pointer over the Space header (or anything in
                    // the lane the tab list's own view does not cover) landed
                    // here and went nowhere. Padded out of the lanes, the
                    // sidebar's targets see those points again, and the zone
                    // math runs on the page-sized surface directly.
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [UTType.text],
                            delegate: BrowserSurfaceSplitDropDelegate(
                                store: store,
                                size: pageSize,
                                laneInsets: BrowserInterfaceInsets(leading: 0, trailing: 0)
                            )
                        )
                        .padding(.leading, laneInsets.leading)
                        .padding(.trailing, laneInsets.trailing)

                    if let preview = store.splitDropPreview {
                        SplitDropPreviewOverlay(
                            preview: preview,
                            cornerRadius: surfaceCornerRadius,
                            laneInsets: laneInsets
                        )
                        .padding(containedSurfaceInsets)
                        .transition(.opacity)
                    }

                }
                .animation(.easeOut(duration: 0.12), value: store.splitDropPreview)
            }
        }
    }

    private func browserSurface<Content: View>(
        drawsBorder: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: surfaceCornerRadius,
            bottomLeadingRadius: surfaceCornerRadius,
            bottomTrailingRadius: surfaceCornerRadius,
            topTrailingRadius: surfaceCornerRadius,
            style: .continuous
        )

        return content()
            .clipShape(shape)
            .overlay {
                if drawsBorder {
                    shape
                        .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                }
            }
            .background(
                shape
                    .fill(InterfaceStyle.surfaceFill.opacity(0.74))
            )
            .compositingGroup()
            // Kept tight: the surrounding gutter is only 8pt, so a wide
            // falloff visibly darkens the whole gap and breaks the flat
            // chrome surface around the card.
            .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 1)
    }

    private var containedSurfaceInsets: EdgeInsets {
        EdgeInsets(
            top: surfacePadding,
            leading: surfacePadding,
            bottom: surfacePadding,
            // Eli owns the adjacent trailing lane after its transition. It
            // must not add a second inset inside the page surface.
            trailing: attachesToTrailingPanel ? 0 : surfacePadding
        )
    }

    /// The reserved interface lanes in the surface row's own coordinates,
    /// which is what WebKit's obscured insets and the row's own bars measure
    /// against.
    ///
    /// Two surfacePaddings cancel here: the row already starts one padding in
    /// from the window edge, and the visible surface starts one padding
    /// beyond the lane, so inside the row a lane is exactly as wide as it is
    /// in the window. Reserving one padding *less* — the old arithmetic —
    /// anchored every page's fixed bottom-left content under the mask, where
    /// the surface's rounded corner clipped it.
    private var webContentInsets: BrowserInterfaceInsets {
        visibleInterfaceInsets
    }

    /// Which window-edge insets a pane needs depends on where the layout
    /// puts it: only panes touching the leading/trailing window edge reserve
    /// the corresponding interface lane.
    private func splitPaneInsets(
        forPaneAt index: Int,
        paneCount: Int,
        layout: SplitViewLayout
    ) -> BrowserInterfaceInsets {
        switch layout {
        case .horizontal:
            return BrowserInterfaceInsets(
                leading: index == 0 ? webContentInsets.leading : 0,
                trailing: index == paneCount - 1 ? webContentInsets.trailing : 0
            )
        case .vertical:
            // Stacked rows all span the full width, touching both edges.
            return webContentInsets
        }
    }

    /// The masked interface lanes at the split row's own edges, in row
    /// coordinates. splitPaneFrames divides the visible page between these so
    /// the cards the mask reveals follow the pane ratios.
    private var splitRowLaneInsets: BrowserInterfaceInsets {
        webContentInsets
    }

    private var usesTopToolbarPlacement: Bool {
        addressBarPlacement == AddressBarPlacement.top.rawValue
    }

    /// The sidebar reserves its lane here rather than resizing this view, so
    /// a leading lane is exactly the state of the sidebar being pinned open.
    private var isSidebarVisible: Bool {
        visibleInterfaceInsets.leading > 0
    }

    private var topToolbarLeadingControls: TopToolbarLeadingControls {
        TopToolbarLeadingControls(
            store: store,
            isSidebarVisible: isSidebarVisible,
            onToggleSidebar: onToggleSidebar
        )
    }

    @ViewBuilder
    private func singleTabContent(for tab: BrowserTab) -> some View {
        VStack(spacing: 0) {
            if tab.isWelcomePage {
                WelcomeToCandoaPage(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, visibleInterfaceInsets.leading)
                    .padding(.trailing, visibleInterfaceInsets.trailing)
            } else if let url = tab.url,
               DeveloperModeConfiguration.isEnabled(
                   for: url,
                   storedOverrides: developerModeOverrides
               ) {
                DeveloperToolbar(
                    url: url,
                    urlText: url.localDevelopmentDisplayText,
                    pageTitle: tab.title,
                    faviconData: tab.faviconData,
                    contentInsets: webContentInsets,
                    leadingControls: usesTopToolbarPlacement ? topToolbarLeadingControls : nil,
                    sharePresentationID: store.sharePickerPresentationID,
                    onSubmitURL: { store.navigateActiveTab(to: $0) },
                    onToggleChat: { store.requestAISidebarToggle() }
                )
                // The web host's opaque surface background paints over
                // earlier siblings' rows; keep the toolbar above it or the
                // bar renders dimmed behind that fill.
                .zIndex(1)
            } else if usesTopToolbarPlacement {
                TopAddressBar(
                    store: store,
                    url: tab.url,
                    contentInsets: webContentInsets,
                    isSidebarVisible: isSidebarVisible,
                    onToggleSidebar: onToggleSidebar
                )
                .zIndex(1)
            }

            if tab.isWelcomePage {
                EmptyView()
            } else if tab.url == nil {
                // Deliberately not openNewTab(): clicking the empty page is
                // that page's own affordance for summoning the command bar,
                // whatever "New tabs open with" says — an Empty Page user
                // would otherwise have no way in from here.
                EmptyTabSurface {
                    store.openNewTabCommandPalette()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(InterfaceStyle.surfaceFill.opacity(0.72))
            } else {
                ActiveWebViewHost(
                    tab: tab,
                    store: store,
                    laneInsets: webContentInsets
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(InterfaceStyle.surfaceFill.opacity(0.72))
                    .overlay {
                        // Covers the pane, never replaces it: the web view
                        // stays mounted so retrying repaints underneath and
                        // didCommit drops this cover.
                        if let failure = store.tabLoadFailures[tab.id] {
                            TabRecoveryView(failure: failure) {
                                store.retryLoadFailure(tabID: tab.id)
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        PageLoadingPill(
                            isLoading: tab.isLoading
                        )
                        .padding(.top, 2)
                        .id(tab.id)
                    }
            }
        }
    }

    private struct FindBarView: View {
        @ObservedObject var store: BrowserStore
        @FocusState private var isFieldFocused: Bool

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                // The tally rides the field's trailing edge, as it does in
                // Safari, rather than taking a slot of its own: the bar keeps
                // one width in every state, and a query with no tally leaves
                // no hole behind — it just reads as the field's own padding.
                // Digits only, because this bar floats over the page and has
                // to stay narrow; the spoken label carries the full sentence.
                ZStack(alignment: .trailing) {
                    TextField("Find in page", text: $store.findQuery)
                        .textFieldStyle(.plain)
                        .tint(AppColor.accent)
                        .padding(.trailing, 54)
                        .focused($isFieldFocused)
                        .accessibilityIdentifier("find-bar-field")
                        .onSubmit { store.findNext() }

                    Text(matchTally ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityLabel(matchStatus ?? "")
                        .accessibilityIdentifier("find-bar-status")
                }
                .frame(width: 200)

                Button {
                    store.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonTreatment(.content)
                .disabled(store.findQuery.isEmpty)
                .help("Find Previous")

                Button {
                    store.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonTreatment(.content)
                .disabled(store.findQuery.isEmpty)
                .help("Find Next")

                Button {
                    store.dismissFindBar()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonTreatment(.content)
                .help("Done")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(InterfaceStyle.popoverBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(InterfaceStyle.popoverBorder, lineWidth: 1)
            }
            .onAppear { focusField(selectingQuery: !store.findQuery.isEmpty) }
            .onChange(of: store.findFocusRequestID) { _, _ in
                // A repeat Command-F with the bar already up: reclaim focus
                // from the page and select what is there, so typing replaces
                // the previous query.
                focusField(selectingQuery: !store.findQuery.isEmpty)
            }
            .onExitCommand { store.dismissFindBar() }
            .onChange(of: store.findQuery) { _, _ in
                store.findNext()
            }
        }

        /// The compact form the bar shows: "9/235", or "0" for a query that
        /// matches nothing. Absent while the query is empty, and on pages the
        /// in-page find engine cannot count.
        private var matchTally: String? {
            guard !store.findQuery.isEmpty, let tally = store.findTally else { return nil }
            guard tally.count > 0 else { return "0" }
            return "\(tally.index)/\(tally.count)"
        }

        /// What VoiceOver reads for that tally — Safari's full wording, which
        /// there is no room to print.
        private var matchStatus: String? {
            guard !store.findQuery.isEmpty, let tally = store.findTally else { return nil }
            guard tally.count > 0 else { return String(localized: "Not found") }
            return String(
                localized: "\(tally.index) of \(tally.count) matches",
                comment: "Find in Page: position of the current match among all matches."
            )
        }

        /// Focus has to be claimed a runloop later than the state change that
        /// mounts the bar: at `onAppear` the field is not in the window yet, so
        /// a synchronous `isFieldFocused = true` is dropped and the page keeps
        /// first responder — the same deferral the command palette uses.
        private func focusField(selectingQuery: Bool) {
            DispatchQueue.main.async {
                isFieldFocused = true

                guard selectingQuery else { return }

                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    // MARK: - Split panes

    static let splitRowCoordinateSpace = "candoa-split-row"

    private func splitPaneRow(for splitTabs: [BrowserTab]) -> some View {
        GeometryReader { proxy in
            let spacing = surfacePadding
            let layout = store.splitLayout
            // A zoomed pane takes the row alone. Its partners are not rendered
            // at a token size — they leave the hierarchy entirely, which is
            // the state every background tab is already in (the coordinator
            // owns the web views, not these hosts), so nothing reloads and no
            // hidden page reflows to a sliver and back. Unzooming re-hosts
            // them exactly the way switching tabs does.
            let zoomedIndex = store.zoomedSplitTabID.flatMap { zoomedID in
                splitTabs.firstIndex { $0.id == zoomedID }
            }
            let visibleTabs = zoomedIndex.map { [splitTabs[$0]] } ?? splitTabs
            let ratios = store.splitPaneRatios(forPaneCount: splitTabs.count)
            let frames = zoomedIndex == nil
                ? Self.splitPaneFrames(
                    layout: layout,
                    ratios: ratios,
                    in: proxy.size,
                    spacing: spacing,
                    laneInsets: splitRowLaneInsets
                )
                : [CGRect(origin: .zero, size: proxy.size)]

            ZStack(alignment: .topLeading) {
                ForEach(Array(visibleTabs.enumerated()), id: \.element.id) { slot, splitTab in
                    let frame = frames.indices.contains(slot) ? frames[slot] : .zero
                    // The pane's own index in the group, which the zoomed row
                    // keeps even though it renders in slot 0: hover tracking,
                    // the pill's identity and the pane's accessibility
                    // identifier all address panes by it, and none of them
                    // should shift under the person when a pane zooms.
                    let paneIndex = zoomedIndex ?? slot
                    // A pane's frame runs under the reserved interface lanes
                    // (sidebar/Eli); only the mask reveals the visible card.
                    // Every pane adornment must wrap the visible card, not
                    // the raw frame, or its edge hides under the lane. A
                    // zoomed pane spans the row, so it reserves both lanes.
                    let paneInsets = splitPaneInsets(
                        forPaneAt: slot,
                        paneCount: visibleTabs.count,
                        layout: layout
                    )

                    browserSurface {
                        webPane(for: splitTab, at: paneIndex, laneInsets: paneInsets)
                    }
                    // No accent ring on the focused pane: the panes wear the
                    // standard surface border only, and focus is read from the
                    // sidebar's active row. Don't reintroduce it.
                    .overlay(alignment: .top) {
                        SplitPaneControlPill(
                            isPaneHovered: hoveredSplitPaneIndex == paneIndex,
                            isDraggingThisPane: splitPaneReorder?.sourceIndex == paneIndex,
                            isZoomed: zoomedIndex != nil,
                            paneIndex: paneIndex,
                            onDragChanged: { location in
                                splitPaneReorder = SplitPaneReorderState(sourceIndex: paneIndex, location: location)
                            },
                            onDragEnded: { location in
                                splitPaneReorder = nil
                                guard let targetIndex = Self.splitPaneIndex(at: location, in: frames, spacing: spacing) else {
                                    return
                                }
                                // A pane's edge bands re-stack the layout,
                                // Zen-style; the middle keeps the slot swap.
                                if let side = Self.splitPaneDropEdge(at: location, inPaneFrame: frames[targetIndex]) {
                                    store.moveSplitPane(from: paneIndex, toEdge: side, of: targetIndex)
                                } else {
                                    store.moveSplitPane(from: paneIndex, to: targetIndex)
                                }
                            },
                            onUnsplit: { store.removeTabFromSplit(splitTab.id, focusRemovedTab: true) },
                            onToggleZoom: {
                                if zoomedIndex == nil {
                                    store.zoomSplitPane(splitTab.id)
                                } else {
                                    store.toggleSplitPaneZoom()
                                }
                            }
                        )
                        // Below the row dividers' 7pt overhang so the pill
                        // and a divider strip never contend for the pointer.
                        .padding(.top, 8)
                        // Centered on the visible card, not the raw frame.
                        .padding(.leading, paneInsets.leading)
                        .padding(.trailing, paneInsets.trailing)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }

                // Nothing to resize while one pane holds the row.
                if zoomedIndex == nil {
                    splitDividers(layout: layout, frames: frames, spacing: spacing, in: proxy.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The reorder adornments must be an overlay, not ZStack siblings:
            // SwiftUI draws plain siblings beneath the AppKit-hosted web
            // views, while overlay content provably layers above them (the
            // pane pill and focus ring rely on the same hosting). Mounted
            // only during a drag so the idle row keeps its hover cursors
            // (divider resize arrows, grip hand) unobstructed.
            // `frames` describes one pane while zoomed, so a drag that somehow
            // outlives a zoom (the keyboard toggle fires mid-drag) must not
            // read it against the full group.
            .overlay {
                if splitPaneReorder != nil, zoomedIndex == nil {
                    splitReorderOverlay(splitTabs: splitTabs, frames: frames, layout: layout, spacing: spacing)
                }
            }
            .coordinateSpace(name: Self.splitRowCoordinateSpace)
        }
    }

    /// Drag feedback for the pane grip: an accent ring on the pane the grab
    /// would move to, and a cursor-following ghost of the grabbed page in
    /// the source pane's aspect ratio. The ghost tracks the pointer directly
    /// (no animation) and the real panes never move until the drop commits.
    @ViewBuilder
    private func splitReorderOverlay(
        splitTabs: [BrowserTab],
        frames: [CGRect],
        layout: SplitViewLayout,
        spacing: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if let reorder = splitPaneReorder,
               let targetIndex = Self.splitPaneIndex(at: reorder.location, in: frames, spacing: spacing),
               frames.indices.contains(targetIndex) {
                let edge = Self.splitPaneDropEdge(at: reorder.location, inPaneFrame: frames[targetIndex])
                // Middle-of-own-pane means no drop; an edge band always has
                // meaning (even on the source pane it re-stacks the layout).
                if targetIndex != reorder.sourceIndex || edge != nil {
                    // Zen-style claim highlight: an edge drop re-stacks the
                    // whole group into a row or column, so it claims a full
                    // half of the surface — never a slice of one pane. Only
                    // the middle slot-swap highlights the target pane itself.
                    // One primary-accent region, no per-pane mosaic.
                    let highlightFrame = edge != nil
                        ? Self.splitPaneEdgeHighlightFrame(
                            for: edge,
                            in: visibleRowFrame(frames: frames, paneCount: splitTabs.count, layout: layout)
                        )
                        : paneVisibleFrame(at: targetIndex, frames: frames, paneCount: splitTabs.count, layout: layout)
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .fill(AppColor.accent.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                                .strokeBorder(AppColor.accent.opacity(0.85), lineWidth: 2)
                        }
                        .frame(width: highlightFrame.width, height: highlightFrame.height)
                        .offset(x: highlightFrame.minX, y: highlightFrame.minY)
                }
            }

            if let reorder = splitPaneReorder,
               splitTabs.indices.contains(reorder.sourceIndex),
               frames.indices.contains(reorder.sourceIndex) {
                let sourceFrame = frames[reorder.sourceIndex]
                let scale = min(
                    1,
                    200 / max(sourceFrame.width, 1),
                    150 / max(sourceFrame.height, 1)
                )
                let ghostWidth = max(120, sourceFrame.width * scale)
                let ghostHeight = max(84, sourceFrame.height * scale)
                TabDragGhost(
                    tab: splitTabs[reorder.sourceIndex],
                    width: ghostWidth,
                    height: ghostHeight
                )
                .opacity(0.9)
                .offset(
                    x: reorder.location.x - ghostWidth / 2,
                    y: reorder.location.y + 14
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Pane rectangles for the current layout, distributing the panes'
    /// shared ratios along the layout's axis.
    ///
    /// laneInsets are the masked interface lanes (sidebar/Eli) at the row's
    /// leading/trailing edges, in row coordinates. Ratios divide the
    /// *visible* page between the lanes — edge panes then extend under their
    /// lane so the cards the mask reveals match the ratios. Without this,
    /// an open sidebar eats into the first pane's visible card and a 50/50
    /// split looks lopsided (and never matches the drop claim highlight).
    static func splitPaneFrames(
        layout: SplitViewLayout,
        ratios: [Double],
        in size: CGSize,
        spacing: CGFloat,
        laneInsets: BrowserInterfaceInsets = BrowserInterfaceInsets()
    ) -> [CGRect] {
        let paneCount = ratios.count
        guard paneCount > 0 else { return [] }

        switch layout {
        case .horizontal:
            let available = max(
                1,
                size.width - laneInsets.leading - laneInsets.trailing - spacing * CGFloat(paneCount - 1)
            )
            var x: CGFloat = 0
            return ratios.enumerated().map { index, ratio in
                var width = available * CGFloat(ratio)
                if index == 0 { width += laneInsets.leading }
                if index == paneCount - 1 { width += laneInsets.trailing }
                defer { x += width + spacing }
                return CGRect(x: x, y: 0, width: width, height: size.height)
            }
        case .vertical:
            // Stacked rows all span the full width under both lanes, so the
            // lanes trim every row equally and the height ratios are unaffected.
            let available = max(1, size.height - spacing * CGFloat(paneCount - 1))
            var y: CGFloat = 0
            return ratios.map { ratio in
                let height = available * CGFloat(ratio)
                defer { y += height + spacing }
                return CGRect(x: 0, y: y, width: size.width, height: height)
            }
        }
    }

    static func splitPaneIndex(at location: CGPoint, in frames: [CGRect], spacing: CGFloat) -> Int? {
        frames.firstIndex { frame in
            frame.insetBy(dx: -spacing / 2, dy: -spacing / 2).contains(location)
        }
    }

    /// Zen-style edge targeting within a pane for a grip drag: the outer
    /// quarters map to the nearest edge (top/bottom stack the panes into a
    /// column, leading/trailing lay them into a row) and the middle is the
    /// plain slot swap.
    static func splitPaneDropEdge(at location: CGPoint, inPaneFrame frame: CGRect) -> SplitTabDropSide? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let fractionX = (location.x - frame.minX) / frame.width
        let fractionY = (location.y - frame.minY) / frame.height
        let insideMiddleX = fractionX > 0.25 && fractionX < 0.75
        let insideMiddleY = fractionY > 0.25 && fractionY < 0.75
        guard !(insideMiddleX && insideMiddleY) else { return nil }

        let edgeDistances: [(side: SplitTabDropSide, distance: CGFloat)] = [
            (.leading, fractionX),
            (.trailing, 1 - fractionX),
            (.top, fractionY),
            (.bottom, 1 - fractionY)
        ]
        return edgeDistances.min { $0.distance < $1.distance }?.side
    }

    /// The half of the target pane an edge drop would claim; the whole pane
    /// for a middle (slot swap) drop.
    /// A pane's frame trimmed to its visible card (lane-touching sides are
    /// masked away — see splitPaneAdornmentInsets).
    private func paneVisibleFrame(
        at index: Int,
        frames: [CGRect],
        paneCount: Int,
        layout: SplitViewLayout
    ) -> CGRect {
        let insets = splitPaneInsets(forPaneAt: index, paneCount: paneCount, layout: layout)
        let frame = frames.indices.contains(index) ? frames[index] : .zero
        return CGRect(
            x: frame.minX + insets.leading,
            y: frame.minY,
            width: frame.width - insets.leading - insets.trailing,
            height: frame.height
        )
    }

    /// The visible bounds of the whole pane row — the area an edge drop's
    /// re-stack redistributes, so it is what a claim highlight halves.
    private func visibleRowFrame(
        frames: [CGRect],
        paneCount: Int,
        layout: SplitViewLayout
    ) -> CGRect {
        let maxX = frames.map(\.maxX).max() ?? 0
        let maxY = frames.map(\.maxY).max() ?? 0
        let leading = splitPaneInsets(forPaneAt: 0, paneCount: paneCount, layout: layout).leading
        let trailing = splitPaneInsets(
            forPaneAt: max(paneCount - 1, 0),
            paneCount: paneCount,
            layout: layout
        ).trailing
        return CGRect(x: leading, y: 0, width: maxX - leading - trailing, height: maxY)
    }

    static func splitPaneEdgeHighlightFrame(for side: SplitTabDropSide?, in frame: CGRect) -> CGRect {
        switch side {
        case .leading:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .trailing:
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case nil:
            frame
        }
    }

    /// Divider handles between adjacent panes.
    @ViewBuilder
    private func splitDividers(
        layout: SplitViewLayout,
        frames: [CGRect],
        spacing: CGFloat,
        in size: CGSize
    ) -> some View {
        // Visible lengths, not frame lengths: the edge frames extend
        // under the interface lanes, and the ratios the drag commits
        // divide the visible page (see splitPaneFrames), so clamping and
        // normalizing must strip the lanes back off or an open sidebar
        // skews every committed ratio toward the edge panes.
        let rowLaneInsets = splitRowLaneInsets
        let lengths = frames.enumerated().map { index, frame in
            layout == .vertical
                ? frame.height
                : frame.width
                    - (index == 0 ? rowLaneInsets.leading : 0)
                    - (index == frames.count - 1 ? rowLaneInsets.trailing : 0)
        }
        let minimumPaneLength = min(
            Self.splitPaneMinimumWidth,
            lengths.reduce(0, +) / CGFloat(max(1, lengths.count))
        )

        ForEach(0..<max(0, frames.count - 1), id: \.self) { index in
            let dividerCenter = (layout == .vertical ? frames[index].maxY : frames[index].maxX) + spacing / 2
            let clampedTranslation = clampedDividerTranslation(
                splitDividerDrag?.dividerIndex == index ? splitDividerDrag?.translation ?? 0 : 0,
                at: index,
                lengths: lengths,
                minimumPaneLength: minimumPaneLength
            )

            SplitPaneDivider(
                axis: layout == .vertical ? .vertical : .horizontal,
                isDragging: splitDividerDrag?.dividerIndex == index,
                onDragChanged: { translation in
                    splitDividerDrag = SplitDividerDragState(dividerIndex: index, translation: translation)
                },
                onDragEnded: { translation in
                    splitDividerDrag = nil
                    commitDividerDrag(
                        translation,
                        at: index,
                        lengths: lengths,
                        minimumPaneLength: minimumPaneLength
                    )
                },
                onReset: {
                    splitDividerDrag = nil
                    store.resetSplitPaneRatios()
                }
            )
            .frame(
                width: layout == .vertical ? size.width : 14,
                height: layout == .vertical ? 14 : size.height
            )
            .offset(
                x: layout == .vertical ? 0 : dividerCenter - 7 + clampedTranslation,
                y: layout == .vertical ? dividerCenter - 7 + clampedTranslation : 0
            )
            .accessibilityElement()
            .accessibilityLabel("Resize Split Panes")
            .accessibilityIdentifier("split-divider-\(index)")
        }
    }

    private func clampedDividerTranslation(
        _ translation: CGFloat,
        at index: Int,
        lengths: [CGFloat],
        minimumPaneLength: CGFloat
    ) -> CGFloat {
        guard lengths.indices.contains(index), lengths.indices.contains(index + 1) else { return 0 }
        let lowerBound = minimumPaneLength - lengths[index]
        let upperBound = lengths[index + 1] - minimumPaneLength
        guard lowerBound <= upperBound else { return 0 }
        return min(max(translation, lowerBound), upperBound)
    }

    private func commitDividerDrag(
        _ translation: CGFloat,
        at index: Int,
        lengths: [CGFloat],
        minimumPaneLength: CGFloat
    ) {
        let clamped = clampedDividerTranslation(
            translation,
            at: index,
            lengths: lengths,
            minimumPaneLength: minimumPaneLength
        )
        guard clamped != 0 else { return }

        var resizedLengths = lengths
        resizedLengths[index] += clamped
        resizedLengths[index + 1] -= clamped
        store.commitSplitPaneRatios(resizedLengths.map(Double.init))
    }

    private func webPane(for tab: BrowserTab, at paneIndex: Int, in splitTabs: [BrowserTab]) -> some View {
        webPane(
            for: tab,
            at: paneIndex,
            laneInsets: splitPaneInsets(
                forPaneAt: paneIndex,
                paneCount: splitTabs.count,
                layout: store.splitLayout
            )
        )
    }

    private func webPane(
        for tab: BrowserTab,
        at paneIndex: Int,
        laneInsets: BrowserInterfaceInsets
    ) -> some View {
        SplitWebViewHost(
            tab: tab,
            paneIndex: paneIndex,
            store: store,
            laneInsets: laneInsets,
            onPaneHoverChange: { isInside in
                if isInside {
                    hoveredSplitPaneIndex = paneIndex
                } else if hoveredSplitPaneIndex == paneIndex {
                    hoveredSplitPaneIndex = nil
                }
            }
        )
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(InterfaceStyle.surfaceFill.opacity(0.72))
            .overlay {
                if let failure = store.tabLoadFailures[tab.id] {
                    TabRecoveryView(failure: failure) {
                        store.retryLoadFailure(tabID: tab.id)
                    }
                }
            }
            .overlay(alignment: .top) {
                PageLoadingPill(
                    isLoading: tab.isLoading
                )
                .padding(.top, 2)
                .id(tab.id)
            }
    }

}

private struct EmptyTabSurface: View {
    let openCommandBar: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: openCommandBar)
        .help(BrowserDefaults.addressPlaceholder)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(BrowserDefaults.addressPlaceholder)
        .accessibilityIdentifier("empty-tab-surface")
    }
}
