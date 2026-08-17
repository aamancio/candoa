import AppKit
import Foundation

/// How a split group arranges its panes. Two arrangements only: a row of
/// side-by-side panes or a column of stacked ones. (A grid layout existed
/// once; persisted or synced "grid" values fall back to horizontal via the
/// failable rawValue decode.)
enum SplitViewLayout: String, Codable {
    /// Side-by-side columns — the default.
    case horizontal
    /// Stacked rows.
    case vertical
}

/// A Space's split group, stashed while another Space is frontmost so the
/// split survives switching away and back.
struct SuspendedSplitState {
    var tabIDs: [UUID]
    var paneRatios: [Double]
    var layout: SplitViewLayout
}

extension BrowserStore {
    /// A split group exists (isSplitViewEnabled) *and* the active tab is one
    /// of its members, so the group is on screen as side-by-side panes.
    /// While the active tab is outside the group, the split is suspended:
    /// membership persists (and shows in the sidebar pill) but the content
    /// area shows the active tab alone.
    var isSplitViewDisplayed: Bool {
        guard let activeTabID else { return false }
        let groupIDs = splitGroupTabIDs()
        return groupIDs.count >= 2 && groupIDs.contains(activeTabID)
    }

    func toggleSplitView() {
        if isSplitViewDisplayed {
            closeSplitView()
            return
        }

        // Arc-style: the new pane opens empty with the command bar focused
        // rather than guessing a tab to put there. A split is a place to put
        // something, and the guess was wrong often enough to be a step
        // backwards — dropping a tab in still names its own pane.
        guard let previousActiveID = activeTabID else { return }
        openSplitView(with: nil)

        guard
            isSplitViewDisplayed,
            let blankID = splitGroupTabIDs().last,
            blankID != previousActiveID
        else {
            return
        }

        applySplitGroup(splitGroupTabIDs(), activeID: blankID)
        updateNavigationState()
        openCommandPaletteForActivePane()
    }

    func openSplitView(with tabID: UUID?) {
        guard let activeTabID else { return }
        let candidateID = tabID == activeTabID ? replacementSplitTab(excluding: activeTabID)?.id : tabID
        // Splitting with a global favorite recorded under another Space first
        // brings it into this Space, the same as activating it would.
        if let candidateID,
           let candidateIndex = tabs.firstIndex(where: { $0.id == candidateID }),
           tabs[candidateIndex].isFavorite {
            reparentTabToActiveSpaceIfNeeded(at: candidateIndex)
        }
        // A suspended group does not absorb the active tab: starting a split
        // from outside it replaces it (one split per Space).
        var groupIDs = isSplitViewDisplayed ? splitGroupTabIDs() : [activeTabID]

        if let candidateID, tabs.contains(where: { $0.id == candidateID && $0.spaceID == activeSpaceID }) {
            if !groupIDs.contains(candidateID) {
                groupIDs.append(candidateID)
            }
        } else {
            let tab = newInternalBlankTab(in: activeSpaceID)
            self.activeTabID = activeTabID
            groupIDs.append(tab.id)
        }

        if !groupIDs.contains(activeTabID) {
            groupIDs.insert(activeTabID, at: 0)
        }
        applySplitGroup(groupIDs, activeID: activeTabID)
        updateNavigationState()
    }

    func splitTab(_ draggedID: UUID, onto targetID: UUID, side: SplitTabDropSide = .leading) {
        guard
            draggedID != targetID,
            let draggedTab = tabs.first(where: { $0.id == draggedID }),
            let targetTab = tabs.first(where: { $0.id == targetID }),
            draggedTab.spaceID == targetTab.spaceID
        else {
            return
        }

        activeSpaceID = targetTab.spaceID
        var groupIDs: [UUID]
        if isSplitViewDisplayed, splitGroupTabIDs().contains(targetID) {
            // Joining a displayed split keeps its current layout; the edge
            // only picks which end the tab enters at.
            let existingGroupIDs = splitGroupTabIDs()
            guard existingGroupIDs.contains(draggedID) || existingGroupIDs.count < Self.splitViewMaxTabs else { return }
            groupIDs = Self.insertingSplitTab(draggedID, beside: targetID, side: side, in: existingGroupIDs)
        } else {
            // A fresh split takes its axis from the drop edge, Zen-style:
            // top/bottom stacks rows, leading/trailing makes columns.
            groupIDs = side.insertsBeforeTarget ? [draggedID, targetID] : [targetID, draggedID]
            splitLayout = side.isVerticalAxis ? .vertical : .horizontal
        }

        applySplitGroup(groupIDs, activeID: draggedID)
        updateNavigationState()
    }

