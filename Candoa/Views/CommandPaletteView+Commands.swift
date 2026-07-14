import Foundation

extension CommandPaletteView {
    internal func dedupedCommands(_ commands: [PaletteCommand]) -> [PaletteCommand] {
        var seenKeys = Set<String>()
        return commands.filter { command in
            switch command.action {
            case .navigate(let input):
                // Two keys: revisits of one page can differ by tracking
                // params (same title+host, different URL), and the same URL
                // can carry different titles across visits. Either repeating
                // reads as a duplicate row.
                let urlInserted = seenKeys
                    .insert("navigate:\(normalizedURLKey(input))").inserted
                let labelInserted = seenKeys
                    .insert("navlabel:\(command.title.lowercased())|\(command.detail?.lowercased() ?? "")").inserted
                return urlInserted && labelInserted
            case .switchTab(let id):
                // Tab rows claim their page's label too, so a history visit
                // of the same page (under a cosmetically different URL)
                // can't trail it as a second row. The label must also be
                // unclaimed: two tabs on the same page read as one entry,
                // so only the first (highest-ranked) shows.
                let idInserted = seenKeys.insert("tab:\(id.uuidString)").inserted
                let labelInserted = seenKeys
                    .insert("navlabel:\(command.title.lowercased())|\(command.detail?.lowercased() ?? "")").inserted
                return idInserted && labelInserted
            default:
                return true
            }
        }
    }

    /// Pages get revisited with cosmetic URL differences (trailing slash,
    /// letter case); those must still count as the same target.
    internal func normalizedURLKey(_ text: String) -> String {
        var key = text.lowercased()
        if key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }

    internal func openTab(matching url: URL) -> BrowserTab? {
        let key = normalizedURLKey(url.absoluteString)
        return store.tabs.first {
            guard $0.spaceID == store.activeSpaceID else { return false }
            guard let tabURL = $0.url else { return false }
            return normalizedURLKey(tabURL.absoluteString) == key
        }
    }

    /// The open tab on a provider's site, if any — provider rows offer
    /// "Switch to Tab" instead of opening the site again in a fresh tab.
    /// The most recently used tab wins; the active tab is excluded so the
    /// row keeps its open-site action when the user is already there.
    internal func openTab(onSiteOf provider: SearchProvider) -> BrowserTab? {
        guard let providerHost = normalizedHost(provider.homeURL) else { return nil }
        return store.tabs
            .filter {
                $0.spaceID == store.activeSpaceID &&
                    $0.id != store.activeTabID &&
                    normalizedHost($0.url) == providerHost
            }
            .max { $0.lastAccessedAt < $1.lastAccessedAt }
    }

