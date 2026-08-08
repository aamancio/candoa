import Foundation
import SwiftUI

internal struct SpaceIconOption: Identifiable {
    let symbolName: String
    let title: String

    init(symbolName: String, title: String) {
        self.symbolName = symbolName
        self.title = title
    }

    init(emoji: String, title: String) {
        self.symbolName = Self.emojiPrefix + emoji
        self.title = title
    }

    var id: String { symbolName }

    var emoji: String? {
        Self.emoji(from: symbolName)
    }

    static func emoji(from symbolName: String) -> String? {
        guard symbolName.hasPrefix(emojiPrefix) else { return nil }
        return String(symbolName.dropFirst(emojiPrefix.count))
    }

    private static let emojiPrefix = BrowserSpace.emojiSymbolPrefix
}

internal enum SpaceIconPickerMode: String, CaseIterable, Identifiable {
    case emojis
    case symbols
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emojis:
            return "Emojis"
        case .symbols:
            return "Symbols"
        case .icons:
            return "Icons"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .emojis:
            return String(localized: "Search emojis")
        case .symbols, .icons:
            return String(localized: "Search icons")
        }
    }
}

internal enum SpaceComposerMode: Equatable {
    case create
    case initial
    case edit

    var defaultName: String {
        switch self {
        case .initial:
            return String(localized: "Personal")
        case .create, .edit:
            return ""
        }
    }

    var title: String {
        switch self {
        case .create, .initial:
            return String(localized: "Create a Space")
        case .edit:
            return String(localized: "Edit Space")
        }
    }

    var subtitle: String {
        switch self {
        case .create, .initial:
            return String(localized: "Spaces organize your tabs and sessions.")
        case .edit:
            return String(localized: "Update this Space's name, icon, and theme.")
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .create, .initial:
            return BrowserCommandTitles.createSpace
        case .edit:
            return String(localized: "Save Changes")
        }
    }
}

internal enum SpaceDataMode: String, CaseIterable, Identifiable {
    case isolated
    case shareCurrent
    case personal
    case work
    case banking
    case shopping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolated:
            return "Default"
        case .shareCurrent:
            return "Current"
        case .personal:
            return "Personal"
        case .work:
            return "Work"
        case .banking:
            return "Banking"
        case .shopping:
            return "Shopping"
        }
    }

    var detail: String {
        switch self {
        case .isolated:
            return String(localized: "Separate browsing session")
        case .shareCurrent:
            return String(localized: "Share active Space session")
        case .personal:
            return String(localized: "Shared personal profile")
        case .work:
            return String(localized: "Shared work profile")
        case .banking:
            return String(localized: "Shared finance profile")
        case .shopping:
            return String(localized: "Shared shopping profile")
        }
    }

    var symbolName: String {
        switch self {
        case .isolated:
            return "person.crop.circle"
        case .shareCurrent:
            return "link"
        case .personal:
            return "person.crop.circle.fill"
        case .work:
            return "briefcase.fill"
        case .banking:
            return "dollarsign.circle.fill"
        case .shopping:
            return "cart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .isolated:
            return .blue
        case .shareCurrent:
            return .green
        case .personal:
            return .cyan
        case .work:
            return .orange
        case .banking:
            return Color(red: 0.39, green: 0.82, blue: 0.18)
        case .shopping:
            return .pink
        }
    }

    func dataStoreID(current: UUID?) -> UUID {
        switch self {
        case .isolated:
            return UUID()
        case .shareCurrent:
            return current ?? UUID()
        case .personal:
            return UUID(uuidString: "69E60654-3E84-4761-87DA-B13A2C7195E3")!
        case .work:
            return UUID(uuidString: "3ED24A8B-6573-46BE-9059-8E8E331F0143")!
        case .banking:
            return UUID(uuidString: "28166B44-6387-4216-9EAE-39A569C6014D")!
        case .shopping:
            return UUID(uuidString: "72BC27D2-3D02-459A-A0AF-98036B15CF13")!
        }
    }
}
