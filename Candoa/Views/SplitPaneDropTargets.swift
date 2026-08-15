import SwiftUI

internal struct BrowserSurfaceSplitDropDelegate: DropDelegate {
    let store: BrowserStore
    let size: CGSize
    /// The reserved interface lanes (sidebar, Eli). The drop surface spans
    /// the whole container — including under the lanes — so zone math must
    /// run on the visible page region or a release over the sidebar's empty
    /// area reads as a leading-edge drop and splits the page.
    let laneInsets: BrowserInterfaceInsets

    // Validation gates the whole drag session, and the session's first event
    // arrives at the drag's starting position — usually the sidebar row the
    // drag began on, because this surface spans the container. Any per-
    // position rejection here (or a .cancel proposal from dropUpdated) is
    // terminal: AppKit stops consulting this destination for the rest of
    // the drag. Position handling therefore stays in updatePreview and
    // performDrop, which are location-aware but never terminal.
    func validateDrop(info: DropInfo) -> Bool {
        store.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updatePreview(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(info: info)
        return store.splitDropPreview == nil ? nil : DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSplitDropPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard
            let draggedID = store.draggedTabID,
            let target = dropTarget(for: info, draggedID: draggedID)
        else {
            store.clearSplitDropPreview()
            return false
        }

        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        store.splitTab(draggedID, onto: target.tabID, side: target.side)
        store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? .regular)
        return true
    }

    private func updatePreview(info: DropInfo) {
        guard
            let draggedID = store.draggedTabID,
            let target = dropTarget(for: info, draggedID: draggedID)
        else {
            store.clearSplitDropPreview()
            return
        }

        store.updateSplitDropPreview(targetTabID: target.tabID, side: target.side)
    }

    private func dropTarget(
        for info: DropInfo,
        draggedID: UUID
    ) -> (tabID: UUID, side: SplitTabDropSide)? {
        guard let side = dropSide(for: info) else { return nil }
        guard let tabID = store.splitDropTargetTabID(for: side, draggedID: draggedID) else { return nil }
        return (tabID, side)
    }

    /// Zen-style edge targeting: only the page's outer quarters accept a
    /// split drop — the nearest edge wins, and the middle of the page is not
    /// a target, so an abandoned drag over content does nothing.
    private func dropSide(for info: DropInfo) -> SplitTabDropSide? {
        let pageWidth = max(size.width - laneInsets.leading - laneInsets.trailing, 1)
        let pageX = info.location.x - laneInsets.leading
        guard pageX >= 0, pageX <= pageWidth else { return nil }
        let fractionX = pageX / pageWidth
        let fractionY = info.location.y / max(size.height, 1)
        let insideMiddleX = fractionX > 0.25 && fractionX < 0.75
        let insideMiddleY = fractionY > 0.25 && fractionY < 0.75
        guard !(insideMiddleX && insideMiddleY) else { return nil }

        let edgeDistances: [(side: SplitTabDropSide, distance: CGFloat)] = [
            (.leading, fractionX),
            (.trailing, 1 - fractionX),
            (.top, fractionY),
            (.bottom, 1 - fractionY)
        ]
        return edgeDistances.min { $0.distance < $1.distance }?.side
    }
}

/// Zen-style drop preview: one primary-accent region covering the half of
/// the page the drop would claim — a full-height column for leading and
/// trailing, a full-width row for top and bottom. Deliberately not a mocked
/// up pane arrangement: the drag needs a single unambiguous "this is what
/// you get", matching the grip drag's claim highlight.
internal struct SplitDropPreviewOverlay: View {
    let preview: SplitTabDropPreview
    let cornerRadius: CGFloat
    /// The reserved interface lanes; the claim region wraps the visible
    /// page, not the container that runs under them.
    let laneInsets: BrowserInterfaceInsets

    var body: some View {
        GeometryReader { proxy in
            let page = CGRect(
                x: laneInsets.leading,
                y: 0,
                width: max(proxy.size.width - laneInsets.leading - laneInsets.trailing, 0),
                height: proxy.size.height
            )
            let claim = WebViewContainer.splitPaneEdgeHighlightFrame(for: preview.side, in: page)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppColor.accent.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppColor.accent.opacity(0.85), lineWidth: 2)
                }
                .frame(width: claim.width, height: claim.height)
                .offset(x: claim.minX, y: claim.minY)
        }
        .allowsHitTesting(false)
    }
}
