import Foundation

/// One prompt chip in Eli's empty state.
///
/// `title` is what the chip shows and what gets submitted; the two are the
/// same string so the user sends exactly what they read. `personalizedFormat`
/// is the slot template the on-device model can fill (issue #467): the
/// catalog carries the structure, the model only supplies the subject.
struct EliSuggestion: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case summarize
        case explain
        case compare
        case draftReply
        case trends
        case suggestEdits
        case review
        case nextSteps
        case gettingStarted
        case keyMoments
        case prosAndCons
        case bestResult
        case agenda
        case keyFacts
    }

    let kind: Kind
    let title: String
    let symbolName: String
    /// A `String(localized:)` format with one `%@` slot for the page's
    /// subject. `nil` means the chip never changes wording.
    let personalizedFormat: String?
    /// Whether a personalized fill is showing; the static title is what the
    /// catalog produced and is restored when the page changes.
    let isPersonalized: Bool

    var id: String { kind.rawValue }

    init(
        kind: Kind,
        title: String,
        symbolName: String,
        personalizedFormat: String? = nil,
        isPersonalized: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.symbolName = symbolName
        self.personalizedFormat = personalizedFormat
        self.isPersonalized = isPersonalized
    }

    /// The same chip with its slot filled; chips without a slot are returned
    /// unchanged so a personalized row keeps its static members.
    func personalized(with subject: String) -> EliSuggestion {
        guard let personalizedFormat else { return self }
        return EliSuggestion(
            kind: kind,
            title: String(format: personalizedFormat, subject),
            symbolName: symbolName,
            personalizedFormat: personalizedFormat,
            isPersonalized: true
        )
    }
}

/// Static, zero-token suggestions keyed by what kind of page is open.
///
/// Detection runs on the URL alone: host plus a path shape, no page read and
/// no network. An unknown page gets the generic pair. The comparison chip is
/// not part of the catalog because it starts a mention flow instead of
/// submitting text; the view appends it.
enum EliSuggestionCatalog {
    enum Domain: String, Sendable, CaseIterable {
        case generic
        case email
        case spreadsheet
        case document
        case codeReview
        case issue
        case repository
        case video
        case chat
        case shopping
        case pdf
        case search
        case calendar
        case reference
    }

    static func domain(for url: URL?) -> Domain {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file"
        else { return .generic }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let pathComponents = path.split(separator: "/").map(String.init)

        if path.hasSuffix(".pdf") { return .pdf }

        if hostMatches(host, ["mail.google.com", "outlook.live.com", "outlook.office.com",
                              "outlook.office365.com", "mail.proton.me", "mail.yahoo.com",
                              "app.hey.com", "app.fastmail.com", "mail.aol.com", "mail.zoho.com"]) {
            return .email
        }

        if host == "docs.google.com" {
            if path.hasPrefix("/spreadsheets") { return .spreadsheet }
            if path.hasPrefix("/document") { return .document }
            if path.hasPrefix("/presentation") { return .document }
            return .generic
        }
        if host == "calendar.google.com" { return .calendar }

        if hostMatches(host, ["airtable.com", "sheet.zoho.com"]) { return .spreadsheet }
        if host.hasSuffix(".sharepoint.com") || host == "onedrive.live.com" {
            if path.contains(".xlsx") { return .spreadsheet }
            if path.contains(".docx") || path.contains(".pptx") { return .document }
            return .generic
        }

        if hostMatches(host, ["notion.so", "notion.site", "coda.io", "paper.dropbox.com",
                              "quip.com", "craft.do", "app.clickup.com"])
            || (host.hasSuffix(".atlassian.net") && path.hasPrefix("/wiki")) {
            return .document
        }

        if hostMatches(host, ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]) {
            if pathComponents.contains("pull") || pathComponents.contains("merge_requests")
                || pathComponents.contains("pull-requests") {
                return .codeReview
            }
            if pathComponents.contains("issues") { return .issue }
            return pathComponents.count >= 2 ? .repository : .generic
        }
        if host.hasSuffix(".atlassian.net") && path.hasPrefix("/browse") { return .issue }
        if hostMatches(host, ["linear.app"]) && pathComponents.contains("issue") { return .issue }