    func focusSplitTab(_ id: UUID) {
        guard isSplitViewEnabled, activeSplitGroupTabIDs.contains(id), let activeTabID, activeTabID != id else {
            switchTab(to: id)
            return
        }

        let groupIDs = splitGroupTabIDs()
        applySplitGroup(groupIDs, activeID: id)
        updateNavigationState()
    }

    func closeSplitView() {
        isSplitViewEnabled = false
        splitTabIDs = []
        splitPaneRatios = []
        splitLayout = .horizontal
        isSplitPaneZoomRequested = false
    }

    // MARK: - Pane zoom

    /// The pane currently filling the surface on its own, or nil while every
    /// pane is on screen.
    ///
    /// Zoom is a flag on the lane, not a tab id: it means "the focused pane
    /// has the surface", so wherever focus goes the zoom follows. That is
    /// what lets Focus Next Pane page through a zoomed split, and it closes
    /// the trap where a chip click or Control-Tab could hand focus to a pane
    /// the zoom was hiding. Computed, never stored as an id: a suspended
    /// group (active tab outside it) reads as not zoomed, and browsing back
    /// to a member finds the pane still zoomed, the way pane ratios survive
    /// the same trip.
    var zoomedSplitTabID: UUID? {
        guard
            isSplitPaneZoomRequested,
            isSplitViewDisplayed,
            let activeTabID,
            splitGroupTabIDs().contains(activeTabID)
        else {
            return nil
        }
        return activeTabID
    }

    var isSplitPaneZoomed: Bool {
        zoomedSplitTabID != nil
    }

    /// Fills the surface with the focused pane, or restores the split when a
    /// pane already has it. Same command both ways: the gesture that zooms in
    /// is the gesture that gets you back, which is what makes the mode safe to
    /// enter. Escape is deliberately not bound — it is already stacked behind
    /// Reader and the find bar.
    func toggleSplitPaneZoom() {
        if isSplitPaneZoomed {
            isSplitPaneZoomRequested = false
            return
        }
        guard let activeTabID, isSplitViewDisplayed, splitGroupTabIDs().contains(activeTabID) else { return }
        isSplitPaneZoomRequested = true
    }

    /// Zooms a named pane (the pane pill's own button). The pane takes focus
    /// on the way in, since it is about to be the only one on screen.
    func zoomSplitPane(_ id: UUID) {
        guard isSplitViewDisplayed, splitGroupTabIDs().contains(id) else { return }
        if activeTabID != id {
            focusSplitTab(id)
        }
        isSplitPaneZoomRequested = true
    }

    /// Drops the zoom whenever the group's membership changes, so a zoomed
    /// pane can never hide a pane the person just added — dropping a tab into
    /// a zoomed split would otherwise land it somewhere invisible. Reordering
    /// and resizing keep the zoom; only who is in the group matters.
    func pruneSplitPaneZoom(previousIDs: [UUID], currentIDs: [UUID]) {
        guard isSplitPaneZoomRequested, previousIDs != currentIDs else { return }
        isSplitPaneZoomRequested = false
    }

    // MARK: - Pane focus

