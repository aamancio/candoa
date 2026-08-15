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
    /// Whether the sidebar is unpinned. The address lives in the sidebar, so
    /// the web surface grows its own strip to keep the URL visible and
    /// editable while the sidebar is away.
    let isSidebarHidden: Bool
    /// Extra trailing clip while Eli covers the page beyond the reserved web
    /// layout (widening resize drags, and the close paint-fence hold).
    /// Mask-only: it never reaches the WKWebView's obscured content insets
    /// or frame.
    let slideOverTrailingInset: CGFloat
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""
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
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [UTType.text],
                            delegate: BrowserSurfaceSplitDropDelegate(
                                store: store,
                                size: proxy.size,
                                laneInsets: BrowserInterfaceInsets(
                                    leading: visibleInterfaceInsets.leading,
                                    trailing: visibleInterfaceInsets.trailing + slideOverTrailingInset
                                )
                            )
                        )

                    if let preview = store.splitDropPreview {
                        SplitDropPreviewOverlay(
                            preview: preview,
                            cornerRadius: surfaceCornerRadius,
                            laneInsets: BrowserInterfaceInsets(
                                leading: visibleInterfaceInsets.leading,
                                trailing: visibleInterfaceInsets.trailing + slideOverTrailingInset
                            )
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

    private var webContentInsets: BrowserInterfaceInsets {
        BrowserInterfaceInsets(
            leading: max(0, visibleInterfaceInsets.leading - surfacePadding),
            trailing: max(0, visibleInterfaceInsets.trailing - surfacePadding)
        )
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
    /// coordinates — the same "one surfacePadding beyond the web-content
    /// insets" math as splitPaneAdornmentInsets, hoisted to the whole row.
    /// splitPaneFrames divides the visible page between these so the cards
    /// the mask reveals follow the pane ratios.
    private var splitRowLaneInsets: BrowserInterfaceInsets {
        BrowserInterfaceInsets(
            leading: webContentInsets.leading > 0 ? webContentInsets.leading + surfacePadding : 0,
            trailing: webContentInsets.trailing > 0 ? webContentInsets.trailing + surfacePadding : 0
        )
    }

    /// Insets that wrap a pane's *visible card* for adornments (focus ring,
    /// control pill, reorder highlight). The interface mask reveals the card
    /// from the full lane width, measured from the window edge — one
    /// surfacePadding beyond the web-content insets, which are measured from
    /// the already-padded row. Adornments padded by the content insets sit
    /// entirely under the mask on lane-touching sides and vanish.
    private func splitPaneAdornmentInsets(
        forPaneAt index: Int,
        paneCount: Int,
        layout: SplitViewLayout
    ) -> BrowserInterfaceInsets {
        let contentInsets = splitPaneInsets(forPaneAt: index, paneCount: paneCount, layout: layout)
        return BrowserInterfaceInsets(
            leading: contentInsets.leading > 0 ? contentInsets.leading + surfacePadding : 0,
            trailing: contentInsets.trailing > 0 ? contentInsets.trailing + surfacePadding : 0
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
                    contentInsets: webContentInsets,
                    isSplitViewEnabled: store.isSplitViewDisplayed,
                    onCopyURL: { store.copyActiveTabURL() },
                    onCapturePage: { store.captureActiveTabPage() },
                    onToggleSplitView: { store.toggleSplitView() },
                    onSubmitURL: { store.navigateActiveTab(to: $0) },
                    onSetDeveloperMode: { store.setDeveloperMode($0, for: url) }
                )
                // The web host's opaque surface background paints over
                // earlier siblings' rows; keep the toolbar above it or the
                // bar renders dimmed behind that fill.
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
                    obscuredContentInsets: webContentInsets
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
        .overlay {
            collapsedAddressBar(for: tab)
        }
    }

    /// The hidden-sidebar address strip. It rides over the page rather than
    /// taking a row of its own and only appears while the pointer is at the
    /// window's top edge, the way Arc's does: a permanent strip would cost
    /// every page a band of height that the sidebar was hidden to reclaim.
    @ViewBuilder
    private func collapsedAddressBar(for tab: BrowserTab) -> some View {
        let isDeveloperToolbarShown = tab.url.map {
            DeveloperModeConfiguration.isEnabled(
                for: $0,
                storedOverrides: developerModeOverrides
            )
        } ?? false

        if isSidebarHidden, !tab.isWelcomePage, !isDeveloperToolbarShown {
            ZStack(alignment: .top) {
                // Spans the surface so its bands can measure from the top
                // edge; it never takes a click meant for the page.
                TopEdgeRevealMonitor(
                    isEnabled: isSidebarHidden,
                    isRevealed: $store.isCollapsedAddressBarRevealed
                )

                CollapsedAddressBar(
                    store: store,
                    url: tab.url,
                    contentInsets: webContentInsets
                )
                .opacity(store.isCollapsedAddressBarRevealed ? 1 : 0)
                .allowsHitTesting(store.isCollapsedAddressBarRevealed)
                .animation(.easeOut(duration: 0.12), value: store.isCollapsedAddressBarRevealed)
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
            let ratios = store.splitPaneRatios(forPaneCount: splitTabs.count)
            let frames = Self.splitPaneFrames(
                layout: layout,
                ratios: ratios,
                in: proxy.size,
                spacing: spacing,
                laneInsets: splitRowLaneInsets
            )

            ZStack(alignment: .topLeading) {
                ForEach(Array(splitTabs.enumerated()), id: \.element.id) { index, splitTab in
                    let frame = frames.indices.contains(index) ? frames[index] : .zero
                    // A pane's frame runs under the reserved interface lanes
                    // (sidebar/Eli); only the mask reveals the visible card.
                    // Every pane adornment must wrap the visible card, not
                    // the raw frame, or its edge hides under the lane.
                    let paneInsets = splitPaneAdornmentInsets(
                        forPaneAt: index,
                        paneCount: splitTabs.count,
                        layout: layout
                    )

                    browserSurface {
                        webPane(for: splitTab, at: index, in: splitTabs)
                    }
                    .overlay {
                        // The focused pane carries a restrained accent ring on
                        // top of the standard surface border, mirroring the
                        // active treatment of sidebar rows and chips. Only the
                        // ring's opacity animates — never the pane layout, so
                        // focus changes cannot animate live WKWebView frames.
                        let isFocused = splitTab.id == store.activeTabID
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            // strokeBorder, not stroke: a centered stroke
                            // straddles the visible card's edge, and the
                            // interface mask clips the half that falls on the
                            // lane side — the leading edge vanished entirely.
                            .strokeBorder(AppColor.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                            .padding(.leading, paneInsets.leading)
                            .padding(.trailing, paneInsets.trailing)
                            .allowsHitTesting(false)
                            .animation(.easeOut(duration: 0.12), value: isFocused)
                    }
                    .overlay(alignment: .top) {
                        SplitPaneControlPill(
                            isPaneHovered: hoveredSplitPaneIndex == index,
                            isDraggingThisPane: splitPaneReorder?.sourceIndex == index,
                            paneIndex: index,
                            onDragChanged: { location in
                                splitPaneReorder = SplitPaneReorderState(sourceIndex: index, location: location)
                            },
                            onDragEnded: { location in
                                splitPaneReorder = nil
                                guard let targetIndex = Self.splitPaneIndex(at: location, in: frames, spacing: spacing) else {
                                    return
                                }
                                // A pane's edge bands re-stack the layout,
                                // Zen-style; the middle keeps the slot swap.
                                if let side = Self.splitPaneDropEdge(at: location, inPaneFrame: frames[targetIndex]) {
                                    store.moveSplitPane(from: index, toEdge: side, of: targetIndex)
                                } else {
                                    store.moveSplitPane(from: index, to: targetIndex)
                                }
                            },
                            onUnsplit: { store.removeTabFromSplit(splitTab.id, focusRemovedTab: true) },
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

                splitDividers(layout: layout, frames: frames, spacing: spacing, in: proxy.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The reorder adornments must be an overlay, not ZStack siblings:
            // SwiftUI draws plain siblings beneath the AppKit-hosted web
            // views, while overlay content provably layers above them (the
            // pane pill and focus ring rely on the same hosting). Mounted
            // only during a drag so the idle row keeps its hover cursors
            // (divider resize arrows, grip hand) unobstructed.
            .overlay {
                if splitPaneReorder != nil {
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
        let insets = splitPaneAdornmentInsets(forPaneAt: index, paneCount: paneCount, layout: layout)
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
        let leading = splitPaneAdornmentInsets(forPaneAt: 0, paneCount: paneCount, layout: layout).leading
        let trailing = splitPaneAdornmentInsets(
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
            obscuredContentInsets: splitPaneInsets(
                forPaneAt: paneIndex,
                paneCount: splitTabs.count,
                layout: store.splitLayout
            )
        )
    }

    private func webPane(
        for tab: BrowserTab,
        at paneIndex: Int,
        obscuredContentInsets: BrowserInterfaceInsets
    ) -> some View {
        SplitWebViewHost(
            tab: tab,
            paneIndex: paneIndex,
            store: store,
            obscuredContentInsets: obscuredContentInsets,
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

private struct SplitDividerDragState: Equatable {
    var dividerIndex: Int
    var translation: CGFloat
}

private struct SplitPaneReorderState: Equatable {
    var sourceIndex: Int
    var location: CGPoint
}

/// The draggable handle between two adjacent split panes. It rides in the
/// panes' 8pt gutter, shows the axis-appropriate resize cursor on hover, and
/// highlights while dragging (the panes themselves commit their new lengths
/// on release). Double-click resets the whole split to equal panes.
private struct SplitPaneDivider: View {
    /// The axis panes are laid out along: .horizontal dividers sit between
    /// columns (a vertical line), .vertical dividers between rows.
    let axis: Axis
    let isDragging: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(
                    isDragging
                        ? AppColor.accent.opacity(0.85)
                        : Color.primary.opacity(isHovering ? 0.28 : 0)
                )
                .frame(
                    width: axis == .horizontal ? (isDragging ? 3 : 2) : nil,
                    height: axis == .vertical ? (isDragging ? 3 : 2) : nil
                )
                .frame(
                    maxWidth: axis == .vertical ? .infinity : nil,
                    maxHeight: axis == .horizontal ? .infinity : nil
                )
                .padding(axis == .horizontal ? .vertical : .horizontal, 10)
        }
        .onHover { isHovering = $0 }
        .aiSidebarCursor(
            axis == .horizontal ? AISidebarResizeCursor.horizontal : AISidebarResizeCursor.vertical
        )
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    onDragChanged(axis == .horizontal ? value.translation.width : value.translation.height)
                }
                .onEnded { value in
                    onDragEnded(axis == .horizontal ? value.translation.width : value.translation.height)
                }
        )
        .onTapGesture(count: 2, perform: onReset)
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .animation(.easeOut(duration: 0.10), value: isDragging)
        .help("Drag to resize panes; double-click for equal panes")
    }
}

/// Zen-style control pill at a pane's top center, revealed on hover: a
/// six-dot grab area that drags the pane to another slot (the target pane
/// highlights, the reorder commits on release — panes never relayout
/// mid-drag), and an expand toggle that gives the pane the whole surface
/// and back. The pill's footprint is small so the rest of the page's top
/// edge stays clickable.
private struct SplitPaneControlPill: View {
    /// The pointer is over the pane (reported by the pane host's tracking
    /// area) — the discoverable way the pill reveals itself.
    let isPaneHovered: Bool
    let isDraggingThisPane: Bool
    let paneIndex: Int
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onUnsplit: () -> Void

    @State private var isHovering = false

    private var isRevealed: Bool {
        isPaneHovered || isHovering || isDraggingThisPane
    }

    var body: some View {
        HStack(spacing: 0) {
            gripDots
                .frame(width: 34, height: 20)
                .contentShape(Rectangle())
                // Grab cursors live in the AppKit layer: the open hand
                // as a re-asserted hover cursor (WebKit fights one-shot
                // pushes over web content), the closed hand from the
                // NSView's mouseDown — SwiftUI's zero-distance
                // DragGesture does not track dependably on macOS, so the
                // press itself must be caught natively.
                .modifier(SplitPaneGripCursorModifier())
                .gesture(
                    DragGesture(
                        minimumDistance: 2,
                        coordinateSpace: .named(WebViewContainer.splitRowCoordinateSpace)
                    )
                    .onChanged { value in
                        onDragChanged(value.location)
                    }
                    .onEnded { value in
                        onDragEnded(value.location)
                    }
                )
                .help("Drag to move this pane")
                .accessibilityElement()
                .accessibilityLabel("Move Pane")
                .accessibilityIdentifier("split-pane-grip-\(paneIndex)")

            Button(action: onUnsplit) {
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .foregroundStyle(.secondary)
            .help("Unsplit — Move Back to Tab List")
            .accessibilityLabel("Unsplit")
            .accessibilityIdentifier("split-pane-unsplit-\(paneIndex)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(InterfaceStyle.popoverBorder, lineWidth: 1)
        }
        // Not 0: fully transparent views stop hit-testing, and the pill must
        // keep its hover/click footprint while visually absent.
        .opacity(isRevealed ? 1 : 0.02)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isRevealed)
    }

    private var gripDots: some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(
                                isDraggingThisPane
                                    ? AppColor.accent
                                    : Color.secondary
                            )
                            .frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
    }
}

/// Reserves native interface space without ever changing the live WKWebView's frame.
/// Keep this at the WebViewContainer boundary: moving the reservation into a
/// parent HStack makes WebKit stretch a stale remote-layer frame on every
/// sidebar toggle.
private struct BrowserInterfaceMaskModifier: ViewModifier {
    let insets: BrowserInterfaceInsets
    let slideOverTrailingInset: CGFloat
    let surfaceCornerRadius: CGFloat
    let surfacePadding: CGFloat
    let trailingSurfacePadding: CGFloat
    let drawsFullSurfaceBorder: Bool

    // The trailing lane is reserved either persistently (insets) or
    // transiently while Eli covers the page beyond the reserved layout.
    // Both clip the same way, so every trailing measurement uses their sum.
    private var leadingInset: CGFloat {
        insets.leading
    }

    private var trailingInset: CGFloat {
        insets.trailing + slideOverTrailingInset
    }

    func body(content: Content) -> some View {
        content
            .mask {
                if leadingInset > 0 || trailingInset > 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .padding(.vertical, surfacePadding)
                            .padding(.leading, leadingInset + surfacePadding)
                            .padding(.trailing, trailingInset + trailingSurfacePadding)

                        // Preserve the surface's existing top, trailing, and
                        // bottom shadow. Only the interface regions need clipping.
                        Rectangle()
                            .padding(
                                .leading,
                                leadingInset > 0
                                    ? leadingInset + surfacePadding + surfaceCornerRadius
                                    : 0
                            )
                            .padding(
                                .trailing,
                                trailingInset > 0
                                    ? trailingInset + surfacePadding + surfaceCornerRadius
                                    : 0
                            )
                    }
                } else {
                    Rectangle()
                }
            }
            .overlay {
                if drawsFullSurfaceBorder {
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                        .padding(.vertical, surfacePadding)
                        .padding(.leading, leadingInset + surfacePadding)
                        .padding(.trailing, trailingInset + trailingSurfacePadding)
                        .allowsHitTesting(false)
                } else {
                    // Split panes own their individual borders. Add only sides
                    // introduced by this mask so shared edges are not repainted.
                    if leadingInset > 0 {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: surfaceCornerRadius + 1)
                            }
                            .padding(.vertical, surfacePadding)
                            .padding(.leading, leadingInset + surfacePadding)
                            .padding(.trailing, trailingInset + trailingSurfacePadding)
                            .allowsHitTesting(false)
                    }

                    if trailingInset > 0 {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                            .mask(alignment: .trailing) {
                                Rectangle()
                                    .frame(width: surfaceCornerRadius + 1)
                            }
                            .padding(.vertical, surfacePadding)
                            .padding(.leading, leadingInset + surfacePadding)
                            .padding(.trailing, trailingInset + trailingSurfacePadding)
                            .allowsHitTesting(false)
                    }
                }
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

private struct BrowserSurfaceSplitDropDelegate: DropDelegate {
    let store: BrowserStore
    let size: CGSize
    /// The reserved interface lanes (sidebar, Eli). The drop surface spans
    /// the whole container — including under the lanes — so zone math must
    /// run on the visible page region or a release over the sidebar's empty
    /// area reads as a leading-edge drop and splits the page.
    let laneInsets: BrowserInterfaceInsets

    // Validation gates the whole drag session, and the session's first event
    // arrives at the drag's starting position — usually the sidebar row the
    // drag began on, because this surface spans the container. Any per-
    // position rejection here (or a .cancel proposal from dropUpdated) is
    // terminal: AppKit stops consulting this destination for the rest of
    // the drag. Position handling therefore stays in updatePreview and
    // performDrop, which are location-aware but never terminal.
    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updatePreview(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(info: info)
        return store.splitDropPreview == nil ? nil : DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSplitDropPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard
            let draggedID = store.draggedTabID,
            let target = dropTarget(for: info, draggedID: draggedID)
        else {
            store.clearSplitDropPreview()
            return false
        }

        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        store.splitTab(draggedID, onto: target.tabID, side: target.side)
        store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? .regular)
        return true
    }

    private func updatePreview(info: DropInfo) {
        guard
            let draggedID = store.draggedTabID,
            let target = dropTarget(for: info, draggedID: draggedID)
        else {
            store.clearSplitDropPreview()
            return
        }

        store.updateSplitDropPreview(targetTabID: target.tabID, side: target.side)
    }

    private func dropTarget(
        for info: DropInfo,
        draggedID: UUID
    ) -> (tabID: UUID, side: SplitTabDropSide)? {
        guard let side = dropSide(for: info) else { return nil }
        guard let tabID = store.splitDropTargetTabID(for: side, draggedID: draggedID) else { return nil }
        return (tabID, side)
    }

    /// Zen-style edge targeting: only the page's outer quarters accept a
    /// split drop — the nearest edge wins, and the middle of the page is not
    /// a target, so an abandoned drag over content does nothing.
    private func dropSide(for info: DropInfo) -> SplitTabDropSide? {
        let pageWidth = max(size.width - laneInsets.leading - laneInsets.trailing, 1)
        let pageX = info.location.x - laneInsets.leading
        guard pageX >= 0, pageX <= pageWidth else { return nil }
        let fractionX = pageX / pageWidth
        let fractionY = info.location.y / max(size.height, 1)
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
}

/// Zen-style drop preview: one primary-accent region covering the half of
/// the page the drop would claim — a full-height column for leading and
/// trailing, a full-width row for top and bottom. Deliberately not a mocked
/// up pane arrangement: the drag needs a single unambiguous "this is what
/// you get", matching the grip drag's claim highlight.
private struct SplitDropPreviewOverlay: View {
    let preview: SplitTabDropPreview
    let cornerRadius: CGFloat
    /// The reserved interface lanes; the claim region wraps the visible
    /// page, not the container that runs under them.
    let laneInsets: BrowserInterfaceInsets

    var body: some View {
        GeometryReader { proxy in
            let page = CGRect(
                x: laneInsets.leading,
                y: 0,
                width: max(proxy.size.width - laneInsets.leading - laneInsets.trailing, 0),
                height: proxy.size.height
            )
            let claim = WebViewContainer.splitPaneEdgeHighlightFrame(for: preview.side, in: page)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppColor.accent.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppColor.accent.opacity(0.85), lineWidth: 2)
                }
                .frame(width: claim.width, height: claim.height)
                .offset(x: claim.minX, y: claim.minY)
        }
        .allowsHitTesting(false)
    }
}

/// Native developer toolbar shown for local development pages. It remains
/// neutral chrome so Space identity colors stay in the passive content layer.
private struct DeveloperToolbar: View {
    let url: URL
    let urlText: String
    /// The interface lanes covering the card's edges. The striped surface
    /// spans the full card, but content placed under a lane is masked away
    /// with it, so the URL field and controls stay inside the visible run.
    let contentInsets: BrowserInterfaceInsets
    let isSplitViewEnabled: Bool
    let onCopyURL: () -> Void
    let onCapturePage: () -> Void
    let onToggleSplitView: () -> Void
    let onSubmitURL: (String) -> Void
    let onSetDeveloperMode: (Bool) -> Void

    private static let storageKey = "CandoaDeveloperToolbarControlIDs"
    private static let noControlIDsValue = "none"
    private static let defaultControlIDs = DeveloperToolbarControlKind.allCases
        .filter(\.isDefaultVisible)
        .map(\.id)
        .joined(separator: ",")

    @State private var draftURL = ""
    @State private var hoveredControl: DeveloperToolbarControlKind?
    @State private var isHoveringControlMenu = false
    @State private var isSiteInfoPresented = false
    @State private var isExtensionsPresented = false
    @AppStorage(Self.storageKey) private var storedControlIDs = ""
    @FocusState private var isURLFieldFocused: Bool

    private var isLocalDevelopment: Bool { url.isLocalDevelopment }

    // Local development wears the brand-blue striped treatment (Arc-style),
    // which needs the white-on-accent foreground regardless of appearance.
    private var foreground: Color {
        isLocalDevelopment ? .white : InterfaceStyle.sidebarText
    }

    private var selectedControlIDs: [String] {
        if storedControlIDs == Self.noControlIDsValue {
            return []
        }

        let value = storedControlIDs.isEmpty ? Self.defaultControlIDs : storedControlIDs
        return value
            .split(separator: ",")
            .map(String.init)
            .filter { id in DeveloperToolbarControlKind.allCases.contains { $0.id == id } }
    }

    private var selectedControlIDSet: Set<String> {
        Set(selectedControlIDs)
    }

    private var visibleControls: [DeveloperToolbarControlKind] {
        let ids = selectedControlIDSet
        return DeveloperToolbarControlKind.allCases.filter { ids.contains($0.id) }
    }

    private var currentURL: URL? {
        URL(string: urlText)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $draftURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.92))
                .tint(isLocalDevelopment ? foreground : AppColor.accent)
                .lineLimit(1)
                .focused($isURLFieldFocused)
                .onSubmit {
                    isURLFieldFocused = false
                    onSubmitURL(draftURL)
                }
                .onExitCommand {
                    draftURL = urlText
                    isURLFieldFocused = false
                }
                .onAppear { draftURL = urlText }
                .onChange(of: urlText) { _, newValue in
                    // Navigation landed: refresh the field, but never clobber
                    // an edit in progress.
                    if !isURLFieldFocused {
                        draftURL = newValue
                    }
                }
                .onChange(of: isURLFieldFocused) { _, isFocused in
                    // Abandoned edits (click away) revert to the live URL.
                    if !isFocused {
                        draftURL = urlText
                    }
                }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Array(visibleControls.enumerated()), id: \.element.id) { index, control in
                    if shouldInsertSeparator(before: index) {
                        Rectangle()
                            .fill(foreground.opacity(0.18))
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 3)
                    }

                    toolbarButton(for: control)
                }

                controlMenu
            }
        }
        .padding(.leading, isLocalDevelopment ? 16 : 10)
        .padding(.trailing, 10)
        .padding(.leading, contentInsets.leading)
        .padding(.trailing, contentInsets.trailing)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background {
            if isLocalDevelopment {
                LocalDevelopmentStripedBackground()
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isLocalDevelopment ? Color.black.opacity(0.18) : InterfaceStyle.sidebarSeparator)
                .frame(height: 1)
        }
    }

    private var controlMenu: some View {
        Menu {
            Text("Shown Controls")

            ForEach(DeveloperToolbarControlKind.allCases) { control in
                Button {
                    toggleControl(control)
                } label: {
                    if selectedControlIDSet.contains(control.id) {
                        Label(control.title(isSplitViewEnabled: isSplitViewEnabled), systemImage: "checkmark")
                    } else {
                        Text(control.title(isSplitViewEnabled: isSplitViewEnabled))
                    }
                }
                .disabled(!control.isImplemented)
            }

            Divider()

            Button("Reset to Arc Controls") {
                storedControlIDs = Self.defaultControlIDs
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(foreground.opacity(isHoveringControlMenu ? 0.95 : 0.72))
                .frame(width: 22, height: 22)
                .background(foreground.opacity(isHoveringControlMenu ? 0.12 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // The borderless menu button re-tints its template label with the
        // accent, ignoring the label's foregroundStyle; match the sibling
        // buttons' foreground explicitly.
        .tint(foreground.opacity(isHoveringControlMenu ? 0.95 : 0.72))
        .fixedSize()
        .onHover { isHoveringControlMenu = $0 }
        .help("Customize Developer Controls")
    }

    private func toolbarButton(for control: DeveloperToolbarControlKind) -> some View {
        Button {
            perform(control)
        } label: {
            Image(systemName: control.symbolName(isSplitViewEnabled: isSplitViewEnabled))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    foreground.opacity(
                        control.isImplemented
                            ? (hoveredControl == control ? 0.95 : 0.72)
                            : 0.34
                    )
                )
                .frame(width: 22, height: 22)
                .background(foreground.opacity(hoveredControl == control && control.isImplemented ? 0.12 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .disabled(!control.isImplemented)
        .onHover { isHovering in
            hoveredControl = isHovering ? control : nil
        }
        .help(control.help(isSplitViewEnabled: isSplitViewEnabled))
        .popover(
            isPresented: Binding(
                get: { control == .siteInfo && isSiteInfoPresented },
                set: { isPresented in
                    if control == .siteInfo {
                        isSiteInfoPresented = isPresented
                    }
                }
            ),
            arrowEdge: .top
        ) {
            DeveloperSiteInfoPopover(
                url: currentURL,
                urlText: urlText,
                isLocalDevelopment: url.isLocalDevelopment,
                onSetDeveloperMode: onSetDeveloperMode
            )
        }
        .popover(
            isPresented: Binding(
                get: { control == .extensions && isExtensionsPresented },
                set: { isPresented in
                    if control == .extensions {
                        isExtensionsPresented = isPresented
                    }
                }
            ),
            arrowEdge: .top
        ) {
            if #available(macOS 15.4, *) {
                ExtensionActionsPopover(isPresented: $isExtensionsPresented)
            }
        }
    }

    private func shouldInsertSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return visibleControls[index].group != visibleControls[index - 1].group
    }

    private func perform(_ control: DeveloperToolbarControlKind) {
        switch control {
        case .copyURL:
            onCopyURL()
        case .capturePage:
            onCapturePage()
        case .splitView:
            onToggleSplitView()
        case .siteInfo:
            isSiteInfoPresented = true
        case .extensions:
            isExtensionsPresented = true
        case .easel, .developerTools, .inspectElement:
            break
        }
    }

    private func toggleControl(_ control: DeveloperToolbarControlKind) {
        var ids = Set(selectedControlIDs)
        if ids.contains(control.id) {
            ids.remove(control.id)
        } else {
            ids.insert(control.id)
        }

        let orderedIDs = DeveloperToolbarControlKind.allCases
            .map(\.id)
            .filter { ids.contains($0) }
        storedControlIDs = orderedIDs.isEmpty
            ? Self.noControlIDsValue
            : orderedIDs.joined(separator: ",")
    }
}

/// Arc-style local-development banner: the primary blue muted into the
/// chrome (55% over the window background — Alex compared full-strength,
/// gray-with-blue-stripes, and this in situ, and settled here), with wide
/// 45° stripes in a slightly lighter tint so the bar reads as a deliberate
/// "you are on localhost" surface without shouting over the chrome.
private struct LocalDevelopmentStripedBackground: View {
    var body: some View {
        Canvas { context, size in
            let bounds = Path(CGRect(origin: .zero, size: size))
            context.fill(bounds, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.fill(bounds, with: .color(AppColor.Apple.systemBlue.opacity(0.55)))

            // Wide bands like Arc's — Alex found 14pt too thin.
            let bandWidth: CGFloat = 24
            let period = bandWidth * 2
            var x: CGFloat = -size.height
            while x < size.width {
                var band = Path()
                band.move(to: CGPoint(x: x, y: size.height))
                band.addLine(to: CGPoint(x: x + bandWidth, y: size.height))
                band.addLine(to: CGPoint(x: x + bandWidth + size.height, y: 0))
                band.addLine(to: CGPoint(x: x + size.height, y: 0))
                band.closeSubpath()
                context.fill(band, with: .color(.white.opacity(0.08)))
                x += period
            }
        }
    }
}

private struct DeveloperSiteInfoPopover: View {
    let url: URL?
    let urlText: String
    let isLocalDevelopment: Bool
    let onSetDeveloperMode: (Bool) -> Void

    private var hostText: String {
        url?.host(percentEncoded: false) ?? "Local page"
    }

    private var schemeText: String {
        url?.scheme?.uppercased() ?? "Unknown"
    }

    private var portText: String {
        guard let port = url?.port else { return String(localized: "Default") }
        return String(port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hostText, systemImage: "info.circle")
                .font(.headline)

            Divider()

            DeveloperSiteInfoRow(title: String(localized: "Address"), value: urlText)
            DeveloperSiteInfoRow(title: String(localized: "Scheme"), value: schemeText)
            DeveloperSiteInfoRow(title: String(localized: "Port"), value: portText)

            Toggle("Developer Mode", isOn: Binding(
                get: { true },
                set: { isEnabled in
                    onSetDeveloperMode(isEnabled)
                }
            ))

            Text(
                isLocalDevelopment
                    ? "Enabled automatically for local development."
                    : "Enabled for this site."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

private struct DeveloperSiteInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum DeveloperToolbarControlKind: String, CaseIterable, Identifiable {
    case copyURL
    case easel
    case capturePage
    case developerTools
    case siteInfo
    case inspectElement
    case extensions
    case splitView

    var id: String { rawValue }

    var group: Int {
        switch self {
        case .copyURL:
            return 0
        case .easel, .capturePage:
            return 1
        case .developerTools, .siteInfo, .inspectElement:
            return 2
        case .extensions, .splitView:
            return 3
        }
    }

    var isDefaultVisible: Bool {
        switch self {
        case .copyURL, .capturePage, .siteInfo, .splitView:
            return true
        case .easel, .developerTools, .inspectElement, .extensions:
            return false
        }
    }

    var isImplemented: Bool {
        switch self {
        case .copyURL, .capturePage, .siteInfo, .splitView:
            return true
        case .extensions:
            if #available(macOS 15.4, *) {
                return true
            }
            return false
        case .easel, .developerTools, .inspectElement:
            return false
        }
    }

    func title(isSplitViewEnabled: Bool) -> String {
        switch self {
        case .copyURL:
            return String(localized: "Copy Link")
        case .easel:
            return String(localized: "Capture to Easel")
        case .capturePage:
            return String(localized: "Capture Page")
        case .developerTools:
            return String(localized: "Developer Tools")
        case .siteInfo:
            return String(localized: "Site Info")
        case .inspectElement:
            return String(localized: "Inspect Element")
        case .extensions:
            return String(localized: "Extensions")
        case .splitView:
            return isSplitViewEnabled ? BrowserCommandTitles.closeSplitView : BrowserCommandTitles.addSplitView
        }
    }

    func symbolName(isSplitViewEnabled: Bool) -> String {
        switch self {
        case .copyURL:
            return "link"
        case .easel:
            return "rectangle.on.rectangle"
        case .capturePage:
            return "camera"
        case .developerTools:
            return "terminal"
        case .siteInfo:
            return "globe"
        case .inspectElement:
            return "scope"
        case .extensions:
            return "puzzlepiece.extension"
        case .splitView:
            return isSplitViewEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
        }
    }

    var shortcutText: String {
        switch self {
        case .copyURL:
            return "⇧⌘C"
        case .capturePage:
            return String(localized: "Set in Settings > Shortcuts")
        case .splitView:
            // Reflect the person's configured shortcut, not the default.
            let caps = ShortcutKeyCaps.current(for: .toggleSplitView).joined()
            return caps.isEmpty ? String(localized: "Set in Settings > Shortcuts") : caps
        case .extensions:
            if #available(macOS 15.4, *) {
                return String(localized: "Manage in Settings > Extensions")
            }
            return String(localized: "Extensions require macOS 15.4 or later.")
        case .easel, .developerTools, .siteInfo, .inspectElement:
            return String(localized: "Not implemented in Candoa yet")
        }
    }

    func help(isSplitViewEnabled: Bool) -> String {
        "\(title(isSplitViewEnabled: isSplitViewEnabled))\n\(shortcutText)"
    }
}

/// Zen-style loading pill: a small capsule centered at the top of the web
/// surface that pulses while the page loads, settles into a wide shimmering
/// track on long loads (3s+), and shrink-fades away once the page lands.
/// Shape and timing mirror Zen's #zen-loading-progress-bar; color remains a
/// neutral semantic macOS label treatment rather than following the Space.
private struct PageLoadingPill: View {
    let isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading {
                LoadingPillCore()
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .scale(scale: 0.8))
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: isLoading ? 0.4 : 0.3), value: isLoading)
        .allowsHitTesting(false)
    }
}

private struct LoadingPillCore: View {
    @State private var isPulsedUp = false
    @State private var isLongLoad = false
    @State private var isShimmerSwept = false

    private let pillWidth: CGFloat = 80
    private let longLoadWidth: CGFloat = 160
    private let pillHeight: CGFloat = 6
    private let longLoadDelay: Duration = .seconds(3)

    var body: some View {
        Capsule()
            .fill(isLongLoad ? trackColor : pillColor)
            .overlay {
                if isLongLoad {
                    shimmer
                }
            }
            .clipShape(Capsule())
            .frame(width: isLongLoad ? longLoadWidth : pillWidth, height: pillHeight)
            .scaleEffect(isLongLoad ? 1 : (isPulsedUp ? 0.95 : 0.85))
            .opacity(isLongLoad ? 1 : (isPulsedUp ? 1 : 0.6))
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    isPulsedUp = true
                }
            }
            .task {
                try? await Task.sleep(for: longLoadDelay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    isLongLoad = true
                }
            }
    }

    /// Long-load state: the pill becomes a faint track with a tinted
    /// segment sweeping through it, like an indeterminate marquee.
    private var shimmer: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(pillColor)
                .frame(width: proxy.size.width * 0.75)
                .offset(x: isShimmerSwept ? proxy.size.width : -proxy.size.width * 0.75)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1).repeatForever(autoreverses: false).delay(0.3)
                    ) {
                        isShimmerSwept = true
                    }
                }
        }
    }

    private var pillColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    private var trackColor: Color {
        Color(nsColor: .separatorColor)
    }
}

