import Foundation

enum CandoaAskDrafts {
    static func response(
        for prompt: String,
        context: CandoaAIPageContext,
        recentTurns: [CandoaAIConversationTurn] = []
    ) -> String {
        let normalizedPrompt = CandoaAskPromptPolicy.normalizedText(prompt)
        let visibleControlPrompt = visibleControlPrompt(
            normalizedPrompt,
            recentTurns: recentTurns
        )
        let pageTitle = context.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageText = pageTitle?.isEmpty == false ? pageTitle! : "this page"

        if !context.hasAttachedContext, referencesCurrentPage(normalizedPrompt) {
            return noContextDraft
        }

        if let controlAnswer = visibleControlAnswer(for: visibleControlPrompt, contextText: context.text) {
            return controlAnswer
        }

        if let contentAnswer = pageContentAnswer(for: normalizedPrompt, contextText: context.text) {
            return contentAnswer
        }

        if normalizedPrompt.contains("what is this page about") || normalizedPrompt.contains("summarize") {
            return summaryDraft(from: context.text) ?? "I can't read enough page text to summarize \(pageText)."
        }

        if normalizedPrompt.contains("key details") || normalizedPrompt.contains("key facts") {
            return summaryDraft(from: context.text) ?? "I can't read enough page text to find key details on \(pageText)."
        }

        if normalizedPrompt.contains("compare") {
            return "I can read the page now, but comparison still needs a product or option extractor. Try asking a specific question about one item on \(pageText)."
        }

        if normalizedPrompt.contains("explain") {
            return summaryDraft(from: context.text) ?? "I can't read enough page text to explain \(pageText)."
        }

        if referencesCurrentPage(normalizedPrompt) {
            return summaryDraft(from: context.text) ?? "I can't read enough page text to summarize \(pageText)."
        }

        if normalizedPrompt.contains("suggest useful questions") {
            return """
            You could ask:
            - What matters most on this page?
            - What should I do next?
            - What is missing or unclear?
            """
        }

        return "I can't answer that yet."
    }

    private static var noContextDraft: String {
        """
        I can't see what you're currently looking at because no page context is attached to this message.

        Attach the current page, mention a tab with @, or share the URL and I can summarize it.
        """
    }

    static func referencesCurrentPage(_ normalizedPrompt: String) -> Bool {
        normalizedPrompt.contains("this page")
            || normalizedPrompt.contains("this website")
            || normalizedPrompt.contains("this site")
            || normalizedPrompt.contains("what about this")
            || normalizedPrompt.contains("what about that")
            || normalizedPrompt.contains("that page")
            || normalizedPrompt.contains("that website")
            || normalizedPrompt.contains("page about")
            || normalizedPrompt.contains("website about")
            || normalizedPrompt.contains("summarize")
            || normalizedPrompt.contains("key details")
            || normalizedPrompt.contains("key facts")
            || normalizedPrompt.contains("what should i do next")
    }

    private static func visibleControlAnswer(for normalizedPrompt: String, contextText: String?) -> String? {
        guard asksAboutVisibleControl(normalizedPrompt) else { return nil }

        let controlLines = visibleControlLines(from: contextText)
        guard !controlLines.isEmpty else {
            return "I can't reliably place that control because I don't have a fresh scan of the visible page controls."
        }

        let matchingControls = controlLines.compactMap(VisiblePageControl.init(rawLine:)).filter { control in
            let normalizedControlText = CandoaAskPromptPolicy.normalizedText(control.searchableText)
            if asksAboutSignIn(normalizedPrompt) {
                return normalizedControlText.contains("sign in")
                    || normalizedControlText.contains("signin")
                    || normalizedControlText.contains("log in")
                    || normalizedControlText.contains("login")
                    || normalizedControlText.contains("account")
            }

            let promptWords = Set(normalizedPrompt
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !controlSearchStopWords.contains($0) }
            )
            return promptWords.contains(where: { normalizedControlText.contains($0) })
        }

        if matchingControls.isEmpty, asksAboutSignIn(normalizedPrompt) {
            return "I don't see a visible Sign in or login control on the part of the page I can scan. It may be hidden in an account menu, offscreen, or loaded after another interaction."
        }

        guard let firstMatch = matchingControls.first else {
            return "I don't see that control in the visible part of the page."
        }

