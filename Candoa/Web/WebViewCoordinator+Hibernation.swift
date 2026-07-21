import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    // MARK: - Tab Hibernation

    func hibernateIdleWebViews() {
        guard let store else { return }
        let cutoff = Date().addingTimeInterval(-TabHibernationConfiguration.idleInterval)

        for tab in store.tabs where webViews[tab.id] != nil && isHibernatable(tab, idleBefore: cutoff) {
            hibernateIfNoUnsavedInput(tab.id)
        }
    }

    func isHibernatable(_ tab: BrowserTab, idleBefore cutoff: Date) -> Bool {
        guard let store else { return false }
        return tab.id != store.activeTabID
            && !store.activeSplitGroupTabIDs.contains(tab.id)
            && tab.id != miniPlayerHostedTabID
            && tab.id != store.mediaControllerTabID
            && !tab.isPinned
            && !tab.isLoading
            && tab.url != nil
            && tab.lastAccessedAt < cutoff
            && store.mediaStates[tab.id] == nil
            && !popupTabIDsAwaitingFirstLoad.contains(tab.id)
            && !restoringTabIDs.contains(tab.id)
    }

    func hibernateIfNoUnsavedInput(_ tabID: UUID, idleBefore cutoff: Date = Date()) {
        guard let webView = webViews[tabID] else { return }

        webView.evaluateJavaScript(WebPageScripts.unsavedInputCheckScript) { [weak self] value, error in
            Task { @MainActor in
                guard error == nil, (value as? Bool) == false else { return }
                self?.hibernate(tabID, idleBefore: cutoff)
            }
        }
    }

    func hibernate(_ tabID: UUID, idleBefore cutoff: Date = Date()) {
        guard
            let store,
            let webView = webViews[tabID],
            let tab = store.tabs.first(where: { $0.id == tabID }),
            // State may have changed while the unsaved-input check ran.
            isHibernatable(tab, idleBefore: cutoff)
        else { return }

        if let interactionState = webView.interactionState as? Data {
            hibernatedInteractionStates[tabID] = interactionState
        }
        removeWebView(for: tabID, keepingHibernationData: true)
    }

    // MARK: - Wake Snapshots & Restore Overlay

    func captureWakeSnapshot(for tabID: UUID) {
        guard
            let webView = webViews[tabID],
            !webView.bounds.isEmpty,
            !webView.isHidden,
            webView.window != nil
        else { return }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.snapshotWidth = NSNumber(
            value: Double(min(webView.bounds.width, TabHibernationConfiguration.snapshotMaxWidth))
        )

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self, let image else { return }
                self.storeWakeSnapshot(image, for: tabID)
            }
        }
    }

    func storeWakeSnapshot(_ image: NSImage, for tabID: UUID) {
        wakeSnapshots[tabID] = image
        guard wakeSnapshots.count > TabHibernationConfiguration.snapshotCacheLimit else { return }

        // Evict live tabs' snapshots first; hibernated tabs need theirs to
        // cover the wake-up reload.
        let evictableID = wakeSnapshots.keys.first { hibernatedInteractionStates[$0] == nil && $0 != tabID }
            ?? wakeSnapshots.keys.first { $0 != tabID }
        if let evictableID {
            wakeSnapshots[evictableID] = nil
        }
    }

    func presentRestoreOverlay(_ snapshot: NSImage, for tabID: UUID, in container: NSView) {
        removeRestoreOverlay(for: tabID)

        let overlay = NSImageView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.imageScaling = .scaleProportionallyUpOrDown
        overlay.image = snapshot
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.addSubview(overlay)
        restoreOverlays[tabID] = overlay

        // Failsafe: never leave a stale snapshot covering a live page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.removeRestoreOverlay(for: tabID, animated: true)
        }
    }

    func scheduleRestoreOverlayRemoval(for tabID: UUID) {
        // Commit precedes first paint; hold the snapshot a beat longer so the
        // swap lands on rendered content instead of a flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.removeRestoreOverlay(for: tabID, animated: true)
        }
    }

    func removeRestoreOverlay(for tabID: UUID, animated: Bool = false) {
        guard let overlay = restoreOverlays.removeValue(forKey: tabID) else { return }
        guard animated else {
            overlay.removeFromSuperview()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            // The completion handler is nonisolated in the SDK signature but
            // always runs on the main thread.
            MainActor.assumeIsolated {
                overlay.removeFromSuperview()
            }
        })
    }

    func finishRestoreIfNeeded(for webView: WKWebView, failed: Bool = false) {
        guard let tabID = tabID(for: webView), restoringTabIDs.remove(tabID) != nil else { return }
        if failed {
            removeRestoreOverlay(for: tabID, animated: true)
        } else {
            scheduleRestoreOverlayRemoval(for: tabID)
        }
    }
}
