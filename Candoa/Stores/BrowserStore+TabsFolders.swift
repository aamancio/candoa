import AppKit
import Foundation

extension BrowserStore {
    var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var activeSplitTab: BrowserTab? {
        activeSplitTabs.first
    }

    /// The on-screen panes other than the active tab. Empty while the split
    /// group is suspended (active tab outside the group).
    var activeSplitTabs: [BrowserTab] {
        let activeID = activeTabID
        return displayedSplitTabs.filter { $0.id != activeID }
    }

    /// The active Space's split group members, whether or not the group is
    /// currently displayed. Sidebar surfaces (the group pill, row filtering)
    /// key off this so a suspended split keeps its grouped identity.
    var activeSplitGroupTabs: [BrowserTab] {
        splitGroupTabIDs().compactMap(tab)
    }

    var activeSplitGroupTabIDs: Set<UUID> {
        Set(splitGroupTabIDs())
    }

    /// The tabs rendered as side-by-side panes right now. Empty unless the
    /// active tab is a group member — everything about visible web content
    /// (hosting, hibernation exemptions, navigation state, crash visibility)
    /// keys off this, never off suspended membership.
    var displayedSplitTabs: [BrowserTab] {
        guard isSplitViewDisplayed else { return [] }
        return splitGroupTabIDs().compactMap(tab)
    }

    var displayedSplitTabIDs: Set<UUID> {
        Set(displayedSplitTabs.map(\.id))
    }

    var activeSidebarDropIndicator: SidebarTabDropIndicator? {
        draggedTabID == nil ? nil : sidebarDropIndicator
    }

    /// The half of this row a split would take, or nil if the row is not
    /// currently offering one. Rows ask for the side rather than comparing
    /// against a whole constructed indicator: the side is a detail of the
    /// state, not part of identifying it, and equality would go stale the
    /// next time the indicator gains a field.
    func sidebarSplitDropSide(
        for tabID: UUID,
        placement: SidebarTabDropPlacement
    ) -> SplitTabDropSide? {
        guard
            let indicator = activeSidebarDropIndicator,
            indicator.edge == .split,
            indicator.placement == placement,
            indicator.targetTabID == tabID
        else { return nil }
        return indicator.splitSide ?? .trailing
    }

    var visibleTabsForActiveSpace: [BrowserTab] {
        visibleTabs(in: activeSpaceID)
    }