internal struct SpaceSetupCanvas: View {
    let hexes: [String]
    let intensity: Double
    let texture: Double

    var body: some View {
        if hexes.isEmpty {
            neutralCanvas
        } else {
            themedCanvas
        }
    }

    private var neutralCanvas: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(InterfaceStyle.workspaceBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
            }
    }

    private var themedCanvas: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let highlight = Color(nsColor: .highlightColor)
        let shadow = Color(nsColor: .shadowColor)

        return ZStack {
            shape.fill(canvasFill)

            LinearGradient(
                colors: [highlight.opacity(0.03), shadow.opacity(0.012)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(shape)

            LinearGradient(
                colors: [highlight.opacity(0.04), .clear, shadow.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.overlay)
            .clipShape(shape)
        }
        .overlay {
            shape.stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: shadow.opacity(0.18), radius: 30, y: 10)
        .shadow(color: shadow.opacity(0.10), radius: 14, x: -4, y: 1)
    }

    private var canvasFill: Color {
        guard let firstHex = hexes.first else {
            // This is the visible empty-workspace surface. Keep it on the
            // semantic under-page role instead of compositing the darker
            // control background over the window backdrop.
            return InterfaceStyle.workspaceBackground
        }

        // The window backdrop already carries the theme color at full
        // strength; keep the card nearly transparent so interface and canvas
        // read as one continuous surface (Zen-style).
        return Color(spaceHex: firstHex).opacity(0.08)
    }
}

/// Explainer shown on the empty content surface of a private window,
/// describing exactly what Candoa's private browsing does and doesn't
/// keep. Onboarding-sheet style: icon badge, lede, symbol feature rows.
/// Replaced by web content as soon as a tab opens.
private struct PrivateBrowsingExplainer: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(.quaternary.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .padding(.bottom, 16)

            Text("Private Browsing")
                .font(.title.weight(.semibold))
                .padding(.bottom, 4)

            Text("Browse without leaving a trace on this Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 18) {
                featureRow(
                    symbol: "clock.arrow.circlepath",
                    title: String(localized: "No history"),
                    detail: String(
                        localized: "Pages you visit and searches you make aren't saved."
                    )
                )
                featureRow(
                    symbol: "wind",
                    title: String(localized: "Nothing sticks"),
                    detail: String(
                        localized: "Cookies, logins, and site data vanish when you close this window."
                    )
                )
                featureRow(
                    symbol: "square.grid.2x2",
                    title: String(localized: "Outside your Spaces"),
                    detail: String(
                        localized: "Tabs here never join your workspace or sync with iCloud."
                    )
                )
                featureRow(
                    symbol: "arrow.down.circle",
                    title: String(localized: "Downloads are kept"),
                    detail: String(
                        localized: "Files you save stay in your Downloads folder."
                    )
                )
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 40)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("private-browsing-explainer")
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grab-cursor feedback for the pane grip, handled in AppKit because both
/// halves fail in SwiftUI: hover cursors over web content are re-asserted
/// away by WebKit, and a zero-distance DragGesture does not track dependably
/// on macOS, so mouse-down must be caught natively. The NSView owns every
/// cursor assertion; SwiftUI-side hover sets were racing WebKit's tracking
/// areas within the same event and the alternation read as flicker.
private struct SplitPaneGripCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SplitPaneGripCursorView())
    }
}

