import Foundation

/// Applies the General pane's "Remove history items" choice: visits older
/// than the retention window are deleted at launch and every few hours
/// afterward, so long-running instances keep up without any work when
/// nothing has expired. CloudKit mirroring treats the prune as ordinary
/// deletes, so synced copies follow.
@MainActor
final class HistoryRetentionService {
    static let shared = HistoryRetentionService()

    private static let recheckInterval: TimeInterval = 6 * 60 * 60

    private var timer: Timer?
    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    func activate() {
        prune()
        let timer = Timer(timeInterval: Self.recheckInterval, repeats: true) { _ in
            Task { @MainActor in
                HistoryRetentionService.shared.prune()
            }
        }
        timer.tolerance = 60 * 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Also called by the Settings pane when the retention choice changes,
    /// so tightening the window takes effect immediately.
    func prune() {
        guard let cutoff = HistoryRetentionPreference.current.cutoff else { return }
        let persistence = persistence
        Task.detached(priority: .utility) {
            try? persistence.deleteHistory(visitedBefore: cutoff)
        }
    }
}
