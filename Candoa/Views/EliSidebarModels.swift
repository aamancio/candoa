import AppKit
import SwiftUI

enum AISidebarResponseFeedback: Equatable {
    case positive
    case negative
}

struct AISidebarMentionOption: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let symbolName: String
    let faviconData: Data?
    let action: AISidebarMentionAction
}

enum AISidebarMentionAction {
    case mention(AISidebarContextMention)
    case mentionAllOpenTabs
    case uploadFile
}

struct AISidebarContextChip: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let faviconData: Data?
    var previewImageData: Data? = nil
    let isRemovable: Bool
}

enum AISidebarContextMention: Equatable {
    case tab(UUID)
    case history(AISidebarHistoryContext)
    case file(AISidebarFileContext)
}

struct AISidebarHistoryContext: Equatable {
    let id: UUID
    let title: String
    let url: URL
}

struct AISidebarFileContext: Equatable {
    var id = UUID()
    let name: String
    let text: String
    var previewImageData: Data? = nil
}

/// A tab attached via an @-mention, captured at submission so a later
/// browser-control event can resolve the model's targetTabURL back to the
/// exact tab the user attached.
struct EliMentionedTab: Equatable {
    let id: UUID
    let url: String
}

struct EliSubmission {
    let prompt: String
    let contextChips: [AISidebarContextChip]
    let contextMentions: [AISidebarContextMention]
    let recentTurns: [AIConversationTurn]
    let currentPageTabID: UUID?
    let browserControlTabID: UUID?
    let mentionedTabs: [EliMentionedTab]
    let inheritedPageContext: AIPageContext?
}

/// Which Space the conversation's not-yet-distilled turns belong to, and where
/// in the transcript they start. Lives alongside `messages` above the sidebar:
/// the sidebar view is destroyed every time Eli is closed, and a window that
/// reset with it would reopen over turns that were said in another Space.
struct EliMemoryWindow: Equatable {
    var startIndex = 0
    var spaceID: UUID?
}

struct AISidebarMessage: Identifiable, Equatable {
    var id = UUID()
    let role: AISidebarMessageRole
    var text: String
    var isStreaming: Bool
    var transientStatus: String? = nil
    var contextChips: [AISidebarContextChip] = []
    var action: AISidebarMessageAction? = nil
    var feedback: AISidebarResponseFeedback? = nil
    var responseImageData: Data? = nil

    var responseImage: NSImage? {
        responseImageData.flatMap(NSImage.init(data:))
    }

    var hasCopyableContent: Bool {
        !text.isEmpty || responseImageData != nil
    }

    static var subscriptionGate: Self {
        AISidebarMessage(
            role: .assistant,
            text: "",
            isStreaming: false,
            action: .subscribe
        )
    }
}

enum AISidebarMessageAction: Equatable {
    case subscribe
    /// The browser-agent run is paused on something only the user can clear
    /// (an ad, a sign-in, a CAPTCHA); `reason` is the model's plain-language
    /// description of what to do before continuing.
    case waitingForUser(reason: String)
}

enum AISidebarMessageRole: Equatable {
    case user
    case assistant

    var conversationRole: AIConversationTurn.Role {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        }
    }
}
