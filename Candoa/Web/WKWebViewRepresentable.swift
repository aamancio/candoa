import SwiftUI
import WebKit

struct WKWebViewRepresentable: NSViewRepresentable {
    let tab: BrowserTab
    @ObservedObject var store: BrowserStore

    func makeNSView(context: Context) -> WKWebView {
        store.webCoordinator.webView(for: tab)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        store.webCoordinator.ensureLoaded(tab)
    }
}

/// Shared behaviour for the AppKit views that host a live `WKWebView`: the
/// lane-inset box an attached Web Inspector is laid out in, and the page-area
/// insets that box leaves for the page itself.
class WebPaneHostView: NSView {
    let inspectorLane = InspectorLaneHost()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(inspectorLane)
        // WebKit re-splits the card between page and inspector on its own
        // schedule (attach, detach, and every inspector resize drag), so the
        // page's obscured insets are re-derived from the split it settled on.
        inspectorLane.onPageAreaChange = { [weak self] in
            self?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Pins the hosted web views to the host's own bounds — they deliberately
    /// span the reserved interface lanes — and gives the inspector lane the
    /// visible page card.
    func layoutHostedSubviews(laneInsets: BrowserInterfaceInsets) {
        for subview in subviews where subview !== inspectorLane {
            subview.frame = bounds
        }

        inspectorLane.resizeCard(
            to: NSRect(
                x: laneInsets.leading,
                y: 0,
                width: max(bounds.width - laneInsets.leading - laneInsets.trailing, 0),
                height: bounds.height
            )
        )
    }

    /// What the hosted page has to be inset by: the reserved interface lanes,
    /// plus whatever an attached inspector has taken out of the card.
    var pageAreaInsets: NSEdgeInsets {
        let pageArea = inspectorLane.convert(inspectorLane.pageArea.frame, to: self)
        return NSEdgeInsets(
            top: max(bounds.maxY - pageArea.maxY, 0),
            left: max(pageArea.minX - bounds.minX, 0),
            bottom: max(pageArea.minY - bounds.minY, 0),
            right: max(bounds.maxX - pageArea.maxX, 0)
        )
    }

    /// Web views are parented *under* the inspector lane so an attached
    /// inspector paints over the page instead of behind it.
    func hostSubview(_ view: NSView) {
        addSubview(view, positioned: .below, relativeTo: inspectorLane)
    }
}

/// The box an attached Web Inspector is laid out in: the visible page card.
///
/// WebKit sizes an attached inspector against the *superview bounds* of the
/// page's inspector attachment view, and rewrites that view's frame to the
/// area left over (`WebInspectorUIProxyMac::inspectedViewFrameDidChange`).
/// Candoa's live web views deliberately span their whole host — the sidebar
/// and Eli lanes are reserved by a mask, never by resizing a live WKWebView
/// (see `BrowserInterfaceMaskModifier`) — so while a web view was its own
/// attachment view the inspector spanned those lanes too, and an open sidebar
/// covered the inspector's toolbar, its close button first.
///
/// The web view points WebKit at `pageArea` instead: an empty stand-in filling
/// this lane-inset host. WebKit then fits the inspector to the visible card and
/// shrinks the stand-in to what is left for the page — which is exactly the
/// rectangle the page's obscured content insets have to describe, so the
/// stand-in's frame is what drives them.
final class InspectorLaneHost: NSView {
    /// The view WebKit treats as the inspected page. It never draws and never
    /// takes a click; only its frame carries information.
    let pageArea = InspectorPageAreaView()
    /// Fires whenever WebKit re-splits this host between page and inspector.
    var onPageAreaChange: (() -> Void)?
    // nonisolated(unsafe): deinit is not main-actor isolated, and the token is
    // only ever touched there and in init.
    private nonisolated(unsafe) var pageAreaFrameObserver: (any NSObjectProtocol)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pageArea.frame = bounds
        pageArea.autoresizingMask = [.width, .height]
        addSubview(pageArea)

        pageAreaFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pageArea,
            queue: nil
        ) { [weak self] _ in
            // Frames only ever change on the main thread; AppKit's own
            // observer of this same notification is what drives WebKit's side.
            MainActor.assumeIsolated {
                self?.onPageAreaChange?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let pageAreaFrameObserver {
            NotificationCenter.default.removeObserver(pageAreaFrameObserver)
        }
    }

    /// True once WebKit has parked an inspector's own web view in here.
    var isInspectorAttached: Bool {
        subviews.contains { $0 !== pageArea }
    }

    /// Takes the card's frame and hands the whole of it to the stand-in —
    /// unless the inspector is attached, in which case WebKit owns the split:
    /// autoresizing carries both panes through the resize and its own
    /// frame-change handler corrects them straight after.
    ///
    /// The stand-in is resized here rather than in `layout()` because WebKit
    /// reads its frame to decide whether docking is even possible (it wants at
    /// least 500pt of width), and that question can be asked long before
    /// AppKit gets around to laying this view out.
    func resizeCard(to frame: NSRect) {
        self.frame = frame
        guard !isInspectorAttached else { return }
        pageArea.frame = bounds
    }

    override func layout() {
        super.layout()
        guard !isInspectorAttached else { return }
        pageArea.frame = bounds
    }

    /// Transparent to the pointer wherever the inspector is not: every click
    /// the inspector does not want belongs to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// WebKit's stand-in for the inspected page — see `InspectorLaneHost`.
final class InspectorPageAreaView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SplitWebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    let paneIndex: Int
    @ObservedObject var store: BrowserStore
    let laneInsets: BrowserInterfaceInsets
    var onPaneHoverChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let container = SplitWebViewHostContainer()
        // A plain NSView is accessibility-ignored; expose the pane as a group
        // so UI tests can address and click it.
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        store.webCoordinator.ensureLoaded(tab)
        guard let container = container as? SplitWebViewHostContainer else { return }
        container.setAccessibilityIdentifier("split-pane-\(paneIndex)")
        let tabID = tab.id
        container.configure(
            tabID: tabID,
            laneInsets: laneInsets,
            coordinator: store.webCoordinator,
            onPaneInteraction: { [weak store] in
                guard let store, store.activeTabID != tabID else { return }
                store.focusSplitTab(tabID)
            },
            onPaneHoverChange: onPaneHoverChange
        )
    }
}

private final class SplitWebViewHostContainer: WebPaneHostView {
    private var tabID: UUID?
    private var laneInsets = BrowserInterfaceInsets()
    private weak var coordinator: WebViewCoordinator?
    private var onPaneInteraction: (() -> Void)?
    private var onPaneHoverChange: ((Bool) -> Void)?
    private var mouseDownMonitor: Any?
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInPane = false

    func configure(
        tabID: UUID,
        laneInsets: BrowserInterfaceInsets,
        coordinator: WebViewCoordinator,
        onPaneInteraction: @escaping () -> Void,
        onPaneHoverChange: ((Bool) -> Void)?
    ) {
        self.tabID = tabID
        self.laneInsets = laneInsets
        self.coordinator = coordinator
        self.onPaneInteraction = onPaneInteraction
        self.onPaneHoverChange = onPaneHoverChange
        needsLayout = true
    }

    // MARK: - Pane hover
    // Tracked here with an AppKit tracking area because the hosted WKWebView
    // consumes pointer events before SwiftUI hover ever fires. Reveals the
    // pane's control pill while the pointer is anywhere over the pane.

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        // .mouseMoved as well as enter/exit: enter events can be missed when
        // panes relayout under a stationary pointer, so moves re-assert the
        // hover. Tracking areas fire on geometry even while the WKWebView
        // subview consumes the events themselves.
        // .activeAlways: the hover-revealed pill is the only path to a
        // pane's controls, so the reveal must not depend on key status —
        // the first pass over a background window should surface it too.
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        reportPaneHover(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        reportPaneHover(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInPane(false)
    }

    private func reportPaneHover(for event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        setPointerInPane(bounds.contains(location))
    }

    private func setPointerInPane(_ isInside: Bool) {
        guard isPointerInPane != isInside else { return }
        isPointerInPane = isInside
        onPaneHoverChange?(isInside)
    }

    override func layout() {
        super.layout()
        layoutHostedSubviews(laneInsets: laneInsets)

        guard
            window != nil,
            !bounds.isEmpty,
            let tabID,
            let coordinator
        else {
            return
        }

        coordinator.hostSplitWebView(
            for: tabID,
            in: self,
            pageAreaInsets: pageAreaInsets
        )
    }

    // Clicking anywhere inside a pane's web content commits that tab as
    // active, so every tab-scoped command (reload, copy URL, zoom, find,
    // back/forward) targets the pane the user is actually working in. The
    // WKWebView consumes mouse events itself, so the commit rides a local
    // mouse-down monitor — event-driven, no polling — that exists only while
    // this pane is mounted in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMouseDownMonitor()
        } else {
            installMouseDownMonitorIfNeeded()
        }
    }

    private func installMouseDownMonitorIfNeeded() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Local event monitors always run on the main thread.
            MainActor.assumeIsolated {
                self?.commitPaneFocusIfNeeded(for: event)
            }
            return event
        }
    }

    private func commitPaneFocusIfNeeded(for event: NSEvent) {
        guard let window, event.window === window else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        // Overlaying chrome (command palette, find bar, toasts) floats above
        // the panes; a click that lands on it must not steal pane focus, so
        // only clicks whose hit view lives inside this pane commit.
        guard
            let contentView = window.contentView,
            let hitView = contentView.hitTest(contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
            hitView.isDescendant(of: self)
        else { return }
        onPaneInteraction?()
    }

    private func removeMouseDownMonitor() {
        guard let mouseDownMonitor else { return }
        NSEvent.removeMonitor(mouseDownMonitor)
        self.mouseDownMonitor = nil
    }
}

