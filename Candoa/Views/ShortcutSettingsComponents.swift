import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @State private var searchText = ""

    private var filteredDefinitions: [ShortcutDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ShortcutDefinition.allCases }
        return ShortcutDefinition.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                $0.category.localizedCaseInsensitiveContains(query) ||
                $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("Type a feature name or shortcut", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }

                SettingsCard {
                    if filteredDefinitions.isEmpty {
                        Text("No shortcuts found.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ForEach(Array(filteredDefinitions.enumerated()), id: \.element.id) { index, definition in
                            ShortcutSettingsRow(definition: definition)

                            if index < filteredDefinitions.count - 1 {
                                SettingsDivider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }

                Text("Custom shortcut capture is local to this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
        }
    }
}

internal struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 640)
                .padding(.horizontal, 48)
                .padding(.top, 28)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

internal struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
    }
}

internal struct SettingsRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let accessory: Accessory

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Guaranteed air between a long subtitle and the trailing
            // control, so text never crowds a picker at the pane's width.
            Spacer(minLength: 32)

            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

internal struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
    }
}

internal struct SettingsToggleRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(systemImage: systemImage, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

/// A compact labeled text field for rows that are self-explanatory from their
/// label — a profile's city needs no sentence under it, and eleven subtitles
/// would bury the section.
internal struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(width: 150, alignment: .leading)

            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

internal struct SettingsPickerOption: Identifiable {
    let id: String
    let title: String
}

internal struct SettingsPickerRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @Binding var selection: String
    let options: [SettingsPickerOption]

    var body: some View {
        SettingsRow(systemImage: systemImage, title: title, subtitle: subtitle) {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .flexibleControlSizing()
            .frame(width: 190)
        }
    }
}

/// Fitted pop-ups (macOS 26's default) hug their longest option, so each
/// row's pill lands at a different offset inside the reserved slot. Safari
/// stretches its pop-ups to one shared width; flexible sizing makes the
/// control fill the frame so every column edge aligns. Earlier systems
/// stretch pop-ups natively, so no fallback work is needed.
internal struct FlexibleControlSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonSizing(.flexible)
        } else {
            content
        }
    }
}

extension View {
    func flexibleControlSizing() -> some View {
        modifier(FlexibleControlSizing())
    }
}

internal struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.primary.opacity(0.10))
    }
}

internal struct SettingsStatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

internal struct SettingsShortcutPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

internal struct SettingsIdentityCard: View {
    let displayName: String
    let emailAddress: String
    let initials: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.04, green: 0.68, blue: 0.64),
                                Color(red: 0.15, green: 0.50, blue: 0.84),
                                Color(red: 0.44, green: 0.25, blue: 0.70)
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
                    .frame(height: 210)
                    .overlay(alignment: .bottomLeading) {
                        Circle()
                            .fill(.regularMaterial)
                            .frame(width: 86, height: 86)
                            .overlay {
                                Text(initials)
                                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                            }
                            .padding(18)
                    }

                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(displayName.isEmpty ? "Candoa User" : displayName)
                    .font(.system(size: 28, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(emailAddress.isEmpty ? "Local profile" : emailAddress)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(20)
        }
        .frame(height: 392)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

internal struct SearchProviderSettingsRow: View {
    let provider: SearchProvider

    private var aliasText: String {
        provider.aliases.prefix(4).joined(separator: ", ")
    }

    var body: some View {
        SettingsRow(
            systemImage: provider.symbolName,
            title: provider.name,
            subtitle: aliasText
        ) {
            Text(provider.homeURL.host ?? provider.homeURL.absoluteString)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .trailing)
        }
    }
}

internal struct ShortcutSettingsRow: View {
    let definition: ShortcutDefinition

    @AppStorage private var storedShortcut: String
    @State private var isRecording = false

    private var displayShortcut: String {
        if storedShortcut == ShortcutDefinition.removedValue {
            return "None"
        }

        return storedShortcut.isEmpty ? definition.defaultShortcut : storedShortcut
    }

    private var isRemoved: Bool {
        storedShortcut == ShortcutDefinition.removedValue
    }

    init(definition: ShortcutDefinition) {
        self.definition = definition
        _storedShortcut = AppStorage(wrappedValue: "", definition.storageKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: definition.symbolName)
                .foregroundStyle(.secondary)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(definition.title)
                    .font(.system(size: 13))

                Text(definition.category)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isRecording = true
            } label: {
                Text(isRecording ? "Press Keys" : displayShortcut)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 132)
            }
            .buttonTreatment(.secondary)
            .controlSize(.small)
            .help("Set Shortcut")

            Button {
                storedShortcut = isRemoved ? "" : ShortcutDefinition.removedValue
            } label: {
                Image(systemName: isRemoved ? "plus" : "minus")
                    .frame(width: 16, height: 16)
            }
            .buttonTreatment(.chrome)
            .controlSize(.small)
            .help(isRemoved ? "Restore Shortcut" : "Remove Shortcut")

            Button {
                storedShortcut = ""
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonTreatment(.chrome)
            .controlSize(.small)
            .disabled(storedShortcut.isEmpty)
            .help("Reset to Default")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if isRecording {
                ShortcutCaptureView { shortcut in
                    storedShortcut = shortcut
                    isRecording = false
                } onCancel: {
                    isRecording = false
                }
            }
        }
    }
}

