import SwiftUI

/// The leading half of a toolbar above the page: the sidebar toggle, then
/// back, forward, and reload. Shared by the address strip and the developer
/// bar, which occupy the same slot on different pages and must present the
/// same controls in the same order.
internal struct TopToolbarLeadingControls: View {
    @ObservedObject var store: BrowserStore
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // The toggle stays here whether the sidebar is open or away, the
            // way Dia keeps it: the sidebar header gives its own up under
            // this placement, so the control never moves out from under the
            // pointer just because the sidebar it opened is now on screen.
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
            }
            .toolbarIconButton()
            .shortcutTooltip(
                isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                shortcut: .toggleSidebar
            )
            .accessibilityIdentifier("top-sidebar-toggle-button")

            BrowserNavigationControls(store: store)
        }
    }
}

/// The toolbar above the page for people who chose the "Above the Page"
/// placement (`AddressBarPlacement.top`).
///
/// It is laid out the way Dia lays its toolbar out — navigation at the leading
/// edge, the address reading as plain text beside it, and Eli at the trailing
/// edge — because the placement moves the whole toolbar out of the sidebar,
/// not just the address. The sidebar hides its own pill and its navigation
/// controls while this strip is shown, so exactly one copy of each is on
/// screen. Local-development pages keep the developer bar, which grows the
/// same navigation cluster under this placement.
struct TopAddressBar: View {
    @ObservedObject var store: BrowserStore
    let url: URL?
    /// The interface lanes covering the strip's edges, matching the developer
    /// bar so both start at the same visible run.
    let contentInsets: BrowserInterfaceInsets
    /// Whether the sidebar is pinned open. The strip owns the toggle either
    /// way under this placement; this only decides whether it offers to show
    /// or to hide.
    let isSidebarVisible: Bool
    /// While the window chrome wears the page's own color, the strip trades
    /// its material for that tint and its neutral separator and hover fills
    /// for the tint's darker shades, the way Dia derives its toolbar's
    /// landmarks from the worn color. Nil restores the neutral treatments.
    let chromeTint: TopBarChromeTint?
    let onToggleSidebar: () -> Void

    @State private var isAddressHovered = false
    @State private var sharePicker = SharePickerCoordinator()
    /// The window's own scheme — read above the re-schemed subtree, so the
    /// untinted strip and the Site Info popover stay with the window.
    @Environment(\.colorScheme) private var windowScheme

    /// Dia's proportions: tall enough that 24pt controls sit in the strip
    /// with air around them rather than filling it edge to edge.
    static let height: CGFloat = 38

    /// Dia's address hierarchy: the domain reads clear, everything around it
    /// stays passive — an insecure scheme dimmed before it, and the page's
    /// title dimmed after a " / " — so the one word that says where you are
    /// is the one word that pops. Verbatim segments: URLs and titles are
    /// data, not catalog strings.
    private var addressDisplay: Text {
        guard let url else {
            return Text(BrowserDefaults.addressPlaceholder)
                .foregroundColor(InterfaceStyle.sidebarTextSecondary)
        }

        let passive = InterfaceStyle.sidebarTextSecondary.opacity(0.8)
        var display = Text(verbatim: "")
        if url.scheme?.lowercased() == "http" {
            display = display + Text(verbatim: "http://").foregroundColor(passive)
        }
        display = display + Text(verbatim: url.displayDomainText)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(InterfaceStyle.sidebarText)

        let title = store.activeTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, title.localizedCaseInsensitiveCompare(url.displayDomainText) != .orderedSame {
            display = display
                + Text(verbatim: " / ").foregroundColor(passive)
                + Text(verbatim: title).foregroundColor(passive)
        }
        return display
    }

    private var siteInfoSymbol: String {
        guard let url else { return "magnifyingglass" }
        if url.isFileURL { return "doc" }
        return url.scheme?.lowercased() == "https" ? "lock" : "lock.slash"
    }