    internal func normalizedHost(_ url: URL?) -> String? {
        guard var host = url?.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    /// The open tab showing this visit's page, if any. Exact URL match
    /// first; SPA sites mutate the query string after the visit is
    /// recorded (YouTube adds playback params), so a same-host tab whose
    /// title still matches the visit counts as the same page.
    internal func openTab(for visit: HistoryVisit) -> BrowserTab? {
        if let tab = openTab(matching: visit.url) {
            return tab
        }

        let title = visit.title.lowercased()
        guard !title.isEmpty, let host = visit.url.host(percentEncoded: false)?.lowercased() else {
            return nil
        }

        return store.tabs.first { tab in
            guard tab.spaceID == store.activeSpaceID else { return false }
            guard let tabURL = tab.url else { return false }
            return tab.title.lowercased() == title
                && tabURL.host(percentEncoded: false)?.lowercased() == host
        }
    }

    /// Arc/Zen-style result navigation: Up/Down arrows and Control-P/N move
    /// the highlight through the visible results, wrapping at the ends.
    internal func moveSelection(by delta: Int) {
        let count = visibleCommands.count
        guard count > 0 else { return }
        selectedCommandIndex = ((selectedCommandIndex + delta) % count + count) % count
    }

    internal func commandCandidates(for trimmedQuery: String, isResumingSearchURL: Bool = false) -> [PaletteCommand] {
        // Open tabs rank above history matches (Arc's ordering), which also
        // lets the dedupe keep the tab row when a page exists as both.
        let commands = tabCommands + historyCommands(for: trimmedQuery) + spaceCommands + baseCommands

        if let selectedSearchProvider {
            let suggestionCommands = providerSearchSuggestionCommands(
                for: selectedSearchProvider,
                matching: trimmedQuery
            )

            guard !trimmedQuery.isEmpty else { return suggestionCommands }

            let providerSearchCommand = PaletteCommand(
                title: trimmedQuery,
                detail: nil,
                symbolName: "magnifyingglass",
                searchText: "\(selectedSearchProvider.name) \(trimmedQuery)",
                sourceLabel: "Search",
                style: .providerSearch(selectedSearchProvider),
                action: .searchProvider(selectedSearchProvider, trimmedQuery)
            )

            return [providerSearchCommand] + suggestionCommands.filter {
                $0.title.localizedCaseInsensitiveCompare(trimmedQuery) != .orderedSame
            } + commands
        }

        guard !trimmedQuery.isEmpty else { return defaultSuggestions }

        let navigateCommand: PaletteCommand
        if isResumingSearchURL {
            navigateCommand = PaletteCommand(
                title: trimmedQuery,
                detail: nil,
                symbolName: "globe",
                searchText: "\(trimmedQuery) \(query)",
                action: .navigate(trimmedQuery)
            )
        } else {
            navigateCommand = PaletteCommand(
                title: "Search or Go to \"\(trimmedQuery)\"",
                detail: store.commandPaletteOpensNewTab ? "Open in new tab" : "Open in current tab",
                symbolName: "globe",
                searchText: trimmedQuery,
                action: .navigate(trimmedQuery)
            )
        }

        if !isResumingSearchURL,
           let autocompleteSuggestion = autocompleteSuggestion(
                for: trimmedQuery,
                allowsProviderSuggestions: selectedSearchProvider == nil
           ) {
            return [autocompleteSuggestion.command, navigateCommand] + commands
        }

        if !store.commandPalettePrefersCurrentTabNavigation,
           let provider = suggestedSearchProvider(for: trimmedQuery, allowsAutocomplete: false) {
            let matchingProviders = searchProviderCommands.filter { $0.provider == provider }
            return matchingProviders + [navigateCommand] + commands
        }

        return [navigateCommand] + commands
    }

    internal var defaultSuggestions: [PaletteCommand] {
        // Resting state: the user's recent trail — open tabs and history
        // interleaved by recency. Rows backed by an open tab carry Switch to
        // Tab (historyCommand converts matches); the page the user is on
        // never suggests itself; providers pad the tail so the palette
        // always has substance.
        let activeTabURLKey = store.activeTab?.url.map { normalizedURLKey($0.absoluteString) }
        let historyEntries: [(visitedAt: Date, command: PaletteCommand)] = store.recentHistory(limit: 6)
            .filter {
                normalizedURLKey($0.url.absoluteString) != activeTabURLKey
                    && openTab(for: $0)?.id != store.activeTabID
            }
            .map { ($0.visitedAt, historyCommand(for: $0)) }
        let tabEntries: [(visitedAt: Date, command: PaletteCommand)] = store.tabs
            .filter { $0.spaceID == store.activeSpaceID && $0.url != nil && $0.id != store.activeTabID }
            .map { tab in
                (
                    tab.lastAccessedAt,
                    PaletteCommand(
                        title: tab.title,
                        detail: tab.url?.host(percentEncoded: false),
                        symbolName: tab.faviconSymbol,
                        faviconData: tab.faviconData,
                        searchText: "\(tab.title) \(tab.url?.absoluteString ?? "")",
                        sourceLabel: "Tab",
                        style: .tab,
                        action: .switchTab(tab.id)
                    )
                )
            }

        let recentTrail = (historyEntries + tabEntries)
            .sorted { $0.visitedAt > $1.visitedAt }
            .map(\.command)

        let tailCommands = Array(searchProviderCommands.dropFirst().prefix(2))
        return [defaultSearchCommand] + recentTrail + tailCommands
    }

    internal var defaultSearchCommand: PaletteCommand {
        let provider = NavigationService.defaultSearchProvider(for: defaultSearchProvider)
        let openTab = openTab(onSiteOf: provider)
        return PaletteCommand(
            title: provider.name,
            detail: nil,
            symbolName: provider.id == "google" ? "google" : provider.symbolName,
            searchText: ([provider.name] + provider.aliases).joined(separator: " "),
            sourceLabel: "Search",
            style: .provider(provider),
            action: openTab.map { .switchTab($0.id) } ?? .navigate(provider.homeURL.absoluteString)
        )
    }

    internal var searchProviderCommands: [PaletteCommand] {
        NavigationService.searchProviders.map { provider in
            let openTab = openTab(onSiteOf: provider)
            return PaletteCommand(
                title: provider.name,
                detail: openTab == nil ? "Open Site" : nil,
                symbolName: provider.id == "google" ? "google" : provider.symbolName,
                searchText: ([provider.name] + provider.aliases).joined(separator: " "),
                sourceLabel: "Search",
                style: .provider(provider),
                action: openTab.map { .switchTab($0.id) } ?? .navigate(provider.homeURL.absoluteString)
            )
        }
    }

    internal func providerSearchSuggestionCommands(
        for provider: SearchProvider,
        matching rawQuery: String
    ) -> [PaletteCommand] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedQuery = query.lowercased()

        let tabSuggestions = store.tabs
            .filter { $0.spaceID == store.activeSpaceID }
            .compactMap { tab -> (Date, String, String)? in
                guard
                    let url = tab.url,
                    let suggestion = store.navigationService.searchQuery(from: url, provider: provider)
                else {
                    return nil
                }

                return (tab.lastAccessedAt, suggestion, "Tab")
            }

        let historySuggestions = store.recentHistory(limit: 40)
            .compactMap { visit -> (Date, String, String)? in
                guard let suggestion = store.navigationService.searchQuery(from: visit.url, provider: provider) else {
                    return nil
                }

                return (visit.visitedAt, suggestion, "History")
            }

        var seenSuggestions = Set<String>()
        return (tabSuggestions + historySuggestions)
            .sorted { $0.0 > $1.0 }
            .compactMap { _, suggestion, sourceLabel -> PaletteCommand? in
                let normalizedSuggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSuggestion.isEmpty else { return nil }

                let suggestionKey = normalizedSuggestion.lowercased()
                guard seenSuggestions.insert(suggestionKey).inserted else { return nil }
                guard lowercasedQuery.isEmpty || suggestionKey.contains(lowercasedQuery) else { return nil }

                return PaletteCommand(
                    title: normalizedSuggestion,
                    detail: nil,
                    symbolName: "magnifyingglass",
                    searchText: "\(provider.name) \(normalizedSuggestion)",
                    sourceLabel: sourceLabel,
                    style: .providerSearch(provider),
                    action: .searchProvider(provider, normalizedSuggestion)
                )
            }
    }

