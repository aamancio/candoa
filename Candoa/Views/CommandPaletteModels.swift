import SwiftUI

internal func commandPaletteAccessibilitySlug(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let parts = value
        .lowercased()
        .unicodeScalars
        .map { allowed.contains($0) ? Character($0) : "-" }
    let slug = String(parts)
        .split(separator: "-")
        .joined(separator: "-")
    return slug.isEmpty ? "item" : slug
}

internal struct PaletteCommand: Identifiable {
    /// Identity follows what the row *is* (title, address, action), not
    /// the moment it was built. The list is rebuilt on every keystroke;
    /// a per-build UUID made each rebuild a brand-new row, which reset
    /// the icon's loaded favicon and refetched it — the favicon visibly
    /// blinked on every character typed.
    var id: String {
        "\(action.identityKey)|\(title)|\(detail ?? "")|\(sourceLabel ?? "")"
    }

    let title: String
    var detail: String?
    let symbolName: String
    var faviconData: Data? = nil
    var faviconPageURL: URL? = nil
    var searchText = ""
    var sourceLabel: String? = nil
    var style: PaletteCommandStyle = .generic
    let action: PaletteAction

    /// The person's configured key caps for this command, resolved at read
    /// time so a rebind in Settings ▸ Shortcuts shows on the next palette
    /// open. Empty when the action has no shortcut or it was removed.
    var shortcutKeys: [String] {
        guard let definition = action.shortcutDefinition else { return [] }
        return ShortcutKeyCaps.current(for: definition)
    }

    var provider: SearchProvider? {
        switch style {
        case .provider(let provider), .providerSearch(let provider):
            return provider
        case .generic, .tab, .history:
            return nil
        }
    }

    var showsSwitchToTab: Bool {
        if case .switchTab = action {
            return true
        }

        return false
    }

    var accessibilityLabel: String {
        [title, detail, sourceLabel]
            .compactMap { value in
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedValue?.isEmpty == false ? trimmedValue : nil
            }
            .joined(separator: ", ")
    }
}

internal struct PaletteAutocompleteSuggestion {
    let text: String
    let suffix: String
    let provider: SearchProvider?
    let command: PaletteCommand
}

internal enum PaletteCommandStyle: Equatable {
    case generic
    case tab
    case history
    case provider(SearchProvider)
    case providerSearch(SearchProvider)
}

internal enum PaletteAction {
    case newTab
    case closeCurrentTab
    case duplicateCurrentTab
    case reloadTab
    case toggleSplitView
    case toggleSplitPaneZoom
    case focusSplitPane(Int)
    case unsplitPane
    case createSpace
    case focusAddressBar
    case copyURL
    case copyURLAsMarkdown
    case sharePage
    case setDeveloperMode(Bool)
    case togglePinTab
    case navigate(String)
    case searchProvider(SearchProvider, String)
    case switchTab(UUID)
    case splitWithTab(UUID)
    case splitWithNavigate(String)
    case switchSpace(UUID)
}

internal extension PaletteAction {
    /// A stable description of the action for row identity.
    var identityKey: String {
        switch self {
        case .newTab: return "newTab"
        case .closeCurrentTab: return "closeCurrentTab"
        case .duplicateCurrentTab: return "duplicateCurrentTab"
        case .reloadTab: return "reloadTab"
        case .toggleSplitView: return "toggleSplitView"
        case .toggleSplitPaneZoom: return "toggleSplitPaneZoom"
        case .focusSplitPane(let step): return "focusSplitPane:\(step)"
        case .unsplitPane: return "unsplitPane"
        case .createSpace: return "createSpace"
        case .focusAddressBar: return "focusAddressBar"
        case .copyURL: return "copyURL"
        case .copyURLAsMarkdown: return "copyURLAsMarkdown"
        case .setDeveloperMode(let on): return "setDeveloperMode:\(on)"
        case .togglePinTab: return "togglePinTab"
        case .navigate(let target): return "navigate:\(target)"
        case .searchProvider(let provider, let query): return "search:\(provider.id):\(query)"
        case .switchTab(let id): return "switchTab:\(id.uuidString)"
        case .splitWithTab(let id): return "splitWithTab:\(id.uuidString)"
        case .splitWithNavigate(let target): return "splitWithNavigate:\(target)"
        case .switchSpace(let id): return "switchSpace:\(id.uuidString)"
        }
    }

