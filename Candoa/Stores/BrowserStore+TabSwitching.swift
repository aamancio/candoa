import AppKit
import Foundation

extension BrowserStore {
    func switchTab(to id: UUID) {
        switchTab(to: id, updatesAccessTime: true)
    }

    func switchTab(to id: UUID, updatesAccessTime: Bool) {
        guard tabs.contains(where: { $0.id == id }) else { return }

        // Switching to the floating player's own tab morphs the player back
        // into the page instead of swapping abruptly; the real switch lands
        // in finishMiniPlayerReturn once the morph completes. The Ctrl-Tab
        // switcher's release commit keeps the instant swap — a morph landing
        // under the dismissing overlay would fight the switcher.
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
        hoveredLinkHref = nil
        if updatesAccessTime {
            tabs[index].lastAccessedAt = Date()
        }
        // Favorites are global: activating one recorded under another Space
        // pulls the tab into the current Space instead of switching Spaces.
        if tabs[index].isFavorite, tabs[index].spaceID != activeSpaceID {
            reparentTabToActiveSpaceIfNeeded(at: index)
        }
        let previousSpaceID = activeSpaceID
        let nextSpaceID = tabs[index].spaceID
        if previousSpaceID != nextSpaceID {
            suspendSplitState(for: previousSpaceID)
        }
        activeSpaceID = nextSpaceID
        if previousSpaceID != nextSpaceID {
            restoreSplitState(for: nextSpaceID)
        }
        activeTabID = id
        let existingSplitGroupIDs = splitGroupTabIDs()
        if existingSplitGroupIDs.contains(id) {
            applySplitGroup(existingSplitGroupIDs, activeID: id)
        }
        // Switching to a non-member tab leaves the split group intact but
        // suspended: the sidebar pill stays, and focusing any member brings
        // the panes back. Leaving a split for good is an explicit action
        // (Close Split View / removing panes).
        updateNavigationState()
    }

    func switchSpace(to id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        let previousSpaceID = activeSpaceID
        if previousSpaceID != id {
            suspendSplitState(for: previousSpaceID)
        }
        activeSpaceID = id
        hoveredLinkHref = nil
        if previousSpaceID != id {
            restoreSplitState(for: id)
        }

        if let existingTab = tabs
            .filter({ $0.spaceID == id })
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first {
            activeTabID = existingTab.id
        } else {
            activeTabID = nil
        }

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
        // Cycling only moved the preview selection; releasing Control is the
        // commit point where the selected tab actually becomes the page.
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

        // The commit above already landed the page, so there is nothing to
        // wait for — dropping the overlay immediately keeps the release
        // feeling instant.
        hideTabSwitcher()
    }

    /// Delete while Control is held closes the highlighted card. The strip
    /// backfills from the frozen recency list — the next tab slides in at
    /// the tail — and the highlight keeps its slot, so repeated Delete eats
    /// through a long session from a strip that never grows. Only the last
    /// tab in the list is refused: a strip with nothing left has nothing to
    /// commit. ⇧⌘T is the undo.
    /// Returns whether a tab was closed.
    @discardableResult
    func closeHighlightedTabInTabSwitcher() -> Bool {
        guard
            isTabSwitcherPresented,
            tabSwitcherCandidates.count > 1,
            let id = tabSwitcherSelectedTabID,
            let cardIndex = tabSwitcherTabs.firstIndex(where: { $0.id == id })
        else { return false }

        // The frozen cycling list forgets the tab first, so the rebuilt strip
        // and the next Tab press agree on what is there.
        tabSwitcherCandidates.removeAll { $0.id == id }
        tabSwitcherSnapshots[id] = nil

        let refilled = tabSwitcherPreviewTabs(from: tabSwitcherCandidates, selectedTabID: nil)
        tabSwitcherTabs = refilled
        tabSwitcherSelectedTabID = refilled[min(cardIndex, refilled.count - 1)].id
        // A backfilled card needs its thumbnail; everything else is cached.
        prefetchTabSwitcherSnapshots(for: refilled, refreshExisting: false)

        // Closing the page that is on screen swaps in its usual replacement
        // underneath the strip; the highlight (and the release commit) is
        // independent of that.
        closeTab(id)
        return true
    }

    /// Arc-style pointer selection: moving the mouse over a card highlights
    /// it exactly as Tab would — release (or a click) commits it.
    func highlightTabInTabSwitcher(_ id: UUID) {
        guard isTabSwitcherPresented, tabSwitcherTabs.contains(where: { $0.id == id }) else { return }
        tabSwitcherSelectedTabID = id
    }

