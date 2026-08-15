import SwiftUI

/// The persistent address strip above the page for people who chose the
/// "Top" placement (`AddressBarPlacement.top`).
///
/// It is the sidebar pill relocated, not a second address surface: the lock
/// opens Site Info, the address opens the command bar, and the hover control
/// shares the page — the same three affordances, in the slot the developer
/// bar occupies on local-development pages (which keep that bar instead).
/// The sidebar hides its own pill while this strip is shown.
struct TopAddressBar: View {
    @ObservedObject var store: BrowserStore
    let url: URL?
    /// The interface lanes covering the strip's edges, matching the developer
    /// bar so both start at the same visible run.
    let contentInsets: BrowserInterfaceInsets

    @State private var isHovering = false
    @State private var sharePicker = SharePickerCoordinator()

    private var addressText: String {
        guard let url else { return BrowserDefaults.addressPlaceholder }
        if let host = url.host(percentEncoded: false) {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return url.absoluteString
    }

    private var siteInfoSymbol: String {
        guard let url else { return "magnifyingglass" }
        if url.isFileURL { return "doc" }
        return url.scheme?.lowercased() == "https" ? "lock" : "lock.slash"
    }

    var body: some View {
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

                    Text(addressText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .padding(.leading, url == nil ? 10 : 6)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .help(BrowserDefaults.addressPlaceholder)
            .accessibilityLabel("Address")
            .accessibilityIdentifier("top-address-button")

            if let url {
                Button {
                    let tab = store.activeTab
                    sharePicker.present(
                        url: url,
                        title: tab?.title,
                        faviconData: tab?.faviconData
                    ) {}
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(InterfaceStyle.sidebarIcon)
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonTreatment(.content)
                .background(SharePickerAnchor(coordinator: sharePicker))
                .help("Share")
                .accessibilityLabel("Share")
                .accessibilityIdentifier("top-share-url-button")
                // Not 0: fully transparent views stop hit-testing, and the
                // button must keep its click footprint while visually absent.
                .opacity(isHovering ? 1 : 0.02)
                .animation(.easeOut(duration: 0.10), value: isHovering)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.leading, contentInsets.leading)
        .padding(.trailing, contentInsets.trailing)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Rectangle().fill(.regularMaterial))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(InterfaceStyle.sidebarSeparator)
                .frame(height: 1)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("top-address-bar")
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
                .frame(width: 18, height: 30)
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
