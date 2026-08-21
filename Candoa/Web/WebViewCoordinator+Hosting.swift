import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    // MARK: - Web View Hosting

    /// Hosts the active tab's web view inside a persistent container while
    /// keeping background tabs' web views parented (hidden) underneath it.
    /// Unparenting a web view tears down media presentation and throttles
    /// playback, so the floating mini player explicitly rehosts its tab.
    func hostActiveWebView(
        for tabID: UUID,
        in container: NSView,
        excludingTabIDs: Set<UUID>,
        pageAreaInsets: NSEdgeInsets
    ) {
        guard let activeWebView = webViews[tabID] else { return }
        // A video blown up to full screen belongs to WebKit until it comes
        // back (see `isInElementFullscreen`); hosting it now would pull the
        // page out of the full-screen window mid-animation.
        guard !isInElementFullscreen(activeWebView) else { return }
        syncHostBackground(in: container, with: activeWebView)
        applyObscuredContentInsets(pageAreaInsets, to: activeWebView)
        attachInspector(of: activeWebView, to: container)
        reportInspectorPlacementForUITesting(for: tabID)
        if miniPlayerHostedTabID == tabID {
            restoreMiniPlayerPresentation(tabID: tabID)
            miniPlayerHostedTabID = nil
            miniPlayerSummon = nil
        }

        for (id, webView) in webViews where id != tabID && !excludingTabIDs.contains(id) && id != miniPlayerHostedTabID {
            // A backgrounded page no longer owns this host's inspector lane;
            // leaving it pointed here would lay its inspector out over the
            // page that took its place.
            attachInspector(of: webView, to: nil)
            if keepsBackgroundWebViewParented(id) {
                guard webView.superview !== container else { continue }
                webView.frame = container.bounds
                webView.autoresizingMask = [.width, .height]
                webView.isHidden = true
                container.addSubview(webView, positioned: .below, relativeTo: nil)
            } else if webView.superview === container, webView.isHidden {
                // Idle background pages leave the hierarchy entirely so WebKit
                // can throttle their timers and rendering toward zero.
                webView.removeFromSuperview()
            }
        }

        guard hostedActiveTabID != tabID || activeWebView.superview !== container else { return }
        let previousActiveTabID = hostedActiveTabID
        hostedActiveTabID = tabID

        activeWebView.frame = container.bounds
        activeWebView.autoresizingMask = [.width, .height]
        activeWebView.isHidden = false
        activeWebView.removeFromSuperview()
        addHostedSubview(activeWebView, to: container)

        if restoringTabIDs.contains(tabID), let snapshot = wakeSnapshots[tabID] {
            presentRestoreOverlay(snapshot, for: tabID, in: container)
        }

        focusActiveWebViewIfIdle()

        // The outgoing web view stays visible (covered by the new active one)
        // for a beat so media keeps rendering while the mini player attaches.
        guard let previousActiveTabID, previousActiveTabID != tabID else { return }
        captureWakeSnapshot(for: previousActiveTabID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard
                let self,
                self.hostedActiveTabID != previousActiveTabID,
                // The mini player may have adopted this web view in the
                // meantime; hiding it would blank the floating player.
                self.miniPlayerHostedTabID != previousActiveTabID,
                let webView = self.webViews[previousActiveTabID],
                webView.superview != nil
            else {
                return
            }
            webView.isHidden = true
        }
    }

    /// Hands keyboard focus to the active page so a freshly opened tab scrolls,
    /// selects, and copies without needing a click first. AppKit only promotes a
    /// web view to first responder on mouse-down, and the palette hands focus
    /// back to the window on dismiss, so without this the window itself stays
    /// first responder and every Edit command validates as disabled.
    ///
    /// Focus is claimed from anything except an active text editor, so the
    /// command palette, address bar, find bar, Eli, and the sidebar's rename
    /// fields are never interrupted mid-keystroke.
    func focusActiveWebViewIfIdle() {
        guard
            let tabID = hostedActiveTabID,
            let webView = webViews[tabID],
            let window = webView.window,
            !webView.isHidden
        else {
            return
        }

        let responder = window.firstResponder
        if let focusedView = responder as? NSView,
           focusedView === webView || focusedView.isDescendant(of: webView) {
            // WebKit parks focus on its own content subview; re-setting it here
            // would knock out the page's internal focus (and any focused field).
            return
        }

        // Someone is typing. The command palette, address bar, find bar, Eli, and
        // the sidebar's rename fields all edit through the window's field editor,
        // so never pull focus out from under them. Everything else is ours to
        // claim — including the outgoing tab's web view, which stays first
        // responder until it is unparented and otherwise strands the new page.
        guard !(responder is NSText) else { return }

        window.makeFirstResponder(webView)
    }

    /// Whether the active page currently holds keyboard focus. Surfaced in the
    /// UI-testing state string because focus is invisible to element queries and
    /// screenshots alike.
    var activeWebViewHasKeyboardFocus: Bool {
        guard
            let tabID = hostedActiveTabID,
            let webView = webViews[tabID],
            let focusedView = webView.window?.firstResponder as? NSView
        else {
            return false
        }
        return focusedView === webView || focusedView.isDescendant(of: webView)
    }

    func hostSplitWebView(
        for tabID: UUID,
        in container: NSView,
        pageAreaInsets: NSEdgeInsets
    ) {
        guard let webView = webViews[tabID] else { return }
        guard !isInElementFullscreen(webView) else { return }
        syncHostBackground(in: container, with: webView)
        applyObscuredContentInsets(pageAreaInsets, to: webView)
        attachInspector(of: webView, to: container)
        if miniPlayerHostedTabID == tabID {
            restoreMiniPlayerPresentation(tabID: tabID)
            miniPlayerHostedTabID = nil
            miniPlayerSummon = nil
        }

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = false

        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        addHostedSubview(webView, to: container)

        if restoringTabIDs.contains(tabID), let snapshot = wakeSnapshots[tabID] {
            presentRestoreOverlay(snapshot, for: tabID, in: container)
        }
    }

    // MARK: - Element full screen

    /// True while WebKit owns this page's presentation because a video (or
    /// any element) asked for full screen.
    ///
    /// WebKit does this by swapping the web view out of its host for a
    /// placeholder and re-parenting it into its own full-screen window. Both
    /// of Candoa's hosts re-assert their hosting from `layout()`, which runs
    /// again while that swap is in flight — and re-hosting yanked the page
    /// straight back into the browser window, leaving the full-screen window
    /// black with nothing in it. So hosting stands down for the round trip;
    /// `elementFullscreenStateDidChange` re-runs it when the page returns.
    func isInElementFullscreen(_ webView: WKWebView) -> Bool {
        webView.fullscreenState != .notInFullscreen
    }

    /// Follows a page in and out of element full screen.
    ///
    /// Going in, the reserved sidebar and Eli lanes do not exist on the
    /// full-screen window, so the page's obscured content insets — which
    /// describe those lanes — have to go with them, or the video is laid out
    /// around chrome that is not on screen. Coming back, the host re-derives
    /// them from its live lane geometry on the next layout pass.
    func elementFullscreenStateDidChange(for webView: WKWebView) {
        switch webView.fullscreenState {
        case .enteringFullscreen, .inFullscreen:
            applyObscuredContentInsets(NSEdgeInsets(), to: webView)
        default:
            // WebKit re-parents the web view as part of the same exit, and a
            // host whose geometry never changed has no reason to lay out on
            // its own — ask it, so the page is re-hosted and re-inset.
            hostOfWebView(webView)?.needsLayout = true
        }
    }

    private func hostOfWebView(_ webView: WKWebView) -> WebPaneHostView? {
        var candidate: NSView? = webView.superview
        while let view = candidate {
            if let host = view as? WebPaneHostView { return host }
            candidate = view.superview
        }
        return nil
    }

    /// Match the host to the page-derived under-page color so any transient
    /// unpainted edge during WebKit's one-time interface-inset commit blends with
    /// the page instead of flashing the unrelated window backdrop.
    func syncHostBackground(in container: NSView, with webView: WKWebView) {
        container.wantsLayer = true
        container.layer?.backgroundColor = webView.underPageBackgroundColor.cgColor
    }

    func applyObscuredContentInsets(_ insets: NSEdgeInsets, to webView: WKWebView) {
        guard #available(macOS 26.0, *) else { return }
        let current = webView.obscuredContentInsets
        guard current.top != insets.top
            || current.left != insets.left
            || current.bottom != insets.bottom
            || current.right != insets.right
        else {
            return
        }
        webView.obscuredContentInsets = insets
    }

    /// Points WebKit's attached Web Inspector at the host's lane-inset
    /// stand-in, so the inspector is laid out inside the visible page card
    /// instead of running under the sidebar (see `InspectorLaneHost`). Passing
    /// no host hands the page back its own default, which is the web view.
    ///
    /// Private API (`-[WKWebView _setInspectorAttachmentView:]`), probed first
    /// like the rest of the inspector bridging: an SDK that drops it just
    /// leaves the inspector where WebKit would have put it anyway.
    func attachInspector(of webView: WKWebView, to container: NSView?) {
        let standIn = (container as? WebPaneHostView)?.inspectorLane.pageArea
        // Re-setting runs WebKit's whole attach path, which re-parents the
        // inspector and steals first responder; only move a real change.
        guard inspectorAttachmentView(of: webView) !== standIn else { return }

        let setter = NSSelectorFromString("_setInspectorAttachmentView:")
        guard webView.responds(to: setter) else { return }
        webView.perform(setter, with: standIn)
    }

    func inspectorAttachmentView(of webView: WKWebView) -> NSView? {
        let getter = NSSelectorFromString("_inspectorAttachmentView")
        guard webView.responds(to: getter) else { return nil }
        return webView.perform(getter)?.takeUnretainedValue() as? NSView
    }

    /// Web views are parented under the host's inspector lane so an attached
    /// inspector paints over the page rather than behind it.
    private func addHostedSubview(_ webView: WKWebView, to container: NSView) {
        if let host = container as? WebPaneHostView {
            host.hostSubview(webView)
        } else {
            container.addSubview(webView)
        }
    }

    /// Adopts the tab's web view into the floating player.
    ///
    /// The page keeps its full layout the whole time it floats — the view
    /// stays at the active host's size and lane insets, and the player-size
    /// presentation is pure style (everything but the video invisible, the
    /// video pinned at the layout viewport's top-left at player size; see
    /// `WebPageScripts`). The host then shows just that top-left region, 1:1,
    /// by way of its `bounds`. Nothing relayouts on the way in or out, so
    /// the video plays through the summon glide without a hitch, and going
    /// back to the tab is a style change away from a page that is already
    /// laid out and painted at full size.
    ///
    /// With a summon page frame the host first shows the video's on-page
    /// region instead (the glide's stage); `finishMiniPlayerSummon` hands
    /// over when the glide lands.
    func hostMiniPlayerWebView(for tabID: UUID, in container: MiniPlayerHostView, summonPageFrame: CGRect?) {
        guard let webView = webViews[tabID] else { return }
        // Re-entered on every store update the host observes (playback
        // progress ticks once a second); an already-adopted page has
        // nothing to redo.
        guard miniPlayerHostedTabID != tabID || webView.superview !== container else { return }
        // Adopting a different tab must first restore the previously hosted
        // tab's page; otherwise that page is left stripped down to its video
        // element and shows a black shell when reopened from the sidebar.
        if let previousID = miniPlayerHostedTabID, previousID != tabID {
            detachMiniPlayerWebView(for: previousID)
        }
        // The floating player is not a pane host, so its page hands the
        // inspector back to WebKit's own default placement.
        attachInspector(of: webView, to: nil)
        miniPlayerHostedTabID = tabID
        // A page that had left the hierarchy comes back at the active host's
        // geometry, which is the layout everything below assumes.
        if let activeID = hostedActiveTabID, let activeWebView = webViews[activeID],
           activeWebView.frame.size != .zero, webView.frame.size != activeWebView.frame.size {
            webView.frame = CGRect(origin: .zero, size: activeWebView.frame.size)
            applyObscuredContentInsets(pageInsets(of: activeWebView), to: webView)
        }
        webView.autoresizingMask = []
        webView.frame = CGRect(origin: .zero, size: webView.frame.size)
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        container.onResize = { [weak self, weak container] in
            guard let self, let container, self.miniPlayerHostedTabID == tabID, self.miniPlayerSummon == nil else { return }
            self.presentMiniPlayer(webView, tabID: tabID, in: container)
        }

        if let summonPageFrame,
           let stage = summonStage(for: summonPageFrame, of: webView, in: container) {
            miniPlayerSummon = MiniPlayerSummonHandoff(tabID: tabID, pageFrame: summonPageFrame)
            webView.isHidden = false
            container.bounds = stage
            return
        }

        // A plain appearance (no glide): the region shows the page's own
        // top-left until the presentation commits, so stay hidden until then.
        webView.isHidden = true
        presentMiniPlayer(webView, tabID: tabID, in: container)
    }

    /// The visible-page region to scale into the player, in the host's
    /// (bottom-left origin) coordinates, widened or heightened as needed
    /// to keep the player's aspect — so the video is scaled uniformly.
    private func summonStage(for pageFrame: CGRect, of webView: WKWebView, in container: NSView) -> CGRect? {
        let hostSize = container.frame.size
        let viewRect = viewRect(forPageRect: pageFrame, in: webView)
        guard hostSize.width > 0, hostSize.height > 0, viewRect.width > 0, viewRect.height > 0 else { return nil }
        var stage = viewRect
        let hostAspect = hostSize.width / hostSize.height
        if stage.width / stage.height > hostAspect {
            let height = stage.width / hostAspect
            stage.origin.y -= (height - stage.height) / 2
            stage.size.height = height
        } else {
            let width = stage.height * hostAspect
            stage.origin.x -= (width - stage.width) / 2
            stage.size.width = width
        }
        // Top-left page coordinates → the web view's bottom-left frame.
        return CGRect(
            x: stage.minX,
            y: webView.frame.height - stage.maxY,
            width: stage.width,
            height: stage.height
        )
    }

    /// The player-size region of the page: the layout viewport's top-left
    /// corner, in the host's (bottom-left origin) coordinates.
    private func presentationRegion(of webView: WKWebView, playerSize: CGSize) -> CGRect {
        let insets = pageInsets(of: webView)
        return CGRect(
            x: insets.left,
            y: webView.frame.height - insets.top - playerSize.height,
            width: playerSize.width,
            height: playerSize.height
        )
    }

    private static let doAfterNextPresentationUpdate = NSSelectorFromString("_doAfterNextPresentationUpdate:")

    /// Runs `block` in the transaction that commits the page's next layer
    /// tree — WebKit's own after-commit callback, so a host-side change can
    /// land in the same frame as the page change it belongs to. Without the
    /// callback (probed: private API), a short ceiling stands in.
    private func afterNextPresentationUpdate(of webView: WKWebView, fallbackDelay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        var done = false
        let once: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            block()
        }
        if webView.responds(to: Self.doAfterNextPresentationUpdate) {
            let afterCommit: @convention(block) () -> Void = { MainActor.assumeIsolated { once() } }
            webView.perform(Self.doAfterNextPresentationUpdate, with: afterCommit)
            // A page that never commits (throttled, mid-navigation) must
            // not leave the handoff hanging.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { once() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { once() }
        }
    }

    /// The steady state: the page styled down to its video at player size,
    /// the host showing that region. Activation is idempotent (a resize just
    /// re-sizes the pinned video), and the host's window moves onto the
    /// region in the transaction that commits the style — the same frame.
    private func presentMiniPlayer(_ webView: WKWebView, tabID: UUID, in container: MiniPlayerHostView) {
        miniPlayerSummon = nil
        let playerSize = container.frame.size
        guard playerSize.width > 0, playerSize.height > 0 else { return }
        activateMiniPlayerPresentation(tabID: tabID, playerSize: playerSize)
        afterNextPresentationUpdate(of: webView, fallbackDelay: 0.1) { [weak self, weak webView, weak container] in
            guard
                let self, let webView, let container,
                self.miniPlayerHostedTabID == tabID, webView.superview === container,
                self.miniPlayerSummon == nil
            else { return }
            container.bounds = self.presentationRegion(of: webView, playerSize: container.frame.size)
            webView.isHidden = false
        }
    }

    /// The player's glide landed: hand the live video over to the
    /// player-size presentation.
    func finishMiniPlayerSummon(for tabID: UUID) {
        guard
            let summon = miniPlayerSummon, summon.tabID == tabID,
            let webView = webViews[tabID],
            let container = webView.superview as? MiniPlayerHostView
        else { return }
        presentMiniPlayer(webView, tabID: tabID, in: container)
    }

    func detachMiniPlayerWebView(for tabID: UUID) {
        guard miniPlayerHostedTabID == tabID else { return }
        if miniPlayerSummon?.tabID == tabID {
            miniPlayerSummon = nil
        }
        restoreMiniPlayerPresentation(tabID: tabID)
        miniPlayerHostedTabID = nil
        webViews[tabID]?.isHidden = true
    }

    private func viewRect(forPageRect rect: CGRect, in webView: WKWebView) -> CGRect {
        let insets = pageInsets(of: webView)
        return rect.offsetBy(dx: insets.left, dy: insets.top)
    }

    private func pageInsets(of webView: WKWebView) -> NSEdgeInsets {
        guard #available(macOS 26.0, *) else { return NSEdgeInsetsZero }
        return webView.obscuredContentInsets
    }

    /// Starts the return to the tab: the page's full layout is already
    /// there, so this is the presentation style coming off — the video back
    /// in its place — and the switch lands in the transaction that commits
    /// it: the active host takes a page that is already laid out and
    /// painted at full size, so it appears big in one frame, the way Arc's
    /// does, and the player simply goes. (Growing the player back onto the
    /// page, or relayouting in view, read as flicker.)
    func prepareMiniPlayerReturn(for tabID: UUID, completion: @escaping @MainActor () -> Void) {
        guard miniPlayerHostedTabID == tabID, let webView = webViews[tabID] else {
            completion()
            return
        }
        miniPlayerSummon = nil
        restoreMiniPlayerPresentation(tabID: tabID)
        afterNextPresentationUpdate(of: webView, fallbackDelay: 0.1) { completion() }
    }

    /// The return was overtaken by another switch: the player floats on,
    /// so the page styles back down to its video.
    func abandonMiniPlayerReturn(for tabID: UUID) {
        guard
            miniPlayerHostedTabID == tabID,
            let webView = webViews[tabID],
            let container = webView.superview as? MiniPlayerHostView
        else { return }
        presentMiniPlayer(webView, tabID: tabID, in: container)
    }

    /// Unparenting tears down media presentation, so tabs with media stay
    /// parented (hidden); everything else is throttled by WebKit once removed.
    func keepsBackgroundWebViewParented(_ tabID: UUID) -> Bool {
        store?.mediaStates[tabID] != nil
    }
}

/// The summon glide in flight: which tab, and the on-page rect its stage
/// shows until the glide lands.
struct MiniPlayerSummonHandoff {
    let tabID: UUID
    let pageFrame: CGRect
}
