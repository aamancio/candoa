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
    static let shared = DownloadsStore()

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

        var isActive: Bool {
            if case .active = phase { return true }
            return false
        }
    }

    @Published private(set) var items: [Item] = []

    private var downloadsByItemID: [UUID: WKDownload] = [:]
    private var itemIDsByDownload: [WKDownload: UUID] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    var hasClearableItems: Bool {
        items.contains { !$0.isActive }
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
    }

    /// Removes settled rows from the list. Never touches the files —
    /// deleting a download from disk stays an explicit Finder action.
    func clearSettledItems() {
        items.removeAll { !$0.isActive }
    }

    private func detach(itemID: UUID, download: WKDownload) {
        progressObservations[itemID] = nil
        downloadsByItemID[itemID] = nil
        itemIDsByDownload[download] = nil
    }

    private func setPhase(_ phase: Item.Phase, forItemID itemID: UUID, onlyWhileActive: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if onlyWhileActive, !items[index].isActive { return }
        items[index].phase = phase
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