    /// Favorites are global (Arc/Zen-style): one shared grid that stays the
    /// same in every Space. Pinned and regular tabs remain per-Space. Each
    /// favorite still records a home `spaceID`, but it is ignored for
    /// display and reassigned to the active Space on activation.
    var favoriteTabs: [BrowserTab] {
        tabs
            .filter { $0.isFavorite }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var pinnedTabsForActiveSpace: [BrowserTab] {
        pinnedTabs(in: activeSpaceID)
    }

    var foldersForActiveSpace: [BrowserFolder] {
        rootFolders(in: activeSpaceID)
    }

    var folderedTabsForActiveSpace: [BrowserTab] {
        folders
            .filter { $0.spaceID == activeSpaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { folder in
                tabsInFolder(folder.id)
            }
    }

    var regularTabsForActiveSpace: [BrowserTab] {
        regularTabs(in: activeSpaceID)
    }

    func pinnedTabs(in spaceID: UUID) -> [BrowserTab] {
        tabs
            .filter { $0.spaceID == spaceID && $0.folderID == nil && $0.isPinned && !$0.isFavorite }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func rootFolders(in spaceID: UUID) -> [BrowserFolder] {
        folders
            .filter { $0.spaceID == spaceID && $0.parentFolderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func regularTabs(in spaceID: UUID) -> [BrowserTab] {
        tabs
            .filter { $0.spaceID == spaceID && $0.folderID == nil && !$0.isFavorite && !$0.isPinned }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func visibleTabs(in spaceID: UUID) -> [BrowserTab] {
        // The shared favorites lead every Space's visible list, so ⌘1–⌘9 and
        // tab cycling can reach them from anywhere.
        let favorites = favoriteTabs
        let pinned = pinnedTabs(in: spaceID)
        let foldered = folders
            .filter { $0.spaceID == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { folder in
                tabsInFolder(folder.id)
            }
        let regular = regularTabs(in: spaceID)

        return favorites + pinned + foldered + regular
    }

    func tabsInFolder(_ folderID: UUID) -> [BrowserTab] {
        tabs
            .filter { $0.folderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func subfolders(in folderID: UUID) -> [BrowserFolder] {
        folders
            .filter { $0.parentFolderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func tabsInFolderTree(_ folderID: UUID) -> [BrowserTab] {
        tabsInFolder(folderID) + subfolders(in: folderID).flatMap { tabsInFolderTree($0.id) }
    }

    func descendantFolderIDs(of folderID: UUID) -> Set<UUID> {
        subfolders(in: folderID).reduce(into: Set<UUID>()) { result, folder in
            result.insert(folder.id)
            result.formUnion(descendantFolderIDs(of: folder.id))
        }
    }

    /// Re-points a tab at the web view's real location after a navigation
    /// converted to a download (see realignTabAfterDownloadConversion).
    func realignTabURL(tabID: UUID, to url: URL?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].url?.absoluteString != url?.absoluteString else { return }
        tabs[index].url = url
        if url == nil {
            tabs[index].title = ""
        }
        updateNavigationState()
        flushSession()
    }

    /// An Empty Page new tab: a URL-less row that renders the empty surface
    /// and is filled in place by the first committed navigation (see
    /// navigate(to:), which treats URL-less active tabs as placeholders).
    func newEmptyTab() {
        let targetSpaceID = activeSpaceID
        let tab = BrowserTab(
            spaceID: targetSpaceID,
            sortOrder: nextSortOrder(
                spaceID: targetSpaceID,
                isFavorite: false,
                isPinned: false,
                folderID: nil
            )
        )
        tabs.insert(tab, at: 0)
        unsyncedLocalTabIDs.insert(tab.id)
        switchTab(to: tab.id)
    }

    func newTab(
        url: URL,
        favorite: Bool = false,
        pinned: Bool = false,
        folderID: UUID? = nil,
        in spaceID: UUID? = nil
    ) -> BrowserTab {
        let targetSpaceID = spaceID ?? activeSpaceID
        let targetFolderID = folderID.flatMap { folder in
            folders.contains(where: { $0.id == folder && $0.spaceID == targetSpaceID }) ? folder : nil
        }
        let isPinned = (pinned || targetFolderID != nil) && !favorite
        var tab = BrowserTab(
            title: title(for: url),
            url: url,
            faviconSymbol: faviconService.placeholderSymbol(for: url),
            isFavorite: favorite,
            isPinned: isPinned,
            folderID: favorite ? nil : targetFolderID,
            spaceID: targetSpaceID,
            sortOrder: nextSortOrder(
                spaceID: targetSpaceID,
                isFavorite: favorite,
                isPinned: isPinned,
                folderID: favorite ? nil : targetFolderID
            )
        )
        if favorite {
            tab.favoriteTitle = tab.title
            tab.favoriteURL = tab.url
            tab.favoriteFaviconSymbol = tab.faviconSymbol
            tab.favoriteFaviconData = tab.faviconData
        }

        tabs.insert(tab, at: 0)
        unsyncedLocalTabIDs.insert(tab.id)
        switchTab(to: tab.id)

        if !tab.isWelcomePage {
            webCoordinator.load(url, in: tab.id)
        }

        return tab
    }

    /// Safari's last-tab rule: ⌘W closes the tab, and when the Space has no
    /// other tab to fall back to it closes the window rather than leaving an
    /// empty one behind.
    ///
    /// "No other tab" means no other *closable* tab. Pinned tabs and
    /// favorites answer ⌘W by resetting to their saved page
    /// (`performPinnedCloseShortcutIfNeeded`), so a Space down to its last
    /// ordinary tab beside them has nothing left for a second ⌘W to act on —
    /// the window would sit there, uncloseable by the very shortcut asked to
    /// close it. An active pinned tab or favorite keeps its own meaning: it
    /// resets, and the window stays.
    func closeCurrentTabOrWindow() {
        guard let activeTabID, let activeTab = tabs.first(where: { $0.id == activeTabID }) else {
            closeKeyWindow()
            return
        }

        guard !activeTab.isPinned, !activeTab.isFavorite else {
            closeCurrentTab()
            return
        }

        let otherClosableTabRemains = visibleTabsForActiveSpace.contains {
            $0.id != activeTabID && !$0.isPinned && !$0.isFavorite
        }

        if otherClosableTabRemains {
            closeCurrentTab()
        } else {
            closeKeyWindow()
        }
    }

    private func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    func closeCurrentTab() {
        guard let activeTabID else { return }
        if performPinnedCloseShortcutIfNeeded(activeTabID) {
            return
        }
        closeTab(activeTabID)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let previousSplitGroupIDs = splitGroupTabIDs()
        let wasSplitGroupTab = previousSplitGroupIDs.contains(id)
        let wasActiveTab = activeTabID == id
        let replacementTabID = wasActiveTab ? replacementTabIDAfterClosing(id) : nil
        let closingTab = tabs[index]
        let closesWelcomeDuringTour = closingTab.isWelcomePage && initialOnboardingStep == .tour
        rememberClosedTab(closingTab)
        tabs.remove(at: index)
        webCoordinator.removeWebView(for: id)
        clearLoadFailure(tabID: id)
        mediaStates[id] = nil
        if mediaControllerTabID == id {
            mediaControllerTabID = nil
        }

        if wasSplitGroupTab {
            let remainingGroupIDs = previousSplitGroupIDs.filter { $0 != id }
            let nextActiveID = wasActiveTab
                ? remainingGroupIDs.first
                : activeTabID
            applySplitGroup(remainingGroupIDs, activeID: nextActiveID)
            if activeTabID == nil {
                activeTabID = tabs
                    .filter { $0.spaceID == activeSpaceID }
                    .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                    .first?.id
            }
            updateNavigationState()
        } else if activeTabID == id {
            activeTabID = replacementTabID
            updateNavigationState()
        }

        if closesWelcomeDuringTour {
            completeInitialTour()
        }
    }

    /// Command-W keeps pinned and favorite tabs in the sidebar: reset the tab
    /// to its saved URL, switch away, and unload the page instead of closing.
    func performPinnedCloseShortcutIfNeeded(_ id: UUID) -> Bool {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            tab.isPinned || tab.isFavorite
        else {
            return false
        }

        let nextTabID = replacementTabIDAfterClosing(id, prefersRecentlyUsed: false)

        resetSavedURLIfAvailable(for: id, loadsWebView: false)

        if let nextTabID {
            switchTab(to: nextTabID)
        }

        unloadWebView(for: id)

        updateNavigationState()
        return true
    }

    /// Closing the active tab returns to the tab used most recently (the
    /// place the person came from — Arc's behavior), not its neighbor in
    /// the list; the pinned-tab reset is the one caller that wants the
    /// neighbor, since that tab stays where it is.
    func replacementTabIDAfterClosing(_ id: UUID, prefersRecentlyUsed: Bool = true) -> UUID? {
        guard let closingTab = tabs.first(where: { $0.id == id }) else { return nil }
        let candidates = tabs.filter { $0.id != id && $0.spaceID == closingTab.spaceID }
        guard !candidates.isEmpty else { return nil }

        if prefersRecentlyUsed {
            return candidates
                .sorted {
                    if $0.lastAccessedAt == $1.lastAccessedAt {
                        return $0.sortOrder < $1.sortOrder
                    }
                    return $0.lastAccessedAt > $1.lastAccessedAt
                }
                .first?.id
        }

        let orderedVisibleTabs = visibleTabs(in: closingTab.spaceID)
        guard
            let closingIndex = orderedVisibleTabs.firstIndex(where: { $0.id == id })
        else {
            return candidates
                .sorted { $0.sortOrder < $1.sortOrder }
                .first?.id
        }

        let remainingVisibleTabs = orderedVisibleTabs.filter { $0.id != id }
        guard !remainingVisibleTabs.isEmpty else { return nil }

        if closingIndex < remainingVisibleTabs.count {
            return remainingVisibleTabs[closingIndex].id
        }
        return remainingVisibleTabs.last?.id
    }

    func resetSavedURLIfAvailable(for tabID: UUID, loadsWebView: Bool) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            let savedURL = tabs[index].favoriteURL
        else {
            return
        }

        let title = tabs[index].favoriteDisplayTitle
        setURL(savedURL, title: title, for: tabID)

        if loadsWebView {
            webCoordinator.load(savedURL, in: tabID)
        }
    }

    func unloadWebView(for tabID: UUID) {
        webCoordinator.removeWebView(for: tabID)
        mediaStates[tabID] = nil
        if mediaControllerTabID == tabID {
            mediaControllerTabID = nil
        }
    }

    func duplicateCurrentTab() {
        guard let tab = activeTab,
              !tab.isWelcomePage,
              let url = tab.isFavorite ? tab.favoriteURL ?? tab.url : tab.url
        else { return }
        _ = newTab(
            url: url,
            favorite: tab.isFavorite,
            pinned: tab.isPinned,
            folderID: tab.folderID,
            in: tab.spaceID
        )
    }

    func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }),
              !tab.isWelcomePage,
              let url = tab.isFavorite ? tab.favoriteURL ?? tab.url : tab.url
        else { return }
        _ = newTab(
            url: url,
            favorite: tab.isFavorite,
            pinned: tab.isPinned,
            folderID: tab.folderID,
            in: tab.spaceID
        )
    }

    @discardableResult
    func createPopupTab(url: URL?, in spaceID: UUID) -> BrowserTab {
        let tab = BrowserTab(
            title: title(for: url),
            url: url,
            faviconSymbol: faviconService.placeholderSymbol(for: url),
            spaceID: spaceID,
            sortOrder: nextSortOrder(spaceID: spaceID, isFavorite: false, isPinned: false, folderID: nil)
        )

        tabs.insert(tab, at: 0)
        unsyncedLocalTabIDs.insert(tab.id)
        switchTab(to: tab.id)
        return tab
    }

    /// Reopens a specific entry from the History menu's Recently Closed list,
    /// rather than the most recent one.
    func reopenClosedTab(at url: URL) {
        guard let index = recentlyClosedTabs.lastIndex(where: { $0.url == url }) else { return }
        let snapshot = recentlyClosedTabs.remove(at: index)
        let targetSpaceID = spaces.contains(where: { $0.id == snapshot.spaceID })
            ? snapshot.spaceID
            : activeSpaceID
        _ = newTab(url: snapshot.url, favorite: snapshot.isFavorite, pinned: snapshot.isPinned, in: targetSpaceID)
    }

    func reopenLastClosedTab() {
        guard let snapshot = recentlyClosedTabs.popLast() else { return }
        let targetSpaceID = spaces.contains(where: { $0.id == snapshot.spaceID })
            ? snapshot.spaceID
            : activeSpaceID
        _ = newTab(url: snapshot.url, favorite: snapshot.isFavorite, pinned: snapshot.isPinned, in: targetSpaceID)
    }

    func clearUnpinnedTabs() {
        regularTabsForActiveSpace.map(\.id).forEach(closeTab)
    }

    /// Safari's File ▸ Close Other Tabs. Closes the other ordinary tabs in
    /// the kept tab's Space; pinned tabs, favorites, and foldered tabs stay,
    /// exactly as Clear Unpinned Tabs leaves them.
    func closeOtherTabs(keeping keptTabID: UUID) {
        guard let keptTab = tabs.first(where: { $0.id == keptTabID }) else { return }
        otherClosableTabs(keeping: keptTab).map(\.id).forEach(closeTab)
    }

    func closeOtherTabsForActiveTab() {
        guard let activeTabID else { return }
        closeOtherTabs(keeping: activeTabID)
    }

    var canCloseOtherTabs: Bool {
        guard let activeTab else { return false }
        return !otherClosableTabs(keeping: activeTab).isEmpty
    }

    private func otherClosableTabs(keeping keptTab: BrowserTab) -> [BrowserTab] {
        regularTabs(in: keptTab.spaceID).filter { $0.id != keptTab.id }
    }

    func toggleFavoriteForActiveTab() {
        guard let activeTabID else { return }
        toggleFavorite(activeTabID)
    }

    func togglePinForActiveTab() {
        guard let activeTabID else { return }
        togglePin(activeTabID)
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].isFavorite {
            // Leaving the global favorites grid lands the tab in the Space
            // the user is looking at, not its recorded home Space.
            reparentTabToActiveSpaceIfNeeded(at: index)
        }
        let pinned = !tabs[index].isPinned
        tabs[index].isFavorite = false
        tabs[index].folderID = nil
        tabs[index].isPinned = pinned
        tabs[index].sortOrder = nextSortOrder(
            spaceID: tabs[index].spaceID,
            isFavorite: false,
            isPinned: pinned,
            folderID: nil
        )
        normalizeSortOrder()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let favorite = !tabs[index].isFavorite
        if !favorite {
            // Un-favoriting returns the tab to the Space on screen.
            reparentTabToActiveSpaceIfNeeded(at: index)
        }
        tabs[index].isFavorite = favorite
        tabs[index].folderID = nil
        if favorite {
            tabs[index].isPinned = false
            captureFavoriteSnapshot(at: index)
        } else {
            clearFavoriteSnapshot(at: index)
        }
        tabs[index].sortOrder = nextSortOrder(
            spaceID: tabs[index].spaceID,
            isFavorite: favorite,
            isPinned: tabs[index].isPinned,
            folderID: nil
        )
        normalizeSortOrder()
    }

    func addTabToFavorites(_ id: UUID, before targetID: UUID? = nil) {
        moveTabToPlacement(id, isFavorite: true, isPinned: false, folderID: nil, before: targetID)
    }

    func activateFavorite(_ id: UUID) {
        switchTab(to: id)
    }

    /// Favorites are global, but every tab still lives in exactly one Space.
    /// When a favorite recorded under another Space is activated or converted
    /// back to a Space-scoped placement, it moves into the active Space. A
    /// data-store change requires a fresh web view, matching moveTab(toSpace:).
    func reparentTabToActiveSpaceIfNeeded(at index: Int) {
        guard tabs[index].spaceID != activeSpaceID else { return }
        let sourceDataStoreID = dataStoreID(for: tabs[index].spaceID)
        let targetDataStoreID = dataStoreID(for: activeSpaceID)
        tabs[index].spaceID = activeSpaceID
        tabs[index].folderID = nil
        if sourceDataStoreID != targetDataStoreID {
            webCoordinator.removeWebView(for: tabs[index].id)
        }
    }

    @discardableResult
    func createFolder(named name: String = String(localized: "New Folder"), parentFolderID: UUID? = nil) -> BrowserFolder {
        let resolvedParentID = parentFolderID.flatMap { parentID in
            folders.contains { $0.id == parentID && $0.spaceID == activeSpaceID } ? parentID : nil
        }
        let folder = BrowserFolder(
            name: uniqueFolderName(base: name, in: activeSpaceID),
            spaceID: activeSpaceID,
            parentFolderID: resolvedParentID,
            sortOrder: nextFolderSortOrder(spaceID: activeSpaceID, parentFolderID: resolvedParentID)
        )
        folders.append(folder)
        if let resolvedParentID, let parentIndex = folders.firstIndex(where: { $0.id == resolvedParentID }) {
            folders[parentIndex].isExpanded = true
        }
        editingFolderID = folder.id
        flushSession()
        return folder
    }

    @discardableResult
    func createSubfolder(in parentFolderID: UUID) -> BrowserFolder? {
        guard folders.contains(where: { $0.id == parentFolderID && $0.spaceID == activeSpaceID }) else {
            return nil
        }
        return createFolder(named: "New Folder", parentFolderID: parentFolderID)
    }

    func renameFolder(_ id: UUID, to name: String) {
        let normalizedName = normalizedFolderName(name)
        guard !normalizedName.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = normalizedName
        editingFolderID = nil
        flushSession()
    }

    func toggleFolderExpanded(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isExpanded.toggle()
        flushSession()
    }

    func setFolderExpanded(_ id: UUID, _ isExpanded: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].isExpanded != isExpanded else { return }
        folders[index].isExpanded = isExpanded
        flushSession()
    }

    func revealFolder(_ id: UUID) {
        var changed = false
        var currentID: UUID? = id
        var seen = Set<UUID>()

        while let folderID = currentID, seen.insert(folderID).inserted {
            guard let index = folders.firstIndex(where: { $0.id == folderID }) else { break }
            if !folders[index].isExpanded {
                folders[index].isExpanded = true
                changed = true
            }
            currentID = folders[index].parentFolderID
        }

        if changed {
            flushSession()
        }
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let deletedFolderIDs = descendantFolderIDs(of: id).union([id])
        folders.removeAll { deletedFolderIDs.contains($0.id) }
        if let currentEditingFolderID = editingFolderID, deletedFolderIDs.contains(currentEditingFolderID) {
            editingFolderID = nil
        }

        for index in tabs.indices where tabs[index].folderID.map(deletedFolderIDs.contains) == true {
            tabs[index].folderID = nil
            tabs[index].isFavorite = false
            tabs[index].isPinned = true
            tabs[index].sortOrder = nextSortOrder(
                spaceID: folder.spaceID,
                isFavorite: false,
                isPinned: true,
                folderID: nil
            )
        }

        normalizeSortOrder()
        flushSession()
    }

    func moveTabToFolder(
        _ tabID: UUID,
        folderID: UUID,
        before targetID: UUID? = nil,
        appendToEnd: Bool = false
    ) {
        moveTabToPlacement(
            tabID,
            isFavorite: false,
            isPinned: true,
            folderID: folderID,
            before: targetID,
            appendToEnd: appendToEnd
        )
    }

    func switchToTab(at position: Int) {
        let visibleTabs = visibleTabsForActiveSpace
        guard position >= 1, position <= visibleTabs.count else { return }
        switchTab(to: visibleTabs[position - 1].id)
    }

    func switchToSpace(at position: Int) {
        guard position >= 1, position <= spaces.count else { return }
        requestSpaceSelection(spaces[position - 1].id)
    }

    /// Placement buckets are per-Space, except favorites: the global grid is
    /// one shared ordering, so its bucket ignores `spaceID`.
    private func tabsInPlacementBucket(
        spaceID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID?
    ) -> [BrowserTab] {
        let resolvedPinned = isPinned && !isFavorite
        return tabs.filter {
            guard $0.isFavorite == isFavorite else { return false }
            if isFavorite { return true }
            return $0.spaceID == spaceID &&
                $0.isPinned == resolvedPinned &&
                $0.folderID == folderID
        }
    }

    func nextSortOrder(
        spaceID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID? = nil
    ) -> Double {
        let orders = tabsInPlacementBucket(
            spaceID: spaceID,
            isFavorite: isFavorite,
            isPinned: isPinned,
            folderID: isFavorite ? nil : folderID
        )
        .map(\.sortOrder)
        return (orders.min() ?? 0) - 1
    }

    func lastSortOrder(
        spaceID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID? = nil
    ) -> Double {
        let orders = tabsInPlacementBucket(
            spaceID: spaceID,
            isFavorite: isFavorite,
            isPinned: isPinned,
            folderID: isFavorite ? nil : folderID
        )
        .map(\.sortOrder)
        return (orders.max() ?? -1) + 1
    }

    func nextFolderSortOrder(spaceID: UUID, parentFolderID: UUID? = nil) -> Double {
        let orders = folders
            .filter { $0.spaceID == spaceID && $0.parentFolderID == parentFolderID }
            .map(\.sortOrder)
        return (orders.min() ?? 0) - 1
    }

    func normalizedFolderName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    }

    func uniqueFolderName(base: String, in spaceID: UUID) -> String {
        let normalizedBase = normalizedFolderName(base).isEmpty ? "New Folder" : normalizedFolderName(base)
        let existingNames = Set(
            folders
                .filter { $0.spaceID == spaceID }
                .map { $0.name.lowercased() }
        )
        guard existingNames.contains(normalizedBase.lowercased()) else { return normalizedBase }

        for index in 2...99 {
            let candidate = "\(normalizedBase) \(index)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
        }

        return "\(normalizedBase) \(folders.count + 1)"
    }

    func folderHasAncestor(_ folderID: UUID, ancestorID: UUID) -> Bool {
        var seen = Set<UUID>()
        var currentID: UUID? = folderID

        while let id = currentID {
            if id == ancestorID { return true }
            guard seen.insert(id).inserted else { return true }
            currentID = folders.first { $0.id == id }?.parentFolderID
        }

        return false
    }

    func normalizeSortOrder() {
        // Favorites are one global bucket, normalized once, not per Space.
        normalizeSortOrder(orderedIDs: sortedBucketTabIDs(tabs.filter(\.isFavorite)))
        for spaceID in spaces.map(\.id) {
            normalizeFolderSortOrder(spaceID: spaceID)
            normalizeSortOrder(spaceID: spaceID, isFavorite: false, isPinned: true, folderID: nil)
            for folder in folders where folder.spaceID == spaceID {
                normalizeSortOrder(spaceID: spaceID, isFavorite: false, isPinned: true, folderID: folder.id)
            }
            normalizeSortOrder(spaceID: spaceID, isFavorite: false, isPinned: false, folderID: nil)
        }
    }

    func normalizeFolderSortOrder(spaceID: UUID) {
        let parentIDs = Set(folders.filter { $0.spaceID == spaceID }.map(\.parentFolderID)) as Set<UUID?>

        for parentID in parentIDs {
            let orderedIDs = folders
                .filter { $0.spaceID == spaceID && $0.parentFolderID == parentID }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.id)

            for (offset, id) in orderedIDs.enumerated() {
                guard let index = folders.firstIndex(where: { $0.id == id }) else { continue }
                folders[index].sortOrder = Double(offset)
            }
        }
    }

    func normalizeSortOrder(spaceID: UUID, isFavorite: Bool, isPinned: Bool, folderID: UUID?) {
        let bucket = tabsInPlacementBucket(
            spaceID: spaceID,
            isFavorite: isFavorite,
            isPinned: isPinned,
            folderID: isFavorite ? nil : folderID
        )
        normalizeSortOrder(orderedIDs: sortedBucketTabIDs(bucket))
    }

    private func sortedBucketTabIDs(_ bucket: [BrowserTab]) -> [UUID] {
        bucket
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.lastAccessedAt > $1.lastAccessedAt
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map(\.id)
    }

    private func normalizeSortOrder(orderedIDs: [UUID]) {
        for (offset, id) in orderedIDs.enumerated() {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            tabs[index].sortOrder = Double(offset)
        }
    }
}
