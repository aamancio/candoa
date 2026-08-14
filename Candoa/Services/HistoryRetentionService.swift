import AppKit
import Foundation

/// Applies the General pane's "Remove history items" choice: visits older
/// than the retention window are deleted at launch, and again on app
/// activation once enough time has passed. Event-driven on purpose — the
/// product guardrails rule out standing timers, and day-granularity
/// retention doesn't need one. CloudKit mirroring treats the prune as
/// ordinary deletes, so synced copies follow.
@MainActor
final class HistoryRetentionService {
    static let shared = HistoryRetentionService()

    private static let recheckInterval: TimeInterval = 6 * 60 * 60

    private var lastPruneAt: Date?
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?
    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func activate() {
        prune()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Application notifications on .main always run on the main thread.
            MainActor.assumeIsolated {
                guard let self,
                      let lastPruneAt = self.lastPruneAt,
                      Date().timeIntervalSince(lastPruneAt) >= Self.recheckInterval else {
                    return
                }
                self.prune()
            }
        }
    }

    /// Also called by the Settings pane when the retention choice changes,
    /// so tightening the window takes effect immediately.
    func prune() {
        lastPruneAt = Date()
        guard let cutoff = HistoryRetentionPreference.current.cutoff else { return }
        let persistence = persistence
        Task.detached(priority: .utility) {
            let removed = (try? persistence.deleteHistory(visitedBefore: cutoff)) ?? 0
            guard removed > 0 else { return }
            // An open History window pages by offset against the store; a
            // prune underneath it would skew that silently. It already
            // reloads on this notification for the Clear Browsing Data flow.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: BrowsingDataService.browsingDataDidClear,
                    object: nil
                )
            }
        }
    }
}
