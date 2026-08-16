import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag reordering

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

    // Deliberately not clearing the indicator: with live reordering the
    // rows move as the gap moves, so the pointer keeps entering and exiting
    // rows that slid under it. Clearing here made the gap flicker between
    // its new home and the source — the jumpiness this replaces. The gap
    // survives until another row claims it, the section delegate reports the
    // pointer leaving the list, or the drag ends.
    func dropExited(info: DropInfo) {}

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        let sourcePlacement = store.sidebarPlacement(for: draggedID)

        // Live reordering parks the dragged row under the pointer, so a
        // release usually lands on the row's own delegate. Commit the gap it
        // is sitting in — an insertion relative to itself is a no-op, which
        // is what made a dropped tab spring back to where it started.
        if targetTab.id == draggedID {
            guard
                let indicator = store.activeSidebarDropIndicator,
                indicator.placement == placement,
                indicator.edge != .split
            else {
                store.clearSidebarDropIndicator()
                return false
            }

            let beforeID = indicator.targetTabID.flatMap { targetID in
                insertionBeforeID(
                    targetTabID: targetID,
                    edge: indicator.edge,
                    tabs: tabs,
                    draggedID: draggedID
                )
            }
            store.moveTabToPlacement(
                draggedID,
                isFavorite: isFavorite,
                isPinned: pinned,
                folderID: folderID,
                before: beforeID,
                appendToEnd: beforeID == nil && indicator.edge == .after
            )
            store.finishTabDrop(draggedID, from: sourcePlacement, to: placement)
            return true
        }

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
        if indicator?.placement == .regular,
            let targetID = indicator?.targetTabID,
            let targetTab = store.regularTabsForActiveSpace.first(where: { $0.id == targetID }) {
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
        if indicator?.placement == .pinned,
            let targetID = indicator?.targetTabID,
            let targetTab = store.pinnedTabsForActiveSpace.first(where: { $0.id == targetID }) {
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
        // Arc reserves splitting for a deliberate hover over the middle of a
        // row; reordering owns the rest. The band used to be 14 of the row's
        // 36 points, so an ordinary reorder drag kept flashing the split
        // ring on its way past.
        if info.location.y < 14 { return .before }
        if info.location.y > 22 { return .after }
        return .split
    case .horizontal:
        return info.location.x < 44 ? .before : .after
    }
}