private struct SplitPaneGripCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> SplitPaneGripCursorNSView {
        SplitPaneGripCursorNSView()
    }

    func updateNSView(_ nsView: SplitPaneGripCursorNSView, context: Context) {}
}

private final class SplitPaneGripCursorNSView: NSView {
    private var monitor: Any?
    private var hasPushedClosedHand = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
            popClosedHandIfNeeded()
        } else {
            installMonitorIfNeeded()
        }
    }

    // SwiftUI's hosting view hit-tests its gesture regions to itself, so
    // this view never receives mouse events directly — the monitor sees
    // them before dispatch, the same way the pane focus and tab drag
    // monitors do. Presses and drags pass through untouched (the SwiftUI
    // drag gesture needs them); only mouseMoved inside the grip is
    // swallowed, so WebKit never processes those moves and cannot answer
    // them with a page-cursor change.
    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            // Local event monitors always run on the main thread. NSEvent is
            // not Sendable, so the isolated closure returns only the swallow
            // decision rather than the event itself.
            let swallowed = MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
            return swallowed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns true when the event was consumed for the grip's cursor.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard isEventInside(event) else { return false }
            if !hasPushedClosedHand {
                hasPushedClosedHand = true
                NSCursor.closedHand.push()
            }
            return false
        case .leftMouseUp:
            popClosedHandIfNeeded()
            return false
        case .mouseMoved:
            guard isEventInside(event), !hasPushedClosedHand else { return false }
            // Swallowing the move starves WebKit of the event, so its
            // asynchronous web-process round trip can't land a page cursor
            // AFTER ours — that late reply is why the hand only appeared
            // once the pointer rested. The deferred re-assert still covers
            // replies already in flight from moves just outside the grip.
            NSCursor.openHand.set()
            assertCursorAfterWebKit(.openHand)
            return true
        case .leftMouseDragged:
            // The grip drag keeps the fist wherever the pointer travels.
            // Never swallowed: the SwiftUI drag gesture tracks these.
            guard hasPushedClosedHand else { return false }
            assertCursorAfterWebKit(.closedHand)
            return false
        default:
            return false
        }
    }

    private func isEventInside(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let location = convert(event.locationInWindow, from: nil)
        return bounds.contains(location) && visibleRect.contains(location)
    }

    // WebKit answers earlier mouse moves asynchronously (web-process IPC),
    // so a cursor it decided moments ago can land after a synchronous set.
    // Re-asserting on the next runloop turn wins over those stragglers.
    private func assertCursorAfterWebKit(_ cursor: NSCursor) {
        DispatchQueue.main.async { [weak self] in
            guard self?.window != nil else { return }
            cursor.set()
        }
    }

    private func popClosedHandIfNeeded() {
        guard hasPushedClosedHand else { return }
        hasPushedClosedHand = false
        NSCursor.pop()
    }
}
