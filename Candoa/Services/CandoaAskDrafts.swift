import Foundation

/// Page-context helpers used to decide what to send to the hosted Ask service.
/// This deliberately contains no local response generation.
enum CandoaAskDrafts {
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
                        return asksAboutVisibleControl(CandoaAskPromptPolicy.normalizedText(turn.text))
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
}
