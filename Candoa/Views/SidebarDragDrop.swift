import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag reordering

internal struct SpaceLabelDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let store: BrowserStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        store.clearSidebarDropIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        isTargeted = false
        store.moveTabToPlacement(
            draggedID,
            isFavorite: false,
            isPinned: true,
            folderID: nil,
            before: nil,
            appendToEnd: true
        )
        store.finishTabDrop(draggedID, from: sourcePlacement, to: .pinned)
        return true
    }

    private func updateIndicator() {
        isTargeted = true
        store.updateSidebarDropIndicator(
            placement: .pinned,
            targetTabID: nil,
            edge: .after
        )
    }
}
internal struct TabReorderDropDelegate: DropDelegate {
    let targetTab: BrowserTab
    let tabs: [BrowserTab]
    let isFavorite: Bool
    let pinned: Bool
    let folderID: UUID?
    let store: BrowserStore

    // Only tab drags reorder the list; text dragged off a web page also
    // matches UTType.text and must fall through.
    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSidebarDropIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        let edge = store.activeSidebarDropIndicator?.targetTabID == targetTab.id
            ? store.activeSidebarDropIndicator?.edge ?? dropEdge(for: info, axis: dropAxis)
            : dropEdge(for: info, axis: dropAxis)
        if edge == .split {
            store.splitTab(draggedID, onto: targetTab.id, side: splitDropSide(for: info, axis: dropAxis))
            store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? placement)
            return true
        }

        let beforeID = insertionBeforeID(
            targetTabID: targetTab.id,
            edge: edge,
            tabs: tabs,
            draggedID: draggedID
        )
        store.moveTabToPlacement(
            draggedID,
            isFavorite: isFavorite,
            isPinned: pinned,
            folderID: folderID,
            before: beforeID,
            appendToEnd: beforeID == nil && edge == .after
        )
        store.finishTabDrop(draggedID, from: sourcePlacement, to: placement)
        return true
    }

    private func updateIndicator(info: DropInfo) {
        guard let draggedID = store.draggedTabID, draggedID != targetTab.id else { return }
        store.updateSidebarDropIndicator(
            placement: placement,
            targetTabID: targetTab.id,
            edge: dropEdge(for: info, axis: dropAxis)
        )
    }

    private var placement: SidebarTabDropPlacement {
        if isFavorite { return .favorites }
        if let folderID { return .folder(folderID) }
        return pinned ? .pinned : .regular
    }

    private var dropAxis: SidebarDropAxis {
        isFavorite ? .horizontal : .vertical
    }
}

internal struct FolderTabDropDelegate: DropDelegate {
    let folder: BrowserFolder
    let targetTab: BrowserTab?
    let tabs: [BrowserTab]
    let store: BrowserStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSidebarDropIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        let beforeID: UUID?
        if let targetTab {
            let edge = store.activeSidebarDropIndicator?.targetTabID == targetTab.id
                ? store.activeSidebarDropIndicator?.edge ?? dropEdge(for: info)
                : dropEdge(for: info)
            if edge == .split {
                store.splitTab(draggedID, onto: targetTab.id, side: splitDropSide(for: info))
                store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? .folder(folder.id))
                return true
            }
            beforeID = insertionBeforeID(
                targetTabID: targetTab.id,
                edge: edge,
                tabs: tabs,
                draggedID: draggedID
            )
        } else {
            beforeID = nil
        }

        store.moveTabToFolder(
            draggedID,
            folderID: folder.id,
            before: beforeID,
            appendToEnd: targetTab == nil || beforeID == nil
        )
        store.finishTabDrop(draggedID, from: sourcePlacement, to: .folder(folder.id))
        return true
    }

    private func updateIndicator(info: DropInfo) {
        guard let draggedID = store.draggedTabID else { return }
        if let targetTab {
            guard draggedID != targetTab.id else { return }
            store.updateSidebarDropIndicator(
                placement: .folder(folder.id),
                targetTabID: targetTab.id,
                edge: dropEdge(for: info)
            )
        } else {
            store.updateSidebarDropIndicator(
                placement: .folder(folder.id),
                targetTabID: nil,
                edge: .after
            )
        }
    }
}

internal struct RegularTabSectionDropDelegate: DropDelegate {
    let store: BrowserStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSidebarDropIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        let indicator = store.activeSidebarDropIndicator
        let beforeID: UUID?
        let appendToEnd: Bool
        if
            indicator?.placement == .regular,
            let targetID = indicator?.targetTabID,
            let targetTab = store.regularTabsForActiveSpace.first(where: { $0.id == targetID })
        {
            let edge = indicator?.edge ?? .after
            if edge == .split {
                store.splitTab(draggedID, onto: targetTab.id, side: splitDropSide(for: info))
                store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? .regular)
                return true
            }
            beforeID = insertionBeforeID(
                targetTabID: targetTab.id,
                edge: edge,
                tabs: store.regularTabsForActiveSpace,
                draggedID: draggedID
            )
            appendToEnd = beforeID == nil && edge == .after
        } else {
            beforeID = nil
            appendToEnd = true
        }

        store.moveTabToPlacement(
            draggedID,
            isFavorite: false,
            isPinned: false,
            folderID: nil,
            before: beforeID,
            appendToEnd: appendToEnd
        )
        store.finishTabDrop(draggedID, from: sourcePlacement, to: .regular)
        return true
    }

    private func updateIndicator() {
        if store.activeSidebarDropIndicator?.placement == .regular,
           store.activeSidebarDropIndicator?.targetTabID != nil {
            return
        }
        store.updateSidebarDropIndicator(placement: .regular, targetTabID: nil, edge: .after)
    }
}

