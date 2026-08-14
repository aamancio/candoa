import AppKit
import Combine
import Foundation
import WebKit

/// Session-scoped download list behind the Downloads popover and the
/// View > Show Downloads command. Ordinary windows share one instance;
/// each private window owns an ephemeral one, so private-browsing
/// downloads never reach the shared surface and vanish with the window
/// (the downloaded files themselves stay in ~/Downloads either way).
/// Progress arrives through KVO on each download's `Progress` — there
/// are no timers and no idle polling; an empty or settled list costs
/// nothing at steady state.
@MainActor
final class DownloadsStore: ObservableObject {
    static let shared = DownloadsStore(persistsAcrossLaunches: true)

    struct Item: Identifiable, Equatable {
        enum Phase: Equatable {
            /// nil fraction = size unknown, show an indeterminate bar.
            case active(fraction: Double?)
            case completed
            case failed(reason: String)
            case cancelled
        }

        let id: UUID
        var filename: String
        var destination: URL?
        var phase: Phase
        let startedAt: Date
        /// When the row left the active state. Day-based list retention
        /// counts from here, not from startedAt — a download slower than
        /// the retention window must still get its moment in the list.
        var settledAt: Date? = nil

        var isActive: Bool {
            if case .active = phase { return true }
            return false
        }
    }

    @Published private(set) var items: [Item] = []

    private var downloadsByItemID: [UUID: WKDownload] = [:]
    private var itemIDsByDownload: [WKDownload: UUID] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    /// Only the shared (ordinary-window) store writes its settled rows to
    /// disk; private-window stores stay ephemeral by design.
    private let persistsAcrossLaunches: Bool

    init(persistsAcrossLaunches: Bool = false) {
        // UI-test launches share the real defaults domain; rows persisted by
        // a previous run must not leak into a fixture-driven list.
        self.persistsAcrossLaunches = persistsAcrossLaunches
            && ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1"
        loadPersistedItems()
    }

    var hasClearableItems: Bool {
        items.contains { !$0.isActive }
    }

    /// Mean progress across active downloads, or nil when none are active —
    /// drives the ring on the sidebar's Downloads button. Indeterminate
    /// downloads count as 0 so the ring appears the moment one starts.
    var activeProgress: Double? {
        let fractions = items.compactMap { item -> Double? in
            if case .active(let fraction) = item.phase { return fraction ?? 0 }
            return nil
        }
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    // MARK: - WKDownload lifecycle

    func begin(_ download: WKDownload, destination: URL) {
        let item = Item(
            id: UUID(),
            filename: destination.lastPathComponent,
            destination: destination,
            phase: .active(fraction: nil),
            startedAt: Date()
        )
        items.insert(item, at: 0)
        downloadsByItemID[item.id] = download
        itemIDsByDownload[download] = item.id

        progressObservations[item.id] = download.progress.observe(
            \.fractionCompleted,
            options: [.initial]
        ) { [weak self] progress, _ in
            let fraction = progress.isIndeterminate ? nil : progress.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, let itemID = self.itemIDsByDownload[download] else { return }
                self.setPhase(.active(fraction: fraction), forItemID: itemID, onlyWhileActive: true)
            }
        }
    }

    func finish(_ download: WKDownload) {
        conclude(download, as: .completed)
    }

    func fail(_ download: WKDownload, reason: String) {
        conclude(download, as: .failed(reason: reason))
    }

    private func conclude(_ download: WKDownload, as phase: Item.Phase) {
        // An explicitly cancelled download was already detached; a late
        // delegate callback for it must not resurrect the row.
        guard let itemID = itemIDsByDownload[download] else { return }
        detach(itemID: itemID, download: download)
        setPhase(phase, forItemID: itemID, onlyWhileActive: true)
        settleDidMutate()
    }

    // MARK: - User actions

    func cancelItem(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].isActive else { return }

