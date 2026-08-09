import Foundation
import WebKit

extension WebViewCoordinator {
    // MARK: - Reader Mode

    /// Runs the availability probe once for the active tab's finished page.
    /// Event-driven only: a finished load or a tab activation asks; nothing
    /// polls, and background tabs are never probed.
    func probeReaderAvailabilityIfNeeded(for tabID: UUID) {
        guard
            let store,
            store.activeTabID == tabID,
            !readerProbedTabIDs.contains(tabID),
            let webView = webViews[tabID],
            !webView.isLoading,
            let url = webView.url,
            url.scheme == "https" || url.scheme == "http" || url.isFileURL
        else { return }

        readerProbedTabIDs.insert(tabID)
        webView.evaluateJavaScript(ReaderMode.availabilityProbeScript) { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard let self, self.readerProbedTabIDs.contains(tabID) else { return }
                self.store?.setReaderAvailable((result as? Bool) == true, for: tabID)
            }
        }
    }

    /// Presents the reader overlay over the live page. The page keeps its
    /// document, history, and scroll position — reader is presentation, not
    /// navigation.
    func showReader(for tabID: UUID) {
        guard
            let store,
            store.readerAvailableTabIDs.contains(tabID),
            let webView = webViews[tabID]
        else { return }

        webView.evaluateJavaScript(ReaderMode.enterReaderScript) { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard (result as? Bool) == true else { return }
                self?.store?.setReaderActive(true, for: tabID)
            }
        }
    }

    /// Removes the overlay; the untouched page is simply visible again.
    func hideReader(for tabID: UUID) {
        guard
            store?.readerActiveTabIDs.contains(tabID) == true,
            let webView = webViews[tabID]
        else { return }

        store?.setReaderActive(false, for: tabID)
        webView.evaluateJavaScript(ReaderMode.exitReaderScript)
    }

    /// Drops every reader trace for the tab. The overlay itself lives in
    /// the page's DOM, so it vanishes with the document on navigation and
    /// teardown — only the flags need reconciling.
    func clearReaderState(for tabID: UUID) {
        readerProbedTabIDs.remove(tabID)
        store?.setReaderAvailable(false, for: tabID)
        store?.setReaderActive(false, for: tabID)
    }
}
