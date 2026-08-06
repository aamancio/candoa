import AppKit
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

        if includeWebsiteData {
            let identifiers: [UUID]
            switch scope {
            case .space(_, let dataStoreID):
                identifiers = [dataStoreID]
            case .allSpaces:
                // Every persistent identifier on disk, which also reaches
                // stores orphaned by deleted Spaces. Private windows use
                // non-persistent stores and never appear here.
                identifiers = await allPersistentDataStoreIdentifiers()
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

    private static func allPersistentDataStoreIdentifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
                continuation.resume(returning: identifiers)
            }
        }
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
        let ranges = HistoryClearRange.allCases
        let rangePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 210, height: 26), pullsDown: false)
        rangePicker.addItems(withTitles: ranges.map(\.title))
        rangePicker.selectItem(at: 0)
        rangePicker.setAccessibilityIdentifier("clear-browsing-data-range")

        let scopePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 210, height: 26), pullsDown: false)
        scopePicker.addItems(withTitles: [
            String(localized: "This Space"),
            String(localized: "All Spaces")
        ])
        scopePicker.selectItem(at: 0)
        scopePicker.setAccessibilityIdentifier("clear-browsing-data-scope")

        let websiteDataCheckbox = NSButton(
            checkboxWithTitle: String(localized: "Remove cookies and other website data"),
            target: nil,
            action: nil
        )
        websiteDataCheckbox.state = .on
        websiteDataCheckbox.setAccessibilityIdentifier("clear-browsing-data-website-data")

        let accessory = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10

        let rangeRow = NSStackView()
        rangeRow.orientation = .horizontal
        rangeRow.alignment = .centerY
        rangeRow.spacing = 8
        rangeRow.addArrangedSubview(NSTextField(labelWithString: String(localized: "Clear")))
        rangeRow.addArrangedSubview(rangePicker)
        accessory.addArrangedSubview(rangeRow)

        if currentSpace != nil {
            let scopeRow = NSStackView()
            scopeRow.orientation = .horizontal
            scopeRow.alignment = .centerY
            scopeRow.spacing = 8
            scopeRow.addArrangedSubview(NSTextField(labelWithString: String(localized: "From")))
            scopeRow.addArrangedSubview(scopePicker)
            accessory.addArrangedSubview(scopeRow)
        }

        accessory.addArrangedSubview(websiteDataCheckbox)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = String(localized: "Clear browsing data?")
        alert.informativeText = informativeText(currentSpace: currentSpace)
        alert.accessoryView = accessory
        let clearButton = alert.addButton(withTitle: String(localized: "Clear"))
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let range = ranges[max(rangePicker.indexOfSelectedItem, 0)]
            let scope: BrowsingDataService.Scope = {
                guard let currentSpace, scopePicker.indexOfSelectedItem == 0 else { return .allSpaces }
                return .space(id: currentSpace.id, dataStoreID: currentSpace.dataStoreID)
            }()
            let includeWebsiteData = websiteDataCheckbox.state == .on
            Task {
                do {
                    try await BrowsingDataService.clear(
                        range: range,
                        scope: scope,
                        includeWebsiteData: includeWebsiteData
                    )
                } catch {
                    presentClearError(error)
                }
            }
        }

        if let window = NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private static func informativeText(currentSpace: CurrentSpace?) -> String {
        var lines: [String] = []
        if currentSpace != nil {
            lines.append(String(localized: """
            History from the chosen period is removed from the selected Spaces.
            """))
        } else {
            lines.append(String(localized: """
            History from the chosen period is removed from all Spaces.
            """))
        }
        lines.append(String(localized: """
        Removing website data also clears cookies, caches, and other data \
        those websites stored for the same period, which may sign you out of them.
        """))
        if CandoaSyncPreferences.syncsWorkspaceWithICloud, CandoaSyncPreferences.syncsHistoryWithICloud {
            lines.append(String(localized: """
            History is also removed from your other Macs that sync history with iCloud.
            """))
        }
        lines.append(String(localized: "This can’t be undone."))
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
