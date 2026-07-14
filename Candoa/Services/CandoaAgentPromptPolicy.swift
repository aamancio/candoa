import Foundation

enum CandoaAgentPromptPolicy {
    private static let singleWordPageCommands: Set<String> = [
        "summarize",
        "summary",
        "explain",
        "compare"
    ]

    static func canSubmit(_ prompt: String, hasConversation: Bool = false) -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }

        if containsArithmeticExpression(trimmedPrompt) {
            return true
        }

        let words = normalizedText(trimmedPrompt)
            .split(separator: " ")
            .map(String.init)

        guard let firstWord = words.first else { return false }

        if hasConversation, firstWord.count >= 3 {
            return true
        }

        if words.count == 1 {
            return firstWord.count >= 3 || singleWordPageCommands.contains(firstWord)
        }

        if words.count == 2 {
            return trimmedPrompt.contains("?") || words.joined().count >= 6
        }

        return true
    }

    static func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "teh", with: "the")
            .replacingOccurrences(of: "whats", with: "what is")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsArithmeticExpression(_ prompt: String) -> Bool {
        let normalizedPrompt = prompt
            .lowercased()
            .replacingOccurrences(of: "+", with: " plus ")
            .replacingOccurrences(of: "-", with: " minus ")
            .replacingOccurrences(of: "*", with: " times ")
            .replacingOccurrences(of: "×", with: " times ")
            .replacingOccurrences(of: "/", with: " divided ")

        let words = normalizedPrompt
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var hasNumber = false
        var hasOperation = false
        for word in words {
            if Double(word) != nil || numberWords.contains(word) {
                hasNumber = true
            }

            if operationWords.contains(word) {
                hasOperation = true
            }
        }

        return hasNumber && hasOperation
    }

    private static let numberWords: Set<String> = [
        "zero",
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
        "nine",
        "ten",
        "eleven",
        "twelve",
        "thirteen",
        "fourteen",
        "fifteen",
        "sixteen",
        "seventeen",
        "eighteen",
        "nineteen",
        "twenty"
    ]

    private static let operationWords: Set<String> = [
        "plus",
        "add",
        "added",
        "minus",
        "subtract",
        "subtracted",
        "less",
        "times",
        "multiply",
        "multiplied",
        "x",
        "divided",
        "divide",
        "over"
    ]
}
