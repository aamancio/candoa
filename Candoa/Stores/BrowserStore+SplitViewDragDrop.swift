import AppKit
import Foundation

extension BrowserStore {
    func toggleSplitView() {
        if isSplitViewEnabled {
            isSplitViewEnabled = false
            splitTabIDs = []
            return
        }

        openSplitView(with: replacementSplitTab(excluding: activeTabID)?.id)
    }

    func openSplitView(with tabID: UUID?) {
        guard let activeTabID else { return }
        let candidateID = tabID == activeTabID ? replacementSplitTab(excluding: activeTabID)?.id : tabID
        var groupIDs = isSplitViewEnabled ? splitGroupTabIDs() : [activeTabID]

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
        if isSplitViewEnabled, splitGroupTabIDs().contains(targetID) {
            let existingGroupIDs = splitGroupTabIDs()
            guard existingGroupIDs.contains(draggedID) || existingGroupIDs.count < Self.splitViewMaxTabs else { return }
            groupIDs = Self.insertingSplitTab(draggedID, beside: targetID, side: side, in: existingGroupIDs)
        } else {
            groupIDs = side == .leading ? [draggedID, targetID] : [targetID, draggedID]
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

        guard let targetID,
              tabs.contains(where: {
                  $0.id == targetID &&
                  $0.spaceID == spaceID &&
                  $0.isFavorite == isFavorite &&
                  $0.isPinned == resolvedPinned &&
                  $0.folderID == resolvedFolderID
              })
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
            .filter {
                $0.spaceID == spaceID &&
                $0.isFavorite == isFavorite &&
                $0.isPinned == resolvedPinned &&
                $0.folderID == resolvedFolderID
            }
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
        settlingDroppedTabID = nil
        settlingDroppedTabSource = nil
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

    func shouldHideSidebarTab(_ tabID: UUID, placement: SidebarTabDropPlacement) -> Bool {
        if draggedTabID == tabID { return true }
        if settlingDroppedTabID == tabID { return true }
        return settlingDroppedTabSource == SidebarDroppedTabSource(tabID: tabID, placement: placement)
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

        if isSplitViewEnabled, groupIDs.count >= 2 {
            if !groupIDs.contains(draggedID), groupIDs.count >= Self.splitViewMaxTabs {
                return nil
            }

            let orderedIDs = side == .leading ? groupIDs : groupIDs.reversed()
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
        settlingDroppedTabID = nil
        settlingDroppedTabSource = nil
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

        let settledTabID = tabID
        let source = sourcePlacement == destinationPlacement
            ? nil
            : sourcePlacement.map { SidebarDroppedTabSource(tabID: tabID, placement: $0) }
        settlingDroppedTabID = settledTabID
        settlingDroppedTabSource = source
        dropSourceClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sidebarDropSettleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard
                    let self,
                    self.settlingDroppedTabID == settledTabID,
                    self.settlingDroppedTabSource == source
                else { return }
                self.settlingDroppedTabID = nil
                self.settlingDroppedTabSource = nil
                self.dropSourceClearTask = nil
            }
        }
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
        guard isSplitViewEnabled, let activeTabID else { return [] }

        var ids = splitTabIDs
        if !ids.contains(activeTabID) {
            // Older persisted sessions stored only the non-active split tabs.
            // Keep those sessions valid without letting focus reorder panes.
            ids.insert(activeTabID, at: 0)
        }

        var seen = Set<UUID>()
        return ids
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

        guard validIDs.count >= 2 else {
            if let activeID, validIDs.contains(activeID) {
                activeTabID = activeID
            } else if let firstID = validIDs.first {
                activeTabID = firstID
            }
            splitTabIDs = []
            isSplitViewEnabled = false
            return
        }

        let resolvedActiveID = activeID.flatMap { validIDs.contains($0) ? $0 : nil } ?? validIDs[0]
        activeTabID = resolvedActiveID
        splitTabIDs = validIDs
        isSplitViewEnabled = validIDs.count >= 2
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

        let insertionIndex = side == .leading
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
        if
            includesActiveTabID,
            let activeTabID,
            !orderedIDs.contains(activeTabID)
        {
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