internal struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private let onCapture: (String) -> Void
        private let onCancel: () -> Void
        private var monitor: Any?

        init(onCapture: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func install() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                if event.keyCode == 53 {
                    onCancel()
                    return nil
                }

                guard let shortcut = Self.shortcutString(for: event) else {
                    NSSound.beep()
                    return nil
                }

                onCapture(shortcut)
                return nil
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func shortcutString(for event: NSEvent) -> String? {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])

            guard !modifiers.isEmpty else { return nil }

            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Control") }
            if modifiers.contains(.option) { parts.append("Option") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Command") }

            let key = keyString(for: event)
            guard !key.isEmpty else { return nil }
            parts.append(key)
            return parts.joined(separator: "-")
        }

        private static func keyString(for event: NSEvent) -> String {
            switch event.keyCode {
            case 48: return "Tab"
            case 123: return "Left"
            case 124: return "Right"
            case 125: return "Down"
            case 126: return "Up"
            default:
                return event.charactersIgnoringModifiers?.uppercased() ?? ""
            }
        }
    }
}

enum ShortcutDefinition: String, CaseIterable, Identifiable {
    static let removedValue = "none"

    case newTab
    case closeCurrentTab
    case reopenClosedTab
    case focusAddressBar
    case commandBar
    case copyURL
    case copyURLAsMarkdown
    case sharePage
    case captureFullPage
    case pinOrUnpinTab
    case toggleSidebar
    case toggleAISidebar
    case clearUnpinnedTabs
    case goBack
    case goForward
    case nextRecentTab
    case previousRecentTab
    case nextTab
    case previousTab
    case nextSpace
    case previousSpace
    case toggleSplitView
    case splitLayoutHorizontal
    case splitLayoutVertical
    case zoomSplitPane
    case focusNextSplitPane
    case focusPreviousSplitPane
    case unsplitPane
    case splitWithTab
    case findInPage
    case findNext
    case findPrevious
    case reloadTab
    case reloadTabFromOrigin
    case stopLoading
    case zoomIn
    case zoomOut
    case resetZoom
    case reportAProblem
    case getExtensions

    var id: String { rawValue }
    var storageKey: String { "CandoaShortcut.\(rawValue)" }

    var title: String {
        switch self {
        case .newTab: return BrowserCommandTitles.newTab
        case .closeCurrentTab: return BrowserCommandTitles.closeCurrentTab
        case .reopenClosedTab: return BrowserCommandTitles.reopenClosedTab
        case .focusAddressBar: return BrowserCommandTitles.focusAddressBar
        case .commandBar: return BrowserCommandTitles.commandBar
        case .copyURL: return BrowserCommandTitles.copyURL
        case .copyURLAsMarkdown: return BrowserCommandTitles.copyURLAsMarkdown
        case .sharePage: return BrowserCommandTitles.share
        case .captureFullPage: return String(localized: "Capture Page")
        case .pinOrUnpinTab: return BrowserCommandTitles.pinOrUnpinTab
        case .toggleSidebar: return BrowserCommandTitles.toggleSidebar
        case .toggleAISidebar: return BrowserCommandTitles.toggleAISidebar
        case .clearUnpinnedTabs: return BrowserCommandTitles.clearUnpinnedTabs
        case .goBack: return BrowserCommandTitles.back
        case .goForward: return BrowserCommandTitles.forward
        case .nextRecentTab: return String(localized: "Next Recent Tab")
        case .previousRecentTab: return String(localized: "Previous Recent Tab")
        case .nextTab: return BrowserCommandTitles.nextTab
        case .previousTab: return BrowserCommandTitles.previousTab
        case .nextSpace: return BrowserCommandTitles.nextSpace
        case .previousSpace: return BrowserCommandTitles.previousSpace
        case .toggleSplitView: return BrowserCommandTitles.splitViewMenu
        case .splitLayoutHorizontal: return BrowserCommandTitles.splitLayoutHorizontal
        case .splitLayoutVertical: return BrowserCommandTitles.splitLayoutVertical
        case .zoomSplitPane: return BrowserCommandTitles.zoomSplitPane
        case .focusNextSplitPane: return BrowserCommandTitles.focusNextSplitPane
        case .focusPreviousSplitPane: return BrowserCommandTitles.focusPreviousSplitPane
        case .unsplitPane: return BrowserCommandTitles.unsplitPane
        case .splitWithTab: return BrowserCommandTitles.splitWithTab
        case .findInPage: return BrowserCommandTitles.findInPage
        case .findNext: return BrowserCommandTitles.findNext
        case .findPrevious: return BrowserCommandTitles.findPrevious
        case .reloadTab: return BrowserCommandTitles.reloadTab
        case .reloadTabFromOrigin: return BrowserCommandTitles.reloadTabFromOrigin
        case .stopLoading: return BrowserCommandTitles.stopLoading
        case .zoomIn: return BrowserCommandTitles.zoomIn
        case .zoomOut: return BrowserCommandTitles.zoomOut
        case .resetZoom: return BrowserCommandTitles.resetZoom
        case .reportAProblem: return BrowserCommandTitles.reportAProblem
        case .getExtensions: return BrowserCommandTitles.getExtensions
        }
    }

