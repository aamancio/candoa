import Foundation

/// Deterministic page-context helpers used before invoking the hosted Eli service.
enum CandoaEliDrafts {
    struct PriceComparisonResult {
        let answer: String
        let suggestedAction: CandoaPageActionProposal?
    }

    static func priceComparisonResult(
        for prompt: String,
        context: CandoaAIPageContext
    ) -> PriceComparisonResult? {
        let normalizedPrompt = CandoaEliPromptPolicy.normalizedText(prompt)
        let direction: PriceComparisonDirection
        if normalizedPrompt.contains("cheapest")
            || normalizedPrompt.contains("least expensive")
            || normalizedPrompt.contains("lowest price") {
            direction = .cheapest
        } else if normalizedPrompt.contains("most expensive")
            || normalizedPrompt.contains("highest price")
            || normalizedPrompt.contains("priciest") {
            direction = .mostExpensive
        } else {
            return nil
        }

        guard let text = context.text else { return nil }
        var candidates = priceCandidates(in: text)
        let sizedCandidates = candidates.filter { $0.sizeLabel != nil }
        if sizedCandidates.count >= 2 {
            candidates = sizedCandidates
        }
        guard candidates.count >= 2 else { return nil }

        let candidate = switch direction {
        case .cheapest:
            candidates.min { $0.price < $1.price }
        case .mostExpensive:
            candidates.max { $0.price < $1.price }
        }
        guard let candidate else { return nil }

        let price = candidate.price.rounded() == candidate.price
            ? String(Int(candidate.price))
            : String(format: "%.2f", candidate.price)
        let subject = candidate.sizeLabel.map { "The \($0) model" }
            ?? "The \(candidate.label) option"
        let answer = switch direction {
        case .cheapest:
            "\(subject) is the cheapest option shown at $\(price)."
        case .mostExpensive:
            "\(subject) is the most expensive option shown at $\(price)."
        }
        let suggestedAction = candidate.sizeLabel.map {
            CandoaPageActionProposal(kind: .click, target: $0, value: nil)
        }
        return PriceComparisonResult(answer: answer, suggestedAction: suggestedAction)
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
                        return asksAboutVisibleControl(CandoaEliPromptPolicy.normalizedText(turn.text))
                    }
            )
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

    private static func asksAboutSignIn(_ normalizedPrompt: String) -> Bool {
        normalizedPrompt.contains("sign in")
            || normalizedPrompt.contains("signin")
            || normalizedPrompt.contains("log in")
            || normalizedPrompt.contains("login")
            || normalizedPrompt.contains("sign button")
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

    private static func priceCandidates(in text: String) -> [PriceCandidate] {
        let priceExpression = try? NSRegularExpression(
            pattern: #"(?i)(?:from|starting at|starts at|now)\s*\$\s*([0-9][0-9,]*(?:\.[0-9]{2})?)"#
        )
        let sizeExpression = try? NSRegularExpression(
            pattern: #"(?i)\b([0-9]+(?:\.[0-9]+)?[-‑ ]inch)\b"#
        )
        guard let priceExpression else { return [] }

        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = priceExpression.firstMatch(in: line, range: range),
                  let priceRange = Range(match.range(at: 1), in: line),
                  let price = Double(line[priceRange].replacingOccurrences(of: ",", with: ""))
            else { return nil }

            let prefixRange = Range(NSRange(location: 0, length: match.range.location), in: line)
            let rawLabel = prefixRange.map { String(line[$0]) } ?? ""
            let label = cleanedPriceLabel(rawLabel)
            guard !label.isEmpty else { return nil }

            let sizeLabel: String? = sizeExpression.flatMap { expression in
                let labelRange = NSRange(label.startIndex..<label.endIndex, in: label)
                guard let sizeMatch = expression.firstMatch(in: label, range: labelRange),
                      let range = Range(sizeMatch.range(at: 1), in: label)
                else { return nil }
                return String(label[range]).replacingOccurrences(of: "‑", with: "-")
            }
            let key = "\(sizeLabel ?? label.lowercased())|\(price)"
            guard seen.insert(key).inserted else { return nil }
            return PriceCandidate(label: label, sizeLabel: sizeLabel, price: price)
        }
    }

    private static func cleanedPriceLabel(_ rawLabel: String) -> String {
        rawLabel
            .replacingOccurrences(
                of: #"^\s*(?:[-•]\s*)?(?:input|radio|label|option|button)(?:\s*\([^)]*\))?\s*:\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s*(?:Footnote\s*)?[†‡※∆§±◊]?[0-9]*\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum PriceComparisonDirection {
        case cheapest
        case mostExpensive
    }

    private struct PriceCandidate {
        let label: String
        let sizeLabel: String?
        let price: Double
    }
}