    /// Moves focus to the neighbouring pane in layout order, wrapping at the
    /// ends. Panes are ordinary tabs so Next Tab already reaches them, but
    /// it walks every other tab in the Space on the way; this is the
    /// pane-only step a keyboard-driven split needs. With a pane zoomed the
    /// zoom follows focus, so the same key pages through the group at full
    /// size.
    func focusAdjacentSplitPane(offset: Int) {
        guard isSplitViewDisplayed, let activeTabID else { return }
        let groupIDs = splitGroupTabIDs()
        guard let currentIndex = groupIDs.firstIndex(of: activeTabID), groupIDs.count >= 2 else { return }
        let nextIndex = (currentIndex + offset + groupIDs.count) % groupIDs.count
        focusSplitTab(groupIDs[nextIndex])
    }

    /// The keyboard form of the pill's Unsplit: the focused pane leaves the
    /// group and keeps the surface as an ordinary tab.
    func unsplitFocusedPane() {
        guard isSplitViewDisplayed, let activeTabID, splitGroupTabIDs().contains(activeTabID) else { return }
        removeTabFromSplit(activeTabID, focusRemovedTab: true)
    }

    /// Switches the displayed split between side-by-side and stacked
    /// arrangements. Pane order and membership are untouched; the linear
    /// ratios carry over between horizontal and vertical.
    func setSplitLayout(_ layout: SplitViewLayout) {
        guard splitTabIDs.count >= 2, splitLayout != layout else { return }
        splitLayout = layout
    }

    /// Reorders the displayed panes (a pane-handle drag): the pane at
    /// `sourceIndex` moves to `targetIndex`, its width/height ratio riding
    /// along with it.
    func moveSplitPane(from sourceIndex: Int, to targetIndex: Int) {
        var orderedIDs = splitGroupTabIDs()
        var ratios = splitPaneRatios(forPaneCount: orderedIDs.count)
        guard
            sourceIndex != targetIndex,
            orderedIDs.indices.contains(sourceIndex),
            orderedIDs.indices.contains(targetIndex)
        else { return }

        let movedID = orderedIDs.remove(at: sourceIndex)
        orderedIDs.insert(movedID, at: targetIndex)
        let movedRatio = ratios.remove(at: sourceIndex)
        ratios.insert(movedRatio, at: targetIndex)
        splitTabIDs = orderedIDs
        splitPaneRatios = ratios
    }

    /// Zen-style edge drop for a pane-handle drag: releasing on a pane's
    /// top/bottom band stacks the row into a column (and the
    /// leading/trailing bands lay it back into a row), with the dragged
    /// pane landing on that side of the target. Dropping on the source
    /// pane's own edge only changes the arrangement.
    func moveSplitPane(from sourceIndex: Int, toEdge side: SplitTabDropSide, of targetIndex: Int) {
        var orderedIDs = splitGroupTabIDs()
        var ratios = splitPaneRatios(forPaneCount: orderedIDs.count)
        guard
            orderedIDs.indices.contains(sourceIndex),
            orderedIDs.indices.contains(targetIndex)
        else { return }

        setSplitLayout(side.isVerticalAxis ? .vertical : .horizontal)
        guard sourceIndex != targetIndex else { return }

        let movedID = orderedIDs[sourceIndex]
        let targetID = orderedIDs[targetIndex]
        let movedRatio = ratios[sourceIndex]
        orderedIDs.remove(at: sourceIndex)
        ratios.remove(at: sourceIndex)
        guard let anchorIndex = orderedIDs.firstIndex(of: targetID) else { return }
        let insertionIndex = side.insertsBeforeTarget ? anchorIndex : anchorIndex + 1
        orderedIDs.insert(movedID, at: insertionIndex)
        ratios.insert(movedRatio, at: insertionIndex)
        splitTabIDs = orderedIDs
        splitPaneRatios = ratios
    }

    /// Takes one tab out of the split group without closing it: the tab
    /// returns to its ordinary sidebar row, and the remaining panes keep the
    /// split (or the split dissolves once fewer than two members remain).
    func removeTabFromSplit(_ id: UUID, focusRemovedTab: Bool = false) {
        let groupIDs = splitGroupTabIDs()
        guard groupIDs.contains(id) else { return }
        let remainingIDs = groupIDs.filter { $0 != id }
        if focusRemovedTab {
            // The pane pill's unsplit reads as "expand this pane": the
            // clicked pane's page must keep the surface, so the removed tab
            // takes focus and any surviving group suspends behind it.
            applySplitGroup(remainingIDs, activeID: nil)
            activeTabID = id
        } else {
            let nextActiveID = activeTabID == id ? remainingIDs.first : activeTabID
            applySplitGroup(remainingIDs, activeID: nextActiveID)
        }
        updateNavigationState()
    }