/// Persistent host for the active tab's web view. Unlike swapping
/// representables per tab, this keeps background web views parented so
/// media playback can survive tab switches and move into the mini player.
struct ActiveWebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    @ObservedObject var store: BrowserStore
    let laneInsets: BrowserInterfaceInsets

    func makeNSView(context: Context) -> NSView {
        let container = WebViewHostContainer()
        // A plain NSView is accessibility-ignored, and ignored views are
        // dropped from the accessibility tree along with their identifier.
        // Expose the container as a group so it stays addressable.
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier("active-webview-host")
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        store.webCoordinator.ensureLoaded(tab)
        guard let container = container as? WebViewHostContainer else { return }
        container.configure(
            tabID: tab.id,
            excludingTabIDs: store.displayedSplitTabIDs,
            laneInsets: laneInsets,
            coordinator: store.webCoordinator
        )
    }
}

/// The active web view is manually reparented so background media tabs can
/// stay alive without keeping every background page in the hierarchy. Keep
/// hosted web views pinned to the SwiftUI-assigned container bounds whenever
/// the window or surface layout changes.
private final class WebViewHostContainer: WebPaneHostView {
    private var tabID: UUID?
    private var excludingTabIDs = Set<UUID>()
    private var laneInsets = BrowserInterfaceInsets()
    private weak var coordinator: WebViewCoordinator?

    func configure(
        tabID: UUID,
        excludingTabIDs: Set<UUID>,
        laneInsets: BrowserInterfaceInsets,
        coordinator: WebViewCoordinator
    ) {
        self.tabID = tabID
        self.excludingTabIDs = excludingTabIDs
        self.laneInsets = laneInsets
        self.coordinator = coordinator
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutHostedSubviews(laneInsets: laneInsets)

        guard
            window != nil,
            !bounds.isEmpty,
            let tabID,
            let coordinator
        else {
            return
        }

        coordinator.hostActiveWebView(
            for: tabID,
            in: self,
            excludingTabIDs: excludingTabIDs,
            pageAreaInsets: pageAreaInsets
        )
    }
}

struct MiniPlayerWebViewHost: NSViewRepresentable {
    let tabID: UUID
    /// The video's on-page rect the player is gliding out from, while it
    /// is: the page is adopted at full layout and scaled into the player
    /// (see `hostMiniPlayerWebView`). Nil for a plain appearance.
    let summonPageFrame: CGRect?
    @ObservedObject var store: BrowserStore

    func makeNSView(context: Context) -> MiniPlayerHostView {
        let view = MiniPlayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ container: MiniPlayerHostView, context: Context) {
        // While a return is landing the page sits under the active one,
        // restoring its full layout; re-hosting would strip it down again.
        // (The player shows the freeze frame meanwhile.)
        guard store.pendingMiniPlayerReturnTabID != tabID else { return }

        // updateNSView runs inside the SwiftUI commit, before this container
        // is laid out at the panel's corner — adopting the web view now
        // flashes it at the window's top-left. Wait for the first real
        // layout, which also guarantees the active host swap has happened.
        let coordinator = store.webCoordinator
        if container.isPositioned {
            coordinator.hostMiniPlayerWebView(for: tabID, in: container, summonPageFrame: summonPageFrame)
        } else {
            let tabID = tabID
            let summonPageFrame = summonPageFrame
            container.onPositioned = { [weak container] in
                guard let container else { return }
                coordinator.hostMiniPlayerWebView(for: tabID, in: container, summonPageFrame: summonPageFrame)
            }
        }
    }

    static func dismantleNSView(_ nsView: MiniPlayerHostView, coordinator: ()) {
        nsView.onPositioned = nil
        nsView.onResize = nil
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Reports the first layout pass where the view has real geometry in a
/// window, so the web view adoption can wait until the panel is in place.
final class MiniPlayerHostView: NSView {
    private(set) var isPositioned = false
    var onPositioned: (() -> Void)?
    /// The player was resized (its resize handles): the hosted page's
    /// presentation follows.
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard window != nil, !frame.isEmpty else { return }
        if !isPositioned {
            isPositioned = true
            lastSize = frame.size
            let callback = onPositioned
            onPositioned = nil
            callback?()
            return
        }
        if frame.size != lastSize {
            lastSize = frame.size
            onResize?()
        }
    }
}
