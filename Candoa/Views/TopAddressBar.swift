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
    let onToggleSidebar: () -> Void

    @State private var isHovering = false
    @State private var sharePicker = SharePickerCoordinator()

    /// Dia's proportions: tall enough that 24pt controls sit in the strip
    /// with air around them rather than filling it edge to edge.
    static let height: CGFloat = 38

    private var addressText: String {
        guard let url else { return BrowserDefaults.addressPlaceholder }
        return url.displayDomainText
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

            Spacer(minLength: 4)

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
        .background(Rectangle().fill(.regularMaterial))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(InterfaceStyle.sidebarSeparator)
                .frame(height: 1)
        }
        .onHover { isHovering = $0 }
        // The routed Share command (menu, shortcut, palette): under the "Above
        // the Page" placement this strip owns the visible share anchor.
        .onChange(of: store.sharePickerPresentationID) { _, _ in
            presentSharePicker()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("top-address-bar")
    }

    private func presentSharePicker() {
        guard let url else { return }
        let tab = store.activeTab
        sharePicker.present(
            url: url,
            title: tab?.title,
            faviconData: tab?.faviconData
        ) {}
    }

    /// The lock and the address read as one target, the way the sidebar pill
    /// pairs them: the lock opens Site Info, the text opens the command bar.
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
                    Text(addressText)
                        .font(.system(size: 13))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, url == nil ? 6 : 4)
                .padding(.trailing, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .help(BrowserDefaults.addressPlaceholder)
            .accessibilityLabel("Address")
            .accessibilityIdentifier("top-address-button")
        }
    }

    private var shareButton: some View {
        Button {
            presentSharePicker()
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .toolbarIconButton()
        .background(SharePickerAnchor(coordinator: sharePicker))
        .shortcutTooltip("Share", shortcut: .sharePage)
        .accessibilityIdentifier("top-share-url-button")
        // Not 0: fully transparent views stop hit-testing, and the button
        // must keep its click footprint while visually absent.
        .opacity(isHovering ? 1 : 0.02)
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }

    /// Dia's trailing "Chat" pill: the one control on the strip that carries
    /// its name, because it opens a panel rather than acting on the page.
    private var chatButton: some View {
        Button {
            store.requestAISidebarToggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11.5, weight: .semibold))
                    // The bubble's thin tail leaves its mass high, so a
                    // box-centered glyph reads lifted beside the label.
                    .offset(y: 0.5)
                Text("Chat")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(InterfaceStyle.sidebarText.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                InterfaceStyle.sidebarControlFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonTreatment(.content)
        .shortcutTooltip("Chat", shortcut: .toggleAISidebar)
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
        }
    }
}