    /// Stashes the current Space's split group so it can be revived when the
    /// Space becomes frontmost again. Split state is Space-local; the window
    /// state only ever carries the frontmost Space's group.
    func suspendSplitState(for spaceID: UUID) {
        suspendedSplitStatesBySpace[spaceID] = splitTabIDs.count >= 2
            ? SuspendedSplitState(tabIDs: splitTabIDs, paneRatios: splitPaneRatios, layout: splitLayout)
            : nil
        splitTabIDs = []
        splitPaneRatios = []
        splitLayout = .horizontal
        isSplitViewEnabled = false
        // A Space switch tears the group down and rebuilds it on return.
        // Ratios and layout ride along in the suspended state; the zoom does
        // not — coming back to a Space should show the split you left it as.
        isSplitPaneZoomRequested = false
    }

    func restoreSplitState(for spaceID: UUID) {
        guard let suspendedState = suspendedSplitStatesBySpace.removeValue(forKey: spaceID) else { return }
        let validIDs = suspendedState.tabIDs.filter { id in
            tabs.contains { $0.id == id && $0.spaceID == spaceID }
        }
        guard validIDs.count >= 2 else { return }
        splitTabIDs = validIDs
        splitPaneRatios = Self.paneRatios(
            for: validIDs,
            carriedFrom: suspendedState.tabIDs,
            previousRatios: suspendedState.paneRatios
        )
        splitLayout = suspendedState.layout
        isSplitViewEnabled = true
    }

    func reorderTabs(_ orderedIDs: [UUID], isFavorite: Bool, isPinned: Bool, folderID: UUID? = nil) {
        for (offset, id) in orderedIDs.enumerated() {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            let wasFavorite = tabs[index].isFavorite
            tabs[index].isFavorite = isFavorite
            tabs[index].isPinned = isPinned && !isFavorite
            tabs[index].folderID = isFavorite ? nil : folderID
            tabs[index].sortOrder = Double(offset)
            if isFavorite {
                if !wasFavorite || tabs[index].favoriteURL == nil {
                    captureFavoriteSnapshot(at: index)
                }
            } else if wasFavorite {
                clearFavoriteSnapshot(at: index)
            }
        }
    }

    func moveTabToPlacement(
        _ tabID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID? = nil,
        before targetID: UUID? = nil,
        appendToEnd: Bool = false
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        // Dragging a split member into any sidebar placement takes it out of
        // the group first — otherwise the drop only rewrites placement flags
        // and the tab silently stays a hidden split member.
        if splitTabIDs.contains(tabID) {
            removeTabFromSplit(tabID)
        }
        if !isFavorite, tabs[index].isFavorite {
            // Dragging a favorite out of the global grid drops it into the
            // Space on screen, never back into its recorded home Space.
            reparentTabToActiveSpaceIfNeeded(at: index)
        }
        let spaceID = tabs[index].spaceID
        let resolvedFolderID = isFavorite ? nil : folderID.flatMap { folderID in
            folders.contains(where: { $0.id == folderID && $0.spaceID == spaceID }) ? folderID : nil
        }
        let resolvedPinned = (isPinned || resolvedFolderID != nil) && !isFavorite
        let wasFavorite = tabs[index].isFavorite
        tabs[index].isFavorite = isFavorite
        tabs[index].isPinned = resolvedPinned
        tabs[index].folderID = resolvedFolderID
        if isFavorite {
            if !wasFavorite || tabs[index].favoriteURL == nil {
                captureFavoriteSnapshot(at: index)
            }
        } else if wasFavorite {
            clearFavoriteSnapshot(at: index)
        }

        // Favorites form one global bucket; every other placement is scoped
        // to the tab's Space.
        let matchesBucket: (BrowserTab) -> Bool = { tab in
            guard tab.isFavorite == isFavorite else { return false }
            if isFavorite { return true }
            return tab.spaceID == spaceID &&
                tab.isPinned == resolvedPinned &&
                tab.folderID == resolvedFolderID
        }

        guard let targetID,
              tabs.contains(where: { $0.id == targetID && matchesBucket($0) })
        else {
            tabs[index].sortOrder = appendToEnd
                ? lastSortOrder(
                    spaceID: spaceID,
                    isFavorite: isFavorite,
                    isPinned: resolvedPinned,
                    folderID: resolvedFolderID
                )
                : nextSortOrder(
                    spaceID: spaceID,
                    isFavorite: isFavorite,
                    isPinned: resolvedPinned,
                    folderID: resolvedFolderID
                )
            normalizeSortOrder()
            return
        }

        var orderedIDs = tabs
            .filter(matchesBucket)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)

