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
    @ObservedObject var store: BrowserStore
    let obscuredContentInsets: BrowserChromeInsets

    func makeNSView(context: Context) -> NSView {
        SplitWebViewHostContainer()
    }

    func updateNSView(_ container: NSView, context: Context) {
        store.webCoordinator.ensureLoaded(tab)
        guard let container = container as? SplitWebViewHostContainer else { return }
        container.configure(
            tabID: tab.id,
            obscuredContentInsets: obscuredContentInsets,
            coordinator: store.webCoordinator
        )
    }
}

private final class SplitWebViewHostContainer: NSView {
    private var tabID: UUID?
    private var obscuredContentInsets = BrowserChromeInsets()
    private weak var coordinator: WebViewCoordinator?

    func configure(
        tabID: UUID,
        obscuredContentInsets: BrowserChromeInsets,
        coordinator: WebViewCoordinator
    ) {
        self.tabID = tabID
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

        coordinator.hostSplitWebView(
            for: tabID,
            in: self,
            obscuredContentInsets: obscuredContentInsets
        )
    }
}

/// Persistent host for the active tab's web view. Unlike swapping
/// representables per tab, this keeps background web views parented so
/// media playback can survive tab switches and move into the mini player.
struct ActiveWebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    @ObservedObject var store: BrowserStore
    let obscuredContentInsets: BrowserChromeInsets

    func makeNSView(context: Context) -> NSView {
        WebViewHostContainer()
    }

    func updateNSView(_ container: NSView, context: Context) {
        store.webCoordinator.ensureLoaded(tab)
        guard let container = container as? WebViewHostContainer else { return }
        container.configure(
            tabID: tab.id,
            excludingTabIDs: store.activeSplitGroupTabIDs,
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
    private var obscuredContentInsets = BrowserChromeInsets()
    private weak var coordinator: WebViewCoordinator?

    func configure(
        tabID: UUID,
        excludingTabIDs: Set<UUID>,
        obscuredContentInsets: BrowserChromeInsets,
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
