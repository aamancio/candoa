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
            }
        } else {
            splitTabIDs = []
            splitPaneRatios = []
        }
    }

}
