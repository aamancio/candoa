import Foundation
import WebKit

/// Enumerates and removes stored website data per site, across every
/// persistent WKWebsiteDataStore (one can back several Spaces). This is what
/// lets a single site with a wedged session — a stale SSO cookie bouncing
/// every visit to an "invalid session" page — be fixed without signing the
/// user out everywhere else. Private windows use non-persistent stores and
/// never appear here.
@MainActor
enum WebsiteDataInventory {
    /// One site's stored data, merged across data stores. `Record` is
    /// `WKWebsiteDataRecord` in the app; tests substitute a plain value.
    struct Entry<Record>: Identifiable {
        let displayName: String
        let dataTypes: Set<String>
        let records: [(storeID: UUID, record: Record)]

        var id: String { displayName }
    }

    typealias WebsiteDataEntry = Entry<WKWebsiteDataRecord>

    static func fetchEntries() async -> [WebsiteDataEntry] {
        var rows: [(storeID: UUID, displayName: String, dataTypes: Set<String>, record: WKWebsiteDataRecord)] = []
        for identifier in await allPersistentDataStoreIdentifiers() {
            // Resolve through the shared instance: a second
            // WKWebsiteDataStore(forIdentifier:) for a live identifier
            // tears down its network session on dealloc.
            let dataStore = WebViewCoordinator.sharedDataStore(forIdentifier: identifier)
            let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            for record in records {
                rows.append((identifier, record.displayName, record.dataTypes, record))
            }
        }
        return mergedEntries(from: rows)
    }

    static func remove(_ entries: [WebsiteDataEntry]) async {
        var recordsByStore: [UUID: [WKWebsiteDataRecord]] = [:]
        for entry in entries {
            for (storeID, record) in entry.records {
                recordsByStore[storeID, default: []].append(record)
            }
        }
        for (storeID, records) in recordsByStore {
            let dataStore = WebViewCoordinator.sharedDataStore(forIdentifier: storeID)
            await dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: records
            )
        }
    }

    static func allPersistentDataStoreIdentifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
                continuation.resume(returning: identifiers)
            }
        }
    }

    /// Folds per-store records into one entry per site name, ordered the way
    /// Finder orders names. Pure so the unit target can cover it.
    static func mergedEntries<Record>(
        from rows: [(storeID: UUID, displayName: String, dataTypes: Set<String>, record: Record)]
    ) -> [Entry<Record>] {
        var entriesByName: [String: (dataTypes: Set<String>, records: [(storeID: UUID, record: Record)])] = [:]
        for row in rows {
            var entry = entriesByName[row.displayName] ?? (dataTypes: [], records: [])
            entry.dataTypes.formUnion(row.dataTypes)
            entry.records.append((row.storeID, row.record))
            entriesByName[row.displayName] = entry
        }
        return entriesByName
            .map { Entry(displayName: $0.key, dataTypes: $0.value.dataTypes, records: $0.value.records) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The per-row caption, Safari's way: the kinds of data the site stores,
    /// in a fixed order. WebKit types with no user-facing category (hash
    /// salts, media keys, …) are folded into the fallback only when nothing
    /// recognizable is stored.
    static func typeSummary(for dataTypes: Set<String>) -> String {
        var parts: [String] = []
        if dataTypes.contains(WKWebsiteDataTypeCookies) {
            parts.append(String(localized: "Cookies"))
        }
        if !dataTypes.isDisjoint(with: [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache
        ]) {
            parts.append(String(localized: "Cache"))
        }
        if !dataTypes.isDisjoint(with: [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage
        ]) {
            parts.append(String(localized: "Local Storage"))
        }
        if !dataTypes.isDisjoint(with: [
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases
        ]) {
            parts.append(String(localized: "Databases"))
        }
        if dataTypes.contains(WKWebsiteDataTypeServiceWorkerRegistrations) {
            parts.append(String(localized: "Service Workers"))
        }
        guard !parts.isEmpty else {
            return String(localized: "Website Data")
        }
        return parts.joined(separator: ", ")
    }
}
