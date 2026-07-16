import Foundation

extension BrowserStore {
    func switchTab(to id: UUID) {
        switchTab(to: id, updatesAccessTime: true)
    }

    func switchTab(to id: UUID, updatesAccessTime: Bool) {
        guard tabs.contains(where: { $0.id == id }) else { return }

        // Switching to the floating player's own tab morphs the player back
        // into the page instead of swapping abruptly; the real switch lands
        // in finishMiniPlayerReturn once the morph completes. Ctrl-Tab
        // preview cycling keeps the instant swap — a morph per cycle step
        // would fight the switcher.
        if miniPlayerReturn == nil, floatingMiniPlayerTab?.id == id, !isTabSwitcherPresented {
            beginMiniPlayerReturn(tabID: id, updatesAccessTime: updatesAccessTime)
            return
        }

        if let returning = miniPlayerReturn {
            guard returning.tabID != id else { return }
            // A different switch interrupts the in-flight return; clearing
            // the context lets the player re-adopt its web view and float on.
            miniPlayerReturn = nil
        }

        performSwitchTab(to: id, updatesAccessTime: updatesAccessTime)
    }

    func performSwitchTab(to id: UUID, updatesAccessTime: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Any landed switch resolves the return morph's pending destination —
        // either the morph just finished or another switch interrupted it.
        pendingMiniPlayerReturnTabID = nil
        if updatesAccessTime {
            tabs[index].lastAccessedAt = Date()
        }
        let existingSplitGroupIDs = splitGroupTabIDs()
        activeSpaceID = tabs[index].spaceID
        activeTabID = id
        if existingSplitGroupIDs.contains(id) {
            applySplitGroup(existingSplitGroupIDs, activeID: id)
        } else if isSplitViewEnabled {
            closeSplitView()
        }
        updateNavigationState()
    }

    func switchSpace(to id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        activeSpaceID = id

        if let existingTab = tabs
            .filter({ $0.spaceID == id })
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first {
            activeTabID = existingTab.id
        } else {
            activeTabID = nil
        }

        closeSplitView()

        updateNavigationState()
    }

    func switchToNextTab() {
        switchTab(offset: 1)
    }

    func switchToPreviousTab() {
        switchTab(offset: -1)
    }

    func switchToNextRecentTab(keepsPreviewOpen: Bool = false) {
        switchTabInRecentOrder(offset: 1, keepsPreviewOpen: keepsPreviewOpen)
    }

    func switchToPreviousRecentTab(keepsPreviewOpen: Bool = false) {
        switchTabInRecentOrder(offset: -1, keepsPreviewOpen: keepsPreviewOpen)
    }

