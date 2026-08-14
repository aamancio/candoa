import Foundation
import UniformTypeIdentifiers

/// The General pane's behavior choices, mirroring Safari's General tab where
/// Candoa has an equivalent surface. Safari rows without one — "opens with"
/// and "new windows open with" (every Candoa window shows the persistent
/// workspace) and "Start Page Favorites" (favorites live in the sidebar) —
/// are deliberately absent.

/// What the new-tab gesture (⌘T and the sidebar's New Tab affordances)
/// produces. The command bar is Candoa's native flow and stays the default;
/// the other two are Safari's remaining choices that make sense without a
/// tab bar.
enum NewTabPreference: String, CaseIterable {
    case commandBar = "command-bar"
    case homepage
    case emptyPage = "empty-page"

    static var current: NewTabPreference {
        let stored = UserDefaults.standard.string(forKey: SettingsOption.newTabsOpenWith)
        return NewTabPreference(rawValue: stored ?? "") ?? .commandBar
    }
}

/// How long history visits are kept before automatic removal. Safari's
/// choices and Safari's default (one year).
enum HistoryRetentionPreference: String, CaseIterable {
    case afterOneDay = "one-day"
    case afterOneWeek = "one-week"
    case afterTwoWeeks = "two-weeks"
    case afterOneMonth = "one-month"
    case afterOneYear = "one-year"
    case manually

    static var current: HistoryRetentionPreference {
        let stored = UserDefaults.standard.string(forKey: SettingsOption.historyRetention)
        return HistoryRetentionPreference(rawValue: stored ?? "") ?? .afterOneYear
    }

    /// The moment before which visits expire; nil means only manual cleanup.
    var cutoff: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .afterOneDay: return calendar.date(byAdding: .day, value: -1, to: now)
        case .afterOneWeek: return calendar.date(byAdding: .day, value: -7, to: now)
        case .afterTwoWeeks: return calendar.date(byAdding: .day, value: -14, to: now)
        case .afterOneMonth: return calendar.date(byAdding: .month, value: -1, to: now)
        case .afterOneYear: return calendar.date(byAdding: .year, value: -1, to: now)
        case .manually: return nil
        }
    }
}

/// How long settled rows stay in the Downloads popover. Safari's choices and
/// Safari's default (one day). Files on disk are never touched — this only
/// governs the list.
enum DownloadListRetentionPreference: String, CaseIterable {
    case afterOneDay = "one-day"
    case whenQuitting = "when-quitting"
    case uponSuccess = "upon-success"
    case manually

    static var current: DownloadListRetentionPreference {
        let stored = UserDefaults.standard.string(forKey: SettingsOption.downloadListRetention)
        return DownloadListRetentionPreference(rawValue: stored ?? "") ?? .afterOneDay
    }
}

/// Where downloads land: ~/Downloads, a user-chosen folder held through an
/// app-scoped security bookmark, or a per-download save panel.
@MainActor
enum DownloadLocationPreference {
    enum Mode: String {
        case downloads
        case custom
        case ask
    }

    static var mode: Mode {
        let stored = UserDefaults.standard.string(forKey: SettingsOption.downloadLocationMode)
        return Mode(rawValue: stored ?? "") ?? .downloads
    }

    static func setMode(_ mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsOption.downloadLocationMode)
    }

    /// Resolved once per launch and kept security-scope-accessible for the
    /// app's lifetime: WKDownload writes into the folder long after the
    /// bookmark was resolved, so access can never be balanced per-download.
    private static var resolvedCustomFolder: URL??

    static var customFolder: URL? {
        if let cached = resolvedCustomFolder { return cached }
        let resolved = resolveCustomFolderBookmark()
        resolvedCustomFolder = .some(resolved)
        return resolved
    }

    static var customFolderName: String? { customFolder?.lastPathComponent }

    /// Stores the panel-granted folder and switches the mode to custom.
    /// Returns false when the sandbox refuses a bookmark for it.
    @discardableResult
    static func adoptCustomFolder(_ url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }

        UserDefaults.standard.set(bookmark, forKey: SettingsOption.downloadLocationBookmark)
        setMode(.custom)
        _ = url.startAccessingSecurityScopedResource()
        resolvedCustomFolder = .some(url)
        return true
    }

    /// The folder for silent downloads (modes downloads/custom). Falls back
    /// to ~/Downloads whenever the custom folder can no longer be resolved —
    /// deleted, or its bookmark went stale beyond repair.
    static var destinationDirectory: URL? {
        if mode == .custom, let folder = customFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            return folder
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private static func resolveCustomFolderBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: SettingsOption.downloadLocationBookmark) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else {
            return nil
        }

        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: SettingsOption.downloadLocationBookmark)
        }
        return url
    }
}

/// Which finished downloads may open on their own. Narrower than Safari's
/// list on purpose: archives and disk images unpack to arbitrary content —
/// the classic abuse path for "safe file" auto-open — so they stay behind
/// an explicit double-click.
enum SafeDownloadPolicy {
    private static let safeTypes: [UTType] = [.image, .audiovisualContent, .pdf, .text]

    static func allowsAutomaticOpen(of url: URL) -> Bool {
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension.lowercased()) else {
            return false
        }
        guard !type.conforms(to: .executable),
              !type.conforms(to: .archive),
              !type.conforms(to: .diskImage) else {
            return false
        }
        return safeTypes.contains { type.conforms(to: $0) }
    }
}