        if let download = downloadsByItemID[itemID] {
            // Resume data is intentionally discarded: the MVP has no
            // resume affordance, and holding the blob would keep dead
            // state alive for the rest of the session.
            download.cancel { _ in }
            detach(itemID: itemID, download: download)
        }
        items[index].phase = .cancelled
        items[index].settledAt = Date()
        settleDidMutate()
    }

    /// Removes settled rows from the list. Never touches the files —
    /// deleting a download from disk stays an explicit Finder action.
    func clearSettledItems() {
        items.removeAll { !$0.isActive }
        persistSettledItems()
    }

    // MARK: - List retention

    /// Applies the General pane's "Remove download list items" choice to the
    /// rows already present. Called after every settle, when the popover
    /// opens, and when the setting changes — never on a timer. Persists only
    /// when the pass removed something, so an uneventful popover open costs
    /// no defaults write.
    func applyListRetention() {
        if pruneExpiredRows() {
            persistSettledItems()
        }
    }

    /// The funnel for every mutation that settles or removes rows: prune,
    /// then persist unconditionally (the mutation itself changed state).
    private func settleDidMutate() {
        _ = pruneExpiredRows()
        persistSettledItems()
    }

    private func pruneExpiredRows() -> Bool {
        let countBefore = items.count
        switch DownloadListRetentionPreference.current {
        case .afterOneDay:
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            items.removeAll { !$0.isActive && ($0.settledAt ?? $0.startedAt) < cutoff }
        case .uponSuccess:
            items.removeAll { $0.phase == .completed }
        case .whenQuitting, .manually:
            break
        }
        return items.count != countBefore
    }

    // MARK: - Direct saves (no WKDownload)

    /// Records a file written directly by the app — e.g. WebKit's PDF
    /// viewer HUD hands over finished bytes instead of a WKDownload.
    func recordCompletedSave(at destination: URL) {
        items.insert(
            Item(
                id: UUID(),
                filename: destination.lastPathComponent,
                destination: destination,
                phase: .completed,
                startedAt: Date(),
                settledAt: Date()
            ),
            at: 0
        )
        settleDidMutate()
    }

    func recordFailedSave(filename: String, reason: String) {
        items.insert(
            Item(
                id: UUID(),
                filename: filename,
                destination: nil,
                phase: .failed(reason: reason),
                startedAt: Date(),
                settledAt: Date()
            ),
            at: 0
        )
        settleDidMutate()
    }

    // MARK: - Persistence

    private static let persistedItemsKey = "Candoa.Downloads.PersistedItems"
    private static let persistedItemLimit = 50

    private struct PersistedItem: Codable {
        enum Outcome: String, Codable {
            case completed
            case failed
            case cancelled
        }

        var filename: String
        var destinationPath: String?
        var outcome: Outcome
        var failureReason: String?
        var startedAt: Date
        var settledAt: Date?
    }

    private func loadPersistedItems() {
        guard persistsAcrossLaunches else { return }

        // "When quitting Candoa" clears the list between launches — the
        // stored rows are exactly what must not come back. This launch-time
        // purge is the policy's only deletion; persistSettledItems merely
        // stops writing, so flipping the setting mid-session and back
        // doesn't discard the previous launch's rows.
        guard DownloadListRetentionPreference.current != .whenQuitting else {
            UserDefaults.standard.removeObject(forKey: Self.persistedItemsKey)
            return
        }

        guard let data = UserDefaults.standard.data(forKey: Self.persistedItemsKey),
              let persisted = try? JSONDecoder().decode([PersistedItem].self, from: data) else {
            return
        }

        items = persisted.map { stored in
            let phase: Item.Phase
            switch stored.outcome {
            case .completed: phase = .completed
            case .failed: phase = .failed(reason: stored.failureReason ?? "")
            case .cancelled: phase = .cancelled
            }
            return Item(
                id: UUID(),
                filename: stored.filename,
                destination: stored.destinationPath.map { URL(fileURLWithPath: $0) },
                phase: phase,
                startedAt: stored.startedAt,
                settledAt: stored.settledAt
            )
        }

        // Restored rows may point into the custom download folder; resolving
        // the bookmark now (it starts security-scope access for the app's
        // lifetime) keeps their Open/Show-in-Finder actions working even
        // when the location setting has since moved back to Downloads.
        _ = DownloadLocationPreference.customFolder

        _ = pruneExpiredRows()
    }

    private func persistSettledItems() {
        guard persistsAcrossLaunches else { return }
        guard DownloadListRetentionPreference.current != .whenQuitting else { return }

        let settled = items.lazy.filter { !$0.isActive }.prefix(Self.persistedItemLimit).map { item in
            let outcome: PersistedItem.Outcome
            var failureReason: String?
            switch item.phase {
            case .completed: outcome = .completed
            case .failed(let reason):
                outcome = .failed
                failureReason = reason
            case .cancelled: outcome = .cancelled
            case .active: outcome = .cancelled
            }
            return PersistedItem(
                filename: item.filename,
                destinationPath: item.destination?.path,
                outcome: outcome,
                failureReason: failureReason,
                startedAt: item.startedAt,
                settledAt: item.settledAt
            )
        }

        guard let data = try? JSONEncoder().encode(Array(settled)) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedItemsKey)
    }

    private func detach(itemID: UUID, download: WKDownload) {
        progressObservations[itemID] = nil
        downloadsByItemID[itemID] = nil
        itemIDsByDownload[download] = nil
    }

    private func setPhase(_ phase: Item.Phase, forItemID itemID: UUID, onlyWhileActive: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if onlyWhileActive, !items[index].isActive { return }
        let wasActive = items[index].isActive
        items[index].phase = phase
        if wasActive, !items[index].isActive {
            items[index].settledAt = Date()
        }
    }

    // MARK: - UI-testing seam

    /// Applies a fixture row posted by the UI-test runner: real WKDownloads
    /// need a server the harness doesn't have, so tests drive the same
    /// item states through this side door. Spec: "filename|phase|fraction".
    func applyUITestingFixture(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return }
        let filename = parts[0]
        let phase: Item.Phase
        switch parts[1] {
        case "active":
            phase = .active(fraction: parts.count > 2 ? Double(parts[2]) : nil)
        case "completed":
            phase = .completed
        case "failed":
            phase = .failed(reason: parts.count > 2 ? parts[2] : "failed")
        case "cancelled":
            phase = .cancelled
        default:
            return
        }

        if let index = items.firstIndex(where: { $0.filename == filename }) {
            items[index].phase = phase
        } else {
            items.insert(
                Item(id: UUID(), filename: filename, destination: nil, phase: phase, startedAt: Date()),
                at: 0
            )
        }
    }

    var uiTestingDescription: String {
        guard !items.isEmpty else { return "none" }
        return items.map { item in
            switch item.phase {
            case .active(let fraction):
                let fractionText = fraction.map { String(format: "%.2f", $0) } ?? "indeterminate"
                return "\(item.filename):active:\(fractionText)"
            case .completed:
                return "\(item.filename):completed"
            case .failed:
                return "\(item.filename):failed"
            case .cancelled:
                return "\(item.filename):cancelled"
            }
        }
        .joined(separator: "|")
    }
}