    func finishTabSwitcherInteraction() {
        // Releasing Control commits whatever the cycling selected. Until now
        // only the preview selection moved, so a held interaction never
        // switched tabs behind the overlay.
        let landedTabID = tabSwitcherSelectedTabID ?? activeTabID
        if let selectedTabID = tabSwitcherSelectedTabID, selectedTabID != activeTabID {
            switchTab(to: selectedTabID, updatesAccessTime: false)
        } else if pendingMiniPlayerReturnTabID != nil, pendingMiniPlayerReturnTabID != landedTabID {
            // Re-selecting the current tab while a return morph is still in
            // flight cancels that pending switch — the newest intent wins.
            pendingMiniPlayerReturnTabID = nil
        }

        // The interaction ends when Control lifts, not when the overlay's
        // fade does: stamp the landed tab as most recent now (the switch
        // itself may still be deferred behind the mini player's return
        // morph) and stop treating the frozen candidate list as live, so a
        // press during the fade starts a fresh toggle from the landed tab
        // instead of cycling deeper into the old list.
        isTabSwitcherCycling = false
        if let landedTabID, let index = tabs.firstIndex(where: { $0.id == landedTabID }) {
            tabs[index].lastAccessedAt = Date()
        }

        // Quick tap: Control was released before the preview appeared, so the
        // switch stays silent — just commit the interaction.
        if tabSwitcherShowWorkItem != nil {
            hideTabSwitcher()
            return
        }

        guard isTabSwitcherPresented else { return }

        tabSwitcherHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideTabSwitcher()
            }
        }
        tabSwitcherHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    func switchToNextSpace() {
        switchSpace(offset: 1)
    }

    func switchToPreviousSpace() {
        switchSpace(offset: -1)
    }

    func switchTab(offset: Int) {
        let visibleTabs = visibleTabsForActiveSpace
        guard !visibleTabs.isEmpty else { return }
        let currentIndex = visibleTabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        let nextIndex = (currentIndex + offset + visibleTabs.count) % visibleTabs.count
        switchTab(to: visibleTabs[nextIndex].id)
    }

    func switchTabInRecentOrder(offset: Int, keepsPreviewOpen: Bool) {
        // Control-Tab starts from most-recent order, so a quick press toggles
        // between the current tab and the previous tab. The list is frozen
        // while Control stays held so hold-to-cycle doesn't shift underneath
        // the selection; releasing Control ends the interaction even if the
        // overlay is still fading, so the next press re-freezes from the
        // just-committed recency order.
        let isFreshInteraction = !isTabSwitcherCycling || tabSwitcherCandidates.isEmpty
        if isFreshInteraction {
            isTabSwitcherCycling = true
            tabSwitcherCandidates = recentTabsForActiveSpace()
        }

        let recentTabs = tabSwitcherCandidates
        guard !recentTabs.isEmpty else { return }
        guard recentTabs.count > 1 else {
            presentTabSwitcher(
                candidates: recentTabs,
                selectedTabID: activeTabID,
                autoHide: !keepsPreviewOpen
            )
            return
        }

        // A fresh press while the return morph is still landing must cycle
        // from the morph's destination, not the not-yet-switched active tab.
        let currentSelectionID = (isFreshInteraction ? nil : tabSwitcherSelectedTabID)
            ?? pendingMiniPlayerReturnTabID
            ?? activeTabID
        let nextIndex: Int
        if let currentIndex = recentTabs.firstIndex(where: { $0.id == currentSelectionID }) {
            nextIndex = (currentIndex + offset + recentTabs.count) % recentTabs.count
        } else {
            // Active tab sits outside the top tabs: enter the list at the
            // nearest end instead of skipping past it.
            nextIndex = offset > 0 ? 0 : recentTabs.count - 1
        }
        let selectedTabID = recentTabs[nextIndex].id
        // While Control is held only the selection moves; the real switch
        // commits on release (finishTabSwitcherInteraction), so holding to
        // look at the preview never flips the page underneath. Callers
        // without a release event still switch immediately.
        if !keepsPreviewOpen {
            switchTab(to: selectedTabID, updatesAccessTime: false)
        }
        presentTabSwitcher(
            candidates: recentTabs,
            selectedTabID: selectedTabID,
            autoHide: !keepsPreviewOpen
        )
    }

    func presentTabSwitcher(
        candidates: [BrowserTab]? = nil,
        selectedTabID: UUID? = nil,
        autoHide: Bool = true
    ) {
        let selectedTabID = selectedTabID ?? activeTabID
        let previewTabs = tabSwitcherPreviewTabs(
            from: candidates ?? recentTabsForActiveSpace(),
            selectedTabID: selectedTabID
        )
        guard !previewTabs.isEmpty else {
            hideTabSwitcher()
            return
        }

        tabSwitcherHideWorkItem?.cancel()
        tabSwitcherTabs = previewTabs
        tabSwitcherSelectedTabID = selectedTabID ?? previewTabs.first?.id

        if isTabSwitcherPresented || autoHide {
            tabSwitcherShowWorkItem?.cancel()
            tabSwitcherShowWorkItem = nil
            isTabSwitcherPresented = true
        } else if tabSwitcherShowWorkItem == nil {
            // Hold-to-reveal: defer the overlay so a quick Control-Tab stays a
            // silent switch. Repeated presses keep the original deadline.
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.tabSwitcherShowWorkItem = nil
                    self.isTabSwitcherPresented = true
                }
            }
            tabSwitcherShowWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + TabSwitcherConfiguration.holdRevealDelay,
                execute: workItem
            )
        }

        guard autoHide else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideTabSwitcher()
            }
        }
        tabSwitcherHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: workItem)
    }

    func hideTabSwitcher() {
        tabSwitcherHideWorkItem?.cancel()
        tabSwitcherHideWorkItem = nil
        tabSwitcherShowWorkItem?.cancel()
        tabSwitcherShowWorkItem = nil
        isTabSwitcherPresented = false
        tabSwitcherCandidates = []
        tabSwitcherSelectedTabID = nil

        // Flows without a Control-release event (auto-hide) end their
        // interaction here: commit the access time the cycling deferred.
        // Control-release flows already stamped the landed tab in
        // finishTabSwitcherInteraction — stamping again here would hit the
        // old tab when the switch is deferred behind the return morph.
        if isTabSwitcherCycling, let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs[index].lastAccessedAt = Date()
        }
        isTabSwitcherCycling = false
    }

    func recentTabsForActiveSpace() -> [BrowserTab] {
        var candidates = tabs.filter {
            $0.spaceID == activeSpaceID && $0.hasBeenActivated
        }

        if scopesControlTabToCurrentGroup, let activeTab {
            candidates = candidates.filter { tab in
                activeTab.isFavorite ? tab.isFavorite : !tab.isFavorite
            }
        }

        if ignoresPendingTabsWhenCycling {
            candidates = candidates.filter { !isPendingTabForControlTab($0) }
        }

        return candidates
            .sorted {
                if $0.lastAccessedAt == $1.lastAccessedAt {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.lastAccessedAt > $1.lastAccessedAt
            }
    }

    func markActiveTabAsActivated() {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        tabs[index].hasBeenActivated = true
    }

    func isPendingTabForControlTab(_ tab: BrowserTab) -> Bool {
        tab.url == nil || tab.isLoading || !webCoordinator.hasLoadedWebView(for: tab.id)
    }

    func tabSwitcherPreviewTabs(from candidates: [BrowserTab], selectedTabID: UUID?) -> [BrowserTab] {
        var previewTabs = Array(candidates.prefix(TabSwitcherConfiguration.previewLimit))
        guard
            let selectedTabID,
            !previewTabs.contains(where: { $0.id == selectedTabID }),
            let selectedTab = candidates.first(where: { $0.id == selectedTabID })
        else {
            return previewTabs
        }

        if previewTabs.count == TabSwitcherConfiguration.previewLimit {
            previewTabs[previewTabs.count - 1] = selectedTab
        } else {
            previewTabs.append(selectedTab)
        }

        return previewTabs
    }
}