        if hostMatches(host, ["youtube.com", "youtu.be", "vimeo.com", "loom.com",
                              "twitch.tv", "ted.com"]) {
            if host.hasSuffix("youtube.com") {
                return path.hasPrefix("/watch") || path.hasPrefix("/shorts") || path.hasPrefix("/live")
                    ? .video : .generic
            }
            return .video
        }

        if hostMatches(host, ["slack.com", "discord.com", "teams.microsoft.com",
                              "teams.live.com", "web.whatsapp.com", "web.telegram.org",
                              "messenger.com"]) {
            return .chat
        }

        if hostMatches(host, ["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr",
                              "amazon.es", "amazon.co.jp", "amazon.com.br", "amazon.ca",
                              "ebay.com", "etsy.com", "bestbuy.com", "walmart.com",
                              "target.com", "newegg.com", "aliexpress.com", "mercadolivre.com.br"]) {
            return .shopping
        }

        if (host.hasSuffix("google.com") || host.hasSuffix("google.co.uk")) && path == "/search" {
            return .search
        }
        if hostMatches(host, ["bing.com"]) && path == "/search" { return .search }
        if hostMatches(host, ["duckduckgo.com", "kagi.com"]) && (path == "/" || path == "/search") {
            return url.query?.isEmpty == false ? .search : .generic
        }
        if hostMatches(host, ["startpage.com", "ecosia.org", "search.brave.com"]) && path.contains("search") {
            return .search
        }

        if host.hasSuffix("wikipedia.org") || host.hasSuffix("britannica.com")
            || host.hasSuffix("wiktionary.org") {
            return .reference
        }

