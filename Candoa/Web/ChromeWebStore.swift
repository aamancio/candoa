import Foundation

/// The Chrome Web Store's own "Add to Chrome" button can never work outside
/// Chrome: it calls `chrome.webstorePrivate`, an API only Chrome ships, and
/// the store disables the button for every other browser before you can even
/// press it. Candoa swaps its own button into the page
/// (`WebPageScripts.chromeWebStoreScript`) and fetches the item from the same
/// CRX endpoint Chrome's updater downloads from, then hands the archive to
/// `WebExtensionInstaller` like any other picked file.
enum ChromeWebStore {
    /// Today's store, and the legacy host that still redirects to it.
    static let hosts: Set<String> = ["chromewebstore.google.com", "chrome.google.com"]

    /// Where "Get Extensions…" goes.
    static let galleryURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// The endpoint gates downloads on the requesting browser's version
    /// against each item's `minimum_chrome_version`, answering 204 when it
    /// thinks the browser is too old — and it accepts any well-formed
    /// version. Candoa's compatibility ceiling is WebKit's `WKWebExtension`
    /// support, not a Chrome build number, so ask as a browser that no item
    /// can outrank rather than chasing Chrome's release train in a constant.
    private static let productVersion = "9999.0.0.0"

    enum DownloadError: LocalizedError {
        case unavailable
        case badResponse(Int)
        case notAnExtension

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(
                    localized: "The Chrome Web Store has no download for this extension."
                )
            case .badResponse(let statusCode):
                return String(
                    localized: "The Chrome Web Store didn't send the extension (error \(statusCode))."
                )
            case .notAnExtension:
                return String(localized: "The download wasn't a Chrome extension.")
            }
        }
    }

    /// Store item IDs are 32 letters in a–p — base-16 mapped onto letters.
    static func isItemID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    /// The item ID of a store detail page: `/detail/<slug>/<id>`, the older
    /// `/webstore/detail/<slug>/<id>`, and the slugless and trailing-section
    /// forms (`/detail/<id>`, `…/<id>/reviews`) all carry it as the last
    /// ID-shaped path component.
    static func itemID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.contains("detail") else { return nil }
        return components.last(where: isItemID)
    }

    static func downloadURL(forItemID itemID: String) -> URL? {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "prodversion", value: productVersion),
            URLQueryItem(name: "x", value: "id=\(itemID)&installsource=ondemand&uc")
        ]
        return components?.url
    }

    /// Downloads the item's CRX into a temporary file the caller owns and is
    /// responsible for deleting.
    static func downloadItem(_ itemID: String) async throws -> URL {
        guard isItemID(itemID), let url = downloadURL(forItemID: itemID) else {
            throw DownloadError.unavailable
        }

        let (fileURL, response) = try await URLSession.shared.download(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 204 is the endpoint's "nothing to serve" answer — an unlisted or
        // withdrawn item, or one the store won't hand out on demand.
        switch statusCode {
        case 200:
            break
        case 204:
            try? FileManager.default.removeItem(at: fileURL)
            throw DownloadError.unavailable
        default:
            try? FileManager.default.removeItem(at: fileURL)
            throw DownloadError.badResponse(statusCode)
        }

        // URLSession's temporary file is reaped when this call returns, so
        // move it somewhere Candoa controls before handing it on.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(itemID)-\(UUID().uuidString).crx")
        try FileManager.default.moveItem(at: fileURL, to: destination)

        guard hasCRXHeader(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw DownloadError.notAnExtension
        }
        return destination
    }

    /// A CRX opens with the magic "Cr24"; anything else (an error page served
    /// with a 200, most likely) is not worth unpacking.
    private static func hasCRXHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        return magic == Data("Cr24".utf8)
    }
}
