import SwiftUI

/// Native developer toolbar shown for local development pages. It remains
/// neutral chrome so Space identity colors stay in the passive content layer.
internal struct DeveloperToolbar: View {
    let url: URL
    let urlText: String
    /// The page's own title and site icon, handed to the share sheet so its
    /// link preview draws complete instead of filling in after a fetch.
    let pageTitle: String
    let faviconData: Data?
    /// The interface lanes covering the card's edges. The striped surface
    /// spans the full card, but content placed under a lane is masked away
    /// with it, so the URL field and controls stay inside the visible run.
    let contentInsets: BrowserInterfaceInsets
    /// Non-nil under the "Above the Page" placement, where the sidebar header
    /// has given up its navigation cluster: the developer bar then carries the
    /// same leading controls the address strip does, so a local-development
    /// page is not the one page in that mode without a Back button.
    let leadingControls: TopToolbarLeadingControls?
    /// The routed Share command's token (BrowserStore.sharePickerPresentationID).
    /// The bar answers it only under the "Above the Page" placement — exactly
    /// when it carries the leading controls — because under the sidebar
    /// placement the address pill owns the visible share anchor.
    let sharePresentationID: UUID
    let onSubmitURL: (String) -> Void
    let onToggleChat: () -> Void

    @State private var draftURL = ""
    @State private var hoveredControl: DeveloperToolbarControlKind?
    @State private var isHoveringControlMenu = false
    @State private var sharePicker = SharePickerCoordinator()
    @FocusState private var isURLFieldFocused: Bool

    private var isLocalDevelopment: Bool { url.isLocalDevelopment }

    // One treatment for every developer-mode page. Local development used to
    // wear a brand-blue striped bar (Arc-style); it drew the eye to the chrome
    // instead of the page and read as a different app from every other
    // surface, so the bar now matches the rest of Candoa's chrome and the URL
    // itself says where you are.
    private var foreground: Color {
        InterfaceStyle.sidebarText
    }

    private var currentURL: URL? {
        URL(string: urlText)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let leadingControls {
                leadingControls
                    .buttonTreatment(.content)
                    .foregroundStyle(InterfaceStyle.sidebarIcon)
                    .padding(.trailing, -4)
            }

            TextField("", text: $draftURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.92))
                .tint(AppColor.accent)
                .lineLimit(1)
                .focused($isURLFieldFocused)
                .onSubmit {
                    isURLFieldFocused = false
                    onSubmitURL(draftURL)
                }
                .onExitCommand {
                    draftURL = urlText
                    isURLFieldFocused = false
                }
                .onAppear { draftURL = urlText }
                .onChange(of: urlText) { _, newValue in
                    // Navigation landed: refresh the field, but never clobber
                    // an edit in progress.
                    if !isURLFieldFocused {
                        draftURL = newValue
                    }
                }
                .onChange(of: isURLFieldFocused) { _, isFocused in
                    // Abandoned edits (click away) revert to the live URL.
                    if !isFocused {
                        draftURL = urlText
                    }
                }

            Spacer(minLength: 8)

            // Zen's 8px grid: equal 24pt hit boxes on an 8pt gap, so the
            // optical gap between glyphs stays even.
            HStack(spacing: 8) {
                ForEach(DeveloperToolbarControlKind.allCases) { control in
                    toolbarButton(for: control)
                }
            }
        }
        // The bar's first content needs the same breathing room from the
        // card's edge that the sidebar gives its own address, or it reads as
        // hitting the corner. Icons carry their own hit-box padding, so they
        // start closer in than a bare URL field would.
        .padding(.leading, leadingControls == nil ? 16 : 10)
        .padding(.trailing, 10)
        .padding(.leading, contentInsets.leading)
        .padding(.trailing, contentInsets.trailing)
        // Matching the address strip keeps the page's top edge in one place
        // whichever bar a tab gets.
        .frame(height: leadingControls == nil ? 30 : TopAddressBar.height)
        .frame(maxWidth: .infinity)
        .background(Rectangle().fill(.regularMaterial))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(InterfaceStyle.sidebarSeparator)
                .frame(height: 1)
        }
        .onChange(of: sharePresentationID) { _, _ in
            guard leadingControls != nil else { return }
            perform(.share)
        }
    }

    private func toolbarButton(for control: DeveloperToolbarControlKind) -> some View {
        Button {
            perform(control)
        } label: {
            Image(systemName: control.symbolName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    foreground.opacity(hoveredControl == control ? 0.95 : 0.72)
                )
                .offset(y: control.inkCorrection)
                .frame(width: 24, height: 24)
                .background(foreground.opacity(hoveredControl == control ? 0.12 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .background {
            if control == .share {
                SharePickerAnchor(coordinator: sharePicker)
            }
        }
        .onHover { isHovering in
            hoveredControl = isHovering ? control : nil
        }
        .help(control.help)
    }

    private func perform(_ control: DeveloperToolbarControlKind) {
        switch control {
        case .share:
            guard let currentURL else { break }
            sharePicker.present(
                url: currentURL,
                title: pageTitle,
                faviconData: faviconData
            ) {}
        case .chat:
            onToggleChat()
        }
    }

}

/// The developer bar's controls. Three, fixed: the bar used to let people
/// choose from a longer list, but everything else it offered has its own home
/// — Capture Page in the menu bar, Extensions in the sidebar header, Split
/// View on its shortcut, Developer Mode in the palette and the address pill's
/// context menu — so the chooser only added a knob and a fourth icon.
private enum DeveloperToolbarControlKind: String, CaseIterable, Identifiable {
    case share
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .share:
            return String(localized: "Share")
        case .chat:
            return String(localized: "Chat")
        }
    }

    var symbolName: String {
        switch self {
        case .share:
            return "square.and.arrow.up"
        case .chat:
            return "bubble.left"
        }
    }

    /// Symbols centered in equal frames still read crooked, and matching their
    /// ink boxes is not enough: the eye centers on where the ink's *weight*
    /// falls. Rendered at 11.5pt semibold in a 24pt frame, square.and.arrow.up
    /// boxes at 12.47 but carries its mass in the tray, centroid 13.26;
    /// bubble.left boxes dead center at 12.00 while its thin tail leaves the
    /// body's mass high, centroid 11.27. Box-aligned, the bubble therefore
    /// reads lifted. Each correction centers the midpoint of box and centroid
    /// — the optical center — on the frame, rounded to the half point so the
    /// nudge lands on a whole device pixel: share -0.87 → -1, chat +0.36 → +½.
    var inkCorrection: CGFloat {
        switch self {
        case .share:
            return -1
        case .chat:
            return 0.5
        }
    }

    var shortcutText: String {
        let caps = ShortcutKeyCaps.current(for: shortcutDefinition).joined()
        return caps.isEmpty ? String(localized: "Set in Settings > Shortcuts") : caps
    }

    private var shortcutDefinition: ShortcutDefinition {
        switch self {
        case .share: return .sharePage
        case .chat: return .toggleAISidebar
        }
    }

    var help: String {
        "\(title)\n\(shortcutText)"
    }
}
