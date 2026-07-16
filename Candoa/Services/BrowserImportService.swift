import Foundation
import SQLite3

struct ImportedBrowserBookmark: Equatable, Sendable {
    let title: String
    let url: URL
    let folderPath: [String]

    init(title: String, url: URL, folderPath: [String] = []) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
    }
}

enum BrowserImportSource: String, CaseIterable, Identifiable, Sendable {
    case safari
    case chrome
    case arc
    case firefox

    var id: String { rawValue }

    var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .firefox: "Firefox"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .firefox: "org.mozilla.firefox"
        }
    }

    var profileFolderHint: String {
        switch self {
        case .safari:
            "Select Safari’s Safari folder."
        case .chrome:
            "Select Chrome’s Chrome folder or one profile folder inside it."
        case .arc:
            "Select Arc’s Arc folder."
        case .firefox:
            "Select Firefox’s Profiles folder or one profile folder inside it."
        }
    }

    var suggestedProfileFolderURL: URL {
        let libraryURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)

        switch self {
        case .safari:
            return libraryURL.appending(path: "Safari", directoryHint: .isDirectory)
        case .chrome:
            return libraryURL.appending(
                path: "Application Support/Google/Chrome",
                directoryHint: .isDirectory
            )
        case .arc:
            return libraryURL.appending(
                path: "Application Support/Arc",
                directoryHint: .isDirectory
            )
        case .firefox:
            return libraryURL.appending(
                path: "Application Support/Firefox/Profiles",
                directoryHint: .isDirectory
            )
        }
    }
}

enum BrowserImportError: LocalizedError {
    case unreadableFile
    case unsupportedFile
    case profileDataNotFound(String)
    case noBookmarks

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Candoa couldn’t read that bookmarks file."
        case .unsupportedFile:
            return "Choose a bookmarks HTML file exported by your browser."
        case .profileDataNotFound(let sourceName):
            return "Candoa couldn’t find \(sourceName) bookmark data in that folder."
        case .noBookmarks:
            return "No web bookmarks were found there."
        }
    }
}

struct BrowserImportService {
    private struct FirefoxNode {
        let id: Int64
        let parentID: Int64
        let type: Int32
        let title: String
        let url: String
    }

    private static let bookmarkLimit = 2_000

    func bookmarks(from fileURL: URL) async throws -> [ImportedBrowserBookmark] {
        try await Task.detached(priority: .userInitiated) {
            try Self.withSecurityScopedAccess(to: fileURL) {
                guard let data = try? Data(contentsOf: fileURL) else {
                    throw BrowserImportError.unreadableFile
                }
                guard let html = Self.decodeHTML(data) else {
                    throw BrowserImportError.unsupportedFile
                }

                let bookmarks = try Self.parseHTMLBookmarks(in: html)
                guard !bookmarks.isEmpty else {
                    throw BrowserImportError.noBookmarks
                }
                return bookmarks
            }
        }.value
    }

    func bookmarks(
        fromProfileFolder folderURL: URL,
        source: BrowserImportSource
    ) async throws -> [ImportedBrowserBookmark] {
        try await Task.detached(priority: .userInitiated) {
            try Self.withSecurityScopedAccess(to: folderURL) {
                let bookmarks: [ImportedBrowserBookmark]
                switch source {
                case .safari:
                    bookmarks = try Self.safariBookmarks(in: folderURL)
                case .chrome:
                    bookmarks = try Self.chromiumBookmarks(
                        in: folderURL,
                        sourceName: source.name
                    )
                case .arc:
                    bookmarks = try Self.arcBookmarks(in: folderURL)
                case .firefox:
                    bookmarks = try Self.firefoxBookmarks(in: folderURL)
                }

                let result = Self.deduplicated(bookmarks)
                guard !result.isEmpty else {
                    throw BrowserImportError.noBookmarks
                }
                return result
            }
        }.value
    }