        orderedIDs.removeAll { $0 == tabID }
        let targetIndex = orderedIDs.firstIndex(of: targetID) ?? orderedIDs.endIndex
        orderedIDs.insert(tabID, at: targetIndex)
        reorderTabs(orderedIDs, isFavorite: isFavorite, isPinned: resolvedPinned, folderID: resolvedFolderID)
    }

    func beginTabDrag(_ tabID: UUID) -> NSItemProvider {
        dropSourceClearTask?.cancel()
        dropSourceClearTask = nil
        draggedTabID = tabID
        clearSidebarDropIndicator()
        clearSplitDropPreview()
        startTabDragSessionWatcher(for: tabID)
        return NSItemProvider(object: tabID.uuidString as NSString)
    }

    func sidebarPlacement(for tabID: UUID) -> SidebarTabDropPlacement? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        if tab.isFavorite { return .favorites }
        if let folderID = tab.folderID { return .folder(folderID) }
        if tab.isPinned { return .pinned }
        return .regular
    }

    func updateSidebarDropIndicator(
        placement: SidebarTabDropPlacement,
        targetTabID: UUID?,
        edge: SidebarTabDropEdge
    ) {
        let indicator = SidebarTabDropIndicator(
            placement: placement,
            targetTabID: targetTabID,
            edge: edge
        )
        guard sidebarDropIndicator != indicator else { return }
        sidebarDropIndicator = indicator
    }

    func clearSidebarDropIndicator() {
        guard sidebarDropIndicator != nil else { return }
        sidebarDropIndicator = nil
    }

    func splitDropTargetTabID(for side: SplitTabDropSide, draggedID: UUID) -> UUID? {
        guard let activeTabID else { return nil }
        let groupIDs = splitGroupTabIDs()
        let candidateID: UUID?

        if isSplitViewDisplayed {
            if !groupIDs.contains(draggedID), groupIDs.count >= Self.splitViewMaxTabs {
                return nil
            }

            let orderedIDs = side.insertsBeforeTarget ? groupIDs : groupIDs.reversed()
            candidateID = orderedIDs.first { $0 != draggedID }
        } else {
            candidateID = activeTabID == draggedID ? nil : activeTabID
        }

        guard
            let candidateID,
            tabs.contains(where: { $0.id == candidateID && $0.spaceID == activeSpaceID })
        else {
            return nil
        }
        return candidateID
    }

    func updateSplitDropPreview(targetTabID: UUID, side: SplitTabDropSide) {
        let preview = SplitTabDropPreview(targetTabID: targetTabID, side: side)
        guard splitDropPreview != preview else { return }
        splitDropPreview = preview
    }

    func clearSplitDropPreview() {
        guard splitDropPreview != nil else { return }
        splitDropPreview = nil
    }

    func finishTabDrag() {
        draggedTabID = nil
        clearSidebarDropIndicator()
        clearSplitDropPreview()
        tabDragSessionWatcher?.invalidate()
        tabDragSessionWatcher = nil
        dropSourceClearTask?.cancel()
        dropSourceClearTask = nil
    }

    func finishTabDrop(
        _ tabID: UUID,
        from sourcePlacement: SidebarTabDropPlacement?,
        to destinationPlacement: SidebarTabDropPlacement
    ) {
        draggedTabID = nil
        clearSidebarDropIndicator()
        clearSplitDropPreview()
        tabDragSessionWatcher?.invalidate()
        tabDragSessionWatcher = nil

        dropSourceClearTask?.cancel()
        dropSourceClearTask = nil
    }

    // SwiftUI's onDrag exposes no end-of-session signal, and a drag released
    // over the web view or outside the window never reaches a drop delegate —
    // draggedTabID would stay stale, keeping the source row hidden and letting
    // unrelated text drags trigger ghost reorders. The mouse button is the
    // only reliable signal, so watch it while — and only while — a tab drag
    // is in flight; the watcher tears itself down on release.
    func startTabDragSessionWatcher(for tabID: UUID) {
        tabDragSessionWatcher?.invalidate()
        let watcher = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard self.draggedTabID == tabID else {
                    self.tabDragSessionWatcher?.invalidate()
                    self.tabDragSessionWatcher = nil
                    return
                }
                guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
                self.tabDragSessionWatcher?.invalidate()
                self.tabDragSessionWatcher = nil
                // System drag sessions can report the mouse as no longer
                // pressed while SwiftUI is still delivering drop target
                // updates. Keep the source row hidden if a sidebar target is
                // still active, otherwise clear truly abandoned drags.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.draggedTabID == tabID else { return }
                        if self.sidebarDropIndicator != nil || self.splitDropPreview != nil {
                            self.startTabDragSessionWatcher(for: tabID)
                            return
                        }
                        self.finishTabDrag()
                    }
                }
            }
        }
        tabDragSessionWatcher = watcher
        // .common keeps the watcher firing inside the drag's event-tracking
        // runloop mode, where default-mode timers stall.
        RunLoop.main.add(watcher, forMode: .common)
    }

    func replacementSplitTab(excluding excludedID: UUID?) -> BrowserTab? {
        visibleTabsForActiveSpace.first { $0.id != excludedID }
    }

    func tab(_ id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id && $0.spaceID == activeSpaceID }
    }

    func splitGroupTabIDs() -> [UUID] {
        // Membership does not depend on the active tab: the group persists
        // while the active tab is outside it (the suspended split state).
        // Legacy sessions that stored only the non-active members are
        // normalized once at restore time (validSplitGroupIDs).
        guard isSplitViewEnabled else { return [] }

        var seen = Set<UUID>()
        return splitTabIDs
            .filter { id in
                guard !seen.contains(id), tab(id) != nil else { return false }
                seen.insert(id)
                return true
            }
            .prefix(Self.splitViewMaxTabs)
            .map { $0 }
    }

    func applySplitGroup(_ ids: [UUID], activeID: UUID?) {
        var seen = Set<UUID>()
        let validIDs = ids
            .filter { id in
                guard !seen.contains(id), tab(id) != nil else { return false }
                seen.insert(id)
                return true
            }
            .prefix(Self.splitViewMaxTabs)
            .map { $0 }
        let previousIDs = splitTabIDs
        let previousRatios = splitPaneRatios
        pruneSplitPaneZoom(previousIDs: previousIDs, currentIDs: validIDs.count >= 2 ? validIDs : [])

        guard validIDs.count >= 2 else {
            splitTabIDs = []
            splitPaneRatios = []
            splitLayout = .horizontal
            isSplitViewEnabled = false
            // Focus only moves when the caller asked for a member or the
            // active tab is gone; dissolving a suspended group while browsing
            // another tab must not steal focus.
            if let activeID, validIDs.contains(activeID) {
                activeTabID = activeID
            } else if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID }) {
                activeTabID = validIDs.first
            }
            return
        }

        if let activeID, validIDs.contains(activeID) {
            activeTabID = activeID
        }
        splitTabIDs = validIDs
        splitPaneRatios = Self.paneRatios(for: validIDs, carriedFrom: previousIDs, previousRatios: previousRatios)
        isSplitViewEnabled = true
    }

    // MARK: - Pane ratios

    /// Commits the divider drag's resulting pane widths. Values are
    /// normalized so the persisted state always sums to 1.
    func commitSplitPaneRatios(_ ratios: [Double]) {
        guard ratios.count == splitTabIDs.count, splitTabIDs.count >= 2 else { return }
        splitPaneRatios = Self.normalizedPaneRatios(ratios, forPaneCount: ratios.count)
    }

    func resetSplitPaneRatios() {
        guard splitTabIDs.count >= 2 else { return }
        splitPaneRatios = Self.equalPaneRatios(forPaneCount: splitTabIDs.count)
    }

    /// The displayed panes' width fractions, always normalized and matched to
    /// `count` so layout never divides by a stale ratio list.
    func splitPaneRatios(forPaneCount count: Int) -> [Double] {
        Self.normalizedPaneRatios(splitPaneRatios, forPaneCount: count)
    }

    static func equalPaneRatios(forPaneCount count: Int) -> [Double] {
        guard count >= 2 else { return [] }
        return Array(repeating: 1 / Double(count), count: count)
    }

    static func normalizedPaneRatios(_ ratios: [Double], forPaneCount count: Int) -> [Double] {
        guard count >= 2 else { return [] }
        guard ratios.count == count, ratios.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return equalPaneRatios(forPaneCount: count)
        }
        let total = ratios.reduce(0, +)
        guard total > 0 else { return equalPaneRatios(forPaneCount: count) }
        return ratios.map { $0 / total }
    }

    /// Ratios for a changed member list: retained panes keep their widths,
    /// new panes join at the mean width, and the result is renormalized.
    static func paneRatios(
        for ids: [UUID],
        carriedFrom previousIDs: [UUID],
        previousRatios: [Double]
    ) -> [Double] {
        guard ids.count >= 2 else { return [] }
        guard previousIDs.count == previousRatios.count, !previousIDs.isEmpty else {
            return equalPaneRatios(forPaneCount: ids.count)
        }

        // The previous list can come straight from persisted data, so it may
        // contain duplicates; the first occurrence wins.
        let previousRatioByID = Dictionary(zip(previousIDs, previousRatios)) { first, _ in first }
        let joiningRatio = 1 / Double(ids.count)
        let carried = ids.map { previousRatioByID[$0] ?? joiningRatio }
        return normalizedPaneRatios(carried, forPaneCount: ids.count)
    }

    func newInternalBlankTab(in spaceID: UUID) -> BrowserTab {
        let tab = BrowserTab(
            spaceID: spaceID,
            sortOrder: nextSortOrder(spaceID: spaceID, isFavorite: false, isPinned: false, folderID: nil)
        )

        tabs.insert(tab, at: 0)
        switchTab(to: tab.id)
        return tab
    }

    static func insertingSplitTab(
        _ draggedID: UUID,
        beside targetID: UUID,
        side: SplitTabDropSide,
        in groupIDs: [UUID]
    ) -> [UUID] {
        var orderedIDs = groupIDs.filter { $0 != draggedID }
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else {
            return groupIDs
        }

        let insertionIndex = side.insertsBeforeTarget
            ? targetIndex
            : orderedIDs.index(after: targetIndex)
        orderedIDs.insert(draggedID, at: insertionIndex)
        return orderedIDs
    }

    static func validSplitGroupIDs(
        _ ids: [UUID],
        activeTabID: UUID?,
        activeSpaceID: UUID,
        tabs: [BrowserTab],
        includesActiveTabID: Bool
    ) -> [UUID] {
        var orderedIDs = ids
        if includesActiveTabID,
            let activeTabID,
            !orderedIDs.contains(activeTabID) {
            orderedIDs.insert(activeTabID, at: 0)
        }

        var seen = Set<UUID>()
        return orderedIDs
            .filter { id in
                guard !seen.contains(id) else { return false }
                guard tabs.contains(where: { $0.id == id && $0.spaceID == activeSpaceID }) else { return false }
                seen.insert(id)
                return true
            }
            .prefix(Self.splitViewMaxTabs)
            .map { $0 }
    }
}
