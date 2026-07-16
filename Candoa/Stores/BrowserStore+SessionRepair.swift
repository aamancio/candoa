import Foundation

extension BrowserStore {
    func repairSessionState() {
        if spaces.isEmpty {
            spaces = [BrowserSpace(name: "", symbolName: "circle.grid.2x2")]
        }

        for index in spaces.indices where !spaces[index].name.isEmpty {
            spaces[index].name = Self.normalizedSpaceName(spaces[index].name)
        }

        let spaceIDs = Set(spaces.map(\.id))
        folders = folders.filter { spaceIDs.contains($0.spaceID) }
        for index in folders.indices {
            folders[index].name = normalizedFolderName(folders[index].name)
            if folders[index].name.isEmpty {
                folders[index].name = "New Folder"
            }
        }

        let folderSpaceByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.spaceID) })
        for index in folders.indices {
            guard let parentID = folders[index].parentFolderID else { continue }
            if folderSpaceByID[parentID] != folders[index].spaceID || folderHasAncestor(parentID, ancestorID: folders[index].id) {
                folders[index].parentFolderID = nil
            }
        }
        tabs = tabs.filter { spaceIDs.contains($0.spaceID) }

        for index in tabs.indices {
            if tabs[index].isFavorite {
                tabs[index].folderID = nil
                tabs[index].isPinned = false
                if tabs[index].favoriteURL == nil {
                    captureFavoriteSnapshot(at: index)
                }
                continue
            }

            guard let folderID = tabs[index].folderID else { continue }
            if folderSpaceByID[folderID] == tabs[index].spaceID {
                tabs[index].isPinned = true
            } else {
                tabs[index].folderID = nil
            }
        }

        if recoverSavedTabNavigations() {
            needsWorkspaceSaveAfterRepair = true
        }

        if !spaceIDs.contains(activeSpaceID) {
            activeSpaceID = spaces[0].id
        }

        normalizeSortOrder()

        if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID && $0.spaceID == activeSpaceID }) {
            activeTabID = visibleTabsForActiveSpace.first?.id
        }

        if isSplitViewEnabled {
            splitTabIDs = Self.validSplitGroupIDs(
                splitTabIDs,
                activeTabID: activeTabID,
                activeSpaceID: activeSpaceID,
                tabs: tabs,
                includesActiveTabID: true
            )
            isSplitViewEnabled = splitTabIDs.count >= 2
        } else {
            splitTabIDs = []
        }
    }

    /// Older builds allowed the sidebar address field to replace a favorite's
    /// live URL while retaining its saved title and icon. Preserve both sites
    /// when opening that state: restore the favorite and make the live page a
    /// regular tab.
    func recoverSavedTabNavigations() -> Bool {
        let originalTabCount = tabs.count
        var recoveredTabs: [BrowserTab] = []
        var replacementActiveTabID: UUID?

        for index in 0..<originalTabCount {
            let tab = tabs[index]
            guard
                tab.isFavorite,
                let savedURL = tab.favoriteURL,
                let liveURL = tab.url,
                differentHosts(savedURL, liveURL)
            else {
                continue
            }

            let recoveredTab = BrowserTab(
                title: tab.title,
                url: liveURL,
                faviconSymbol: tab.faviconSymbol,
                faviconData: tab.faviconData,
                spaceID: tab.spaceID,
                sortOrder: nextSortOrder(
                    spaceID: tab.spaceID,
                    isFavorite: false,
                    isPinned: false,
                    folderID: nil
                ),
                lastAccessedAt: tab.lastAccessedAt
            )
            recoveredTabs.append(recoveredTab)

            tabs[index].title = tab.favoriteDisplayTitle
            tabs[index].url = savedURL
            tabs[index].faviconSymbol = tab.favoriteDisplayFaviconSymbol
            tabs[index].faviconData = tab.favoriteDisplayFaviconData
            tabs[index].isLoading = false
            tabs[index].loadingProgress = 0

            if activeTabID == tab.id {
                replacementActiveTabID = recoveredTab.id
            }
        }

        guard !recoveredTabs.isEmpty else { return false }
        tabs.append(contentsOf: recoveredTabs)
        activeTabID = replacementActiveTabID ?? activeTabID
        return true
    }
}

