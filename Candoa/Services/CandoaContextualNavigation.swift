import Foundation

struct CandoaPageActionProposal: Identifiable, Sendable {
    let id = UUID()
    let kind: CandoaPageActionKind
    let target: String
    let value: String?

    var needsVisibleLinkResolution: Bool {
        kind == .navigate && !Self.looksLikeDestination(target)
    }

    static func parse(_ prompt: String) -> CandoaPageActionProposal? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please ", "can you ", "could you ", "would you "] {
            if text.lowercased().hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                break
            }
        }
        let lowercased = text.lowercased()

        if lowercased.contains("scroll down") { return .init(kind: .scroll, target: "down", value: nil) }
        if lowercased.contains("scroll up") { return .init(kind: .scroll, target: "up", value: nil) }

        if let match = text.firstMatch(of: /(?i)^(?:(?:navigate|go|browse)\s+to|take\s+me\s+to)\s+(.+?)[.!?]?$/) {
            let target = normalizedTarget(String(match.1))
            return target.isEmpty ? nil : .init(kind: .navigate, target: target, value: nil)
        }

        if let match = text.firstMatch(of: /(?i)^visit\s+(.+?)[.!?]?$/) {
            let target = normalizedTarget(String(match.1))
            return target.isEmpty ? nil : .init(kind: .navigate, target: target, value: nil)
        }

        if let match = text.firstMatch(of: /(?i)^(click|open|press|tap)\s+(?:the\s+)?(.+?)[.!?]?$/) {
            let verb = String(match.1).lowercased()
            let target = normalizedTarget(String(match.2))
            guard !target.isEmpty else { return nil }
            let kind: CandoaPageActionKind = verb == "open" && looksLikeDestination(target)
                ? .navigate
                : .click
            return .init(kind: kind, target: target, value: nil)
        }

        if let match = text.firstMatch(of: /(?i)^(?:select|choose|pick)\s+(?:the\s+)?(.+?)[.!?]?$/) {
            let target = normalizedTarget(String(match.1))
            return target.isEmpty ? nil : .init(kind: .select, target: target, value: nil)
        }

        if let match = text.firstMatch(of: /(?i)^(?:fill|type|enter)\s+["'](.+)["']\s+(?:in|into)\s+(?:the\s+)?(.+?)[.!?]?$/) {
            let value = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = normalizedTarget(String(match.2))
            return value.isEmpty || target.isEmpty ? nil : .init(kind: .fill, target: target, value: value)
        }

        return nil
    }

    private static func normalizedTarget(_ target: String) -> String {
        target
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+(?:button|link|field)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeDestination(_ target: String) -> Bool {
        let normalized = target.lowercased()
        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") ||
            normalized.hasPrefix("www.") || normalized.hasPrefix("localhost") {
            return true
        }
        return !normalized.contains(where: \.isWhitespace) && normalized.contains(".")
    }
}

enum CandoaContextualActionFollowUp {
    static func isApproval(_ prompt: String) -> Bool {
        let normalizedPrompt = CandoaEliPromptPolicy.normalizedText(prompt)
        let affirmativePhrases: Set<String> = [
            "yes", "okay", "ok", "go ahead", "do it", "do that", "lets do it",
            "lets do that", "yes do it", "yes do that", "ok do it", "ok do that",
            "ok lets do it", "ok lets do that", "okay do it", "okay do that",
            "okay lets do it", "okay lets do that", "take me there", "yes take me there",
            "ok take me there", "okay take me there", "open it", "yes open it"
        ]
        if affirmativePhrases.contains(normalizedPrompt) {
            return true
        }

        let words = Set(normalizedPrompt.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        let refersToPriorTarget = words.contains("there")
            || words.contains("it")
            || normalizedPrompt.contains("that one")
            || normalizedPrompt.contains("this one")
        let actionVerbs = ["take", "bring", "go", "open", "select", "choose", "click", "do"]
        return refersToPriorTarget && actionVerbs.contains(where: normalizedPrompt.contains)
    }

    static func parse(
        _ prompt: String,
        recentTurns: [CandoaAIConversationTurn]
    ) -> CandoaPageActionProposal? {
        let normalizedPrompt = CandoaEliPromptPolicy.normalizedText(prompt)
        guard isApproval(prompt) else { return nil }

        let explicitlyReferencesDestination = normalizedPrompt.contains("there")
            || normalizedPrompt.contains("open it")

        guard let lastAssistantText = recentTurns.reversed().first(where: { $0.role == .assistant })?.text else {
            return nil
        }
        let foldedAssistant = lastAssistantText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).lowercased()
        let negativeCues = ["cannot", "can't", "could not", "couldn't", "will not", "won't"]
        guard !negativeCues.contains(where: foldedAssistant.contains) else { return nil }

        let normalizedAssistant = CandoaEliPromptPolicy.normalizedText(lastAssistantText)
        let actionCues = [
            "i can take you", "take you to", "navigate", "open the", "open it",
            "go to the", "visible link", "permission prompt", "approve"
        ]
        guard explicitlyReferencesDestination
            || actionCues.contains(where: normalizedAssistant.contains)
        else { return nil }

        return CandoaPageActionProposal(kind: .navigate, target: "there", value: nil)
    }
}