        return firstMatch.conversationalAnswer
    }

    static func asksAboutVisibleControl(
        _ normalizedPrompt: String,
        recentTurns: [CandoaAIConversationTurn] = []
    ) -> Bool {
        asksAboutSignIn(normalizedPrompt)
            || normalizedPrompt.contains("button")
            || normalizedPrompt.contains("click")
            || normalizedPrompt.contains("tap")
            || normalizedPrompt.contains("press")
            || normalizedPrompt.contains("link")
            || normalizedPrompt.contains("control")
            || normalizedPrompt.contains("search bar")
            || normalizedPrompt.contains("search box")
            || normalizedPrompt.contains("search field")
            || normalizedPrompt.contains("input")
            || normalizedPrompt.contains("field")
            || (
                isRetryPrompt(normalizedPrompt)
                    && recentTurns.reversed().contains { turn in
                        guard case .user = turn.role else { return false }
                        return asksAboutVisibleControl(CandoaAskPromptPolicy.normalizedText(turn.text))
                    }
            )
    }

    private static func asksAboutSignIn(_ normalizedPrompt: String) -> Bool {
        normalizedPrompt.contains("sign in")
            || normalizedPrompt.contains("signin")
            || normalizedPrompt.contains("log in")
            || normalizedPrompt.contains("login")
            || normalizedPrompt.contains("sign button")
    }

    private static func visibleControlPrompt(
        _ normalizedPrompt: String,
        recentTurns: [CandoaAIConversationTurn]
    ) -> String {
        guard isRetryPrompt(normalizedPrompt) else { return normalizedPrompt }

        return recentTurns.reversed().compactMap { turn -> String? in
            guard case .user = turn.role else { return nil }
            let candidate = CandoaAskPromptPolicy.normalizedText(turn.text)
            return asksAboutVisibleControl(candidate) ? candidate : nil
        }.first ?? normalizedPrompt
    }

    private static func isRetryPrompt(_ normalizedPrompt: String) -> Bool {
        normalizedPrompt == "check again"
            || normalizedPrompt == "try again"
            || normalizedPrompt == "scan again"
            || normalizedPrompt == "look again"
            || normalizedPrompt == "look one more time"
            || normalizedPrompt == "can you check again"
            || normalizedPrompt == "please check again"
    }

    private static func visibleControlLines(from contextText: String?) -> [String] {
        guard let controlsSection = visibleControlsSection(from: contextText) else { return [] }

        return controlsSection
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") }
    }

    private static func pageContentAnswer(for normalizedPrompt: String, contextText: String?) -> String? {
        let promptTerms = contentTerms(in: normalizedPrompt)
        guard !promptTerms.isEmpty, let searchableText = searchablePageContent(from: contextText) else { return nil }

        let lines = searchableText
            .components(separatedBy: .newlines)
            .compactMap { cleanedPageContentLine($0) }
            .filter {
                !$0.isEmpty
                    && CandoaAskPromptPolicy.normalizedText($0) != "full page semantic text"
                    && CandoaAskPromptPolicy.normalizedText($0) != "visible page image text from ocr"
            }

        guard !lines.isEmpty else { return nil }

        let scoredLines = lines.enumerated().map { index, line in
            let normalizedLine = CandoaAskPromptPolicy.normalizedText(line)
            let score = promptTerms.reduce(0) { partialScore, term in
                partialScore + (normalizedLine.contains(term) ? 1 : 0)
            }
            return (index: index, score: score)
        }

        guard let bestMatch = scoredLines.max(by: { $0.score < $1.score }), bestMatch.score > 0 else {
            return nil
        }

        let sectionLines = lines[bestMatch.index..<min(lines.count, bestMatch.index + 10)]
            .prefix(8)

        guard !sectionLines.isEmpty else { return nil }

        return """
        Here's the part of the page I found:
        \(sectionLines.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private static let controlSearchStopWords: Set<String> = [
        "and", "are", "button", "can", "click", "control", "field", "for", "from", "how", "input", "into",
        "link", "page", "press", "search", "should", "that", "the", "this", "where", "with", "you"
    ]

    private struct VisiblePageControl {
        let type: String
        let label: String
        let location: String?
        let url: String?

        var searchableText: String {
            [type, label, location].compactMap { $0 }.joined(separator: " ")
        }

        var conversationalAnswer: String {
            var sentence = "I see \(article) \(typeDescription) labeled \"\(label)\""
            if let location, !location.isEmpty {
                sentence += " near the \(location) of the page"
            } else {
                sentence += " in the visible part of the page"
            }
            sentence += "."

            if let url, !url.isEmpty {
                sentence += " It links to \(url)."
            }

            return sentence
        }

        private var typeDescription: String {
            switch type {
            case "a":
                return "link"
            case "input":
                return "input"
            case "textarea":
                return "text field"
            case "select":
                return "menu"
            default:
                return type
            }
        }

        init?(rawLine: String) {
            var remaining = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if remaining.hasPrefix("- ") {
                remaining.removeFirst(2)
            }

            let metadataPattern = #"\s*\[(visible|url): ([^\]]+)\]"#
            let regex = try? NSRegularExpression(pattern: metadataPattern)
            var location: String?
            var url: String?

            if let regex {
                let matches = regex.matches(
                    in: remaining,
                    range: NSRange(remaining.startIndex..<remaining.endIndex, in: remaining)
                )
                for match in matches {
                    guard
                        let keyRange = Range(match.range(at: 1), in: remaining),
                        let valueRange = Range(match.range(at: 2), in: remaining)
                    else { continue }

                    let key = String(remaining[keyRange])
                    let value = String(remaining[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if key == "visible" {
                        location = value
                    } else if key == "url" {
                        url = value
                    }
                }

                remaining = regex.stringByReplacingMatches(
                    in: remaining,
                    range: NSRange(remaining.startIndex..<remaining.endIndex, in: remaining),
                    withTemplate: ""
                )
            }

            let parts = remaining.split(separator: ":", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }

            self.type = parts[0]
            self.label = parts[1]
            self.location = location
            self.url = url
        }

        private var article: String {
            guard let firstCharacter = typeDescription.first else { return "a" }
            return "aeiou".contains(firstCharacter.lowercased()) ? "an" : "a"
        }
    }

    static func semanticPageText(from contextText: String?) -> String? {
        guard let contextText else { return nil }
        let markerStarts = [
            contextText.range(of: "Visible page controls and links:")?.lowerBound,
            contextText.range(of: "Visible page image text from OCR:")?.lowerBound
        ].compactMap { $0 }

        if let firstMarkerStart = markerStarts.min() {
            return String(contextText[..<firstMarkerStart])
        }
        return contextText
    }

    static func visibleControlsSection(from contextText: String?) -> String? {
        guard let contextText else { return nil }
        guard let controlsRange = contextText.range(of: "Visible page controls and links:") else { return nil }
        let controlsTail = contextText[controlsRange.upperBound...]
        let controlsEnd = controlsTail.range(of: "\n\nVisible page image text from OCR:")?.lowerBound
            ?? controlsTail.endIndex
        let section = String(controlsTail[..<controlsEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    static func visibleOCRSection(from contextText: String?) -> String? {
        guard let contextText else { return nil }
        guard let ocrRange = contextText.range(of: "Visible page image text from OCR:") else { return nil }
        let section = String(contextText[ocrRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    private static func searchablePageContent(from contextText: String?) -> String? {
        let sections = [
            semanticPageText(from: contextText),
            visibleOCRSection(from: contextText).map { "Visible page image text from OCR:\n\($0)" }
        ]
            .compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return value
            }

        let text = sections.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private static func cleanedPageContentLine(_ rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        line = line.replacingOccurrences(
            of: #"(?i)\bbutton:\s*watchlist\b"#,
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"(?i)\blink:\s*https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"(?i)\s*-\s*opens in new window or tab"#,
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"(?i)\b(previous price)\s*"#,
            with: "$1 ",
            options: .regularExpression
        )
        line = line.replacingOccurrences(of: "Link:", with: "")
        line = line.replacingOccurrences(of: "Image:", with: "")
        line = line.replacingOccurrences(
            of: #"[\s]+"#,
            with: " ",
            options: .regularExpression
        )
        line = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

        let normalizedLine = CandoaAskPromptPolicy.normalizedText(line)
        guard !normalizedLine.isEmpty else { return nil }
        guard normalizedLine != "button watchlist" else { return nil }
        guard !normalizedLine.hasPrefix("link ") else { return nil }

        return line
    }

    private static func contentTerms(in normalizedPrompt: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "about", "an", "and", "are", "can", "do", "does", "for", "from", "in", "is", "it", "me", "of",
            "on", "page", "section", "site", "that", "the", "this", "to", "what", "where", "which", "with"
        ]

        return normalizedPrompt
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    private static func summaryDraft(from pageText: String?) -> String? {
        guard let pageText = searchablePageContent(from: pageText) else { return nil }
        let normalizedText = pageText
            .replacingOccurrences(of: "Full page semantic text:", with: "")
            .replacingOccurrences(of: "Visible page image text from OCR:", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.count > 80 else { return nil }

        let sentences = normalizedText
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 30 }
            .prefix(3)

        let summary = sentences.map { "- \($0)" }.joined(separator: "\n")
        return summary.isEmpty ? String(normalizedText.prefix(420)) : summary
    }
}
