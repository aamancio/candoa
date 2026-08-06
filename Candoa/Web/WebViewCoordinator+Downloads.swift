import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    // MARK: - Downloads

    func configureDownload(_ download: WKDownload) {
        download.delegate = self
        activeDownloads.insert(download)
    }

    /// A navigation that became a download never commits, but the tab model
    /// may already carry its URL (URL-bar navigations write it up front).
    /// Left mismatched, every SwiftUI pass re-requests the URL through
    /// ensureLoaded — with a download that cannot finish, that's an
    /// infinite retry loop spamming failed rows. Point the tab back at the
    /// last committed page. Not webView.url: during the conversion that
    /// still reports the provisional (download) URL, which is exactly the
    /// value that must go away.
    func realignTabAfterDownloadConversion(for webView: WKWebView?) {
        guard let webView, let store, let tabID = tabID(for: webView) else { return }
        downloadConvertedTabIDs.insert(tabID)
        store.realignTabURL(tabID: tabID, to: webView.backForwardList.currentItem?.url)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }

        let destination = Self.uniqueDestination(for: suggestedFilename, in: downloadsDirectory)
        downloadDestinations[download] = destination
        store?.downloadsStore.begin(download, destination: destination)
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.remove(download)
        store?.downloadsStore.finish(download)
        guard let destination = downloadDestinations.removeValue(forKey: download) else { return }

        // Bounces the Downloads stack in the Dock, matching native browser
        // behavior. The path must be symlink-resolved: the sandbox reports
        // the container's Downloads (a symlink to the real ~/Downloads),
        // and the Dock string-matches the path against its stack URL — the
        // container form silently never bounces.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"),
            object: destination.resolvingSymlinksInPath().path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
        store?.downloadsStore.fail(download, reason: error.localizedDescription)
    }

    /// WebKit's PDF viewer HUD routes its download button through this
    /// private WKUIDelegate method (savePDFToFileInDownloadsFolder) —
    /// without it the button is a silent no-op, since WebKit probes the
    /// delegate with respondsToSelector and falls back to doing nothing.
    /// Candoa ships as a direct DMG, so no App Store private-API rule
    /// applies, and an SDK-side selector change only degrades back to
    /// the old no-op.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func _webView(
        _ webView: WKWebView,
        saveDataToFile data: Data,
        suggestedFilename: String,
        mimeType: String,
        originatingURL url: URL
    ) {
        guard let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else { return }

        let destination = Self.uniqueDestination(for: suggestedFilename, in: downloadsDirectory)
        do {
            try data.write(to: destination, options: .atomic)
            store?.downloadsStore.recordCompletedSave(at: destination)
            // Symlink-resolved for the same reason as downloadDidFinish.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.apple.DownloadFileFinished"),
                object: destination.resolvingSymlinksInPath().path,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            store?.downloadsStore.recordFailedSave(
                filename: suggestedFilename,
                reason: error.localizedDescription
            )
        }
    }

    static func uniqueDestination(for suggestedFilename: String, in directory: URL) -> URL {
        let baseName = (suggestedFilename as NSString).deletingPathExtension
        let fileExtension = (suggestedFilename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(suggestedFilename)
        var attempt = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let numberedName = fileExtension.isEmpty
                ? "\(baseName) \(attempt)"
                : "\(baseName) \(attempt).\(fileExtension)"
            candidate = directory.appendingPathComponent(numberedName)
            attempt += 1
        }

        return candidate
    }
}