struct CandoaPurchaseNavigationIntent: Sendable {
    enum Category: Sendable {
        case computer
    }

    let category: Category

    static func parse(_ prompt: String) -> CandoaPurchaseNavigationIntent? {
        let text = prompt.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let asksForLowestPrice = ["cheapest", "least expensive", "lowest price", "most affordable"]
            .contains { text.contains($0) }
        let asksForComputer = ["computer", "laptop", "macbook", "mac book"]
            .contains { text.contains($0) }
        let asksToOpenPurchaseDestination = [
            "buying screen", "buying page", "buy page", "purchase screen", "purchase page",
            "take control", "take me", "navigate", "open", "go to", "buy it", "purchase it",
            "put me in the", "put me on the"
        ].contains { text.contains($0) }

        guard asksForLowestPrice, asksForComputer, asksToOpenPurchaseDestination else { return nil }
        return CandoaPurchaseNavigationIntent(category: .computer)
    }
}

struct CandoaPagePurchaseCandidate: Codable, Sendable {
    let label: String
    let url: String
    let price: Decimal
}

enum CandoaContextualNavigationResolver {
    static func resolve(
        _ action: CandoaPageActionProposal,
        recentTurns: [CandoaAIConversationTurn],
        pageContext: CandoaAIPageContext
    ) -> CandoaPageActionProposal? {
        guard action.needsVisibleLinkResolution else { return action }

        let links = visibleLinks(in: pageContext).filter { link in
            belongsToCurrentSite(link.url, currentPageURL: pageContext.url)
        }
        guard !links.isEmpty else { return nil }

        let targetTerms = meaningfulTerms(in: action.target)
        let isReferentialTarget = targetTerms.isEmpty || containsReference(in: action.target)
        let latestAssistantText = recentTurns.reversed()
            .first(where: { $0.role == .assistant })?
            .text
        let normalizedAssistantText = latestAssistantText.map(normalizedText)

        let ranked = links.compactMap { link -> (link: VisibleLink, score: Int)? in
            let labelTerms = meaningfulTerms(in: link.label)
            guard !labelTerms.isEmpty else { return nil }

            let directMatches = labelTerms.intersection(targetTerms).count
            if isReferentialTarget {
                // Referential requests such as “take me there” must resolve from the latest
                // recommendation alone. Generic word overlap across older messages can select
                // an unrelated link (for example, Apple's Trade In offer on a Mac page).
                guard
                    let normalizedAssistantText,
                    normalizedText(link.label).count >= 4,
                    normalizedAssistantText.contains(normalizedText(link.label))
                else { return nil }
            } else {
                guard directMatches >= 1 else { return nil }
            }

            let score = isReferentialTarget ? labelTerms.count * 100 : directMatches * 20
            return (link, score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.link.label.count > rhs.link.label.count }
            return lhs.score > rhs.score
        }

        guard let best = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].score == best.score {
            return nil
        }

