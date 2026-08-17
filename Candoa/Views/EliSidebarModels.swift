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
    case selection(AISidebarSelectionContext)
}

/// A passage the person selected on a page and sent to Eli. It carries its
/// own copy of the text rather than a range into the page: the selection is
/// gone the moment they click anywhere else, and the quote has to survive
/// until the turn is submitted.
struct AISidebarSelectionContext: Equatable {
    /// Long enough for a passage worth quoting, short enough that a
    /// select-all can't crowd the page context out of the request.
    static let characterLimit = 8_000
    /// Comfortably more than the three lines the quote block shows, so the
    /// cut lands in the layout rather than mid-sentence in the string.
    static let quotePreviewLimit = 320

    var id = UUID()
    let text: String
    let pageTitle: String?
    let pageURL: URL?

    /// Trims and caps the raw selection; nil when nothing but whitespace was
    /// selected, which is what a stray click-drag produces.
    init?(rawText: String, pageTitle: String?, pageURL: URL?) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count > Self.characterLimit {
            text = String(trimmed.prefix(Self.characterLimit)) + "…"
        } else {
            text = trimmed
        }

        let trimmedTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pageTitle = trimmedTitle?.isEmpty == false ? trimmedTitle : nil
        self.pageURL = pageURL
    }

    /// The quote as the composer block reads it. Newlines and runs of space
    /// collapse first, so a passage spanning paragraphs reads as prose in a
    /// three-line block instead of as a column of fragments.
    var quotePreview: String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > Self.quotePreviewLimit else { return collapsed }
        let head = collapsed.prefix(Self.quotePreviewLimit - 1)
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Where the passage came from, under the quote. The page's own title
    /// says it best; the host stands in when a page has none.
    var sourceLabel: String {
        pageTitle
            ?? pageURL?.host(percentEncoded: false)
            ?? String(localized: "Selected text")
    }
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
    /// Passages quoted above the composer. Held apart from the chips: a chip
    /// says a document was attached, a quote says which part of one already
    /// attached the question is about.
    let quotedSelections: [AISidebarSelectionContext]
    let contextMentions: [AISidebarContextMention]
    let recentTurns: [AIConversationTurn]
    /// Every page on screen at submission, focused pane first — a split view
    /// contributes each of its panes, not just the focused one.
    let currentPageTabIDs: [UUID]
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
    var quotedSelections: [AISidebarSelectionContext] = []
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
