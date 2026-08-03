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
    /// The pane the pointer is inside, reported by the pane host's tracking
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
                                size: proxy.size
                            )
                        )

                    if let preview = store.splitDropPreview {
                        SplitDropPreviewOverlay(
                            store: store,
                            preview: preview,
                            cornerRadius: surfaceCornerRadius
                        )
                        .padding(containedSurfaceInsets)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
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
                        .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
                }
            }
            .background(
                shape
                    .fill(CandoaInterfaceStyle.surfaceFill.opacity(0.74))
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

    /// Which window edges a pane touches depends on where the layout puts
    /// it: only panes on the leading/trailing window edge reserve the
    /// corresponding interface lane.
    private func splitPaneEdgeContact(
        forPaneAt index: Int,
        paneCount: Int,
        layout: SplitViewLayout
    ) -> (leading: Bool, trailing: Bool) {
        switch layout {
        case .horizontal:
            return (index == 0, index == paneCount - 1)
        case .vertical:
            // Stacked rows all span the full width, touching both edges.
            return (true, true)
        case .grid:
            let spansFullWidth = index == paneCount - 1 && paneCount % 2 == 1
            return (index % 2 == 0, index % 2 == 1 || spansFullWidth)
        }
    }

    private func splitPaneInsets(
        forPaneAt index: Int,
        paneCount: Int,
        layout: SplitViewLayout
    ) -> BrowserInterfaceInsets {
        let contact = splitPaneEdgeContact(forPaneAt: index, paneCount: paneCount, layout: layout)
        return BrowserInterfaceInsets(
            leading: contact.leading ? webContentInsets.leading : 0,
            trailing: contact.trailing ? webContentInsets.trailing : 0
        )
    }

    /// Aligns pane adornments (focus ring, control pill, reorder highlight)
    /// with the visible card. The mask reveals the card `surfacePadding`
    /// inside each reserved lane while the pane's raw frame already starts
    /// `surfacePadding` from the window edge, so the adornment offset is the
    /// full lane width — `webContentInsets` (sized for the web view's
    /// obscured-content layout) lands `surfacePadding` short and hides an
    /// edge pane's adornment under the lane. The trailing side also tracks
    /// Eli's transient slide-over clip, which narrows the visible card
    /// without touching the reserved layout.
    private func splitPaneAdornmentInsets(
        forPaneAt index: Int,
        paneCount: Int,
        layout: SplitViewLayout
    ) -> BrowserInterfaceInsets {
        let contact = splitPaneEdgeContact(forPaneAt: index, paneCount: paneCount, layout: layout)
        return BrowserInterfaceInsets(
            leading: contact.leading ? visibleInterfaceInsets.leading : 0,
            trailing: contact.trailing ? visibleInterfaceInsets.trailing + slideOverTrailingInset : 0
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
                    isSplitViewEnabled: store.isSplitViewDisplayed,
                    onCopyURL: { store.copyActiveTabURL() },
                    onCapturePage: { store.captureActiveTabPage() },
                    onToggleSplitView: { store.toggleSplitView() },
                    onSubmitURL: { store.navigateActiveTab(to: $0) },
                    onSetDeveloperMode: { store.setDeveloperMode($0, for: url) }
                )
            }

            if tab.isWelcomePage {
                EmptyView()
            } else if tab.url == nil {
                EmptyTabSurface {
                    store.openNewTabCommandPalette()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CandoaInterfaceStyle.surfaceFill.opacity(0.72))
            } else {
                ActiveWebViewHost(
                    tab: tab,
                    store: store,
                    obscuredContentInsets: webContentInsets
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CandoaInterfaceStyle.surfaceFill.opacity(0.72))
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

                TextField("Find in page", text: $store.findQuery)
                    .textFieldStyle(.plain)
                    .tint(CandoaColor.accent)
                    .frame(width: 190)
                    .focused($isFieldFocused)
                    .accessibilityIdentifier("find-bar-field")
                    .onSubmit { store.findNext() }

                Button {
                    store.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .candoaButton(.content)
                .disabled(store.findQuery.isEmpty)
                .help("Find Previous")

                Button {
                    store.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .candoaButton(.content)
                .disabled(store.findQuery.isEmpty)
                .help("Find Next")

                Button {
                    store.dismissFindBar()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .candoaButton(.content)
                .help("Done")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CandoaInterfaceStyle.popoverBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
            }
            .onAppear { isFieldFocused = true }
            .onExitCommand { store.dismissFindBar() }
            .onChange(of: store.findQuery) { _, _ in
                store.findNext()
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
                spacing: spacing
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
                        // strokeBorder keeps the ring entirely inside the
                        // visible card: a centered stroke straddles the mask's
                        // reveal edge and gets shaved to half a point there.
                        let isFocused = splitTab.id == store.activeTabID
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .strokeBorder(CandoaColor.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                            .padding(.leading, paneInsets.leading)
                            .padding(.trailing, paneInsets.trailing)
                            .allowsHitTesting(false)
                            .animation(.easeOut(duration: 0.12), value: isFocused)
                    }
                    .overlay(alignment: .top) {
                        SplitPaneControlPill(
                            isPaneHovered: hoveredSplitPaneIndex == index,
                            isDraggingThisPane: splitPaneReorder?.sourceIndex == index,
                            showsReorderGrip: true,
                            paneIndex: index,
                            onDragChanged: { location in
                                splitPaneReorder = SplitPaneReorderState(sourceIndex: index, location: location)
                            },
                            onDragEnded: { location in
                                splitPaneReorder = nil
                                if let target = Self.splitPaneDropTarget(at: location, in: frames, spacing: spacing),
                                   target.index != index {
                                    store.moveSplitPane(from: index, toSide: target.side, of: target.index)
                                }
                            },
                            onUnsplit: { store.unsplitPane(splitTab.id) },
                            onClose: { store.closeTab(splitTab.id) }
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

                // Drop preview: the dragged pane's frame after the move —
                // computed from the same order/layout the commit will apply,
                // so a two-pane drop that re-axes the split highlights the
                // resulting full-surface half, not merely the half of the
                // target pane under the pointer. Panes themselves never move
                // until the drop commits.
                if let reorder = splitPaneReorder,
                   let target = Self.splitPaneDropTarget(at: reorder.location, in: frames, spacing: spacing),
                   let order = BrowserStore.movedPaneOrder(
                       count: frames.count,
                       from: reorder.sourceIndex,
                       toSide: target.side,
                       of: target.index
                   ),
                   let movedPosition = order.firstIndex(of: reorder.sourceIndex) {
                    let previewLayout = BrowserStore.movedPaneLayout(
                        current: layout,
                        paneCount: frames.count,
                        side: target.side
                    )
                    let previewFrames = Self.splitPaneFrames(
                        layout: previewLayout,
                        ratios: order.map { ratios[$0] },
                        in: proxy.size,
                        spacing: spacing
                    )
                    if previewFrames.indices.contains(movedPosition) {
                        let previewInsets = splitPaneAdornmentInsets(
                            forPaneAt: movedPosition,
                            paneCount: splitTabs.count,
                            layout: previewLayout
                        )
                        let frame = previewFrames[movedPosition]
                        let highlight = CGRect(
                            x: frame.minX + previewInsets.leading,
                            y: frame.minY,
                            width: max(0, frame.width - previewInsets.leading - previewInsets.trailing),
                            height: frame.height
                        )
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .fill(CandoaColor.accent.opacity(0.12))
                            .overlay {
                                RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                                    .strokeBorder(CandoaColor.accent.opacity(0.85), lineWidth: 2)
                            }
                            .frame(width: highlight.width, height: highlight.height)
                            .offset(x: highlight.minX, y: highlight.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: Self.splitRowCoordinateSpace)
        }
    }

    /// Pane rectangles for the current layout. Horizontal and vertical
    /// distribute the panes' shared ratios along their axis; the grid packs
    /// two equal columns row-major, the odd last pane spanning full width.
    static func splitPaneFrames(
        layout: SplitViewLayout,
        ratios: [Double],
        in size: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        let paneCount = ratios.count
        guard paneCount > 0 else { return [] }

        switch layout {
        case .horizontal:
            let available = max(1, size.width - spacing * CGFloat(paneCount - 1))
            var x: CGFloat = 0
            return ratios.map { ratio in
                let width = available * CGFloat(ratio)
                defer { x += width + spacing }
                return CGRect(x: x, y: 0, width: width, height: size.height)
            }
        case .vertical:
            let available = max(1, size.height - spacing * CGFloat(paneCount - 1))
            var y: CGFloat = 0
            return ratios.map { ratio in
                let height = available * CGFloat(ratio)
                defer { y += height + spacing }
                return CGRect(x: 0, y: y, width: size.width, height: height)
            }
        case .grid:
            let rowCount = (paneCount + 1) / 2
            let rowHeight = max(1, (size.height - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount))
            let columnWidth = max(1, (size.width - spacing) / 2)
            return (0..<paneCount).map { index in
                let row = index / 2
                let column = index % 2
                let spansFullWidth = index == paneCount - 1 && paneCount % 2 == 1
                return CGRect(
                    x: column == 0 ? 0 : columnWidth + spacing,
                    y: CGFloat(row) * (rowHeight + spacing),
                    width: spansFullWidth ? size.width : columnWidth,
                    height: rowHeight
                )
            }
        }
    }

    static func splitPaneIndex(at location: CGPoint, in frames: [CGRect], spacing: CGFloat) -> Int? {
        frames.firstIndex { frame in
            frame.insetBy(dx: -spacing / 2, dy: -spacing / 2).contains(location)
        }
    }

    /// The pane — and the side of it — a grip drag at `location` would drop
    /// onto. The side comes from the pointer's quadrant within the target
    /// pane, split along its diagonals: the nearest edge wins.
    static func splitPaneDropTarget(
        at location: CGPoint,
        in frames: [CGRect],
        spacing: CGFloat
    ) -> (index: Int, side: SplitTabDropSide)? {
        guard let index = splitPaneIndex(at: location, in: frames, spacing: spacing) else { return nil }
        let frame = frames[index]
        guard frame.width > 0, frame.height > 0 else { return (index, .trailing) }
        let dx = (location.x - frame.midX) / frame.width
        let dy = (location.y - frame.midY) / frame.height
        let side: SplitTabDropSide = abs(dx) >= abs(dy)
            ? (dx < 0 ? .leading : .trailing)
            : (dy < 0 ? .top : .bottom)
        return (index, side)
    }


    /// Divider handles between adjacent panes. Only the linear layouts
    /// resize — grid cells stay equal, so the grid draws no dividers.
    @ViewBuilder
    private func splitDividers(
        layout: SplitViewLayout,
        frames: [CGRect],
        spacing: CGFloat,
        in size: CGSize
    ) -> some View {
        if layout != .grid {
            let lengths = frames.map { layout == .vertical ? $0.height : $0.width }
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
            .background(CandoaInterfaceStyle.surfaceFill.opacity(0.72))
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

private struct SplitPaneGripCursorSurface: NSViewRepresentable {
    let isDragging: Bool

    func makeNSView(context: Context) -> SplitPaneGripCursorView {
        SplitPaneGripCursorView()
    }

    func updateNSView(_ view: SplitPaneGripCursorView, context: Context) {
        view.isDragging = isDragging
    }
}

/// Owns the grab cursor for the grip region. SwiftUI hover, pointer
/// styles, and plain `NSCursor` pushes all fail here (verified 2026-08-03):
/// hover attribution dies at the WKWebView platform island the pill floats
/// over, and WebKit re-asserts the page cursor from its own tracking areas
/// on every pointer move. So this view watches moves with a local monitor
/// and re-asserts the grab cursor one runloop turn later — after the
/// event's normal dispatch, where WebKit set its cursor — which reliably
/// wins without touching WebKit. Hit testing passes through: the cursor is
/// this view's only job, clicks and drags belong to the SwiftUI grip.
private final class SplitPaneGripCursorView: NSView {
    var isDragging = false {
        didSet {
            guard isDragging != oldValue else { return }
            if isDragging {
                assertCursor(.closedHand)
            } else if isPointerInside {
                assertCursor(.openHand)
            }
        }
    }

    private var monitor: Any?
    private var isPointerInside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            // Local event monitors always run on the main thread.
            MainActor.assumeIsolated {
                self?.handlePointerEvent(event)
            }
            return event
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handlePointerEvent(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        if isDragging {
            assertCursor(.closedHand)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.contains(location)
        // Leaving needs no reset: WebKit already set the page cursor while
        // dispatching this same event, and nothing re-asserts ours.
        guard isPointerInside else { return }
        assertCursor(.openHand)
    }

    private func assertCursor(_ cursor: NSCursor) {
        DispatchQueue.main.async {
            cursor.set()
        }
    }
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
                        ? CandoaColor.accent.opacity(0.85)
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
        .candoaAISidebarCursor(
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
    /// The pointer is inside the pane (reported by the pane host's tracking
    /// area) — the discoverable way the pill reveals itself.
    let isPaneHovered: Bool
    let isDraggingThisPane: Bool
    let showsReorderGrip: Bool
    let paneIndex: Int
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onUnsplit: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var isProminent: Bool {
        isPaneHovered || isHovering || isDraggingThisPane
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsReorderGrip {
                gripDots
                    .frame(width: 34, height: 20)
                    .contentShape(Rectangle())
                    // Grabbable, so it gets the native grab cursors; the
                    // pill's buttons keep the arrow like any macOS button.
                    .background(SplitPaneGripCursorSurface(isDragging: isDraggingThisPane))
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
            }

            Button(action: onUnsplit) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 20)
                    .contentShape(Rectangle())
            }
            .candoaButton(.content)
            .foregroundStyle(.secondary)
            .help("Unsplit — Open as Full Tab")
            .accessibilityLabel("Unsplit")
            .accessibilityIdentifier("split-pane-unsplit-\(paneIndex)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 20)
                    .contentShape(Rectangle())
            }
            .candoaButton(.content)
            .foregroundStyle(.secondary)
            .help("Close Tab")
            .accessibilityLabel("Close Tab")
            .accessibilityIdentifier("split-pane-close-\(paneIndex)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
        }
        // Revealed by pointer presence only: the pane host's tracking area
        // reports hover dependably even over web content (which swallows
        // SwiftUI hover), so the pill stays hidden until the pointer is
        // inside its pane or a drag is in flight. Hit testing stays on
        // while hidden: the pointer reaching the pill has already entered
        // the pane and revealed it, so an invisible click target never
        // happens live. Full transparency also prunes the buttons from the
        // accessibility tree, so UI-test runs keep a trace opacity —
        // synthetic hovers lose races against real pointer motion, and the
        // tests must still be able to address the pill.
        .opacity(isProminent ? 1 : (BrowserStore.isUITesting ? 0.02 : 0))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isProminent)
    }

    private var gripDots: some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(
                                isDraggingThisPane
                                    ? CandoaColor.accent
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
                        .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
                        .padding(.vertical, surfacePadding)
                        .padding(.leading, leadingInset + surfacePadding)
                        .padding(.trailing, trailingInset + trailingSurfacePadding)
                        .allowsHitTesting(false)
                } else {
                    // Split panes own their individual borders. Add only sides
                    // introduced by this mask so shared edges are not repainted.
                    if leadingInset > 0 {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
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
                            .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
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

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        return dropTarget(for: info, draggedID: draggedID) != nil
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
        let fractionX = info.location.x / max(size.width, 1)
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

private struct SplitDropPreviewOverlay: View {
    @ObservedObject var store: BrowserStore
    let preview: SplitTabDropPreview
    let cornerRadius: CGFloat

    private var previewTabs: [BrowserTab] {
        guard
            let draggedID = store.draggedTabID,
            let draggedTab = store.visibleTabsForActiveSpace.first(where: { $0.id == draggedID }),
            let targetTab = store.visibleTabsForActiveSpace.first(where: { $0.id == preview.targetTabID })
        else {
            return []
        }

        var tabs = store.isSplitViewDisplayed
            ? store.displayedSplitTabs
            : [targetTab]
        tabs.removeAll { $0.id == draggedID }

        let targetIndex = tabs.firstIndex { $0.id == preview.targetTabID } ?? tabs.startIndex
        let insertionIndex = preview.side.insertsBeforeTarget
            ? targetIndex
            : tabs.index(after: targetIndex)
        tabs.insert(draggedTab, at: insertionIndex)
        return Array(tabs.prefix(BrowserStore.splitViewMaxTabs))
    }

    /// The arrangement the drop would produce: a displayed split keeps its
    /// layout, a fresh split takes its axis from the drop edge (Zen-style).
    private var previewLayout: SplitViewLayout {
        store.isSplitViewDisplayed
            ? store.splitLayout
            : (preview.side.isVerticalAxis ? .vertical : .horizontal)
    }

    var body: some View {
        GeometryReader { proxy in
            let tabs = previewTabs
            let frames = WebViewContainer.splitPaneFrames(
                layout: previewLayout,
                ratios: BrowserStore.equalPaneRatios(forPaneCount: tabs.count),
                in: proxy.size,
                spacing: 8
            )

            ZStack(alignment: .topLeading) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    if frames.indices.contains(index) {
                        SplitDropPreviewPane(tab: tab, isDragged: tab.id == store.draggedTabID)
                            .frame(width: frames[index].width, height: frames[index].height)
                            .offset(x: frames[index].minX, y: frames[index].minY)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct SplitDropPreviewPane: View {
    let tab: BrowserTab
    let isDragged: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isDragged ? 0.11 : 0.065))
                .overlay {
                    Image(systemName: isDragged ? "rectangle.split.2x1.fill" : "globe")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(isDragged ? 0.32 : 0.18))
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    Image(systemName: tab.faviconSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isDragged ? CandoaColor.accent : .secondary)

                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(isDragged ? 0.82 : 0.62))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isDragged ? CandoaColor.accent.opacity(0.62) : Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(isDragged ? 0.16 : 0.08), radius: isDragged ? 12 : 6, x: 0, y: 3)
    }
}

/// Native developer toolbar shown for local development pages. It remains
/// neutral chrome so Space identity colors stay in the passive content layer.
private struct DeveloperToolbar: View {
    let url: URL
    let urlText: String
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
    @AppStorage(Self.storageKey) private var storedControlIDs = ""
    @FocusState private var isURLFieldFocused: Bool

    private var foreground: Color { CandoaInterfaceStyle.sidebarText }

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
                .tint(CandoaColor.accent)
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
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CandoaInterfaceStyle.sidebarSeparator)
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
        .candoaButton(.content)
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
        case .easel, .developerTools, .inspectElement, .extensions:
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
        guard let port = url?.port else { return "Default" }
        return String(port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hostText, systemImage: "info.circle")
                .font(.headline)

            Divider()

            DeveloperSiteInfoRow(title: "Address", value: urlText)
            DeveloperSiteInfoRow(title: "Scheme", value: schemeText)
            DeveloperSiteInfoRow(title: "Port", value: portText)

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
        case .easel, .developerTools, .inspectElement, .extensions:
            return false
        }
    }

    func title(isSplitViewEnabled: Bool) -> String {
        switch self {
        case .copyURL:
            return "Copy Link"
        case .easel:
            return "Capture to Easel"
        case .capturePage:
            return "Capture Page"
        case .developerTools:
            return "Developer Tools"
        case .siteInfo:
            return "Site Info"
        case .inspectElement:
            return "Inspect Element"
        case .extensions:
            return "Extensions"
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
            return "Set in Settings > Shortcuts"
        case .splitView:
            // Reflect the person's configured shortcuts, not the defaults.
            let addCaps = ShortcutKeyCaps.current(for: .addSplitView).joined()
            let closeCaps = ShortcutKeyCaps.current(for: .closeSplitView).joined()
            let parts = [addCaps, closeCaps].filter { !$0.isEmpty }
            return parts.isEmpty ? "Set in Settings > Shortcuts" : parts.joined(separator: " / ")
        case .easel, .developerTools, .siteInfo, .inspectElement, .extensions:
            return "Not implemented in Candoa yet"
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
            .fill(CandoaInterfaceStyle.workspaceBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
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
            shape.stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
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
            return CandoaInterfaceStyle.workspaceBackground
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
