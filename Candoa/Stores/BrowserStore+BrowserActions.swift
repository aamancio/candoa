import AppKit
import Foundation
import WebKit

extension BrowserStore {
    enum WebContentPaintEdge {
        case leading
        case trailing
    }

    /// Calls `completion` once the WebContent process has produced a frame
    /// for the current layout of the web view nearest `edge`, or after
    /// `timeout` if the page is too slow. Chrome transitions that reveal a
    /// freshly re-laid-out page use this as a one-shot paint fence so they
    /// uncover painted content rather than the page's background fill. The
    /// 1×1 snapshot exists only to observe the paint and is discarded
    /// immediately.
    func waitForWebContentPaint(
        at edge: WebContentPaintEdge,
        timeout: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        let edgeTab = edge == .trailing
            ? activeSplitGroupTabs.last
            : activeSplitGroupTabs.first
        guard let tab = edgeTab ?? activeTab,
              tab.url != nil,
              let webView = webCoordinator.webViews[tab.id]
        else {
            completion()
            return
        }

        var isCompleted = false
        let completeOnce: @MainActor () -> Void = {
            guard !isCompleted else { return }
            isCompleted = true
            completion()
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        webView.takeSnapshot(with: configuration) { _, _ in
            completeOnce()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            completeOnce()
        }
    }

    func copyActiveTabURL(asMarkdown: Bool = false) {
        guard let tab = activeTab, let url = tab.url else { return }
        let value = asMarkdown ? "[\(tab.title)](\(url.absoluteString))" : url.absoluteString
        copyURL(value, url: url, title: asMarkdown ? "Copied URL as Markdown" : "Copied current URL")
    }

    func copyURL(_ url: URL) {
        copyURL(url.absoluteString, url: url, title: "Copied address")
    }

    private func copyURL(_ value: String, url: URL, title: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        presentCopiedURLToast(title: title, url: url)
    }

    func captureActiveTabPage() {
        guard let tab = activeTab, let url = tab.url else { return }

        webCoordinator.captureVisiblePage(for: tab.id) { [weak self] image in
            guard let self, let image else { return }
            guard
                let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:]),
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            else {
                return
            }

            let host = url.host(percentEncoded: false)?
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "/", with: "-") ?? "page"
            let fileURL = downloadsURL.appendingPathComponent("Candoa Capture - \(host).png")

            do {
                try pngData.write(to: fileURL, options: .atomic)
                presentCopiedURLToast(title: "Captured Page", url: fileURL)
            } catch {
                NSSound.beep()
            }
        }
    }

    func presentCopiedURLToast(title: String, url: URL) {
        isCopiedURLToastSharing = false
        copiedURLToast = CopiedURLToast(id: UUID(), title: title, url: url)
        scheduleCopiedURLToastDismissal()
    }

    /// Zen keeps the toast alive while hovered and restarts the dismissal
    /// timer on mouse-out.
    func setCopiedURLToastHovered(_ hovered: Bool) {
        guard copiedURLToast != nil, !isCopiedURLToastSharing else { return }
        if hovered {
            copiedURLToastHideWorkItem?.cancel()
            copiedURLToastHideWorkItem = nil
        } else {
            scheduleCopiedURLToastDismissal()
        }
    }

    /// While the share picker spawned from the toast is open, the toast must
    /// not auto-dismiss (tearing down its anchor would close the picker).
    func setCopiedURLToastSharing(_ sharing: Bool) {
        guard copiedURLToast != nil else {
            isCopiedURLToastSharing = false
            return
        }
        isCopiedURLToastSharing = sharing
        if sharing {
            copiedURLToastHideWorkItem?.cancel()
            copiedURLToastHideWorkItem = nil
        } else {
            scheduleCopiedURLToastDismissal()
        }
    }

    func scheduleCopiedURLToastDismissal() {
        copiedURLToastHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.copiedURLToast = nil
                self.copiedURLToastHideWorkItem = nil
            }
        }
        copiedURLToastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func showFindBar() {
        guard activeTab != nil else { return }
        isFindBarPresented = true
    }

    func dismissFindBar() {
        guard isFindBarPresented else { return }
        isFindBarPresented = false
        if let activeTabID {
            webCoordinator.clearFindSelection(in: activeTabID)
        }
    }

    func findNext() {
        performFind(forward: true)
    }

    func findPrevious() {
        performFind(forward: false)
    }

    func zoomInActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.zoomIn(tabID: activeTabID)
    }

    func zoomOutActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.zoomOut(tabID: activeTabID)
    }

    func resetZoomForActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.resetZoom(tabID: activeTabID)
    }

    func performFind(forward: Bool) {
        guard let activeTabID, !findQuery.isEmpty else { return }
        webCoordinator.find(findQuery, forward: forward, in: activeTabID)
    }

    func rememberClosedTab(_ tab: BrowserTab) {
        guard let url = tab.isFavorite ? tab.favoriteURL ?? tab.url : tab.url else { return }
        recentlyClosedTabs.append(ClosedTabSnapshot(
            url: url,
            isFavorite: tab.isFavorite,
            isPinned: tab.isPinned,
            spaceID: tab.spaceID
        ))
        if recentlyClosedTabs.count > Self.recentlyClosedTabLimit {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedTabLimit)
        }
    }
}
