import AppKit
import SwiftUI
import Foundation
import WebKit

/// Removes ordinary browsing data: Core Data history plus the persistent
/// WKWebsiteDataStore contents behind each Space. Private windows browse
/// against non-persistent stores owned by their own coordinators, so
/// nothing reachable from here can touch private-browsing data.
@MainActor
enum BrowsingDataService {
    /// Which Spaces a clear applies to. `space` carries both the history
    /// scope (the Space ID) and the website-data scope (its data-store
    /// identifier — Spaces can share one).
    enum Scope {
        case space(id: UUID, dataStoreID: UUID)
        case allSpaces
    }

    /// Posted after a clear completes so open windows refresh their
    /// history surfaces.
    static let browsingDataDidClear = Notification.Name("Candoa.BrowsingDataDidClear")

    static func clear(
        range: HistoryClearRange,
        scope: Scope,
        includeWebsiteData: Bool,
        historyRepository: any HistoryRepository = CoreDataHistoryRepository()
    ) async throws {
        let startDate = range.startDate()

        // History deletes stay object-by-object inside the repository so
        // CloudKit mirroring sees the tombstones; run them off the main thread.
        let spaceID: UUID? = {
            guard case .space(let id, _) = scope else { return nil }
            return id
        }()
        try await Task.detached(priority: .userInitiated) {
            try historyRepository.deleteVisits(visitedAfter: startDate, in: spaceID)
        }.value

        // Command bar learning quotes the pages it was taught with, so it
        // clears with them. It isn't Space-scoped, so a per-Space clear
        // drops picks from the same range everywhere rather than leaving
        // cleared pages reachable from the address bar.
        CommandBarSelectionMemory.shared.forget(selectedAfter: startDate)

        if includeWebsiteData {
            let identifiers: [UUID]
            switch scope {
            case .space(_, let dataStoreID):
                identifiers = [dataStoreID]
            case .allSpaces:
                // Every persistent identifier on disk, which also reaches
                // stores orphaned by deleted Spaces. Private windows use
                // non-persistent stores and never appear here.
                identifiers = await WebsiteDataInventory.allPersistentDataStoreIdentifiers()
            }
            for identifier in identifiers {
                // Resolve through the shared instance: a second
                // WKWebsiteDataStore(forIdentifier:) for a live identifier
                // tears down its network session on dealloc.
                let dataStore = WebViewCoordinator.sharedDataStore(forIdentifier: identifier)
                await dataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: startDate ?? .distantPast
                )
            }
        }

        NotificationCenter.default.post(name: browsingDataDidClear, object: nil)
    }
}

/// The shared confirmation dialog behind every clear entry point: the
/// History surface, History > Clear History…, and Settings > Privacy.
@MainActor
enum ClearBrowsingDataPrompt {
    /// The window's current Space, offered as the default scope. `nil`
    /// (the Settings entry point) restricts the dialog to all Spaces.
    struct CurrentSpace {
        let id: UUID
        let dataStoreID: UUID
    }

    static func present(currentSpace: CurrentSpace?) {
        let scope: BrowsingDataService.Scope = currentSpace.map {
            .space(id: $0.id, dataStoreID: $0.dataStoreID)
        } ?? .allSpaces

        let host = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first { $0.isVisible && $0.canBecomeKey }
        guard let host else { return }

        var controller: NSViewController?
        let dismiss: () -> Void = {
            guard let sheet = controller?.view.window else { return }
            host.endSheet(sheet)
        }

        let sheet = ClearBrowsingDataSheet(
            message: String(localized: "Clearing history will remove related cookies and other website data."),
            detail: informativeText(currentSpace: currentSpace),
            onCancel: dismiss,
            onClear: { range in
                dismiss()
                Task {
                    do {
                        try await BrowsingDataService.clear(
                            range: range,
                            scope: scope,
                            includeWebsiteData: true
                        )
                    } catch {
                        presentClearError(error)
                    }
                }
            }
        )

        let hosting = NSHostingController(rootView: sheet)
        hosting.view.layoutSubtreeIfNeeded()
        controller = hosting
        host.beginSheet(sheetWindow(for: hosting))
    }

    /// Wraps the sheet's content in a plain window, so it drops from the title
    /// bar as a sheet rather than opening as a panel of its own.
    private static func sheetWindow(for controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        return window
    }

    private static func informativeText(currentSpace: CurrentSpace?) -> String {
        var lines: [String] = []
        // Which Spaces are affected is the one thing Safari has no equivalent
        // for, so it is stated plainly.
        lines.append(currentSpace != nil
            ? String(localized: "History is removed from this Space.")
            : String(localized: "History is removed from every Space."))
        if PersistenceService.shared.syncsHistoryWithICloud {
            lines.append(String(localized: "History will also be removed on your other Macs syncing with iCloud."))
        }
        return lines.joined(separator: " ")
    }

    private static func presentClearError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Browsing Data Couldn’t Be Cleared")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
