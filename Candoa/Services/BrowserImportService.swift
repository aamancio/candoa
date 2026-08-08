import Foundation
import SQLite3
import Darwin

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

    var suggestedProfileFolderURL: URL {
        let libraryURL = Self.userHomeDirectory
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

    private static var userHomeDirectory: URL {
        guard let passwordEntry = getpwuid(getuid()),
              let homePath = passwordEntry.pointee.pw_dir
        else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(filePath: String(cString: homePath), directoryHint: .isDirectory)
    }
}

enum BrowserImportError: LocalizedError {
    case unreadableFile
    case profileAccessRequired(String)
    case profileDataNotFound(String)
    case noBookmarks

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return String(localized: "Candoa couldn’t read that bookmarks file.")
        case .profileAccessRequired(let sourceName):
            return String(localized: "macOS requires permission before Candoa can read \(sourceName)’s bookmarks.")
        case .profileDataNotFound(let sourceName):
            return String(localized: "Candoa couldn’t find \(sourceName) bookmark data in that folder.")
        case .noBookmarks:
            return String(localized: "No web bookmarks were found there.")
        }
    }
}

struct BrowserImportService {
    typealias ProfileFolderURLProvider = @Sendable (BrowserImportSource) -> URL

    private struct FirefoxNode {
        let id: Int64
        let parentID: Int64
        let type: Int32
        let title: String
        let url: String
    }

    private static let bookmarkLimit = 2_000
    private let profileFolderURLProvider: ProfileFolderURLProvider
    private let persistsProfileAccess: Bool

    init(
        profileFolderURLProvider: @escaping ProfileFolderURLProvider = { source in
            source.suggestedProfileFolderURL
        },
        persistsProfileAccess: Bool = true
    ) {
        self.profileFolderURLProvider = profileFolderURLProvider
        self.persistsProfileAccess = persistsProfileAccess
    }

    func bookmarks(
        fromProfileFolder folderURL: URL,
        source: BrowserImportSource
    ) async throws -> [ImportedBrowserBookmark] {
        let persistsProfileAccess = persistsProfileAccess
        let (bookmarks, _) = try await Task.detached(priority: .userInitiated) {
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
                if persistsProfileAccess {
                    Self.rememberProfileFolder(folderURL, source: source)
                }
                return result
            }
        }.value
        return bookmarks
    }

    func bookmarks(from source: BrowserImportSource) async throws -> [ImportedBrowserBookmark] {
        let profileFolderURL = (persistsProfileAccess ? Self.rememberedProfileFolder(for: source) : nil)
            ?? profileFolderURLProvider(source)
        return try await bookmarks(fromProfileFolder: profileFolderURL, source: source)
    }

    func hasRememberedProfileFolder(for source: BrowserImportSource) -> Bool {
        Self.rememberedProfileFolder(for: source) != nil
    }

    private static func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) throws -> (T, Bool) {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return (try operation(), accessedSecurityScope)
    }

    private static func rememberProfileFolder(_ url: URL, source: BrowserImportSource) {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let destinationURL = try profileBookmarkURL(for: source, createsDirectory: true)
            try bookmarkData.write(to: destinationURL, options: .atomic)
        } catch let error as NSError {
            NSLog(
                "Could not preserve %@ import access (%@:%ld)",
                source.name,
                error.domain,
                error.code
            )
        }
    }

    private static func rememberedProfileFolder(for source: BrowserImportSource) -> URL? {
        guard let bookmarkURL = try? profileBookmarkURL(for: source, createsDirectory: false),
              let bookmarkData = try? Data(contentsOf: bookmarkURL)
        else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            try? FileManager.default.removeItem(at: bookmarkURL)
            return nil
        }
        if isStale {
            rememberProfileFolder(url, source: source)
        }
        return url
    }

    private static func profileBookmarkURL(
        for source: BrowserImportSource,
        createsDirectory: Bool
    ) throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createsDirectory
        )
        let directoryURL = applicationSupportURL
            .appending(path: "Candoa", directoryHint: .isDirectory)
            .appending(path: "BrowserImportAccess", directoryHint: .isDirectory)
        if createsDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        return directoryURL.appending(path: "\(source.rawValue).bookmark", directoryHint: .notDirectory)
    }

    private static func safariBookmarks(in selectedFolder: URL) throws -> [ImportedBrowserBookmark] {
        let directBookmarksURL = selectedFolder.appending(
            path: "Bookmarks.plist",
            directoryHint: .notDirectory
        )
        let data: Data
        do {
            data = try Data(contentsOf: directBookmarksURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileReadNoPermission.rawValue {
            throw BrowserImportError.profileAccessRequired(BrowserImportSource.safari.name)
        } catch {
            let candidates = try candidateFiles(
                named: "Bookmarks.plist",
                below: selectedFolder,
                maximumDepth: 2,
                sourceName: BrowserImportSource.safari.name
            )
            guard let bookmarksURL = candidates.first else {
                throw BrowserImportError.profileDataNotFound(BrowserImportSource.safari.name)
            }
            do {
                data = try Data(contentsOf: bookmarksURL)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.fileReadNoPermission.rawValue {
                throw BrowserImportError.profileAccessRequired(BrowserImportSource.safari.name)
            } catch {
                throw BrowserImportError.unreadableFile
            }
        }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            throw BrowserImportError.unreadableFile
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
        let bookmarkFiles = try candidateFiles(
            named: "Bookmarks",
            below: selectedFolder,
            maximumDepth: 2,
            sourceName: sourceName
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
        let sidebarFiles = try candidateFiles(
            named: "StorableSidebar.json",
            below: selectedFolder,
            maximumDepth: 2,
            sourceName: BrowserImportSource.arc.name
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
        if try !candidateFiles(
            named: "Bookmarks",
            below: chromiumUserDataURL,
            maximumDepth: 2,
            sourceName: BrowserImportSource.arc.name
        ).isEmpty {
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
        let databaseURLs = try candidateFiles(
            named: "places.sqlite",
            below: selectedFolder,
            maximumDepth: 2,
            sourceName: BrowserImportSource.firefox.name
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
                case "toolbar": rootNames[folderID] = String(localized: "Favorites")
                case "menu": rootNames[folderID] = String(localized: "Bookmarks Menu")
                case "unfiled": rootNames[folderID] = String(localized: "Other Bookmarks")
                case "mobile": rootNames[folderID] = String(localized: "Mobile Bookmarks")
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
        maximumDepth: Int,
        sourceName: String
    ) throws -> [URL] {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: selectedFolder.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return selectedFolder.lastPathComponent == fileName ? [selectedFolder] : []
        }

        var result: [URL] = []
        func search(_ directory: URL, depth: Int) throws {
            guard depth <= maximumDepth, result.count < 20 else { return }
            let directCandidate = directory.appending(path: fileName, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: directCandidate.path) {
                result.append(directCandidate)
            }
            guard depth < maximumDepth else { return }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  )
            } catch let error as NSError where isPermissionDenied(error) {
                throw BrowserImportError.profileAccessRequired(sourceName)
            } catch {
                return
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                try search(child, depth: depth + 1)
                if result.count >= 20 { return }
            }
        }

        try search(selectedFolder, depth: 0)
        return result.sorted { $0.path < $1.path }
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == EACCES || error.code == EPERM {
            return true
        }
        guard let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isPermissionDenied(underlyingError)
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

}