internal func splitDropSide(for info: DropInfo, axis: SidebarDropAxis = .vertical) -> SplitTabDropSide {
    switch axis {
    case .vertical:
        // The lane's leading inset only; docked rows run to the lane edge and
        // lean on the gutter before the page surface for their trailing margin.
        let rowWidth = max(1, InterfaceStyle.sidebarWidth - 8)
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

// MARK: - AppKit drag source

/// Starts sidebar tab drags as native AppKit dragging sessions so the ghost
/// page card is the session's real drag image — visible from the first drag
/// movement, everywhere on screen, with snap-back on cancel. SwiftUI's
/// onDrag(preview:) is not honored on macOS, which left drags showing the
/// default row snapshot until the pointer reached the browser surface.
///
/// One shared controller watches mouse events through a single local
/// monitor that lives only while draggable rows exist. The per-row anchor
/// views are click-through, so clicks and context menus reach the row
/// exactly as before; only a press that travels past the drag threshold
/// becomes a dragging session.
@MainActor
internal final class TabDragSessionController {
    static let shared = TabDragSessionController()

    private let anchors = NSHashTable<TabDragSourceAnchorView>.weakObjects()
    private var monitor: Any?
    private var pendingAnchor: TabDragSourceAnchorView?
    private var pendingMouseDown: NSEvent?

    private static let dragThreshold: CGFloat = 4

    func register(_ anchor: TabDragSourceAnchorView) {
        anchors.add(anchor)
        installMonitorIfNeeded()
    }

    func unregister(_ anchor: TabDragSourceAnchorView) {
        anchors.remove(anchor)
        if pendingAnchor === anchor {
            pendingAnchor = nil
            pendingMouseDown = nil
        }
        if anchors.count == 0, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { event in
            // Local event monitors always run on the main thread. NSEvent is
            // not Sendable, so the isolated closure returns only the swallow
            // decision rather than the event itself.
            let swallowed = MainActor.assumeIsolated {
                TabDragSessionController.shared.handle(event)
            }
            return swallowed ? nil : event
        }
    }

    /// Returns true when the event was consumed by starting a drag session.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pendingAnchor = anchor(for: event)
            pendingMouseDown = pendingAnchor == nil ? nil : event
            return false
        case .leftMouseDragged:
            guard
                let anchor = pendingAnchor,
                let mouseDown = pendingMouseDown,
                anchor.window === event.window
            else { return false }
            let travel = hypot(
                event.locationInWindow.x - mouseDown.locationInWindow.x,
                event.locationInWindow.y - mouseDown.locationInWindow.y
            )
            guard travel >= Self.dragThreshold else { return false }
            pendingAnchor = nil
            pendingMouseDown = nil
            anchor.beginDragSession(with: mouseDown)
            // The dragging session owns the pointer now; SwiftUI must not
            // keep interpreting the press as a gesture.
            return true
        case .leftMouseUp:
            pendingAnchor = nil
            pendingMouseDown = nil
            return false
        default:
            return false
        }
    }

    private func anchor(for event: NSEvent) -> TabDragSourceAnchorView? {
        for anchor in anchors.allObjects {
            guard let window = anchor.window, window === event.window else { continue }
            let location = anchor.convert(event.locationInWindow, from: nil)
            guard anchor.bounds.contains(location) else { continue }
            // visibleRect excludes rows scrolled out of the sidebar's clip.
            guard anchor.visibleRect.contains(location) else { continue }
            return anchor
        }
        return nil
    }
}

/// Click-through anchor marking a sidebar row as a tab drag source.
internal final class TabDragSourceAnchorView: NSView, NSDraggingSource {
    weak var store: BrowserStore?
    var tabID: UUID?
    /// The window the session started in. Live reordering can take this row
    /// out of the list mid-drag (the pointer moved to another section), and
    /// the view leaves the window with it — but AppKit keeps calling the
    /// source, so the header zone is looked up by the remembered number
    /// rather than the current window.
    private var dragWindowNumber: Int?

