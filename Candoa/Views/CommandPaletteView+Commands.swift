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
        if store.commandPaletteSplitsWithSelection {
            return splitWithCandidates(for: trimmedQuery)
        }

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
                title: String(localized: "Search or Go to \"\(trimmedQuery)\""),
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

        // A remembered pick that can't complete the field inline still
        // leads the list, so Return goes where it went last time.
        if !isResumingSearchURL,
           selectedSearchProvider == nil,
           let learnedCommand = learnedSelectionCommand(for: trimmedQuery) {
            return [learnedCommand, navigateCommand] + commands
        }

        if !store.commandPalettePrefersCurrentTabNavigation,
           let provider = suggestedSearchProvider(for: trimmedQuery, allowsAutocomplete: false) {
            let matchingProviders = searchProviderCommands.filter { $0.provider == provider }
            return matchingProviders + [navigateCommand] + commands
        }

        return [navigateCommand] + commands
    }

    /// Split With… mode: the Space's other tabs, most recent first, minus
    /// the panes already on screen; a typed entry offers to open in a new
    /// pane. No history, providers or commands — the question is only
    /// "which tab beside this one", and everything else is noise.
    internal func splitWithCandidates(for trimmedQuery: String) -> [PaletteCommand] {
        let excludedIDs = store.activeSplitGroupTabIDs.union([store.activeTabID].compactMap { $0 })
        let tabRows = store.tabs
            .filter { $0.spaceID == store.activeSpaceID && !excludedIDs.contains($0.id) }
            .sorted {
                if $0.lastAccessedAt == $1.lastAccessedAt {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.lastAccessedAt > $1.lastAccessedAt
            }
            .map { tab in
                PaletteCommand(
                    title: tab.title,
                    detail: addressDisplayText(for: tab.url),
                    symbolName: tab.faviconSymbol,
                    faviconData: tab.faviconData,
                    searchText: "\(tab.title) \(tab.url?.absoluteString ?? "")",
                    sourceLabel: "Tab",
                    style: .tab,
                    action: .splitWithTab(tab.id)
                )
            }

        guard !trimmedQuery.isEmpty else { return tabRows }
        let navigateCommand = PaletteCommand(
            title: String(localized: "Search or Go to \"\(trimmedQuery)\""),
            detail: String(localized: "Open in new pane", comment: "Command bar row detail in Split With… mode."),
            symbolName: "rectangle.split.2x1",
            searchText: trimmedQuery,
            action: .splitWithNavigate(trimmedQuery)
        )
        return tabRows + [navigateCommand]
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
        guard SettingsOption.bool(SettingsOption.showSearchSuggestions, default: true) else {
            return []
        }

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
            PaletteCommand(title: BrowserCommandTitles.closeOtherTabs, symbolName: "xmark.square", action: .closeOtherTabs),
            PaletteCommand(title: BrowserCommandTitles.duplicateTab, symbolName: "square.on.square", action: .duplicateCurrentTab),
            PaletteCommand(title: BrowserCommandTitles.reloadTab, symbolName: "arrow.clockwise", action: .reloadTab),
            PaletteCommand(title: BrowserCommandTitles.toggleSplitView, symbolName: "rectangle.split.2x1", action: .toggleSplitView),
            PaletteCommand(title: BrowserCommandTitles.createSpace, symbolName: "square.grid.2x2", action: .createSpace),
            PaletteCommand(title: BrowserCommandTitles.focusAddressBar, symbolName: "text.cursor", action: .focusAddressBar)
        ]

        // Only while a split is on screen: the palette lists what can be
        // done now, and zoom has no meaning without panes to zoom between.
        if store.isSplitViewDisplayed {
            commands.append(
                PaletteCommand(
                    title: store.isSplitPaneZoomed
                        ? BrowserCommandTitles.showAllSplitPanes
                        : BrowserCommandTitles.zoomSplitPane,
                    symbolName: store.isSplitPaneZoomed
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    action: .toggleSplitPaneZoom
                )
            )
            commands.append(
                PaletteCommand(
                    title: BrowserCommandTitles.focusNextSplitPane,
                    symbolName: "rectangle.righthalf.inset.filled.arrow.right",
                    action: .focusSplitPane(1)
                )
            )
            commands.append(
                PaletteCommand(
                    title: BrowserCommandTitles.focusPreviousSplitPane,
                    symbolName: "rectangle.lefthalf.inset.filled.arrow.left",
                    action: .focusSplitPane(-1)
                )
            )
            commands.append(
                PaletteCommand(
                    title: BrowserCommandTitles.unsplitPane,
                    symbolName: "rectangle.portrait.and.arrow.right",
                    action: .unsplitPane
                )
            )
        }

        if store.isPrivate {
            // Private windows have no Spaces to manage.
            commands.removeAll { command in
                if case .createSpace = command.action { return true }
                return false
            }
        }

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
        let visits = store.recentHistory(matching: query, limit: 8)
        let learnedKeys = learnedSelectionKeys(for: query)
        guard !learnedKeys.isEmpty else { return visits.map(historyCommand) }

        // Pages this person has chosen for these keystrokes before lead the
        // history matches; everything else keeps its recency order.
        return visits
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = learnedRank(of: lhs.element.url, in: learnedKeys)
                let rhsRank = learnedRank(of: rhs.element.url, in: learnedKeys)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map { historyCommand(for: $0.element) }
    }

    internal func learnedSelectionKeys(for query: String) -> [String] {
        store.commandBarSelections
            .selections(matching: query)
            .map { normalizedURLKey($0.urlString) }
    }

    internal func learnedRank(of url: URL, in learnedKeys: [String]) -> Int {
        learnedKeys.firstIndex(of: normalizedURLKey(url.absoluteString)) ?? learnedKeys.count
    }

    /// The destination this person picked the last time they typed this
    /// text. Built from the remembered page rather than the current history
    /// search, so the row leads even when the typed shorthand appears
    /// nowhere in the page's title or URL.
    internal func learnedSelectionCommand(for query: String) -> PaletteCommand? {
        guard !query.isEmpty,
              let selection = store.commandBarSelections.selections(matching: query).first,
              let url = selection.url
        else {
            return nil
        }

        var command = historyCommand(
            for: HistoryVisit(
                id: UUID(),
                title: selection.title,
                url: url,
                tabID: UUID(),
                spaceID: store.activeSpaceID,
                visitedAt: selection.lastSelectedAt
            )
        )
        // The row matches these keystrokes because the person taught it to,
        // which the plain title/URL filter can't know.
        command.searchText += " \(query)"
        return command
    }

    /// Learns from the row the person actually opened: next time they type
    /// the same text, that row leads instead of whatever was most recent.
    internal func recordSelection(for command: PaletteCommand) {
        guard !store.isPrivate, !shouldSelectCurrentURL, !isResumingSearchURL else { return }
        let typedText = commandQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty else { return }

        switch command.action {
        case .navigate(let input):
            // Only rows that stand for a page teach anything; a typed URL
            // or search needs no shortcut back to itself.
            guard command.style == .history || command.style == .tab,
                  let url = URL(string: input),
                  url.host(percentEncoded: false) != nil
            else {
                return
            }
            store.commandBarSelections.record(typedText: typedText, title: command.title, url: url)
        case .switchTab(let id):
            guard let tab = store.tabs.first(where: { $0.id == id }), let url = tab.url else { return }
            store.commandBarSelections.record(
                typedText: typedText,
                title: tab.title.isEmpty ? command.title : tab.title,
                url: url
            )
        default:
            return
        }
    }

    internal func historyCommand(for visit: HistoryVisit) -> PaletteCommand {
        // A history entry that's already open belongs to its tab — Arc shows
        // "Switch to Tab" on those rows instead of opening a fresh visit.
        if let openTab = openTab(for: visit), openTab.id != store.activeTabID {
            return PaletteCommand(
                title: openTab.title.isEmpty ? visit.title : openTab.title,
                detail: addressDisplayText(for: visit.url),
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
            detail: addressDisplayText(for: visit.url),
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
                title: String(localized: "Switch Space"),
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
                    title: String(localized: "Search \(selectedSearchProvider.name)"),
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
        recordSelection(for: command)

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
            store.openNewTab()
        case .closeCurrentTab:
            store.closeCurrentTabOrWindow()
        case .closeOtherTabs:
            store.closeOtherTabsForActiveTab()
        case .duplicateCurrentTab:
            store.duplicateCurrentTab()
        case .reloadTab:
            store.reloadActiveTab()
        case .toggleSplitView:
            store.toggleSplitView()
        case .toggleSplitPaneZoom:
            store.toggleSplitPaneZoom()
        case .focusSplitPane(let offset):
            store.focusAdjacentSplitPane(offset: offset)
        case .unsplitPane:
            store.unsplitFocusedPane()
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
        case .splitWithTab(let id):
            store.openSplitView(with: id)
        case .splitWithNavigate(let input):
            store.splitActivePane(navigatingTo: input)
        case .switchSpace(let id):
            store.switchSpace(to: id)
        }
    }

    internal func spaceName(for id: UUID) -> String {
        store.spaces.first { $0.id == id }?.name ?? String(localized: "Unknown Space")
    }

    /// The address the way Arc prints it beside a row title: host, port and
    /// path with the scheme and "www." dropped — "localhost:8080/dashboard"
    /// rather than a bare "localhost" that hides which server and page the
    /// row stands for (and made distinct pages collapse into one row).
    internal func addressDisplayText(for url: URL?) -> String {
        guard let url, let host = normalizedHostDisplayText(for: url.host(percentEncoded: false)) else {
            return ""
        }

        var text = host
        if let port = url.port {
            text += ":\(port)"
        }

        let path = url.path(percentEncoded: false)
        if !path.isEmpty, path != "/" {
            text += path.hasSuffix("/") ? String(path.dropLast()) : path
        }

        if let query = url.query(percentEncoded: false), !query.isEmpty {
            text += "?\(query)"
        }

        return text
    }

}