        return .generic
    }

    static func suggestions(for url: URL?) -> [EliSuggestion] {
        suggestions(for: domain(for: url))
    }

    static func suggestions(for domain: Domain) -> [EliSuggestion] {
        switch domain {
        case .generic:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this page"),
                    symbolName: "text.alignleft",
                    personalizedFormat: String(localized: "Summarize the page about %@")
                ),
                EliSuggestion(
                    kind: .explain,
                    title: String(localized: "Explain the key points"),
                    symbolName: "list.bullet",
                    personalizedFormat: String(localized: "Explain the key points about %@")
                ),
            ]
        case .email:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this email thread"),
                    symbolName: "envelope",
                    personalizedFormat: String(localized: "Summarize the email thread about %@")
                ),
                EliSuggestion(
                    kind: .draftReply,
                    title: String(localized: "Draft a reply to this email"),
                    symbolName: "arrowshape.turn.up.left",
                    personalizedFormat: String(localized: "Draft a reply about %@")
                ),
            ]
        case .spreadsheet:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize the data in this spreadsheet"),
                    symbolName: "tablecells",
                    personalizedFormat: String(localized: "Summarize the data about %@")
                ),
                EliSuggestion(
                    kind: .trends,
                    title: String(localized: "Point out trends in this data"),
                    symbolName: "chart.line.uptrend.xyaxis"
                ),
            ]
        case .document:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this document"),
                    symbolName: "doc.text",
                    personalizedFormat: String(localized: "Summarize the document about %@")
                ),
                EliSuggestion(
                    kind: .suggestEdits,
                    title: String(localized: "Suggest edits to this document"),
                    symbolName: "pencil.line"
                ),
            ]
        case .codeReview:
            return [
                EliSuggestion(
                    kind: .explain,
                    title: String(localized: "Explain the changes in this pull request"),
                    symbolName: "arrow.triangle.pull",
                    personalizedFormat: String(localized: "Explain the changes to %@")
                ),
                EliSuggestion(
                    kind: .review,
                    title: String(localized: "Review this pull request for risks"),
                    symbolName: "exclamationmark.shield"
                ),
            ]
        case .issue:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this issue"),
                    symbolName: "circle.dotted",
                    personalizedFormat: String(localized: "Summarize the issue about %@")
                ),
                EliSuggestion(
                    kind: .nextSteps,
                    title: String(localized: "Suggest next steps for this issue"),
                    symbolName: "checklist"
                ),
            ]
        case .repository:
            return [
                EliSuggestion(
                    kind: .explain,
                    title: String(localized: "Explain what this project does"),
                    symbolName: "shippingbox"
                ),
                EliSuggestion(
                    kind: .gettingStarted,
                    title: String(localized: "Explain how to get started with this project"),
                    symbolName: "terminal"
                ),
            ]
        case .video:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this video"),
                    symbolName: "play.rectangle",
                    personalizedFormat: String(localized: "Summarize the video about %@")
                ),
                EliSuggestion(
                    kind: .keyMoments,
                    title: String(localized: "List the key moments in this video"),
                    symbolName: "timeline.selection"
                ),
            ]
        case .chat:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this conversation"),
                    symbolName: "bubble.left.and.bubble.right",
                    personalizedFormat: String(localized: "Summarize the conversation about %@")
                ),
                EliSuggestion(
                    kind: .draftReply,
                    title: String(localized: "Draft a reply to this conversation"),
                    symbolName: "arrowshape.turn.up.left",
                    personalizedFormat: String(localized: "Draft a reply about %@")
                ),
            ]
        case .shopping:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize the reviews for this product"),
                    symbolName: "star.bubble"
                ),
                EliSuggestion(
                    kind: .prosAndCons,
                    title: String(localized: "List the pros and cons of this product"),
                    symbolName: "scale.3d"
                ),
            ]
        case .pdf:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize this PDF"),
                    symbolName: "doc.richtext",
                    personalizedFormat: String(localized: "Summarize the document about %@")
                ),
                EliSuggestion(
                    kind: .explain,
                    title: String(localized: "Explain the key points"),
                    symbolName: "list.bullet",
                    personalizedFormat: String(localized: "Explain the key points about %@")
                ),
            ]
        case .search:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize the results for this search"),
                    symbolName: "magnifyingglass"
                ),
                EliSuggestion(
                    kind: .bestResult,
                    title: String(localized: "Pick the best result for this search"),
                    symbolName: "hand.thumbsup"
                ),
            ]
        case .calendar:
            return [
                EliSuggestion(
                    kind: .summarize,
                    title: String(localized: "Summarize my upcoming events"),
                    symbolName: "calendar"
                ),
                EliSuggestion(
                    kind: .agenda,
                    title: String(localized: "Draft an agenda for this meeting"),
                    symbolName: "list.clipboard"
                ),
            ]
        case .reference:
            return [
                EliSuggestion(
                    kind: .explain,
                    title: String(localized: "Explain this to me simply"),
                    symbolName: "lightbulb"
                ),
                EliSuggestion(
                    kind: .keyFacts,
                    title: String(localized: "Give me the key facts"),
                    symbolName: "list.number"
                ),
            ]
        }
    }

    /// Whether a model-produced subject is safe to drop into a chip: short,
    /// single-line, and not a non-answer. Anything else keeps the static
    /// wording — a bad fill is worse than no fill.
    static func isUsableSubject(_ subject: String, host: String? = nil) -> Bool {
        let trimmed = subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'“”‘’"))
        guard !trimmed.isEmpty,
              trimmed.count <= 48,
              !trimmed.contains(where: \.isNewline)
        else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (1...8).contains(words.count) else { return false }
        let lowered = trimmed.lowercased()
        let nonAnswers = ["unknown", "n/a", "none", "this page", "the page", "untitled",
                          "no subject", "not sure", "unclear"]
        if nonAnswers.contains(lowered) { return false }
        // "Summarize the video about YouTube" says nothing; the site name is
        // the one answer the static chip already implies.
        if let host {
            let labels = host.lowercased().split(separator: ".").map(String.init)
                .filter { $0.count >= 3 && !["www", "com", "org", "net", "app"].contains($0) }
            let compact = lowered.replacingOccurrences(of: " ", with: "")
            if labels.contains(where: { $0 == compact || $0 == lowered }) { return false }
        }
        return true
    }

    /// The model input: title, host, and a short slice of the readable text.
    /// Bounded so a 30k-character page costs the same as a short one and fits
    /// the on-device context window with room to spare.
    static func excerpt(title: String?, url: URL?, pageText: String?, limit: Int = 600) -> String {
        var lines: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let host = url?.host, !host.isEmpty {
            lines.append("Site: \(host)")
        }
        if let pageText {
            let collapsed = pageText
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !collapsed.isEmpty {
                lines.append("Text:\n\(String(collapsed.prefix(limit)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func hostMatches(_ host: String, _ candidates: [String]) -> Bool {
        candidates.contains { candidate in
            host == candidate || host.hasSuffix("." + candidate)
        }
    }
}