    var body: some View {
        HStack(spacing: 4) {
            TopToolbarLeadingControls(
                store: store,
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: onToggleSidebar
            )

            addressButton
                .padding(.leading, 6)

            if url != nil {
                shareButton
            }

            chatButton
        }
        .buttonTreatment(.content)
        .foregroundStyle(InterfaceStyle.sidebarIcon)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.leading, contentInsets.leading)
        .padding(.trailing, contentInsets.trailing)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .opacity(chromeTint == nil ? 1 : 0)
                chromeTint?.surface ?? Color.clear
            }
            .animation(.easeInOut(duration: 0.28), value: chromeTint)
        )
        .overlay(alignment: .bottom) {
            // The strip keeps its bottom border while tinted — as a darker
            // shade of the worn color, the way Dia edges its toolbar.
            Rectangle()
                .fill(chromeTint?.border ?? InterfaceStyle.sidebarSeparator)
                .frame(height: 1)
                .animation(.easeInOut(duration: 0.28), value: chromeTint)
        }
        // The worn color decides the strip's labels, not the window: a dark
        // window still shows dark text on a light page's white bar (Dia
        // flips its toolbar text per site the same way).
        .environment(\.colorScheme, chromeTint?.foregroundScheme ?? windowScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("top-address-bar")
    }

    /// The lock and the address read as one target, the way the sidebar pill
    /// pairs them: the lock opens Site Info, the text opens the command bar.
    /// The target spans the strip's whole free run — clicking the empty
    /// space right of the address must edit it, exactly like a real URL
    /// field — and hovering fills that run the way Dia's field fills, with
    /// a darker shade of the worn page color when the strip is tinted.
    private var addressButton: some View {
        HStack(spacing: 0) {
            if let url {
                siteInfoButton(for: url)
            }

            Button {
                store.focusAddressBar()
            } label: {
                HStack(spacing: 8) {
                    if url == nil {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(InterfaceStyle.sidebarIcon)
                    }

                    // Lighter than the sidebar pill's semibold: on the strip
                    // the address is a label beside the controls, not the
                    // one thing in a lane, and Dia's reads the same way.
                    addressDisplay
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, url == nil ? 6 : 4)
                .padding(.trailing, 6)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .help(BrowserDefaults.addressPlaceholder)
            .accessibilityLabel("Address")
            .accessibilityIdentifier("top-address-button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isAddressHovered
                        ? (chromeTint?.controlFill ?? InterfaceStyle.sidebarControlFill)
                        : Color.clear
                )
        )
        .onHover { isAddressHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isAddressHovered)
    }

    private var shareButton: some View {
        Button {
            guard let url else { return }
            let tab = store.activeTab
            sharePicker.present(
                url: url,
                title: tab?.title,
                faviconData: tab?.faviconData
            ) {}
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .toolbarIconButton()
        .background(SharePickerAnchor(coordinator: sharePicker))
        .help("Share")
        .accessibilityLabel("Share")
        .accessibilityIdentifier("top-share-url-button")
    }

    /// A plain icon like the strip's other controls (and the developer
    /// bar's), not a labeled pill — the strip stays a row of quiet glyphs.
    private var chatButton: some View {
        Button {
            store.requestAISidebarToggle()
        } label: {
            Image(systemName: "bubble.left")
                // The bubble's thin tail leaves its mass high, so a
                // box-centered glyph reads lifted otherwise.
                .offset(y: 0.5)
        }
        .toolbarIconButton()
        .shortcutTooltip("Chat", shortcut: .toggleAISidebar)
        .accessibilityLabel("Chat")
        .accessibilityIdentifier("top-chat-button")
    }

    /// The lock doubles as the Site Info trigger, the same pairing the sidebar
    /// pill uses, so the popover keeps one home wherever the address is shown.
    private func siteInfoButton(for url: URL) -> some View {
        Button {
            store.isSiteInfoPopoverPresented.toggle()
        } label: {
            Image(systemName: siteInfoSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InterfaceStyle.sidebarIcon)
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .help("Site Info")
        .accessibilityLabel("Site Info")
        .accessibilityIdentifier("top-site-info-button")
        .popover(isPresented: $store.isSiteInfoPopoverPresented, arrowEdge: .bottom) {
            SiteInfoPopoverView(
                store: store,
                url: url,
                tabID: store.activeTab?.id,
                onShowPrivacyReport: {
                    // Popover teardown and sheet presentation must not share a
                    // transaction (two-beat handoff): presenting while the
                    // popover is still dismissing detaches the sheet.
                    store.isSiteInfoPopoverPresented = false
                    CATransaction.setCompletionBlock { [weak store] in
                        store?.isPrivacyReportPresented = true
                    }
                }
            )
            // The popover is the window's, not the tinted strip's: its
            // chrome renders in the window appearance, so its content must
            // not inherit the strip's re-schemed environment.
            .environment(\.colorScheme, windowScheme)
        }
    }
}
