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

    /// Adopts the tab's web view into the floating player. With a summon
    /// page frame, the glide shows the page's *own* video: the page keeps
    /// its full layout (no relayout, no restyle — nothing to flash) and the
    /// host's bounds are set to the video's rect, so AppKit scales exactly
    /// that region into the player while SwiftUI glides the player to its
    /// corner. A freeze frame of the video is captured meanwhile; once the
    /// glide lands (`finishMiniPlayerSummon`) the page strips down to the
    /// video at player size under that frame, and the frame goes when the
    /// page reports the new presentation painted.
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
        webView.isHidden = false

        if let summonPageFrame,
           let stage = summonStage(for: summonPageFrame, of: webView, in: container) {
            miniPlayerSummon = MiniPlayerSummonHandoff(tabID: tabID, pageFrame: summonPageFrame)
            webView.autoresizingMask = []
            webView.frame = CGRect(origin: .zero, size: webView.frame.size)
            if webView.superview !== container {
                webView.removeFromSuperview()
                container.addSubview(webView)
            }
            container.bounds = stage
            captureSummonFreezeFrame(for: tabID, pageFrame: summonPageFrame)
            return
        }

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

    /// Strips the page down to its video at player size — the steady state.
    private func presentMiniPlayer(_ webView: WKWebView, tabID: UUID, in container: MiniPlayerHostView) {
        miniPlayerSummon = nil
        container.bounds = CGRect(origin: .zero, size: container.frame.size)
        // The page arrives with the active host's lane insets; kept, they
        // would push the mini viewport off to the right of the player and
        // shrink the video into its far corner.
        applyObscuredContentInsets(NSEdgeInsetsZero, to: webView)
        // Activate before shrinking the web view: media selection scores
        // element rects, and at mini player size no video can meet the
        // area thresholds — the page would keep its full layout (the X bug).
        activateMiniPlayerPresentation(tabID: tabID) { [weak self] in
            self?.store?.miniPlayerPresentationDidSettle(tabID: tabID)
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]

        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
    }

    /// Snapshot of the video's on-page rect while the page still has its
    /// full layout; the freeze frame the strip-down happens under.
    private func captureSummonFreezeFrame(for tabID: UUID, pageFrame: CGRect) {
        guard let webView = webViews[tabID] else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        // Snapshot rects are page coordinates (unlike the host's stage,
        // which is view coordinates and so sits inside the obscured lanes).
        configuration.rect = pageFrame
        configuration.snapshotWidth = NSNumber(value: Double(min(pageFrame.width, 800)))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self, self.miniPlayerSummon?.tabID == tabID else { return }
                self.miniPlayerSummon?.freezeFrame = image
                self.miniPlayerSummon?.hasFreezeFrame = true
                self.settleMiniPlayerSummonIfReady()
            }
        }
        // A page that never answers (throttled, mid-navigation) must not
        // keep the glide's full-size page in the player indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.miniPlayerSummon?.tabID == tabID else { return }
            self.miniPlayerSummon?.hasFreezeFrame = true
            self.settleMiniPlayerSummonIfReady()
        }
    }

    /// The player's glide landed.
    func finishMiniPlayerSummon(for tabID: UUID) {
        guard miniPlayerSummon?.tabID == tabID else { return }
        miniPlayerSummon?.glideLanded = true
        settleMiniPlayerSummonIfReady()
    }

    private func settleMiniPlayerSummonIfReady() {
        guard
            let summon = miniPlayerSummon, summon.glideLanded, summon.hasFreezeFrame,
            let webView = webViews[summon.tabID],
            let container = webView.superview as? MiniPlayerHostView
        else { return }
        store?.miniPlayerSummonFreezeFrame = summon.freezeFrame
        // The freeze frame has to be on screen before the page relayouts
        // underneath it. SwiftUI commits the published change in this
        // turn's transaction; a plain main-queue hop can run ahead of that
        // commit, so the strip-down waits for the transaction to land.
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.miniPlayerSummon?.tabID == summon.tabID else { return }
            self.presentMiniPlayer(webView, tabID: summon.tabID, in: container)
        }
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

    /// Starts the return-to-tab handoff: captures a freeze frame of the
    /// hosted web view for the floating player to morph with, then hands the
    /// page back and parks it *under* the current page at the active
    /// container's full size, unhidden. WebKit only renders visible views,
    /// so a page laid out hidden would still show its last mini-sized frame
    /// in the top-left corner when the switch lands; covered by the page in
    /// front, it settles into its full layout unseen and the final swap
    /// reveals a page that has already painted.
    func prepareMiniPlayerReturn(for tabID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard miniPlayerHostedTabID == tabID, let webView = webViews[tabID] else {
            completion(nil)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        // Returned mid-glide: the page is still at full layout, so the
        // freeze frame is the video's region of it, not the whole page.
        if let summon = miniPlayerSummon, summon.tabID == tabID {
            configuration.rect = summon.pageFrame
            configuration.snapshotWidth = NSNumber(value: Double(min(summon.pageFrame.width, 800)))
        }
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, self.miniPlayerHostedTabID == tabID else {
                completion(image)
                return
            }

            self.miniPlayerHostedTabID = nil
            self.miniPlayerSummon = nil
            // Adopt the destination geometry before restoring so the page
            // relayouts (and restores its scroll position) at full layout.
            if let activeID = self.hostedActiveTabID,
                let activeWebView = self.webViews[activeID],
                let container = activeWebView.superview,
                activeWebView.frame.size != .zero {
                webView.frame = activeWebView.frame
                webView.autoresizingMask = [.width, .height]
                self.applyObscuredContentInsets(self.pageInsets(of: activeWebView), to: webView)
                webView.isHidden = false
                webView.removeFromSuperview()
                container.addSubview(webView, positioned: .below, relativeTo: activeWebView)
            } else {
                webView.isHidden = true
            }
            self.restoreMiniPlayerPresentation(tabID: tabID)
            completion(image)
        }
    }

    /// Unparenting tears down media presentation, so tabs with media stay
    /// parented (hidden); everything else is throttled by WebKit once removed.
    func keepsBackgroundWebViewParented(_ tabID: UUID) -> Bool {
        store?.mediaStates[tabID] != nil
    }
}

/// The summon glide's handoff bookkeeping: the strip-down waits for both
/// the glide to land and the freeze frame to come in (or time out).
struct MiniPlayerSummonHandoff {
    let tabID: UUID
    let pageFrame: CGRect
    var freezeFrame: NSImage?
    var hasFreezeFrame = false
    var glideLanded = false
}
