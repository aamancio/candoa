import Foundation

/// A code a search engine issues so it can attribute searches to Candoa and
/// pay the revenue share. DuckDuckGo reads it from `t`, Ecosia from `tt`; the
/// name is the engine's choice, so it travels with the code.
///
/// `expiresAt` is not decoration. Search deals lapse — Vivaldi moved its
/// default off Bing in some regions when that deal ended — and a code that
/// outlives its deal is a parameter sent to a partner who is no longer paying
/// for it. Codes are issued, rotated, and revoked on the engine's schedule,
/// so they arrive as configuration rather than living in the binary.
struct SearchPartnerCode: Equatable, Sendable {
    let providerID: String
    let queryItemName: String
    let value: String
    let expiresAt: Date?

    func isValid(at date: Date) -> Bool {
        guard let expiresAt else { return true }
        return date < expiresAt
    }
}

/// The partner codes in force. Empty until a deal exists, which is the state
/// that ships today: with no code the search URL is byte-for-byte what it was.
struct SearchPartnerCodes: Equatable, Sendable {
    private let codesByProviderID: [String: SearchPartnerCode]

    static let none = SearchPartnerCodes([])

    init(_ codes: [SearchPartnerCode]) {
        codesByProviderID = Dictionary(
            codes.map { ($0.providerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func queryItem(for providerID: String, at date: Date = Date()) -> URLQueryItem? {
        guard let code = codesByProviderID[providerID], code.isValid(at: date) else {
            return nil
        }
        return URLQueryItem(name: code.queryItemName, value: code.value)
    }
}

struct SearchProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let aliases: [String]
    let symbolName: String
    let homeURL: URL
    let baseURL: URL
    let queryItemName: String
    let forwardsQueryIntoWebApp: Bool

    init(
        id: String,
        name: String,
        aliases: [String],
        symbolName: String,
        homeURL: URL,
        baseURL: URL,
        queryItemName: String,
        forwardsQueryIntoWebApp: Bool = false
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.symbolName = symbolName
        self.homeURL = homeURL
        self.baseURL = baseURL
        self.queryItemName = queryItemName
        self.forwardsQueryIntoWebApp = forwardsQueryIntoWebApp
    }

    /// Partner codes are a required argument rather than an optional one: a
    /// call site that forgets them still searches, so the mistake is invisible
    /// and costs revenue silently. Make the compiler ask.
    func searchURL(
        for rawQuery: String,
        partnerCodes: SearchPartnerCodes,
        at date: Date = Date()
    ) -> URL? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: queryItemName, value: query))
        if let partnerItem = partnerCodes.queryItem(for: id, at: date) {
            queryItems.append(partnerItem)
        }
        components?.queryItems = queryItems
        return components?.url
    }

    func matches(_ rawInput: String) -> Bool {
        let input = Self.normalized(rawInput)
        guard !input.isEmpty else { return false }
        return searchTokens.contains { $0 == input || $0.hasPrefix(input) }
    }

    func exactlyMatches(_ rawInput: String) -> Bool {
        let input = Self.normalized(rawInput)
        guard !input.isEmpty else { return false }
        return searchTokens.contains(input)
    }

    private var searchTokens: [String] {
        ([name] + aliases).map(Self.normalized)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}

struct NavigationService {
    static let shared = NavigationService()

    /// Empty until a search deal exists. Populated from server configuration
    /// rather than compiled in, so a code can be issued, rotated, or revoked
    /// without an app release.
    var partnerCodes: SearchPartnerCodes = .none