    var category: String {
        switch self {
        case .reportAProblem:
            return String(localized: "Help")
        case .getExtensions:
            return String(localized: "Extensions")
        case .captureFullPage:
            return String(localized: "Capture")
        case .toggleAISidebar:
            return String(localized: "AI")
        case .toggleSplitView, .splitLayoutHorizontal, .splitLayoutVertical, .zoomSplitPane,
             .focusNextSplitPane, .focusPreviousSplitPane, .unsplitPane, .splitWithTab:
            return String(localized: "Split View")
        case .goBack, .goForward, .nextRecentTab, .previousRecentTab, .nextTab, .previousTab, .nextSpace, .previousSpace:
            return String(localized: "Navigation")
        case .findInPage, .findNext, .findPrevious:
            return String(localized: "Search & Find")
        case .zoomIn, .zoomOut, .resetZoom:
            return String(localized: "Media & Display")
        default:
            return String(localized: "Browser")
        }
    }

    var defaultShortcut: String {
        switch self {
        case .newTab: return "Command-T"
        case .closeCurrentTab: return "Command-W"
        case .reopenClosedTab: return "Shift-Command-T"
        case .focusAddressBar: return "Command-L"
        case .commandBar: return "Option-Command-K"
        case .copyURL: return "Shift-Command-C"
        case .copyURLAsMarkdown: return "Option-Shift-Command-C"
        // Safari ships Share with no shortcut either; the row exists so
        // anyone who shares often can bind one.
        case .sharePage: return "None"
        case .captureFullPage: return "None"
        // Safari gives its own report command no shortcut either; the row
        // exists so anyone who reports often can bind one.
        case .reportAProblem: return "None"
        // No Chrome or Safari precedent to copy — the row exists so anyone
        // who browses the store often can bind one.
        case .getExtensions: return "None"
        case .pinOrUnpinTab: return "Command-D"
        case .toggleSidebar: return "Command-S"
        case .toggleAISidebar: return "Command-E"
        case .clearUnpinnedTabs: return "Shift-Command-K"
        case .goBack: return "Command-Left"
        case .goForward: return "Command-Right"
        case .nextRecentTab: return "Control-Tab"
        case .previousRecentTab: return "Control-Shift-Tab"
        case .nextTab: return "Option-Command-Down"
        case .previousTab: return "Option-Command-Up"
        case .nextSpace: return "Option-Command-Right"
        case .previousSpace: return "Option-Command-Left"
        case .toggleSplitView: return "Command-\\"
        case .splitLayoutHorizontal: return "Control-Command-H"
        case .splitLayoutVertical: return "Control-Command-V"
        // Alex's call: Shift on the split key takes the pane OUT (unsplit),
        // Control zooms — the shifted form pairs with the toggle as its
        // undo, and zoom sits with the other Control-Command pane keys.
        case .zoomSplitPane: return "Control-Command-\\"
        // Brackets step through things elsewhere on the Mac (tabs in
        // Terminal, panes in Xcode), and Control-Command is the split
        // view's own modifier pair (H/V above).
        case .focusNextSplitPane: return "Control-Command-]"
        case .focusPreviousSplitPane: return "Control-Command-["
        case .unsplitPane: return "Shift-Command-\\"
        // The last free modifier on the split key: ⌘\ opens, ⇧⌘\ zooms,
        // ⌃⌘\ unsplits, ⌥⌘\ picks what to split with.
        case .splitWithTab: return "Option-Command-\\"
        case .findInPage: return "Command-F"
        case .findNext: return "Command-G"
        case .findPrevious: return "Shift-Command-G"
        case .reloadTab: return "Command-R"
        case .reloadTabFromOrigin: return "Option-Command-R"
        case .stopLoading: return "Command-."
        case .zoomIn: return "Command-="
        case .zoomOut: return "Command--"
        case .resetZoom: return "Command-0"
        }
    }

