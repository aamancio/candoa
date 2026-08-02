import AppKit
import Foundation

/// Local-only disk cache of tab switcher thumbnails, so tabs restored on a
/// fresh launch show a real page preview before their web view first loads.
///
/// Deliberately a flat-file cache outside Core Data: thumbnails are
/// device-local view state and must never ride the CloudKit workspace sync.
/// Every operation is event-driven off a Control-Tab interaction — no timers,
/// no observers — and writes coalesce to one per tab-and-URL per app run.
@MainActor
final class TabSnapshotStore {
    static let shared = TabSnapshotStore()

    private let directoryURL: URL?
    private var persistedURLKeys: [UUID: String] = [:]

    init(directoryURL: URL? = TabSnapshotStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    /// UI test runs share the real bundle's Application Support container;
    /// a nil directory disables persistence so runs stay deterministic and
    /// leave no files behind.
    private nonisolated static var defaultDirectoryURL: URL? {
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return nil }
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL
            .appendingPathComponent("Candoa", isDirectory: true)
            .appendingPathComponent("TabSnapshots", isDirectory: true)
    }

    func persist(_ image: NSImage, for tabID: UUID, url: URL?) {
        guard let directoryURL else { return }

        let urlKey = url?.absoluteString ?? ""
        guard persistedURLKeys[tabID] != urlKey else { return }
        persistedURLKeys[tabID] = urlKey

        // Encoding happens here on the main actor — at switcher thumbnail
        // size it is trivially cheap, and it keeps the detached work to
        // Sendable Data plus file IO.
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { return }

        let fileURL = Self.fileURL(for: tabID, in: directoryURL)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("Candoa failed to persist a tab snapshot: \(error.localizedDescription)")
            }
        }
    }

    func loadSnapshot(for tabID: UUID) async -> NSImage? {
        guard let directoryURL else { return nil }
        let fileURL = Self.fileURL(for: tabID, in: directoryURL)
        return await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: fileURL)
        }.value
    }

    /// Drops files for tabs that no longer exist in the workspace. Private
    /// windows must never call this: their ephemeral tab IDs would sweep away
    /// every regular tab's snapshot.
    func prune(keeping tabIDs: Set<UUID>) {
        guard let directoryURL else { return }
        let keptFileNames = Set(tabIDs.map { Self.fileName(for: $0) })
        Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files where !keptFileNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func fileURL(for tabID: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(fileName(for: tabID))
    }

    private static func fileName(for tabID: UUID) -> String {
        tabID.uuidString + ".jpg"
    }
}