    /// Clicking a card commits it now instead of waiting for Control to
    /// lift; the eventual release then finds nothing left to do.
    func commitTabInTabSwitcher(_ id: UUID) {
        guard isTabSwitcherPresented else { return }
        highlightTabInTabSwitcher(id)
        finishTabSwitcherInteraction()
    }

    /// How many tabs the held strip is cycling through, including the ones
    /// past the visible cards — the strip's tab-count caption.
    var tabSwitcherTabCount: Int {
        tabSwitcherCandidates.count
    }

    /// Escape while Control is held abandons the interaction: the strip
    /// drops and the page stays on the tab it started from, so a wrong turn
    /// mid-cycle does not need to be Tab-bed back around.
    /// Returns whether a strip was open to cancel.
    @discardableResult
    func cancelTabSwitcherInteraction() -> Bool {
        guard isTabSwitcherPresented || tabSwitcherShowWorkItem != nil else { return false }
        tabSwitcherSelectedTabID = activeTabID
        isTabSwitcherCycling = false
        hideTabSwitcher()
        return true
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

        // Cycle only what the strip shows: the highlight must never step
        // onto a tab that has no card. The rest of the frozen list stays
        // behind for Delete to backfill from.
        let recentTabs = Array(tabSwitcherCandidates.prefix(TabSwitcherConfiguration.previewLimit))
        guard !recentTabs.isEmpty else { return }
        guard recentTabs.count > 1 else {
            presentTabSwitcher(
                candidates: recentTabs,
                selectedTabID: activeTabID,
                autoHide: !keepsPreviewOpen,
                refreshesSnapshots: isFreshInteraction
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
        // Arc-style deferred commit: while Control is held, cycling only
        // moves the selection in the preview — the page itself switches when
        // the interaction ends (Control release, or the auto-hide), so
        // holding to browse previews never churns through intermediate tabs.
        presentTabSwitcher(
            candidates: recentTabs,
            selectedTabID: selectedTabID,
            autoHide: !keepsPreviewOpen,
            refreshesSnapshots: isFreshInteraction
        )
    }

    func presentTabSwitcher(
        candidates: [BrowserTab]? = nil,
        selectedTabID: UUID? = nil,
        autoHide: Bool = true,
        refreshesSnapshots: Bool = false
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
        // Capture starts here, on the press itself: the hold-reveal window is
        // free time to have every thumbnail ready before the overlay shows.
        prefetchTabSwitcherSnapshots(for: previewTabs, refreshExisting: refreshesSnapshots)

        if isTabSwitcherCycling {
            startTabSwitcherControlWatchdog()
        }

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

    /// Snapshots persist across interactions so a reopened switcher is warm
    /// from its first frame. A fresh interaction re-captures only the
    /// departing active tab — the one card whose content changed since it
    /// was last left (the stale image stays up until the replacement lands);
    /// everything else fills gaps from cache, wake snapshots, or disk. That
    /// keeps a quick silent Control-Tab at one capture, not one per card.
    func prefetchTabSwitcherSnapshots(for tabs: [BrowserTab], refreshExisting: Bool) {
        if !isPrivate, !hasPrunedPersistedTabSnapshots {
            hasPrunedPersistedTabSnapshots = true
            TabSnapshotStore.shared.prune(keeping: Set(self.tabs.map(\.id)))
        }

        let visibleIDs = Set(tabs.map(\.id))
        tabSwitcherSnapshots = tabSwitcherSnapshots.filter { visibleIDs.contains($0.key) }

        for tab in tabs where (refreshExisting && tab.id == activeTabID) || tabSwitcherSnapshots[tab.id] == nil {
            webCoordinator.snapshotImage(for: tab.id, width: TabSwitcherConfiguration.snapshotWidth) { [weak self] image in
                guard let self else { return }
                guard let image else {
                    if self.tabSwitcherSnapshots[tab.id] == nil {
                        self.loadFallbackTabSwitcherSnapshot(for: tab)
                    }
                    return
                }
                // Late arrivals still land: the cache outlives the overlay,
                // so a capture finishing after hide warms the next open.
                self.tabSwitcherSnapshots[tab.id] = image
                if !self.isPrivate {
                    TabSnapshotStore.shared.persist(image, for: tab.id, url: tab.url)
                }
            }
        }
    }

    /// A tab without a live web view still gets a real preview: reuse the
    /// hibernation wake snapshot when the tab slept this session, else the
    /// thumbnail persisted by a previous run. A tab with neither is loaded
    /// off-screen once so its card fills in (and stays filled next run).
    private func loadFallbackTabSwitcherSnapshot(for tab: BrowserTab) {
        if let wakeSnapshot = webCoordinator.wakeSnapshots[tab.id] {
            tabSwitcherSnapshots[tab.id] = wakeSnapshot
            return
        }

        guard !isPrivate else { return }
        let tabID = tab.id
        Task { @MainActor [weak self] in
            let image = await TabSnapshotStore.shared.loadSnapshot(for: tabID)
            guard let self, self.tabSwitcherSnapshots[tabID] == nil else { return }
            if let image {
                self.tabSwitcherSnapshots[tabID] = image
            } else if let tab = self.tabs.first(where: { $0.id == tabID }) {
                self.webCoordinator.warmUpPreview(for: tab)
            }
        }
    }

    /// A page image captured outside the switcher (a wake snapshot on
    /// switch-away, or an off-screen warm-up) becomes that tab's card and,
    /// outside private windows, its on-disk thumbnail for the next run.
    func didCaptureTabSnapshot(_ image: NSImage, for tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tabSwitcherSnapshots[tabID] = image
        guard !isPrivate else { return }
        TabSnapshotStore.shared.persist(image, for: tabID, url: tab.url)
    }

    /// Launch pass: the active space's switcher candidates that have no live
    /// web view and no thumbnail on disk are warmed up off-screen, so the
    /// first Control-Tab of the run shows real pages rather than favicons.
    func warmUpTabSwitcherPreviewsIfNeeded() {
        guard !isPrivate else { return }
        let candidates = tabSwitcherPreviewTabs(from: recentTabsForActiveSpace(), selectedTabID: activeTabID)
            .filter { !webCoordinator.hasLoadedWebView(for: $0.id) && tabSwitcherSnapshots[$0.id] == nil }
        guard !candidates.isEmpty else { return }
        Task { @MainActor [weak self] in
            for tab in candidates {
                guard await !TabSnapshotStore.shared.hasSnapshot(for: tab.id) else { continue }
                guard let self, self.tabs.contains(where: { $0.id == tab.id }) else { return }
                self.webCoordinator.warmUpPreview(for: tab)
            }
        }
    }

    /// The strip commits when Control lifts, which the window's key monitor
    /// normally reports. It cannot report it while something else is running
    /// the event loop — a context menu, most of all: Control-clicking a
    /// sidebar row opens one (macOS reads ⌃-click as a right-click), the menu
    /// swallows the flags-changed event, and the strip was left on screen
    /// with Control long since released. So while the cycle is live, the
    /// modifier is also polled straight from the hardware state.
    func startTabSwitcherControlWatchdog() {
        guard tabSwitcherControlWatchdog == nil else { return }
        // .common, or the timer would be as blind as the monitor: menu
        // tracking runs the loop in event-tracking mode.
        let watchdog = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isTabSwitcherCycling else { return }
                guard !NSEvent.modifierFlags.contains(.control) else { return }
                self.finishTabSwitcherInteraction()
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        tabSwitcherControlWatchdog = watchdog
    }

    func hideTabSwitcher() {
        tabSwitcherControlWatchdog?.invalidate()
        tabSwitcherControlWatchdog = nil
        tabSwitcherHideWorkItem?.cancel()
        tabSwitcherHideWorkItem = nil
        tabSwitcherShowWorkItem?.cancel()
        tabSwitcherShowWorkItem = nil

        // Flows without a Control-release event (auto-hide) end their
        // interaction here: land the still-uncommitted selection, then
        // commit the access time the cycling deferred. Control-release
        // flows already did both in finishTabSwitcherInteraction — that
        // path clears isTabSwitcherCycling before hiding, so this cannot
        // double-commit or stamp the old tab while a switch is deferred
        // behind the return morph.
        if isTabSwitcherCycling {
            if let selectedTabID = tabSwitcherSelectedTabID, selectedTabID != activeTabID {
                switchTab(to: selectedTabID, updatesAccessTime: false)
            }
            if let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[index].lastAccessedAt = Date()
            }
        }
        isTabSwitcherCycling = false

        isTabSwitcherPresented = false
        tabSwitcherCandidates = []
        tabSwitcherSelectedTabID = nil
    }

    func recentTabsForActiveSpace() -> [BrowserTab] {
        tabs.filter {
            $0.spaceID == activeSpaceID && $0.hasBeenActivated
        }
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

