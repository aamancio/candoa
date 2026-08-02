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

struct SplitWebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    let paneIndex: Int
    @ObservedObject var store: BrowserStore
    let obscuredContentInsets: BrowserInterfaceInsets

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
            obscuredContentInsets: obscuredContentInsets,
            coordinator: store.webCoordinator,
            onPaneInteraction: { [weak store] in
                guard let store, store.activeTabID != tabID else { return }
                store.focusSplitTab(tabID)
            }
        )
    }
}

private final class SplitWebViewHostContainer: NSView {
    private var tabID: UUID?
    private var obscuredContentInsets = BrowserInterfaceInsets()
    private weak var coordinator: WebViewCoordinator?
    private var onPaneInteraction: (() -> Void)?
    private var mouseDownMonitor: Any?

    func configure(
        tabID: UUID,
        obscuredContentInsets: BrowserInterfaceInsets,
        coordinator: WebViewCoordinator,
        onPaneInteraction: @escaping () -> Void
    ) {
        self.tabID = tabID
        self.obscuredContentInsets = obscuredContentInsets
        self.coordinator = coordinator
        self.onPaneInteraction = onPaneInteraction
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }

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
            obscuredContentInsets: obscuredContentInsets
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

    deinit {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
    }
}

/// Persistent host for the active tab's web view. Unlike swapping
/// representables per tab, this keeps background web views parented so
/// media playback can survive tab switches and move into the mini player.
struct ActiveWebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    @ObservedObject var store: BrowserStore
    let obscuredContentInsets: BrowserInterfaceInsets

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
            obscuredContentInsets: obscuredContentInsets,
            coordinator: store.webCoordinator
        )
    }
}

/// The active web view is manually reparented so background media tabs can
/// stay alive without keeping every background page in the hierarchy. Keep
/// hosted web views pinned to the SwiftUI-assigned container bounds whenever
/// the window or surface layout changes.
private final class WebViewHostContainer: NSView {
    private var tabID: UUID?
    private var excludingTabIDs = Set<UUID>()
    private var obscuredContentInsets = BrowserInterfaceInsets()
    private weak var coordinator: WebViewCoordinator?

    func configure(
        tabID: UUID,
        excludingTabIDs: Set<UUID>,
        obscuredContentInsets: BrowserInterfaceInsets,
        coordinator: WebViewCoordinator
    ) {
        self.tabID = tabID
        self.excludingTabIDs = excludingTabIDs
        self.obscuredContentInsets = obscuredContentInsets
        self.coordinator = coordinator
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }

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
            obscuredContentInsets: obscuredContentInsets
        )
    }
}

struct MiniPlayerWebViewHost: NSViewRepresentable {
    let tabID: UUID
    @ObservedObject var store: BrowserStore

    func makeNSView(context: Context) -> MiniPlayerHostView {
        let view = MiniPlayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ container: MiniPlayerHostView, context: Context) {
        // During the return-to-tab morph the page has been handed back and
        // is relayouting hidden; re-hosting would strip it down again
        // mid-flight. (The player shows the freeze frame instead.)
        guard store.miniPlayerReturn == nil else { return }

        // updateNSView runs inside the SwiftUI commit, before this container
        // is laid out at the panel's corner — adopting the web view now
        // flashes it at the window's top-left. Wait for the first real
        // layout, which also guarantees the active host swap has happened.
        let coordinator = store.webCoordinator
        if container.isPositioned {
            coordinator.hostMiniPlayerWebView(for: tabID, in: container)
        } else {
            let tabID = tabID
            container.onPositioned = { [weak container] in
                guard let container else { return }
                coordinator.hostMiniPlayerWebView(for: tabID, in: container)
            }
        }
    }

    static func dismantleNSView(_ nsView: MiniPlayerHostView, coordinator: ()) {
        nsView.onPositioned = nil
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Reports the first layout pass where the view has real geometry in a
/// window, so the web view adoption can wait until the panel is in place.
final class MiniPlayerHostView: NSView {
    private(set) var isPositioned = false
    var onPositioned: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !isPositioned, window != nil, !bounds.isEmpty else { return }
        isPositioned = true
        let callback = onPositioned
        onPositioned = nil
        callback?()
    }
}
