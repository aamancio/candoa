import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    // MARK: - Downloads

    func configureDownload(_ download: WKDownload) {
        download.delegate = self
        activeDownloads.insert(download)
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
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.remove(download)
        guard let destination = downloadDestinations.removeValue(forKey: download) else { return }

        // Bounces the Downloads stack in the Dock, matching native browser behavior.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"),
            object: destination.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
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