    internal var baseCommands: [PaletteCommand] {
        var commands = [
            PaletteCommand(title: BrowserCommandTitles.newTab, symbolName: "plus", action: .newTab),
            PaletteCommand(title: BrowserCommandTitles.closeCurrentTab, symbolName: "xmark", action: .closeCurrentTab),
            PaletteCommand(title: BrowserCommandTitles.duplicateTab, symbolName: "square.on.square", action: .duplicateCurrentTab),
            PaletteCommand(title: BrowserCommandTitles.reloadTab, symbolName: "arrow.clockwise", action: .reloadTab),
            PaletteCommand(title: BrowserCommandTitles.toggleSplitView, symbolName: "rectangle.split.1x2", action: .toggleSplitView),
            PaletteCommand(title: BrowserCommandTitles.createSpace, symbolName: "square.grid.2x2", action: .createSpace),
            PaletteCommand(title: BrowserCommandTitles.focusAddressBar, symbolName: "text.cursor", action: .focusAddressBar)
        ]

        if let url = store.activeTab?.url,
           let host = DeveloperModeConfiguration.displayHost(for: url) {
            let isEnabled = DeveloperModeConfiguration.isEnabled(for: url)
            commands.append(
                PaletteCommand(
                    title: isEnabled
                        ? BrowserCommandTitles.turnOffDeveloperMode
                        : BrowserCommandTitles.turnOnDeveloperMode,
                    detail: host,
                    symbolName: "hammer",
                    action: .setDeveloperMode(!isEnabled)
                )
            )
        }

        return commands
    }

    internal func historyCommands(for query: String) -> [PaletteCommand] {
        guard !query.isEmpty else { return [] }
        return store.recentHistory(matching: query, limit: 8).map(historyCommand)
    }

    internal func historyCommand(for visit: HistoryVisit) -> PaletteCommand {
        // A history entry that's already open belongs to its tab — Arc shows
        // "Switch to Tab" on those rows instead of opening a fresh visit.
        if let openTab = openTab(for: visit), openTab.id != store.activeTabID {
            return PaletteCommand(
                title: openTab.title.isEmpty ? visit.title : openTab.title,
                detail: hostDisplayText(for: visit.url),
                symbolName: openTab.faviconSymbol,
                faviconData: openTab.faviconData,
                searchText: "\(visit.title) \(visit.url.absoluteString)",
                sourceLabel: "Tab",
                style: .tab,
                action: .switchTab(openTab.id)
            )
        }

        return PaletteCommand(
            title: visit.title,
            detail: hostDisplayText(for: visit.url),
            symbolName: FaviconService.shared.placeholderSymbol(for: visit.url),
            faviconPageURL: visit.url,
            searchText: "\(visit.title) \(visit.url.absoluteString)",
            sourceLabel: "History",
            style: .history,
            action: .navigate(visit.url.absoluteString)
        )
    }