    // Click-through: the row's own controls keep every click; the anchor
    // only marks the draggable region for the shared session controller.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            TabDragSessionController.shared.unregister(self)
        } else {
            TabDragSessionController.shared.register(self)
        }
    }

    func beginDragSession(with mouseDownEvent: NSEvent) {
        guard
            let store,
            let tabID,
            store.draggedTabID == nil,
            !store.isNewTabPaletteActive,
            let tab = store.tabs.first(where: { $0.id == tabID })
        else { return }

        // Arc lifts the row itself: the drag image is the row, drawn at the
        // row's own size, and it starts exactly where the row is so the grab
        // point stays under the pointer — a lift, not a swap for a card.
        let ghostImage = TabDragRowImage.make(for: tab, size: bounds.size)

        _ = store.beginTabDrag(tabID)
        // beginTabDrag starts the mouse-button polling watcher that exists
        // for SwiftUI-initiated drags with no end-of-session signal. This
        // native session reports its end through
        // draggingSession(_:endedAt:operation:), so the watcher is not
        // needed — and synthetic test drags don't register in
        // NSEvent.pressedMouseButtons, which made the watcher cancel
        // in-flight drags mid-session.
        store.tabDragSessionWatcher?.invalidate()
        store.tabDragSessionWatcher = nil

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tabID.uuidString, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            bounds.insetBy(dx: -TabDragRowImage.shadowPadding, dy: -TabDragRowImage.shadowPadding),
            contents: ghostImage
        )

        dragWindowNumber = window?.windowNumber
        let session = beginDraggingSession(
            with: [draggingItem],
            event: mouseDownEvent,
            source: self
        )
        // The image never slides home. SwiftUI's drop delegates finish the
        // drop without reporting an operation back to this session, so AppKit
        // treated every release as a failure and animated the row-pill back
        // to where the drag started — half a second of a tab apparently
        // returning to its old slot while the real row already sat in its new
        // one. Releasing outside any target is handled the same way: the list
        // simply springs back.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Tabs never leave the app as text drags.
        context == .withinApplication ? .generic : []
    }

    /// The Space header is targeted from here, by geometry: AppKit's
    /// destination search never reaches the header's view (see
    /// SpaceHeaderDropZones), so the source watches the pointer instead.
    nonisolated func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { SidebarDragAutoScroll.shared.pointerMoved(to: screenPoint) }

        // NSDraggingSource callbacks arrive on the main thread; the session
        // is touched here, before hopping, so it never crosses the boundary.
        let inside = MainActor.assumeIsolated { () -> Bool? in
            guard let store, let windowNumber = dragWindowNumber ?? window?.windowNumber else { return nil }
            let zone = SpaceHeaderDropZones.shared.screenFrame(forWindowNumber: windowNumber)
            let inside = zone?.contains(screenPoint) ?? false
            return inside != store.isSpaceHeaderDropTargeted ? inside : nil
        }
        guard let inside else { return }
        MainActor.assumeIsolated {
            guard let store else { return }
            store.isSpaceHeaderDropTargeted = inside
            if inside {
                store.updateSidebarDropIndicator(placement: .pinned, targetTabID: nil, edge: .after)
            } else {
                store.clearSidebarDropIndicator()
            }
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // NSDraggingSource callbacks arrive on the main thread.
        MainActor.assumeIsolated {
            SidebarDragAutoScroll.shared.stop()
            dragWindowNumber = nil
            guard let store, let tabID else { return }
            if store.isSpaceHeaderDropTargeted {
                store.isSpaceHeaderDropTargeted = false
                store.clearSidebarDropIndicator()
                if store.draggedTabID == tabID {
                    let sourcePlacement = store.sidebarPlacement(for: tabID)
                    store.moveTabToPlacement(
                        tabID,
                        isFavorite: false,
                        isPinned: true,
                        folderID: nil,
                        before: nil,
                        appendToEnd: true
                    )
                    store.finishTabDrop(tabID, from: sourcePlacement, to: .pinned)
                    return
                }
            }
            // Drops land through SwiftUI drop delegates, which can finish
            // after this callback — clear truly abandoned drags only after
            // the same settle delay the polling watcher used.
            Task { @MainActor [weak store] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let store, store.draggedTabID == tabID else { return }
                store.finishTabDrag()
            }
        }
    }
}

/// Row background that makes the row an AppKit tab drag source.
internal struct TabDragSourceBackground: NSViewRepresentable {
    let store: BrowserStore
    let tabID: UUID

    func makeNSView(context: Context) -> TabDragSourceAnchorView {
        let view = TabDragSourceAnchorView()
        view.store = store
        view.tabID = tabID
        return view
    }

    func updateNSView(_ view: TabDragSourceAnchorView, context: Context) {
        view.store = store
        view.tabID = tabID
    }
}

/// The sidebar row as a drag image, Arc-style: the row's rounded shape at
/// the row's own size with its hover fill, favicon and title, so the drag
/// reads as the row lifting off the list. Drawn with AppKit primitives for
/// the same reason as the ghost card below.
internal enum TabDragRowImage {
    /// Room around the row for its shadow. The dragging frame grows by the
    /// same amount so the row itself still lines up with the row it left.
    static let shadowPadding: CGFloat = 12

