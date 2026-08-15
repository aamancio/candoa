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
        Self.discardOutdatedCaches()
    }

    /// Bumped whenever a bug makes already-written thumbnails not worth
    /// keeping, so nobody has to look at stale garbage until each tab happens
    /// to be recaptured. `v1` wrote Retina snapshots with the page squeezed
    /// into the bottom-left quadrant on white.
    private nonisolated static let directoryName = "TabSnapshots-v2"
    private nonisolated static let outdatedDirectoryNames = ["TabSnapshots"]

    /// UI test runs share the real bundle's Application Support container;
    /// a nil directory disables persistence so runs stay deterministic and
    /// leave no files behind.
    private nonisolated static var defaultDirectoryURL: URL? {
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return nil }
        return candoaSupportDirectoryURL?.appendingPathComponent(directoryName, isDirectory: true)
    }

    private nonisolated static var candoaSupportDirectoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Candoa", isDirectory: true)
    }

    /// Best effort, once per launch: drop thumbnail directories written by
    /// superseded cache formats. Missing directories are the normal case.
    private nonisolated static func discardOutdatedCaches() {
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1",
              let supportURL = candoaSupportDirectoryURL
        else { return }
        let outdatedURLs = outdatedDirectoryNames.map {
            supportURL.appendingPathComponent($0, isDirectory: true)
        }
        Task.detached(priority: .utility) {
            for url in outdatedURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func persist(_ image: NSImage, for tabID: UUID, url: URL?) {
        guard let directoryURL else { return }

        let urlKey = url?.absoluteString ?? ""
        guard persistedURLKeys[tabID] != urlKey else { return }
        persistedURLKeys[tabID] = urlKey

        // Encoding happens here on the main actor — at switcher thumbnail
        // size it is trivially cheap, and it keeps the detached work to
        // Sendable Data plus file IO. Wake snapshots arrive wider than the
        // switcher needs; scale them down so the cache stays thumbnail-sized.
        guard
            let bitmap = Self.thumbnailBitmap(from: image, maxWidth: TabSwitcherConfiguration.snapshotWidth),
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

    /// Whether a thumbnail already exists on disk, without decoding it. The
    /// preview warm-up uses this to skip tabs a previous run already covered.
    func hasSnapshot(for tabID: UUID) async -> Bool {
        guard let directoryURL else { return false }
        let path = Self.fileURL(for: tabID, in: directoryURL).path
        return await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
    }

    /// Re-encodes `image` as an sRGB bitmap no wider than `maxWidth`,
    /// preserving aspect ratio. Images already within the limit are returned
    /// at their native pixel size.
    nonisolated static func thumbnailBitmap(from image: NSImage, maxWidth: CGFloat) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation, let source = NSBitmapImageRep(data: tiff) else { return nil }
        let sourceWidth = CGFloat(source.pixelsWide)
        let sourceHeight = CGFloat(source.pixelsHigh)
        guard sourceWidth > maxWidth, sourceWidth > 0, sourceHeight > 0 else { return source }
        // A rep drawn from a Retina snapshot carries a point size half its
        // pixel size, and `draw(in:from:)` reads the source rect in points —
        // so the rect below has to describe the same space the rep does.
        // Pinning the rep to its pixel size makes the two agree; leaving them
        // apart drew the page into a corner of the thumbnail (issue #347).
        source.size = NSSize(width: sourceWidth, height: sourceHeight)

        let scale = maxWidth / sourceWidth
        let targetWidth = Int(maxWidth.rounded())
        let targetHeight = max(1, Int((sourceHeight * scale).rounded()))
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        target.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        return target
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
