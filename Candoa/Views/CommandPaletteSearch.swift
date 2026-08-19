import SwiftUI

extension CommandPaletteView {
    internal var searchField: some View {
        ZStack(alignment: .leading) {
            if let autocompleteSuggestion, !autocompleteSuggestion.suffix.isEmpty {
                HStack(spacing: 0) {
                    Text(query)
                        .foregroundStyle(.clear)
                    // Zen/Arc-style inline completion: the completed range
                    // keeps the typed text's brightness and reads as
                    // provisional through the standard selected-text
                    // background, so the whole string reads as one URL.
                    Text(autocompleteSuggestion.suffix)
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(nsColor: .selectedTextBackgroundColor))
                        )
                }
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            TextField("", text: $query, prompt: Text(placeholderText).foregroundStyle(.secondary))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .tint(AppColor.accent)
                .focused($isSearchFocused)
                .accessibilityLabel("Command Palette")
                .accessibilityIdentifier("command-palette-field")
                .onSubmit(performSelectedCommand)
                .onKeyPress(.return) {
                    performSelectedCommand()
                    return .handled
                }
                .onKeyPress(.tab) {
                    activateSearchProviderFromQuery()
                    return .handled
                }
        }
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
    }

    internal func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true

            guard shouldSelectCurrentURL else { return }

            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    internal var filteredCommands: [PaletteCommand] {
        let trimmedQuery = commandQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAddressEditingPalette && shouldSelectCurrentURL {
            return defaultSuggestions
        }

        let commands = commandCandidates(for: trimmedQuery, isResumingSearchURL: isResumingSearchURL)
        guard !trimmedQuery.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery) ||
            ($0.detail?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            ($0.sourceLabel?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            $0.searchText.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    internal var leadingSymbolName: String {
        return isResumingSearchURL ? "globe" : "magnifyingglass"
    }

    /// The provider the Tab key would activate right now. Mirrors
    /// `activateSearchProviderFromQuery` exactly so the "Search X — Tab" hint
    /// never appears when pressing Tab wouldn't start a site search.
    internal var headerSearchProvider: SearchProvider? {
        guard selectedSearchProvider == nil, !isResumingSearchURL else { return nil }
        if let autocompleteSuggestion {
            return autocompleteSuggestion.provider
        }
        if let provider = selectedCommandSearchProvider {
            return provider
        }
        return store.navigationService.searchProvider(matching: commandQueryText)
    }

    internal var placeholderText: String {
        if store.commandPaletteSplitsWithSelection {
            return String(localized: "Split with a tab or URL…", comment: "Command bar placeholder while choosing what to split the current pane with.")
        }
        return selectedSearchProvider == nil ? "Search or Enter URL..." : "Search..."
    }

    internal var isResumingSearchURL: Bool {
        !store.commandPaletteResumeQuery.isEmpty &&
            !store.commandPaletteInitialText.isEmpty &&
            query == store.commandPaletteInitialText
    }

    internal var commandQueryText: String {
        isResumingSearchURL ? store.commandPaletteResumeQuery : query
    }

    internal var shouldSelectCurrentURL: Bool {
        !store.commandPaletteInitialText.isEmpty && query == store.commandPaletteInitialText
    }

    internal var autocompleteSuggestion: PaletteAutocompleteSuggestion? {
        autocompleteSuggestion(
            for: query,
            allowsProviderSuggestions: selectedSearchProvider == nil
                && !isResumingSearchURL
                && !suppressesAutocomplete
        )
    }

    internal var selectedCommandSearchProvider: SearchProvider? {
        guard visibleCommands.indices.contains(selectedCommandIndex) else { return nil }
        return searchProvider(for: visibleCommands[selectedCommandIndex])
    }

    internal func searchProvider(for command: PaletteCommand) -> SearchProvider? {
        if let provider = command.provider {
            return provider
        }

        if let provider = store.navigationService.searchProvider(matching: command.title) {
            return provider
        }

        if let detail = command.detail,
           let provider = provider(matchingHostText: detail) {
            return provider
        }

        switch command.action {
        case .navigate(let input):
            return provider(forURLText: input)
        case .switchTab(let id):
            return provider(for: store.tabs.first { $0.id == id }?.url)
        case .searchProvider(let provider, _):
            return provider
        default:
            return nil
        }
    }

    internal func provider(forURLText text: String) -> SearchProvider? {
        if let url = URL(string: text), url.host(percentEncoded: false) != nil {
            return provider(for: url)
        }

        if let url = URL(string: "https://\(text)"), url.host(percentEncoded: false) != nil {
            return provider(for: url)
        }

        return nil
    }

    internal func provider(for url: URL?) -> SearchProvider? {
        guard let hostText = url?.host(percentEncoded: false) else { return nil }
        return provider(matchingHostText: hostText)
    }

    internal func provider(matchingHostText hostText: String) -> SearchProvider? {
        guard let host = normalizedHostDisplayText(for: hostText) else { return nil }

        return NavigationService.searchProviders.first { provider in
            providerHostTexts(for: provider)
                .compactMap { normalizedHostDisplayText(for: $0) }
                .contains(host)
        }
    }

    internal func providerHostTexts(for provider: SearchProvider) -> [String] {
        [
            provider.homeURL.host(percentEncoded: false),
            provider.baseURL.host(percentEncoded: false)
        ]
        .compactMap { $0 } + provider.aliases.filter { $0.contains(".") }
    }

    internal func suggestedSearchProvider(for rawQuery: String, allowsAutocomplete: Bool) -> SearchProvider? {
        if allowsAutocomplete,
           let provider = autocompleteSuggestion(
                for: rawQuery,
                allowsProviderSuggestions: selectedSearchProvider == nil
           )?.provider {
            return provider
        }

        return store.navigationService.searchProvider(matching: rawQuery)
    }

    internal func autocompleteSuggestion(
        for rawQuery: String,
        allowsProviderSuggestions: Bool
    ) -> PaletteAutocompleteSuggestion? {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            allowsProviderSuggestions,
            !trimmedQuery.isEmpty,
            trimmedQuery == rawQuery,
            !trimmedQuery.contains("\n")
        else {
            return nil
        }

        // What this person chose for these keystrokes before outranks both
        // the provider guess and plain recency. It completes the field only
        // when the remembered page actually continues what was typed;
        // otherwise the row leads on its own (see commandCandidates).
        if let learnedCommand = learnedSelectionCommand(for: trimmedQuery) {
            return learnedAutocompleteSuggestion(for: trimmedQuery, command: learnedCommand)
        }

        return providerAutocompleteSuggestion(for: trimmedQuery)
            ?? localAutocompleteSuggestion(for: trimmedQuery)
    }

    internal func learnedAutocompleteSuggestion(
        for rawQuery: String,
        command: PaletteCommand
    ) -> PaletteAutocompleteSuggestion? {
        guard let selection = store.commandBarSelections.selections(matching: rawQuery).first,
              let url = selection.url
        else {
            return nil
        }

        return autocompleteTexts(title: selection.title, url: url)
            .compactMap { makeAutocompleteSuggestion(text: $0, query: rawQuery, command: command) }
            .first
    }

    internal func providerAutocompleteSuggestion(for rawQuery: String) -> PaletteAutocompleteSuggestion? {
        var bestCandidate: (suggestion: PaletteAutocompleteSuggestion, score: Int, providerIndex: Int, candidateIndex: Int)?

        for (providerIndex, provider) in NavigationService.searchProviders.enumerated() {
            for (candidateIndex, text) in autocompleteTexts(for: provider).enumerated() {
                let openTab = openTab(onSiteOf: provider)
                let command = PaletteCommand(
                    title: provider.name,
                    detail: openTab == nil ? "Open Site" : nil,
                    symbolName: provider.id == "google" ? "google" : provider.symbolName,
                    searchText: ([provider.name] + provider.aliases).joined(separator: " "),
                    sourceLabel: "Search",
                    style: .provider(provider),
                    action: openTab.map { .switchTab($0.id) } ?? .navigate(provider.homeURL.absoluteString)
                )

                guard let suggestion = makeAutocompleteSuggestion(
                    text: text,
                    query: rawQuery,
                    provider: provider,
                    command: command
                ) else {
                    continue
                }

                let score = text.contains(".") ? 0 : 1
                if let bestCandidate {
                    guard score < bestCandidate.score ||
                        (score == bestCandidate.score && providerIndex < bestCandidate.providerIndex) ||
                        (score == bestCandidate.score && providerIndex == bestCandidate.providerIndex && candidateIndex < bestCandidate.candidateIndex)
                    else {
                        continue
                    }
                }

                bestCandidate = (suggestion, score, providerIndex, candidateIndex)
            }
        }

        return bestCandidate?.suggestion
    }

    internal func localAutocompleteSuggestion(for rawQuery: String) -> PaletteAutocompleteSuggestion? {
        let learnedKeys = learnedSelectionKeys(for: rawQuery)
        let historySuggestion = store.recentHistory(matching: rawQuery, limit: 8)
            .sorted { learnedRank(of: $0.url, in: learnedKeys) < learnedRank(of: $1.url, in: learnedKeys) }
            .flatMap { visit in
                autocompleteTexts(title: visit.title, url: visit.url).map { (visit, $0) }
            }
            .compactMap { visit, text in
                makeAutocompleteSuggestion(text: text, query: rawQuery, command: historyCommand(for: visit))
            }
            .first

        if let historySuggestion {
            return historySuggestion
        }

        return store.tabs
            .filter { $0.spaceID == store.activeSpaceID }
            .sorted {
                if $0.lastAccessedAt == $1.lastAccessedAt {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.lastAccessedAt > $1.lastAccessedAt
            }
            .flatMap { tab in
                autocompleteTexts(title: tab.title, url: tab.url).map { (tab, $0) }
            }
            .compactMap { tab, text in
                makeAutocompleteSuggestion(text: text, query: rawQuery, command: tabCommand(for: tab))
            }
            .first
    }

    internal func tabCommand(for tab: BrowserTab) -> PaletteCommand {
        let spaceName = spaceName(for: tab.spaceID)
        let urlText = tab.url?.absoluteString ?? ""
        return PaletteCommand(
            title: tab.title,
            detail: urlText.isEmpty ? spaceName : addressDisplayText(for: tab.url),
            symbolName: tab.faviconSymbol,
            faviconData: tab.faviconData,
            searchText: "\(tab.title) \(spaceName) \(urlText)",
            sourceLabel: "Tab",
            style: .tab,
            action: .switchTab(tab.id)
        )
    }

    internal func autocompleteTexts(for provider: SearchProvider) -> [String] {
        let hostText = normalizedHostDisplayText(for: provider.homeURL.host(percentEncoded: false))
        let domainAliases = provider.aliases
            .filter { $0.contains(".") }
            .compactMap { normalizedHostDisplayText(for: $0) }

        let aliasTexts = provider.aliases.filter { !$0.contains(".") && $0.count > 2 }
        return uniqueAutocompleteTexts(([hostText].compactMap { $0 } + domainAliases + [provider.name] + aliasTexts))
    }

    internal func autocompleteTexts(title: String, url: URL?) -> [String] {
        // A port is part of where the page lives ("localhost:8080" is not
        // "localhost"), so the inline completion carries it the way Arc does.
        var hostText = normalizedHostDisplayText(for: url?.host(percentEncoded: false))
        if let port = url?.port, let host = hostText {
            hostText = "\(host):\(port)"
        }
        return uniqueAutocompleteTexts(([hostText, url?.absoluteString].compactMap { $0 } + [title]))
    }

    internal func makeAutocompleteSuggestion(
        text: String,
        query: String,
        provider: SearchProvider? = nil,
        command: PaletteCommand
    ) -> PaletteAutocompleteSuggestion? {
        guard text.range(of: query, options: [.anchored, .caseInsensitive]) != nil else {
            return nil
        }

        guard text.count > query.count else {
            return nil
        }

        let suffixStart = text.index(text.startIndex, offsetBy: query.count)
        return PaletteAutocompleteSuggestion(
            text: text,
            suffix: String(text[suffixStart...]),
            provider: provider,
            command: command
        )
    }

    internal func normalizedHostDisplayText(for host: String?) -> String? {
        guard var host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else {
            return nil
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        if host.hasPrefix("en.") {
            host.removeFirst(3)
        }

        return host
    }

    internal func uniqueAutocompleteTexts(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        var uniqueTexts: [String] = []

        for text in texts {
            let normalizedText = text.lowercased()
            guard !seen.contains(normalizedText) else { continue }
            seen.insert(normalizedText)
            uniqueTexts.append(text)
        }

        return uniqueTexts
    }
}
