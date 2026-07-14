import Foundation

enum CandoaAgentContextCompactor {
    private static let contextThreshold = 18_000
    private static let leadingLimit = 2_500
    private static let trailingLimit = 2_500
    private static let focusedLineLimit = 45
    private static let controlLineLimit = 30
    private static let ocrLimit = 2_500

    static func compactedContextIfNeeded(
        from context: CandoaAIPageContext,
        prompt: String
    ) -> CandoaAIPageContext? {
        guard let text = context.text, text.count > contextThreshold else { return nil }

        let semanticText = CandoaAgentDrafts.semanticPageText(from: text) ?? text
        let focusedLines = focusedContextLines(from: semanticText, prompt: prompt)
        let leadingText = String(semanticText.prefix(leadingLimit))
        let trailingText = String(semanticText.suffix(trailingLimit))
        let visibleControls = CandoaAgentDrafts.visibleControlsSection(from: text)
            .flatMap(compactControlsForModel)
            .map { "\n\nVisible page controls and links:\n\($0)" } ?? ""
        let ocrText = CandoaAgentDrafts.visibleOCRSection(from: text)
            .map { "\n\nVisible page image text from OCR:\n\(String($0.prefix(ocrLimit)))" } ?? ""

        let compactText = """
        Full page semantic text:
        Leading page text:
        \(leadingText)

        Focused lines matching the question:
        \(focusedLines.isEmpty ? "None found." : focusedLines.joined(separator: "\n"))

        Trailing page text:
        \(trailingText)\(visibleControls)\(ocrText)
        """
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compactText.count < text.count else { return nil }

        return CandoaAIPageContext(
            title: context.title,
            url: context.url,
            text: compactText
        )
    }

    private static func focusedContextLines(from text: String, prompt: String) -> [String] {
        let terms = searchTerms(in: CandoaAgentPromptPolicy.normalizedText(prompt))
        guard !terms.isEmpty else { return [] }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let matchingIndexes = lines.indices.filter { index in
            let normalizedLine = CandoaAgentPromptPolicy.normalizedText(lines[index])
            return terms.contains { normalizedLine.contains($0) }
        }

        var includedIndexes = Set<Int>()
        var focusedLines: [String] = []

        for index in matchingIndexes {
            let lowerBound = max(lines.startIndex, index - 2)
            let upperBound = min(lines.endIndex, index + 8)
            for focusedIndex in lowerBound..<upperBound where !includedIndexes.contains(focusedIndex) {
                includedIndexes.insert(focusedIndex)
                focusedLines.append(lines[focusedIndex])
                if focusedLines.count >= focusedLineLimit {
                    return focusedLines
                }
            }
        }

        return focusedLines
    }

    private static func compactControlsForModel(_ controlsSection: String) -> String? {
        let lines = controlsSection
            .components(separatedBy: .newlines)
            .map(compactContextLine)
            .filter { !$0.isEmpty }
            .prefix(controlLineLimit)
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func compactContextLine(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(
            of: #"\s*\[url:\s*https?://[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"[\s]+"#,
            with: " ",
            options: .regularExpression
        )
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchTerms(in normalizedPrompt: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "about", "an", "and", "are", "can", "do", "does", "for", "from", "in", "is", "it", "me", "of",
            "on", "page", "section", "site", "that", "the", "this", "to", "what", "where", "which", "with", "you"
        ]

        return normalizedPrompt
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