internal struct PinnedTabSectionDropDelegate: DropDelegate {
    let store: BrowserStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSidebarDropIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        let indicator = store.activeSidebarDropIndicator
        let beforeID: UUID?
        let appendToEnd: Bool
        if
            indicator?.placement == .pinned,
            let targetID = indicator?.targetTabID,
            let targetTab = store.pinnedTabsForActiveSpace.first(where: { $0.id == targetID })
        {
            let edge = indicator?.edge ?? .after
            if edge == .split {
                store.splitTab(draggedID, onto: targetTab.id, side: splitDropSide(for: info))
                store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? .pinned)
                return true
            }
            beforeID = insertionBeforeID(
                targetTabID: targetTab.id,
                edge: edge,
                tabs: store.pinnedTabsForActiveSpace,
                draggedID: draggedID
            )
            appendToEnd = beforeID == nil && edge == .after
        } else {
            beforeID = nil
            appendToEnd = true
        }

        store.moveTabToPlacement(
            draggedID,
            isFavorite: false,
            isPinned: true,
            folderID: nil,
            before: beforeID,
            appendToEnd: appendToEnd
        )
        store.finishTabDrop(draggedID, from: sourcePlacement, to: .pinned)
        return true
    }

    private func updateIndicator() {
        if store.activeSidebarDropIndicator?.placement == .pinned,
           store.activeSidebarDropIndicator?.targetTabID != nil {
            return
        }
        store.updateSidebarDropIndicator(placement: .pinned, targetTabID: nil, edge: .after)
    }
}

internal struct FavoriteTabDropDelegate: DropDelegate {
    let targetTab: BrowserTab?
    let favoriteTabs: [BrowserTab]
    let store: BrowserStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSidebarDropIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        let beforeID: UUID?
        if let targetTab {
            let edge = store.activeSidebarDropIndicator?.targetTabID == targetTab.id
                ? store.activeSidebarDropIndicator?.edge ?? dropEdge(for: info)
                : dropEdge(for: info)
            beforeID = insertionBeforeID(
                targetTabID: targetTab.id,
                edge: edge,
                tabs: favoriteTabs,
                draggedID: draggedID
            )
        } else {
            beforeID = nil
        }

        store.moveTabToPlacement(
            draggedID,
            isFavorite: true,
            isPinned: false,
            folderID: nil,
            before: beforeID,
            appendToEnd: targetTab == nil || beforeID == nil
        )
        store.finishTabDrop(draggedID, from: sourcePlacement, to: .favorites)
        return true
    }

    private func updateIndicator(info: DropInfo) {
        guard let draggedID = store.draggedTabID else { return }
        if let targetTab {
            guard draggedID != targetTab.id else { return }
            store.updateSidebarDropIndicator(
                placement: .favorites,
                targetTabID: targetTab.id,
                edge: dropEdge(for: info, axis: .horizontal)
            )
        } else {
            store.updateSidebarDropIndicator(
                placement: .favorites,
                targetTabID: nil,
                edge: .after
            )
        }
    }
}

internal enum SidebarDropAxis {
    case vertical
    case horizontal
}

internal func dropEdge(for info: DropInfo, axis: SidebarDropAxis = .vertical) -> SidebarTabDropEdge {
    switch axis {
    case .vertical:
        if info.location.y < 9 { return .before }
        if info.location.y > 23 { return .after }
        return .split
    case .horizontal:
        return info.location.x < 44 ? .before : .after
    }
}

internal func splitDropSide(for info: DropInfo, axis: SidebarDropAxis = .vertical) -> SplitTabDropSide {
    switch axis {
    case .vertical:
        let rowWidth = max(1, CandoaChromeStyle.sidebarWidth - 16)
        return info.location.x < rowWidth / 2 ? .leading : .trailing
    case .horizontal:
        return info.location.x < 44 ? .leading : .trailing
    }
}

internal func insertionBeforeID(
    targetTabID: UUID,
    edge: SidebarTabDropEdge,
    tabs: [BrowserTab],
    draggedID: UUID
) -> UUID? {
    guard edge != .split else { return nil }
    guard edge == .after else {
        return targetTabID
    }

    let orderedIDs = tabs.map(\.id).filter { $0 != draggedID }
    guard let targetIndex = orderedIDs.firstIndex(of: targetTabID) else {
        return nil
    }

    let nextIndex = orderedIDs.index(after: targetIndex)
    return nextIndex < orderedIDs.endIndex ? orderedIDs[nextIndex] : nil
}