    var alternateDefaultShortcuts: [String] {
        switch self {
        case .goBack:
            return ["Command-["]
        case .goForward:
            return ["Command-]"]
        case .zoomIn:
            return ["Shift-Command-="]
        default:
            return []
        }
    }

    var symbolName: String {
        switch self {
        case .closeCurrentTab: return "xmark"
        case .reopenClosedTab: return "arrow.uturn.backward"
        case .captureFullPage: return "camera"
        case .toggleSplitView, .splitLayoutHorizontal: return "rectangle.split.2x1"
        case .splitLayoutVertical: return "rectangle.split.1x2"
        case .zoomSplitPane: return "arrow.up.left.and.arrow.down.right"
        case .focusNextSplitPane: return "rectangle.righthalf.inset.filled.arrow.right"
        case .focusPreviousSplitPane: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .unsplitPane: return "rectangle.portrait.and.arrow.right"
        case .splitWithTab: return "rectangle.split.2x1.fill"
        case .copyURL, .copyURLAsMarkdown: return "link"
        case .sharePage: return "square.and.arrow.up"
        case .findInPage, .findNext, .findPrevious: return "magnifyingglass"
        case .reloadTab: return "arrow.clockwise"
        case .reloadTabFromOrigin: return "arrow.clockwise.circle"
        case .stopLoading: return "xmark.circle"
        case .pinOrUnpinTab: return "pin"
        case .toggleSidebar: return "sidebar.left"
        case .toggleAISidebar: return "sidebar.right"
        case .focusAddressBar: return "text.cursor"
        case .commandBar: return "command"
        case .newTab: return "plus"
        case .clearUnpinnedTabs: return "clear"
        case .goBack: return "chevron.left"
        case .goForward: return "chevron.right"
        case .nextRecentTab, .previousRecentTab: return "control"
        case .nextTab, .previousTab: return "arrow.up.arrow.down"
        case .nextSpace, .previousSpace: return "square.grid.2x2"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .resetZoom: return "1.magnifyingglass"
        case .reportAProblem: return "exclamationmark.bubble"
        case .getExtensions: return "puzzlepiece.extension"
        }
    }

    var searchText: String {
        "\(title) \(category) \(defaultShortcut)"
    }
}

extension ShortcutDefinition {
    /// The person's effective shortcut as a SwiftUI key equivalent, so menu
    /// items can display the same binding the event monitor acts on. Nil when
    /// the shortcut is removed or not representable as a menu equivalent.
    var currentKeyboardShortcut: KeyboardShortcut? {
        let storedShortcut = UserDefaults.standard.string(forKey: storageKey) ?? ""
        guard storedShortcut != Self.removedValue else { return nil }
        return Self.keyboardShortcut(from: storedShortcut.isEmpty ? defaultShortcut : storedShortcut)
    }

    /// What the menu bar prints for commands whose Safari menu shows the
    /// bracket alternate rather than the arrow default: Safari's History
    /// menu displays ⌘[ and ⌘] for Back and Forward while the arrows work
    /// too. At defaults the menu shows that alternate; once the person
    /// rebinds the command it follows their binding, and a removed
    /// shortcut leaves the menu item bare.
    var menuKeyboardShortcut: KeyboardShortcut? {
        let storedShortcut = UserDefaults.standard.string(forKey: storageKey) ?? ""
        guard storedShortcut.isEmpty, let alternate = alternateDefaultShortcuts.last else {
            return currentKeyboardShortcut
        }
        return Self.keyboardShortcut(from: alternate)
    }

    static func keyboardShortcut(from shortcut: String) -> KeyboardShortcut? {
        guard !shortcut.isEmpty, shortcut != "None" else { return nil }

        var components = shortcut.components(separatedBy: "-")
        // A literal "-" key ("Control-Shift--") splits into trailing empty
        // components, same as in ShortcutKeyCaps.
        if components.last == "" {
            components.removeAll { $0.isEmpty }
            components.append("-")
        }
        guard let keyComponent = components.popLast() else { return nil }

        var modifiers: EventModifiers = []
        for component in components {
            switch component {
            case "Control": modifiers.insert(.control)
            case "Option": modifiers.insert(.option)
            case "Shift": modifiers.insert(.shift)
            case "Command": modifiers.insert(.command)
            default: return nil
            }
        }

        let key: KeyEquivalent
        switch keyComponent {
        case "Tab": key = .tab
        case "Left": key = .leftArrow
        case "Right": key = .rightArrow
        case "Up": key = .upArrow
        case "Down": key = .downArrow
        default:
            guard keyComponent.count == 1, let character = keyComponent.lowercased().first else { return nil }
            key = KeyEquivalent(character)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}
