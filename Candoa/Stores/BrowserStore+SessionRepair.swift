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

        // Favorites are global; sessions that favorited the same page from
        // different Spaces (or twice in one) merge to a single tile. The
        // first by sort order keeps the favorite slot, the rest return to
        // their Space as pinned tabs so no page state is lost.
        var seenFavoriteURLs = Set<String>()
        let orderedFavoriteIDs = tabs
            .filter(\.isFavorite)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
        for id in orderedFavoriteIDs {
            guard
                let index = tabs.firstIndex(where: { $0.id == id }),
                let urlKey = (tabs[index].favoriteURL ?? tabs[index].url)?.absoluteString
            else { continue }
            if !seenFavoriteURLs.insert(urlKey).inserted {
                tabs[index].isFavorite = false
                tabs[index].isPinned = true
                clearFavoriteSnapshot(at: index)
            }
        }

        if !spaceIDs.contains(activeSpaceID) {
            activeSpaceID = spaces[0].id
        }

        normalizeSortOrder()

        if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID && $0.spaceID == activeSpaceID }) {
            activeTabID = visibleTabsForActiveSpace.first?.id
        }

        if isSplitViewEnabled {
            let previousIDs = splitTabIDs
            let previousRatios = splitPaneRatios
            splitTabIDs = Self.validSplitGroupIDs(
                splitTabIDs,
                activeTabID: activeTabID,
                activeSpaceID: activeSpaceID,
                tabs: tabs,
                // Only legacy single-member lists absorb the active tab; a
                // full group may legitimately be suspended with the active
                // tab outside it.
                includesActiveTabID: splitTabIDs.count < 2
            )
            isSplitViewEnabled = splitTabIDs.count >= 2
            if isSplitViewEnabled {
                splitPaneRatios = Self.paneRatios(for: splitTabIDs, carriedFrom: previousIDs, previousRatios: previousRatios)
            } else {
                splitTabIDs = []
                splitPaneRatios = []
                splitLayout = .horizontal
            }
        } else {
            splitTabIDs = []
            splitPaneRatios = []
            splitLayout = .horizontal
        }
    }

}
