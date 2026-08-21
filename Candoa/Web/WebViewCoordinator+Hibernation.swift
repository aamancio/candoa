import AppKit
import Foundation
import OSLog
import WebKit

extension WebViewCoordinator {
    // MARK: - Tab Hibernation

    /// Safari keeps background tabs live and sheds them only when the Mac is
    /// short on memory; so does Candoa. A warning sheds the tabs nobody has
    /// looked at for `warningIdleInterval`, least recently used first, so
    /// the tab someone just switched away from is the last to go. Critical
    /// pressure sheds every eligible background tab.
    ///
    /// Sources fire on their queue even for an instance mid-teardown, so
    /// the handler hops through a weak self; `purgeAllWebContent` and deinit
    /// cancel the source outright.
    func startMemoryPressureMonitoring() {
        stopMemoryPressureMonitoring()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source, !source.isCancelled else { return }
            let event = source.data
            // The source's queue is main; the handler is not annotated.
            MainActor.assumeIsolated {
                self?.respondToMemoryPressure(critical: event.contains(.critical))
            }
        }
        source.activate()
        memoryPressureSource = source
        installDebugMemoryPressureTrigger()
    }

    #if DEBUG
    /// Real pressure can't be simulated without root (`memory_pressure -S`
    /// is sysctl-gated), so Debug builds also answer a distributed
    /// notification: `app.candoa.debug.memory-pressure`, with a "level" of
    /// "warning" or "critical" in its userInfo.
    ///
    ///     notifyutil is no use here; post from Swift/Python:
    ///     DistributedNotificationCenter.default().postNotificationName(
    ///         .init("app.candoa.debug.memory-pressure"), object: nil,
    ///         userInfo: ["level": "critical"], deliverImmediately: true)
    private func installDebugMemoryPressureTrigger() {
        debugMemoryPressureObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.candoa.debug.memory-pressure"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let critical = (notification.userInfo?["level"] as? String) == "critical"
            MainActor.assumeIsolated {
                self?.respondToMemoryPressure(critical: critical)
            }
        }
    }
    #else
    private func installDebugMemoryPressureTrigger() {}
    #endif

    nonisolated func stopMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let debugMemoryPressureObserver {
            DistributedNotificationCenter.default().removeObserver(debugMemoryPressureObserver)
            self.debugMemoryPressureObserver = nil
        }
    }

    func respondToMemoryPressure(critical: Bool) {
        Self.hibernationLogger.notice("Memory pressure \(critical ? "critical" : "warning", privacy: .public); shedding background tabs")
        hibernateBackgroundWebViews(
            idleFor: critical ? 0 : TabHibernationConfiguration.warningIdleInterval
        )
    }

    static let hibernationLogger = Logger(subsystem: "app.candoa.browser", category: "TabHibernation")

    /// Hibernates every eligible background tab idle for at least `idleInterval`,
    /// least recently used first. Zero hibernates all of them.
    func hibernateBackgroundWebViews(idleFor idleInterval: TimeInterval) {
        guard let store else { return }
        let cutoff = Date().addingTimeInterval(-idleInterval)

        let candidates = store.tabs
            .filter { webViews[$0.id] != nil && isHibernatable($0, idleBefore: cutoff) }
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        for tab in candidates {
            hibernateIfNoUnsavedInput(tab.id, idleBefore: cutoff)
        }
    }

    func isHibernatable(_ tab: BrowserTab, idleBefore cutoff: Date) -> Bool {
        guard let store else { return false }
        return tab.id != store.activeTabID
            && !store.displayedSplitTabIDs.contains(tab.id)
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
        Self.hibernationLogger.notice("Hibernated tab \(tabID.uuidString, privacy: .public)")
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
                // Every tab the person has looked at gets a switcher
                // thumbnail — this run and the next — not just the ones the
                // switcher happened to capture while they were live.
                self.store?.didCaptureTabSnapshot(image, for: tabID)
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
