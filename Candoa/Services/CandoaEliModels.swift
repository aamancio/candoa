import Foundation

struct CandoaAIConversationTurn: Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

struct CandoaAIPageContext: Sendable {
    let title: String?
    let url: String?
    let text: String?

    var hasAttachedContext: Bool {
        [title, url, text].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