    internal var tabCommands: [PaletteCommand] {
        store.tabs
            .filter { $0.spaceID == store.activeSpaceID }
            .sorted {
                if $0.lastAccessedAt == $1.lastAccessedAt {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.lastAccessedAt > $1.lastAccessedAt
            }
            .map(tabCommand)
    }

    internal var spaceCommands: [PaletteCommand] {
        store.spaces.map {
            PaletteCommand(
                title: "Switch Space",
                detail: $0.name,
                symbolName: $0.symbolName,
                searchText: $0.name,
                sourceLabel: "Space",
                action: .switchSpace($0.id)
            )
        }
    }

    internal func performSelectedCommand() {
        let commands = visibleCommands
        if commands.indices.contains(selectedCommandIndex) {
            run(commands[selectedCommandIndex])
            return
        }

        let trimmedQuery = commandQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedSearchProvider, !trimmedQuery.isEmpty {
            run(
                PaletteCommand(
                    title: "Search \(selectedSearchProvider.name)",
                    symbolName: selectedSearchProvider.symbolName,
                    action: .searchProvider(selectedSearchProvider, trimmedQuery)
                )
            )
            return
        }

        guard let command = commands.first else { return }
        run(command)
    }

    internal func activateSearchProviderFromQuery() {
        guard selectedSearchProvider == nil else {
            fieldFocusRequestID = UUID()
            return
        }

        if let autocompleteSuggestion {
            if let provider = autocompleteSuggestion.provider {
                selectedSearchProvider = provider
                query = ""
            } else {
                query = autocompleteSuggestion.text
            }
            fieldFocusRequestID = UUID()
            return
        }

        if let provider = store.navigationService.searchProvider(matching: commandQueryText) {
            selectedSearchProvider = provider
            query = ""
            fieldFocusRequestID = UUID()
            return
        }

        if let provider = selectedCommandSearchProvider {
            selectedSearchProvider = provider
            query = ""
            fieldFocusRequestID = UUID()
            return
        }

        fieldFocusRequestID = UUID()
    }

    internal func deleteSelectedSearchProvider() {
        selectedSearchProvider = nil
        fieldFocusRequestID = UUID()
    }

    internal func dismissPalette() {
        isSearchFocused = false
        store.dismissCommandPalette()
    }

    internal func run(_ command: PaletteCommand) {
        store.setUITestingLastCommandDescription(command.title)

        let opensNewTab = store.consumeCommandPaletteNewTabIntent()
        dismissPalette()

        // Deferred one tick: executing the command (tab creation, web view
        // swap) in the same transaction as the dismissal interrupts the
        // palette's removal transition, stranding an invisible palette over
        // the window that swallows every mouse click.
        DispatchQueue.main.async {
            perform(command, opensNewTab: opensNewTab)
        }
    }

    internal func perform(_ command: PaletteCommand, opensNewTab: Bool) {
        switch command.action {
        case .newTab:
            store.openNewTabCommandPalette()
        case .closeCurrentTab:
            store.closeCurrentTab()
        case .duplicateCurrentTab:
            store.duplicateCurrentTab()
        case .reloadTab:
            store.reloadActiveTab()
        case .toggleSplitView:
            store.toggleSplitView()
        case .createSpace:
            store.beginSpaceCreation()
        case .focusAddressBar:
            store.focusAddressBar()
        case .copyURL:
            store.copyActiveTabURL()
        case .copyURLAsMarkdown:
            store.copyActiveTabURL(asMarkdown: true)
        case .setDeveloperMode(let isEnabled):
            guard let url = store.activeTab?.url else { return }
            store.setDeveloperMode(isEnabled, for: url)
        case .togglePinTab:
            store.togglePinForActiveTab()
        case .navigate(let input):
            if opensNewTab {
                store.navigateNewTab(to: input)
            } else {
                store.navigateActiveTab(to: input)
            }
        case .searchProvider(let provider, let input):
            guard let url = store.navigationService.searchURL(provider: provider, query: input) else { return }
            if opensNewTab {
                store.navigateNewTab(to: url)
            } else {
                store.navigateActiveTab(to: url)
            }
        case .switchTab(let id):
            store.switchTab(to: id)
        case .switchSpace(let id):
            store.switchSpace(to: id)
        }
    }

    internal func spaceName(for id: UUID) -> String {
        store.spaces.first { $0.id == id }?.name ?? "Unknown Space"
    }

    internal func hostDisplayText(for url: URL?) -> String {
        url?.host(percentEncoded: false) ?? ""
    }

}
