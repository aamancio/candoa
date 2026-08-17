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

        let getter = NSSelectorFromString("_inspectorAttachmentView")
        if webView.responds(to: getter) {
            let current = webView.perform(getter)?.takeUnretainedValue() as? NSView
            // Re-setting runs WebKit's whole attach path, which re-parents the
            // inspector and steals first responder; only move a real change.
            guard current !== standIn else { return }
        }

        let setter = NSSelectorFromString("_setInspectorAttachmentView:")
        guard webView.responds(to: setter) else { return }
        webView.perform(setter, with: standIn)
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

    func hostMiniPlayerWebView(for tabID: UUID, in container: NSView) {
        guard let webView = webViews[tabID] else { return }
        // Adopting a different tab must first restore the previously hosted
        // tab's page; otherwise that page is left stripped down to its video
        // element and shows a black shell when reopened from the sidebar.
        if let previousID = miniPlayerHostedTabID, previousID != tabID {
            detachMiniPlayerWebView(for: previousID)
        }
        coverActiveContainerWhileAdopting(webView)
        // The floating player is not a pane host, so its page hands the
        // inspector back to WebKit's own default placement.
        attachInspector(of: webView, to: nil)
        miniPlayerHostedTabID = tabID
        // Activate before shrinking the web view: media selection scores
        // element rects, and at mini player size no video can meet the
        // area thresholds — the page would keep its full layout (the X bug).
        activateMiniPlayerPresentation(tabID: tabID)
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = false

        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
    }

    func detachMiniPlayerWebView(for tabID: UUID) {
        guard miniPlayerHostedTabID == tabID else { return }
        restoreMiniPlayerPresentation(tabID: tabID)
        miniPlayerHostedTabID = nil
        webViews[tabID]?.isHidden = true
    }

    /// Summoning steals the page that was covering the content area before
    /// the incoming web view has painted, leaving a black void for a beat.
    /// Bridge it with the incoming tab's wake snapshot — the same cover a
    /// hibernation wake uses — released as soon as the page is up.
    func coverActiveContainerWhileAdopting(_ stolenWebView: WKWebView) {
        guard
            let activeID = hostedActiveTabID,
            let activeWebView = webViews[activeID],
            activeWebView !== stolenWebView,
            let activeContainer = activeWebView.superview,
            stolenWebView.superview === activeContainer,
            restoreOverlays[activeID] == nil,
            let snapshot = wakeSnapshots[activeID]
        else { return }

        presentRestoreOverlay(snapshot, for: activeID, in: activeContainer)
        // Same beat the outgoing web view normally stays visible for after
        // a switch; the overlay then fades onto the painted page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.removeRestoreOverlay(for: activeID, animated: true)
        }
    }

    /// Starts the return-to-tab handoff: captures a freeze frame of the
    /// hosted web view for the floating player to morph with, then hands the
    /// page back and lays it out at the active container's full size while
    /// hidden — so the final swap reveals an already-settled page instead of
    /// the mini-sized layout flashing in the top-left corner.
    func prepareMiniPlayerReturn(for tabID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard miniPlayerHostedTabID == tabID, let webView = webViews[tabID] else {
            completion(nil)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, self.miniPlayerHostedTabID == tabID else {
                completion(image)
                return
            }

            self.miniPlayerHostedTabID = nil
            webView.isHidden = true
            // Adopt the destination size before restoring so the page
            // relayouts (and restores its scroll position) at full layout.
            if let activeID = self.hostedActiveTabID,
                let activeFrame = self.webViews[activeID]?.frame,
                activeFrame.size != .zero {
                webView.frame = activeFrame
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