    static let searchProviders: [SearchProvider] = [
        SearchProvider(
            id: "google",
            name: "Google",
            aliases: ["g", "search", "google.com", "www.google.com"],
            symbolName: "magnifyingglass",
            homeURL: BrowserDefaults.googleHomeURL,
            baseURL: BrowserDefaults.googleSearchURL,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "youtube",
            name: "YouTube",
            aliases: ["yt", "video", "videos", "youtube.com", "www.youtube.com"],
            symbolName: "play.rectangle.fill",
            homeURL: URL(string: "https://www.youtube.com")!,
            baseURL: URL(string: "https://www.youtube.com/results")!,
            queryItemName: "search_query"
        ),
        SearchProvider(
            id: "amazon",
            name: "Amazon",
            aliases: ["amz", "shop", "shopping", "amazon.com", "www.amazon.com"],
            symbolName: "shippingbox.fill",
            homeURL: URL(string: "https://www.amazon.com")!,
            baseURL: URL(string: "https://www.amazon.com/s")!,
            queryItemName: "k"
        ),
        SearchProvider(
            id: "duckduckgo",
            name: "DuckDuckGo",
            aliases: ["duck", "ddg", "duckduckgo.com"],
            symbolName: "scope",
            homeURL: URL(string: "https://duckduckgo.com")!,
            baseURL: URL(string: "https://duckduckgo.com/")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "bing",
            name: "Bing",
            aliases: ["b", "ben", "bing.com", "www.bing.com"],
            symbolName: "b.circle.fill",
            homeURL: URL(string: "https://www.bing.com")!,
            baseURL: URL(string: "https://www.bing.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "brave",
            name: "Brave",
            aliases: ["br", "brave search", "search.brave.com"],
            symbolName: "shield.lefthalf.filled",
            homeURL: URL(string: "https://search.brave.com")!,
            baseURL: URL(string: "https://search.brave.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "startpage",
            name: "Startpage",
            aliases: ["spage", "start", "startpage.com", "www.startpage.com"],
            symbolName: "lock.fill",
            homeURL: URL(string: "https://www.startpage.com")!,
            baseURL: URL(string: "https://www.startpage.com/sp/search")!,
            queryItemName: "query"
        ),
        SearchProvider(
            id: "qwant",
            name: "Qwant",
            aliases: ["q", "qwant.com", "www.qwant.com"],
            symbolName: "q.circle.fill",
            homeURL: URL(string: "https://www.qwant.com")!,
            baseURL: URL(string: "https://www.qwant.com/")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "mojeek",
            name: "Mojeek",
            aliases: ["mj", "mojeek.com", "www.mojeek.com"],
            symbolName: "m.circle.fill",
            homeURL: URL(string: "https://www.mojeek.com")!,
            baseURL: URL(string: "https://www.mojeek.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "swisscows",
            name: "Swisscows",
            aliases: ["swiss", "scows", "swisscows.com"],
            symbolName: "shield.fill",
            homeURL: URL(string: "https://swisscows.com")!,
            baseURL: URL(string: "https://swisscows.com/en/web")!,
            queryItemName: "query"
        ),
        SearchProvider(
            id: "ecosia",
            name: "Ecosia",
            aliases: ["eco", "ecosia.org", "ecosia.com"],
            symbolName: "leaf.fill",
            homeURL: URL(string: "https://www.ecosia.org")!,
            baseURL: URL(string: "https://www.ecosia.org/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "perplexity",
            name: "Perplexity",
            aliases: ["pplx", "perplexity.ai"],
            symbolName: "sparkles",
            homeURL: URL(string: "https://www.perplexity.ai")!,
            baseURL: URL(string: "https://www.perplexity.ai/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "kagi",
            name: "Kagi",
            aliases: ["k", "kagi.com"],
            symbolName: "bolt.fill",
            homeURL: URL(string: "https://kagi.com")!,
            baseURL: URL(string: "https://kagi.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "yahoo",
            name: "Yahoo",
            aliases: ["y", "yh", "yahoo.com", "www.yahoo.com"],
            symbolName: "y.circle.fill",
            homeURL: URL(string: "https://www.yahoo.com")!,
            baseURL: URL(string: "https://search.yahoo.com/search")!,
            queryItemName: "p"
        ),
        SearchProvider(
            id: "yandex",
            name: "Yandex",
            aliases: ["ya", "yandex.com", "yandex.ru"],
            symbolName: "y.circle.fill",
            homeURL: URL(string: "https://yandex.com")!,
            baseURL: URL(string: "https://yandex.com/search/")!,
            queryItemName: "text"
        ),
        SearchProvider(
            id: "github",
            name: "GitHub",
            aliases: ["gh", "code"],
            symbolName: "chevron.left.forwardslash.chevron.right",
            homeURL: URL(string: "https://github.com")!,
            baseURL: URL(string: "https://github.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "reddit",
            name: "Reddit",
            aliases: ["r", "red", "subreddit", "reddit.com", "www.reddit.com"],
            symbolName: "bubble.left.fill",
            homeURL: URL(string: "https://www.reddit.com")!,
            baseURL: URL(string: "https://www.reddit.com/search/")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "x",
            name: "X",
            aliases: ["twitter", "tw", "x.com", "twitter.com"],
            symbolName: "at",
            homeURL: URL(string: "https://x.com")!,
            baseURL: URL(string: "https://x.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "spotify",
            name: "Spotify",
            aliases: ["sp", "music", "spotify.com", "open.spotify.com"],
            symbolName: "music.note",
            homeURL: URL(string: "https://open.spotify.com")!,
            baseURL: URL(string: "https://open.spotify.com/search")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "chatgpt",
            name: "ChatGPT",
            aliases: ["gpt", "openai", "chat.openai.com", "chatgpt.com"],
            symbolName: "sparkles",
            homeURL: URL(string: "https://chatgpt.com")!,
            baseURL: URL(string: "https://chatgpt.com/")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "claude",
            name: "Claude",
            aliases: ["anthropic", "claude code", "claude.ai"],
            symbolName: "text.bubble.fill",
            homeURL: URL(string: "https://claude.ai")!,
            baseURL: URL(string: "https://claude.ai/new")!,
            queryItemName: "q"
        ),
        SearchProvider(
            id: "gemini",
            name: "Gemini",
            aliases: ["bard", "google ai", "gemini.google.com"],
            symbolName: "diamond.fill",
            homeURL: URL(string: "https://gemini.google.com")!,
            baseURL: URL(string: "https://gemini.google.com/app")!,
            queryItemName: "q",
            forwardsQueryIntoWebApp: true
        ),
        SearchProvider(
            id: "wikipedia",
            name: "Wikipedia",
            aliases: ["wiki", "w"],
            symbolName: "book.closed.fill",
            homeURL: URL(string: "https://en.wikipedia.org")!,
            baseURL: URL(string: "https://en.wikipedia.org/w/index.php")!,
            queryItemName: "search"
        )
    ]

    private static let defaultSearchProviderIDs = [
        "google",
        "bing",
        "yahoo",
        "duckduckgo",
        "yandex",
        "perplexity"
    ]

    static var defaultSearchProviders: [SearchProvider] {
        defaultSearchProviderIDs.compactMap { searchProvider(id: $0) }
    }

    static func searchProvider(id: String) -> SearchProvider? {
        searchProviders.first { $0.id == id }
    }

    static func defaultSearchProvider(for id: String?) -> SearchProvider {
        guard
            let id,
            defaultSearchProviderIDs.contains(id),
            let provider = searchProvider(id: id)
        else {
            return searchProviders[0]
        }

        return provider
    }

    func destinationURL(for rawInput: String, defaultSearchProviderID: String? = nil) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let explicitDestination = explicitDestinationURL(for: input) {
            return explicitDestination
        }

        let provider = Self.defaultSearchProvider(for: defaultSearchProviderID)
        return provider.searchURL(for: input, partnerCodes: partnerCodes)
    }

    /// Resolves only destinations the person or a trusted page link specified exactly.
    /// Agent actions use this path so unresolved conversational text never becomes a search.
    func explicitDestinationURL(for rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let directURL = directURL(from: input) {
            return directURL
        }

        if looksLikeHost(input), let url = URL(string: "https://\(input)") {
            // Safari defaults localhost and loopback hosts to plain HTTP;
            // local dev servers rarely serve TLS.
            if url.isLocalDevelopment, let localURL = URL(string: "http://\(input)") {
                return localURL
            }
            return url
        }

        return Self.searchProviders.first(where: { $0.exactlyMatches(input) })?.homeURL
    }

    func searchProvider(matching rawInput: String) -> SearchProvider? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        return Self.searchProviders.first { $0.exactlyMatches(input) }
            ?? Self.searchProviders.first { $0.matches(input) }
    }

    func searchURL(provider: SearchProvider, query: String) -> URL? {
        provider.searchURL(for: query, partnerCodes: partnerCodes)
    }

    func preferredLocaleURL(for url: URL) -> URL {
        url
    }

    func webAppPromptForwardingTarget(for url: URL) -> (providerID: String, query: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let queryItems = components.queryItems else {
            return nil
        }

        for provider in Self.searchProviders where provider.forwardsQueryIntoWebApp {
            guard let providerComponents = URLComponents(url: provider.baseURL, resolvingAgainstBaseURL: false),
                  let providerHost = providerComponents.host?.lowercased(),
                  host == providerHost || host.hasSuffix(".\(providerHost)"),
                  components.path == providerComponents.path else {
                continue
            }

            let query = queryItems
                .first { $0.name == provider.queryItemName }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let query, !query.isEmpty {
                return (provider.id, query)
            }
        }

        return nil
    }

    func canForwardWebAppPrompt(to url: URL?, providerID: String) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let provider = Self.searchProviders.first(where: { $0.id == providerID && $0.forwardsQueryIntoWebApp }),
              let providerComponents = URLComponents(url: provider.baseURL, resolvingAgainstBaseURL: false),
              let providerHost = providerComponents.host?.lowercased() else {
            return false
        }

        return host == providerHost || host.hasSuffix(".\(providerHost)")
    }

    func searchQuery(from url: URL) -> String? {
        for provider in Self.searchProviders {
            if let query = searchQuery(from: url, provider: provider) {
                return query
            }
        }

        return nil
    }

    func searchQuery(from url: URL, provider: SearchProvider) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let queryItems = components.queryItems else {
            return nil
        }

        guard let providerComponents = URLComponents(url: provider.baseURL, resolvingAgainstBaseURL: false),
              let providerHost = providerComponents.host?.lowercased(),
              host == providerHost || host.hasSuffix(".\(providerHost)"),
              components.path == providerComponents.path else {
            return nil
        }

        let query = queryItems
            .first { $0.name == provider.queryItemName }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let query, !query.isEmpty {
            return query
        }

        return nil
    }

    private func directURL(from input: String) -> URL? {
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        if ["http", "https"].contains(scheme), url.host != nil {
            return url
        }

        if scheme == "about" {
            return url
        }

        return nil
    }

    private func looksLikeHost(_ input: String) -> Bool {
        if input.contains(" ") || input.contains("\n") {
            return false
        }

        if input == "localhost" || input.hasPrefix("localhost:") {
            return true
        }

        if input.range(of: #"^(\d{1,3}\.){3}\d{1,3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return true
        }

        return input.contains(".")
    }

}