        return CandoaPageActionProposal(
            kind: .navigate,
            target: best.link.url.absoluteString,
            value: nil
        )
    }

    static func resolve(
        _ intent: CandoaPurchaseNavigationIntent,
        candidates: [CandoaPagePurchaseCandidate],
        currentPageURL: String?
    ) -> CandoaPageActionProposal? {
        let rankedCandidates = candidates
            .compactMap { candidate -> (candidate: CandoaPagePurchaseCandidate, url: URL)? in
                guard
                    let url = URL(string: candidate.url),
                    belongsToCurrentSite(url, currentPageURL: currentPageURL),
                    isPurchaseDestination(label: candidate.label, url: url)
                else {
                    return nil
                }
                return (candidate, url)
            }
            .filter { entry in
                switch intent.category {
                case .computer:
                    return isComputerProduct(label: entry.candidate.label, url: entry.url)
                }
            }
            .sorted { lhs, rhs in
                if lhs.candidate.price == rhs.candidate.price {
                    return lhs.candidate.label < rhs.candidate.label
                }
                return lhs.candidate.price < rhs.candidate.price
        }

        guard let best = rankedCandidates.first else { return nil }
        return CandoaPageActionProposal(
            kind: .click,
            target: best.candidate.label,
            value: nil
        )
    }

    private struct VisibleLink {
        let label: String
        let url: URL
        let price: Decimal?
    }

    private static let ignoredTerms: Set<String> = [
        "a", "an", "and", "at", "buy", "for", "from", "go", "i", "it", "link",
        "me", "of", "on", "one", "page", "please", "take", "that", "the", "there",
        "this", "to", "website", "with"
    ]

    private static func visibleLinks(in context: CandoaAIPageContext) -> [VisibleLink] {
        guard let text = context.text else { return [] }

        return text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard
                line.hasPrefix("- "),
                let urlMarker = line.range(of: " [url: ", options: .backwards),
                line.hasSuffix("]")
            else {
                return nil
            }

            let urlString = String(line[urlMarker.upperBound..<line.index(before: line.endIndex)])
            guard
                let url = URL(string: urlString),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                return nil
            }

            let prefix = String(line[..<urlMarker.lowerBound])
            let labelEnd = prefix.range(of: " [visible: ", options: .backwards)?.lowerBound ?? prefix.endIndex
            guard let labelSeparator = prefix.firstIndex(of: ":") else { return nil }
            let labelStart = prefix.index(after: labelSeparator)
            var label = prefix[labelStart..<labelEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let price: Decimal?
            if let priceMatch = label.firstMatch(of: /\s*\[price:\s*([0-9]+(?:\.[0-9]+)?)\]\s*$/) {
                price = Decimal(string: String(priceMatch.1))
                label.removeSubrange(priceMatch.range)
                label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                price = nil
            }
            return label.isEmpty ? nil : VisibleLink(label: label, url: url, price: price)
        }
    }

    private static func isComputerProduct(label: String, url: URL) -> Bool {
        let text = normalizedText("\(label) \(url.path)")
        let computerTerms = ["macbook", "mac-book", "imac", "mac-mini", "mac-studio", "mac-pro"]
        return computerTerms.contains { text.contains($0) }
            && !text.contains("ipad")
            && !text.contains("iphone")
    }

    private static func isPurchaseDestination(label: String, url: URL) -> Bool {
        let text = normalizedText("\(label) \(url.path)")
        return ["/buy-", "/shop/", "/product/", "/products/", "/purchase", " buy ", " shop "]
            .contains { text.contains($0) }
    }

    private static func belongsToCurrentSite(_ url: URL, currentPageURL: String?) -> Bool {
        guard
            let currentPageURL,
            let currentHost = URL(string: currentPageURL)?.host?.lowercased(),
            let candidateHost = url.host?.lowercased()
        else {
            return false
        }

        return candidateHost == currentHost
            || candidateHost.hasSuffix(".\(currentHost)")
            || currentHost.hasSuffix(".\(candidateHost)")
    }

    private static func meaningfulTerms(in text: String) -> Set<String> {
        Set(
            normalizedText(text)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 1 && !ignoredTerms.contains($0) }
        )
    }

    private static func normalizedText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsReference(in text: String) -> Bool {
        let normalized = " \(normalizedText(text)) "
        return [" it ", " that ", " this ", " the page ", " the one ", " that one ", " this one "]
            .contains { normalized.contains($0) }
    }
}