    @MainActor
    static func make(for tab: BrowserTab, size: NSSize) -> NSImage {
        let title = tab.title.isEmpty ? (tab.url?.host() ?? "New Tab") : tab.title
        let faviconData = tab.faviconData
        let faviconSymbol = tab.faviconSymbol
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let padding = shadowPadding
        let canvas = NSSize(
            width: size.width + padding * 2,
            height: size.height + padding * 2
        )

        return NSImage(size: canvas, flipped: true) { _ in
            let card = NSRect(x: padding, y: padding, width: size.width, height: size.height)
            // The hairline sits inside the card, not straddling its edge:
            // half a pixel of stroke used to fall outside the image and the
            // corners came back squared off.
            let shape = NSBezierPath(
                roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                xRadius: InterfaceStyle.sidebarRowCornerRadius,
                yRadius: InterfaceStyle.sidebarRowCornerRadius
            )

            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.5 : 0.2)
            shadow.shadowBlurRadius = 9
            shadow.shadowOffset = .zero
            shadow.set()
            // Opaque, so the row reads the same over the list, the page, or
            // another app — a translucent card picked up whatever it crossed.
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            // Zen's selected-row tint over that base, the fill the row wears
            // when it is the active tab.
            (isDark
                ? NSColor.white.withAlphaComponent(0.20)
                : NSColor.white.withAlphaComponent(0.85)).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()

            let iconRect = NSRect(
                x: card.minX + 8,
                y: card.minY + (card.height - 16) / 2,
                width: 16,
                height: 16
            )
            if let faviconData, let favicon = NSImage(data: faviconData) {
                favicon.draw(in: iconRect)
            } else if let symbol = NSImage(
                systemSymbolName: faviconSymbol,
                accessibilityDescription: nil
            ) {
                let configured = symbol.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
                ) ?? symbol
                configured.draw(in: iconRect)
            }

            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let textHeight = font.ascender - font.descender
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(
                in: NSRect(
                    x: card.minX + 32,
                    y: card.minY + (card.height - textHeight) / 2,
                    width: card.width - 32 - 10,
                    height: textHeight
                ),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
            )
            return true
        }
    }
}

/// AppKit-drawn ghost page card used as the dragging session's drag image.
/// Drawn with plain NSBezierPath/NSString drawing rather than offscreen
/// SwiftUI rendering, which is not dependable across macOS versions — a drag
/// image that fails to render would make the whole session invisible.
internal enum TabDragGhostImage {
    @MainActor
    static func make(for tab: BrowserTab) -> NSImage {
        let title = tab.title.isEmpty ? (tab.url?.host() ?? "New Tab") : tab.title
        let faviconData = tab.faviconData
        let faviconSymbol = tab.faviconSymbol
        let size = NSSize(width: 168, height: 112)

        return NSImage(size: size, flipped: true) { rect in
            let card = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 9,
                yRadius: 9
            )
            NSGraphicsContext.current?.saveGraphicsState()
            card.addClip()

            NSColor.controlBackgroundColor.setFill()
            rect.fill()

            let headerRect = NSRect(x: 0, y: 0, width: rect.width, height: 27)
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            headerRect.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 27, width: rect.width, height: 1).fill()

            let iconRect = NSRect(x: 9, y: 7, width: 13, height: 13)
            if let faviconData, let favicon = NSImage(data: faviconData) {
                favicon.draw(in: iconRect)
            } else if let symbol = NSImage(
                systemSymbolName: faviconSymbol,
                accessibilityDescription: nil
            ) {
                let configured = symbol.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
                ) ?? symbol
                configured.draw(in: iconRect)
            }

            (title as NSString).draw(
                in: NSRect(x: 28, y: 6, width: rect.width - 37, height: 16),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
            )

            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            for (index, fraction) in [0.82, 0.56, 0.7].enumerated() {
                NSBezierPath(
                    roundedRect: NSRect(
                        x: 10,
                        y: 38 + CGFloat(index) * 11,
                        width: (rect.width - 20) * fraction,
                        height: 5
                    ),
                    xRadius: 2.5,
                    yRadius: 2.5
                ).fill()
            }

            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.separatorColor.setStroke()
            card.lineWidth = 1
            card.stroke()
            return true
        }
    }
}
