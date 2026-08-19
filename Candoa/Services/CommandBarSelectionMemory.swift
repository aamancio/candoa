import Foundation

/// One remembered "typed this, opened that" pairing from the command bar.
/// Safari and Chrome both learn from the row a person actually picks, so
/// the same few keystrokes stop re-offering the row they keep skipping.
struct CommandBarSelection: Codable, Equatable {
    var typedText: String
    var title: String
    var urlString: String
    var count: Int
    var lastSelectedAt: Date

    var url: URL? { URL(string: urlString) }
}

/// The learning rules, kept pure so they're unit-testable: the store below
/// only adds persistence.
enum CommandBarSelectionRanking {
    /// Enough to cover the handful of phrases a person types daily without
    /// letting the list grow into a second history database.
    static let maximumSelections = 200

    static func normalizedTypedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Cosmetic URL differences (trailing slash, letter case) name the same
    /// destination, matching the command bar's own dedupe key.
    static func normalizedURLKey(_ urlString: String) -> String {
        var key = urlString.lowercased()
        if key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }

    /// Past picks that answer what's being typed now. A remembered phrase
    /// counts while the typed text is still a prefix of it: having chosen a
    /// row for "sls", typing "sl" or "sls" recalls it, "slso" doesn't.
    /// Most-chosen first, ties broken by the most recent pick, so a single
    /// correction takes effect the very next time.
    static func matches(_ selections: [CommandBarSelection], for typedText: String) -> [CommandBarSelection] {
        let query = normalizedTypedText(typedText)
        guard !query.isEmpty else { return [] }

        let ranked = selections
            .filter { normalizedTypedText($0.typedText).hasPrefix(query) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.lastSelectedAt != $1.lastSelectedAt { return $0.lastSelectedAt > $1.lastSelectedAt }
                return $0.typedText.count < $1.typedText.count
            }

        var seenURLs = Set<String>()
        return ranked.filter { seenURLs.insert(normalizedURLKey($0.urlString)).inserted }
    }

    static func recording(
        _ selections: [CommandBarSelection],
        typedText: String,
        title: String,
        urlString: String,
        at date: Date
    ) -> [CommandBarSelection] {
        let query = normalizedTypedText(typedText)
        let urlKey = normalizedURLKey(urlString)
        guard !query.isEmpty, !urlKey.isEmpty else { return selections }

        var updated = selections
        var recorded = CommandBarSelection(
            typedText: query,
            title: title,
            urlString: urlString,
            count: 1,
            lastSelectedAt: date
        )
        if let index = updated.firstIndex(where: {
            normalizedTypedText($0.typedText) == query && normalizedURLKey($0.urlString) == urlKey
        }) {
            recorded.count = updated[index].count + 1
            updated.remove(at: index)
        }

        // Over the cap the least useful pairings go first: rarely chosen,
        // then longest untouched. The pick just made is never one of them.
        if updated.count >= maximumSelections {
            updated = updated
                .sorted {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.lastSelectedAt > $1.lastSelectedAt
                }
                .prefix(maximumSelections - 1)
                .map { $0 }
        }

        return updated + [recorded]
    }

    /// Learned picks age out with the visits that produced them, so the
    /// General pane's "Remove history items" choice governs both.
    static func pruned(_ selections: [CommandBarSelection], before cutoff: Date?) -> [CommandBarSelection] {
        guard let cutoff else { return selections }
        return selections.filter { $0.lastSelectedAt >= cutoff }
    }

    /// Clearing history has to take the picks learned from it: each one
    /// quotes a page's title and URL. Picks made before the cleared range
    /// stay, matching what the range promised.
    static func forgetting(_ selections: [CommandBarSelection], selectedAfter startDate: Date?) -> [CommandBarSelection] {
        guard let startDate else { return [] }
        return selections.filter { $0.lastSelectedAt < startDate }
    }

    static func forgetting(_ selections: [CommandBarSelection], urls: Set<String>) -> [CommandBarSelection] {
        let keys = Set(urls.map(normalizedURLKey))
        guard !keys.isEmpty else { return selections }
        return selections.filter { !keys.contains(normalizedURLKey($0.urlString)) }
    }
}

/// Remembers which command bar row a person chose for the text they typed,
/// so the next time they type it that row leads. Local to this Mac and
/// never synced: it's a shortcut, not browsing data worth mirroring, and it
/// is cleared with history.
@MainActor
final class CommandBarSelectionMemory {
    static let shared = CommandBarSelectionMemory(defaults: .standard)
    static let storageKey = "Candoa.CommandBarSelections"

    /// Private windows learn nothing and recall nothing — the same rule the
    /// private history repository follows.
    static func makeEphemeral() -> CommandBarSelectionMemory {
        CommandBarSelectionMemory(defaults: nil)
    }

    private let defaults: UserDefaults?
    private var selections: [CommandBarSelection]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        self.selections = Self.loadSelections(from: defaults)
    }

    func selections(matching typedText: String) -> [CommandBarSelection] {
        guard defaults != nil else { return [] }
        return CommandBarSelectionRanking.matches(
            CommandBarSelectionRanking.pruned(
                selections,
                before: HistoryRetentionPreference.current.cutoff
            ),
            for: typedText
        )
    }

    func record(typedText: String, title: String, url: URL, at date: Date = Date()) {
        guard defaults != nil else { return }
        save(
            CommandBarSelectionRanking.recording(
                selections,
                typedText: typedText,
                title: title,
                urlString: url.absoluteString,
                at: date
            )
        )
    }

    func forget(urls: Set<String>) {
        guard defaults != nil, !urls.isEmpty else { return }
        save(CommandBarSelectionRanking.forgetting(selections, urls: urls))
    }

    func forget(selectedAfter startDate: Date?) {
        guard defaults != nil else { return }
        save(CommandBarSelectionRanking.forgetting(selections, selectedAfter: startDate))
    }

    func removeAll() {
        selections = []
        defaults?.removeObject(forKey: Self.storageKey)
    }

    private func save(_ updated: [CommandBarSelection]) {
        selections = updated
        guard let defaults else { return }
        guard !updated.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func loadSelections(from defaults: UserDefaults?) -> [CommandBarSelection] {
        guard
            let data = defaults?.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode([CommandBarSelection].self, from: data)
        else {
            return []
        }
        return stored
    }
}