    private static func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) throws -> T {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    private static func safariBookmarks(in selectedFolder: URL) throws -> [ImportedBrowserBookmark] {
        let candidates = candidateFiles(
            named: "Bookmarks.plist",
            below: selectedFolder,
            maximumDepth: 2
        )
        guard let bookmarksURL = candidates.first,
              let data = try? Data(contentsOf: bookmarksURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            throw BrowserImportError.profileDataNotFound(BrowserImportSource.safari.name)
        }

        var bookmarks: [ImportedBrowserBookmark] = []
        collectSafariBookmarks(from: root, folderPath: [], into: &bookmarks, includesNodeTitle: false)
        return bookmarks
    }

    private static func collectSafariBookmarks(
        from value: Any,
        folderPath: [String],
        into bookmarks: inout [ImportedBrowserBookmark],
        includesNodeTitle: Bool = true
    ) {
        guard bookmarks.count < bookmarkLimit else { return }

        if let children = value as? [Any] {
            for child in children {
                collectSafariBookmarks(from: child, folderPath: folderPath, into: &bookmarks)
                if bookmarks.count >= bookmarkLimit { return }
            }
            return
        }

        guard let node = value as? [String: Any] else { return }
        let nodeType = node["WebBookmarkType"] as? String
        let title = safariTitle(in: node)

        if nodeType == "WebBookmarkTypeLeaf",
           let rawURL = node["URLString"] as? String,
           let url = webURL(from: rawURL) {
            bookmarks.append(
                ImportedBrowserBookmark(
                    title: title.isEmpty ? fallbackTitle(for: url) : title,
                    url: url,
                    folderPath: folderPath
                )
            )
            return
        }

        let childPath: [String]
        if includesNodeTitle, !title.isEmpty {
            childPath = folderPath + [title]
        } else {
            childPath = folderPath
        }
        collectSafariBookmarks(
            from: node["Children"] as Any,
            folderPath: childPath,
            into: &bookmarks
        )
    }

    private static func safariTitle(in node: [String: Any]) -> String {
        if let title = node["Title"] as? String {
            return cleanedFolderName(title)
        }
        if let uriDictionary = node["URIDictionary"] as? [String: Any],
           let title = uriDictionary["title"] as? String {
            return cleanedFolderName(title)
        }
        return ""
    }

    private static func chromiumBookmarks(
        in selectedFolder: URL,
        sourceName: String
    ) throws -> [ImportedBrowserBookmark] {
        let bookmarkFiles = candidateFiles(
            named: "Bookmarks",
            below: selectedFolder,
            maximumDepth: 2
        )
        guard !bookmarkFiles.isEmpty else {
            throw BrowserImportError.profileDataNotFound(sourceName)
        }

        var result: [ImportedBrowserBookmark] = []
        let includesMultipleProfiles = bookmarkFiles.count > 1

        for bookmarkFile in bookmarkFiles {
            guard result.count < bookmarkLimit,
                  let data = try? Data(contentsOf: bookmarkFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = json["roots"] as? [String: Any]
            else { continue }

            let profilePrefix = includesMultipleProfiles
                ? [cleanedFolderName(bookmarkFile.deletingLastPathComponent().lastPathComponent)]
                : []

            for key in ["bookmark_bar", "other", "synced"] {
                guard let root = roots[key] as? [String: Any] else { continue }
                collectChromiumBookmarks(
                    from: root,
                    folderPath: profilePrefix,
                    into: &result,
                    includesNodeTitle: true
                )
                if result.count >= bookmarkLimit { break }
            }
        }

        return result
    }

    private static func collectChromiumBookmarks(
        from node: [String: Any],
        folderPath: [String],
        into bookmarks: inout [ImportedBrowserBookmark],
        includesNodeTitle: Bool
    ) {
        guard bookmarks.count < bookmarkLimit else { return }

        let type = node["type"] as? String
        let name = cleanedFolderName(node["name"] as? String ?? "")
        if type == "url",
           let rawURL = node["url"] as? String,
           let url = webURL(from: rawURL) {
            bookmarks.append(
                ImportedBrowserBookmark(
                    title: name.isEmpty ? fallbackTitle(for: url) : name,
                    url: url,
                    folderPath: folderPath
                )
            )
            return
        }

        let childPath = includesNodeTitle && !name.isEmpty ? folderPath + [name] : folderPath
        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            collectChromiumBookmarks(
                from: child,
                folderPath: childPath,
                into: &bookmarks,
                includesNodeTitle: true
            )
            if bookmarks.count >= bookmarkLimit { return }
        }
    }

    private static func arcBookmarks(in selectedFolder: URL) throws -> [ImportedBrowserBookmark] {
        let sidebarFiles = candidateFiles(
            named: "StorableSidebar.json",
            below: selectedFolder,
            maximumDepth: 2
        )

        if let sidebarURL = sidebarFiles.first,
           let data = try? Data(contentsOf: sidebarURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let syncState = json["sidebarSyncState"] as? [String: Any] {
            let items = pairedArcValues(in: syncState["items"])
            let spaces = pairedArcValues(in: syncState["spaceModels"])
            let parsed = parseArcSidebarItems(items, spaces: spaces)
            if !parsed.isEmpty { return parsed }
        }

        let chromiumUserDataURL = selectedFolder.lastPathComponent == "User Data"
            ? selectedFolder
            : selectedFolder.appending(path: "User Data", directoryHint: .isDirectory)
        if !candidateFiles(named: "Bookmarks", below: chromiumUserDataURL, maximumDepth: 2).isEmpty {
            return try chromiumBookmarks(in: chromiumUserDataURL, sourceName: BrowserImportSource.arc.name)
        }
        throw BrowserImportError.profileDataNotFound(BrowserImportSource.arc.name)
    }

    private static func pairedArcValues(in value: Any?) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.compactMap { entry in
                guard let wrapped = entry as? [String: Any] else { return nil }
                return wrapped["value"] as? [String: Any]
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.compactMap { entry in
                guard let wrapped = entry as? [String: Any] else { return nil }
                return (wrapped["value"] as? [String: Any]) ?? wrapped
            }
        }
        return []
    }

    private static func parseArcSidebarItems(
        _ items: [[String: Any]],
        spaces: [[String: Any]]
    ) -> [ImportedBrowserBookmark] {
        var itemsByID: [String: [String: Any]] = [:]
        for item in items {
            guard let id = item["id"] as? String else { continue }
            itemsByID[id] = item
        }

        var spaceNameByContainerID: [String: String] = [:]
        for space in spaces {
            let title = cleanedFolderName(space["title"] as? String ?? "")
            guard !title.isEmpty else { continue }
            let containerIDs = (space["containerIDs"] as? [String] ?? [])
                + (space["newContainerIDs"] as? [String] ?? [])
            for containerID in containerIDs {
                spaceNameByContainerID[containerID] = title
            }
        }

        func folderPath(for parentID: String?) -> [String] {
            var currentID = parentID
            var result: [String] = []
            var visited = Set<String>()

            while let id = currentID, visited.insert(id).inserted {
                if let spaceName = spaceNameByContainerID[id] {
                    result.append(spaceName)
                    break
                }
                guard let item = itemsByID[id] else { break }
                if let data = item["data"] as? [String: Any], data["list"] != nil {
                    let title = cleanedFolderName(item["title"] as? String ?? "")
                    if !title.isEmpty { result.append(title) }
                }
                currentID = item["parentID"] as? String
            }
            return Array(result.reversed())
        }

        var bookmarks: [ImportedBrowserBookmark] = []
        for item in items {
            guard bookmarks.count < bookmarkLimit,
                  let data = item["data"] as? [String: Any],
                  let tab = data["tab"] as? [String: Any],
                  let rawURL = tab["savedURL"] as? String,
                  let url = webURL(from: rawURL)
            else { continue }

            let savedTitle = cleanedFolderName(tab["savedTitle"] as? String ?? "")
            let itemTitle = cleanedFolderName(item["title"] as? String ?? "")
            bookmarks.append(
                ImportedBrowserBookmark(
                    title: savedTitle.isEmpty
                        ? (itemTitle.isEmpty ? fallbackTitle(for: url) : itemTitle)
                        : savedTitle,
                    url: url,
                    folderPath: folderPath(for: item["parentID"] as? String)
                )
            )
        }
        return bookmarks
    }

    private static func firefoxBookmarks(in selectedFolder: URL) throws -> [ImportedBrowserBookmark] {
        let databaseURLs = candidateFiles(
            named: "places.sqlite",
            below: selectedFolder,
            maximumDepth: 2
        )
        guard !databaseURLs.isEmpty else {
            throw BrowserImportError.profileDataNotFound(BrowserImportSource.firefox.name)
        }

        var bookmarks: [ImportedBrowserBookmark] = []
        let includesMultipleProfiles = databaseURLs.count > 1
        for databaseURL in databaseURLs {
            let prefix = includesMultipleProfiles
                ? [cleanedFolderName(databaseURL.deletingLastPathComponent().lastPathComponent)]
                : []
            bookmarks.append(contentsOf: try readFirefoxBookmarks(from: databaseURL, profilePrefix: prefix))
            if bookmarks.count >= bookmarkLimit { break }
        }
        return Array(bookmarks.prefix(bookmarkLimit))
    }

    private static func readFirefoxBookmarks(
        from databaseURL: URL,
        profilePrefix: [String]
    ) throws -> [ImportedBrowserBookmark] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw BrowserImportError.unreadableFile
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        var rootNames: [Int64: String] = [:]
        var excludedRootIDs = Set<Int64>()
        var rootStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            database,
            "SELECT folder_id, root_name FROM moz_bookmarks_roots",
            -1,
            &rootStatement,
            nil
        ) == SQLITE_OK, let rootStatement {
            defer { sqlite3_finalize(rootStatement) }
            while sqlite3_step(rootStatement) == SQLITE_ROW {
                let folderID = sqlite3_column_int64(rootStatement, 0)
                let rootName = sqliteString(rootStatement, column: 1)
                switch rootName {
                case "toolbar": rootNames[folderID] = "Favorites"
                case "menu": rootNames[folderID] = "Bookmarks Menu"
                case "unfiled": rootNames[folderID] = "Other Bookmarks"
                case "mobile": rootNames[folderID] = "Mobile Bookmarks"
                case "tags", "placesRoot": excludedRootIDs.insert(folderID)
                default: break
                }
            }
        }

        let query = """
            SELECT b.id, b.parent, b.type, COALESCE(b.title, ''), COALESCE(p.url, '')
            FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk
            ORDER BY b.parent, b.position
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw BrowserImportError.unreadableFile
        }
        defer { sqlite3_finalize(statement) }

        var nodes: [Int64: FirefoxNode] = [:]
        var orderedBookmarkIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let node = FirefoxNode(
                id: sqlite3_column_int64(statement, 0),
                parentID: sqlite3_column_int64(statement, 1),
                type: sqlite3_column_int(statement, 2),
                title: sqliteString(statement, column: 3),
                url: sqliteString(statement, column: 4)
            )
            nodes[node.id] = node
            if node.type == 1 { orderedBookmarkIDs.append(node.id) }
        }

        func folderPath(for parentID: Int64) -> [String]? {
            var currentID = parentID
            var result: [String] = []
            var visited = Set<Int64>()

            while currentID > 0, visited.insert(currentID).inserted {
                if excludedRootIDs.contains(currentID) { return nil }
                if let rootName = rootNames[currentID] {
                    result.append(rootName)
                    break
                }
                guard let node = nodes[currentID] else { break }
                if node.type == 2 {
                    let title = cleanedFolderName(node.title)
                    if !title.isEmpty { result.append(title) }
                }
                currentID = node.parentID
            }
            return profilePrefix + result.reversed()
        }

        var result: [ImportedBrowserBookmark] = []
        for bookmarkID in orderedBookmarkIDs {
            guard result.count < bookmarkLimit,
                  let node = nodes[bookmarkID],
                  let url = webURL(from: node.url),
                  let path = folderPath(for: node.parentID)
            else { continue }

            let title = cleanedFolderName(node.title)
            result.append(
                ImportedBrowserBookmark(
                    title: title.isEmpty ? fallbackTitle(for: url) : title,
                    url: url,
                    folderPath: path
                )
            )
        }
        return result
    }

    private static func sqliteString(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func candidateFiles(
        named fileName: String,
        below selectedFolder: URL,
        maximumDepth: Int
    ) -> [URL] {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: selectedFolder.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return selectedFolder.lastPathComponent == fileName ? [selectedFolder] : []
        }

        var result: [URL] = []
        func search(_ directory: URL, depth: Int) {
            guard depth <= maximumDepth, result.count < 20 else { return }
            let directCandidate = directory.appending(path: fileName, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: directCandidate.path) {
                result.append(directCandidate)
            }
            guard depth < maximumDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  )
            else { return }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                search(child, depth: depth + 1)
                if result.count >= 20 { return }
            }
        }

        search(selectedFolder, depth: 0)
        return result.sorted { $0.path < $1.path }
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

    private static func parseHTMLBookmarks(in html: String) throws -> [ImportedBrowserBookmark] {
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
                  let url = webURL(from: href)
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
                    title: title.isEmpty ? fallbackTitle(for: url) : title,
                    url: url
                )
            )

            if bookmarks.count >= bookmarkLimit {
                stop.pointee = true
            }
        }

        return bookmarks
    }

    private static func deduplicated(
        _ bookmarks: [ImportedBrowserBookmark]
    ) -> [ImportedBrowserBookmark] {
        var seenURLs = Set<String>()
        var result: [ImportedBrowserBookmark] = []
        for bookmark in bookmarks where seenURLs.insert(bookmark.url.absoluteString).inserted {
            result.append(bookmark)
            if result.count >= bookmarkLimit { break }
        }
        return result
    }

    private static func webURL(from source: String) -> URL? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func fallbackTitle(for url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    private static func cleanedFolderName(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
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
