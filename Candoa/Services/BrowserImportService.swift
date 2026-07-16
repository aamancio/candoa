import Foundation

struct ImportedBrowserBookmark: Equatable, Sendable {
    let title: String
    let url: URL
}

enum BrowserImportError: LocalizedError {
    case unreadableFile
    case unsupportedFile
    case noBookmarks

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Candoa couldn’t read that bookmarks file."
        case .unsupportedFile:
            return "Choose a bookmarks HTML file exported by your browser."
        case .noBookmarks:
            return "No web bookmarks were found in that file."
        }
    }
}

struct BrowserImportService {
    private static let bookmarkLimit = 2_000

    func bookmarks(from fileURL: URL) async throws -> [ImportedBrowserBookmark] {
        try await Task.detached(priority: .userInitiated) {
            let accessedSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                throw BrowserImportError.unreadableFile
            }
            guard let html = Self.decodeHTML(data) else {
                throw BrowserImportError.unsupportedFile
            }

            let bookmarks = try Self.parseBookmarks(in: html)
            guard !bookmarks.isEmpty else {
                throw BrowserImportError.noBookmarks
            }
            return bookmarks
        }.value
    }

    private static func decodeHTML(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let value = String(data: data, encoding: encoding),
               value.range(of: "<a", options: .caseInsensitive) != nil {
                return value
            }
        }
        return nil
    }

    private static func parseBookmarks(in html: String) throws -> [ImportedBrowserBookmark] {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#
        let expression = try NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var seenURLs = Set<String>()
        var bookmarks: [ImportedBrowserBookmark] = []

        expression.enumerateMatches(in: html, range: fullRange) { match, _, stop in
            guard let match else { return }
            let href = [1, 2, 3]
                .compactMap { substring(in: html, range: match.range(at: $0)) }
                .first
                .map(decodeHTMLEntities)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard let href,
                  let url = URL(string: href),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }

            let key = url.absoluteString
            guard seenURLs.insert(key).inserted else { return }

            let rawTitle = substring(in: html, range: match.range(at: 4)) ?? ""
            let title = decodeHTMLEntities(
                rawTitle.replacingOccurrences(
                    of: #"<[^>]+>"#,
                    with: "",
                    options: .regularExpression
                )
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            bookmarks.append(
                ImportedBrowserBookmark(
                    title: title.isEmpty ? (url.host(percentEncoded: false) ?? url.absoluteString) : title,
                    url: url
                )
            )

            if bookmarks.count >= bookmarkLimit {
                stop.pointee = true
            }
        }

        return bookmarks
    }

    private static func substring(in source: String, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: source)
        else { return nil }
        return String(source[swiftRange])
    }

    private static func decodeHTMLEntities(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
    }
}