    /// The rebindable shortcut that fires the same action outside the
    /// palette, so rows can teach it. Actions that only exist inside the
    /// palette (tab/space switching, searches, developer mode) have none.
    var shortcutDefinition: ShortcutDefinition? {
        switch self {
        case .newTab: return .newTab
        case .closeCurrentTab: return .closeCurrentTab
        case .reloadTab: return .reloadTab
        case .toggleSplitView: return .toggleSplitView
        case .toggleSplitPaneZoom: return .zoomSplitPane
        case .focusSplitPane(let step): return step >= 0 ? .focusNextSplitPane : .focusPreviousSplitPane
        case .unsplitPane: return .unsplitPane
        case .focusAddressBar: return .focusAddressBar
        case .copyURL: return .copyURL
        case .copyURLAsMarkdown: return .copyURLAsMarkdown
        case .sharePage: return .sharePage
        case .togglePinTab: return .pinOrUnpinTab
        case .duplicateCurrentTab, .createSpace, .setDeveloperMode, .navigate, .searchProvider,
             .switchTab, .splitWithTab, .splitWithNavigate, .switchSpace:
            return nil
        }
    }
}

internal struct PaletteChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(color)
            .clipShape(Capsule())
            .shadow(color: color.opacity(0.42), radius: 14, y: 2)
            .fixedSize(horizontal: true, vertical: false)
    }
}

internal extension SearchProvider {
    var paletteColor: Color {
        switch id {
        case "google":
            return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "youtube":
            return Color(red: 0.94, green: 0.05, blue: 0.05)
        case "amazon":
            return Color(red: 0.92, green: 0.52, blue: 0.06)
        case "duckduckgo":
            return Color(red: 0.32, green: 0.28, blue: 0.86)
        case "bing":
            return Color(red: 0.07, green: 0.48, blue: 0.60)
        case "brave":
            return Color(red: 0.90, green: 0.26, blue: 0.08)
        case "startpage":
            return Color(red: 0.10, green: 0.36, blue: 0.92)
        case "qwant":
            return Color(red: 0.28, green: 0.42, blue: 0.94)
        case "mojeek":
            return Color(red: 0.08, green: 0.58, blue: 0.30)
        case "swisscows":
            return Color(red: 0.76, green: 0.18, blue: 0.38)
        case "ecosia":
            return Color(red: 0.10, green: 0.55, blue: 0.30)
        case "perplexity":
            return Color(red: 0.12, green: 0.62, blue: 0.65)
        case "kagi":
            return Color(red: 0.95, green: 0.45, blue: 0.22)
        case "yahoo":
            return Color(red: 0.38, green: 0.18, blue: 0.86)
        case "yandex":
            return Color(red: 0.92, green: 0.14, blue: 0.12)
        case "github":
            return Color(red: 0.36, green: 0.36, blue: 0.40)
        case "reddit":
            return Color(red: 1.00, green: 0.33, blue: 0.13)
        case "x":
            return Color(red: 0.12, green: 0.12, blue: 0.14)
        case "spotify":
            return Color(red: 0.12, green: 0.72, blue: 0.32)
        case "chatgpt":
            return Color(red: 0.08, green: 0.58, blue: 0.45)
        case "claude":
            return Color(red: 0.72, green: 0.36, blue: 0.20)
        case "gemini":
            return Color(red: 0.34, green: 0.43, blue: 0.93)
        case "wikipedia":
            return Color(red: 0.25, green: 0.25, blue: 0.27)
        default:
            return Color(red: 0.46, green: 0.30, blue: 0.18)
        }
    }
}
