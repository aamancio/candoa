import Foundation

enum TabArrangementKey: String {
    case title, website
}

extension BrowserStore {
    var canArrangeTabs: Bool {
        arrangementBuckets().contains { $0.tabs.count >= 2 }
    }

    /// Sorts the active Space's pinned, regular, and per-folder buckets
    /// independently. The global Favorites grid is deliberately left alone:
    /// favorites are shared across Spaces, so re-sorting them from one
    /// window's command would silently reshuffle every other Space.
    func arrangeTabs(by key: TabArrangementKey) {
        for bucket in arrangementBuckets() where bucket.tabs.count >= 2 {
            let orderedIDs = bucket.tabs
                .sorted { tabPrecedes($0, $1, by: key) }
                .map(\.id)
            guard orderedIDs != bucket.tabs.map(\.id) else { continue }
            reorderTabs(
                orderedIDs,
                isFavorite: false,
                isPinned: bucket.isPinned,
                folderID: bucket.folderID
            )
        }
    }

    private struct ArrangementBucket {
        var tabs: [BrowserTab]
        var isPinned: Bool
        var folderID: UUID?
    }

    private func arrangementBuckets() -> [ArrangementBucket] {
        var buckets = [
            ArrangementBucket(tabs: pinnedTabs(in: activeSpaceID), isPinned: true, folderID: nil),
            ArrangementBucket(tabs: regularTabs(in: activeSpaceID), isPinned: false, folderID: nil)
        ]
        // Foldered tabs live in the pinned section, so their bucket keeps
        // isPinned true (mirrors newTab's placement resolution).
        for folder in folders where folder.spaceID == activeSpaceID {
            buckets.append(
                ArrangementBucket(tabs: tabsInFolder(folder.id), isPinned: true, folderID: folder.id)
            )
        }
        return buckets
    }

    private func tabPrecedes(_ lhs: BrowserTab, _ rhs: BrowserTab, by key: TabArrangementKey) -> Bool {
        switch key {
        case .title:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            guard order == .orderedSame else { return order == .orderedAscending }
            return hostPrecedes(lhs, rhs)
        case .website:
            guard let lhsHost = arrangementHost(of: lhs) else { return false }
            guard let rhsHost = arrangementHost(of: rhs) else { return true }
            guard lhsHost == rhsHost else { return lhsHost < rhsHost }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func hostPrecedes(_ lhs: BrowserTab, _ rhs: BrowserTab) -> Bool {
        guard let lhsHost = arrangementHost(of: lhs) else { return false }
        guard let rhsHost = arrangementHost(of: rhs) else { return true }
        return lhsHost < rhsHost
    }

    private func arrangementHost(of tab: BrowserTab) -> String? {
        tab.url?.host(percentEncoded: false)?.lowercased()
    }
}
