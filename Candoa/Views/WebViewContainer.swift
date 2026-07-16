import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserChromeInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

struct WebViewContainer: View {
    @ObservedObject var store: BrowserStore
    let visibleChromeInsets: BrowserChromeInsets
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""
    private let surfaceCornerRadius: CGFloat = 12
    private let surfacePadding: CGFloat = 8

    private var spaceTint: Color {
        Color(spaceHex: store.activeThemeColorHexes.first ?? "#8A8F98")
    }

    /// Zen resolves the loading pill's light-dark() from the chrome theme,
    /// not the system: a dark space theme means dark chrome. Nil when the
    /// space is unthemed, falling back to the system appearance.
    private var themeIsDarkChrome: Bool? {
        guard let hex = store.activeThemeColorHexes.first else { return nil }
        return !CandoaChromeStyle.prefersDarkForeground(forSpaceHex: hex)
    }

    var body: some View {
        ZStack {
            if store.isInitialSpaceSetupPresented || store.isCreateSpacePresented {
                SpaceSetupCanvas(
                    hexes: store.activeThemeColorHexes,
                    intensity: store.activeThemeIntensityMultiplier,
                    texture: store.activeThemeTexture
                )
                .padding(.top, surfacePadding)
                .padding(.trailing, surfacePadding)
                .padding(.bottom, surfacePadding)
                .transition(.opacity)
            } else if let tab = store.activeTab {
                let splitTabs = store.activeSplitGroupTabs
                if splitTabs.count >= 2 {
                    HStack(spacing: surfacePadding) {
                        ForEach(splitTabs) { splitTab in
                            browserSurface {
                                webPane(for: splitTab)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(surfacePadding)
                } else {
                    browserSurface {
                        VStack(spacing: 0) {
                            if let url = tab.url,
                               DeveloperModeConfiguration.isEnabled(
                                   for: url,
                                   storedOverrides: developerModeOverrides
                               ) {
                                DeveloperToolbar(
                                    url: url,
                                    urlText: url.localDevelopmentDisplayText,
                                    tintHex: store.activeThemeColorHexes.first,
                                    isSplitViewEnabled: store.isSplitViewEnabled,
                                    onCopyURL: { store.copyActiveTabURL() },
                                    onCapturePage: { store.captureActiveTabPage() },
                                    onToggleSplitView: { store.toggleSplitView() },
                                    onSubmitURL: { store.navigateActiveTab(to: $0) },
                                    onSetDeveloperMode: { store.setDeveloperMode($0, for: url) }
                                )
                            }

                            if tab.url == nil {
                                EmptyTabSurface {
                                    store.openNewTabCommandPalette()
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(CandoaChromeStyle.surfaceFill.opacity(0.72))
                            } else {
                                ActiveWebViewHost(
                                    tab: tab,
                                    store: store,
                                    obscuredContentInsets: webContentInsets
                                )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(CandoaChromeStyle.surfaceFill.opacity(0.72))
                                    .overlay(alignment: .top) {
                                        PageLoadingPill(
                                            isLoading: tab.isLoading,
                                            tint: spaceTint,
                                            themeIsDark: themeIsDarkChrome
                                        )
                                        .padding(.top, 2)
                                        .id(tab.id)
                                    }
                            }
                        }
                    }
                    .padding(surfacePadding)
                }
            } else {
                SpaceSetupCanvas(
                    hexes: store.activeThemeColorHexes,
                    intensity: store.activeThemeIntensityMultiplier,
                    texture: store.activeThemeTexture
                )
                .padding(surfacePadding)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            splitDropSurfaceOverlay
        }
        .overlay(alignment: .topTrailing) {
            if store.isFindBarPresented {
                FindBarView(store: store)
                    .padding(.top, surfacePadding + 10)
                    .padding(.trailing, surfacePadding + 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: store.isFindBarPresented)
        .modifier(
            LegacyBrowserChromeMaskModifier(
                insets: visibleChromeInsets,
                surfaceCornerRadius: surfaceCornerRadius,
                surfacePadding: surfacePadding
            )
        )
    }

    @ViewBuilder
    private var splitDropSurfaceOverlay: some View {
        if store.draggedTabID != nil, store.activeTab != nil, !store.isSpaceSetupPresented {
            GeometryReader { proxy in
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [UTType.text],
                            delegate: BrowserSurfaceSplitDropDelegate(
                                store: store,
                                size: proxy.size
                            )
                        )

                    if let preview = store.splitDropPreview {
                        SplitDropPreviewOverlay(
                            store: store,
                            preview: preview,
                            cornerRadius: surfaceCornerRadius
                        )
                        .padding(surfacePadding)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: store.splitDropPreview)
            }
        }
    }

    private func browserSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                    .stroke(CandoaChromeStyle.surfaceBorder, lineWidth: 1)
            }
            .background(
                RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                    .fill(CandoaChromeStyle.surfaceFill.opacity(0.74))
            )
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.10), radius: 16, x: -2, y: 2)
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    private var webContentInsets: BrowserChromeInsets {
        BrowserChromeInsets(
            leading: max(0, visibleChromeInsets.leading - surfacePadding),
            trailing: max(0, visibleChromeInsets.trailing - surfacePadding)
        )
    }

    private func splitPaneInsets(for tab: BrowserTab, in tabs: [BrowserTab]) -> BrowserChromeInsets {
        BrowserChromeInsets(
            leading: tab.id == tabs.first?.id ? webContentInsets.leading : 0,
            trailing: tab.id == tabs.last?.id ? webContentInsets.trailing : 0
        )
    }

    private struct FindBarView: View {
        @ObservedObject var store: BrowserStore
        @FocusState private var isFieldFocused: Bool

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Find in page", text: $store.findQuery)
                    .textFieldStyle(.plain)
                    .tint(CandoaColor.primary)
                    .frame(width: 190)
                    .focused($isFieldFocused)
                    .accessibilityIdentifier("find-bar-field")
                    .onSubmit { store.findNext() }

                Button {
                    store.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(store.findQuery.isEmpty)
                .help("Find Previous")

                Button {
                    store.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(store.findQuery.isEmpty)
                .help("Find Next")

                Button {
                    store.dismissFindBar()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Done")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CandoaChromeStyle.popoverBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(CandoaChromeStyle.popoverBorder, lineWidth: 1)
            }
            .onAppear { isFieldFocused = true }
            .onExitCommand { store.dismissFindBar() }
            .onChange(of: store.findQuery) { _, _ in
                store.findNext()
            }
        }
    }

    private func webPane(for tab: BrowserTab) -> some View {
        return SplitWebViewHost(
            tab: tab,
            store: store,
            obscuredContentInsets: splitPaneInsets(for: tab, in: store.activeSplitGroupTabs)
        )
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CandoaChromeStyle.surfaceFill.opacity(0.72))
            .overlay(alignment: .top) {
                PageLoadingPill(
                    isLoading: tab.isLoading,
                    tint: spaceTint,
                    themeIsDark: themeIsDarkChrome
                )
                .padding(.top, 2)
                .id(tab.id)
            }
    }
}

private struct LegacyBrowserChromeMaskModifier: ViewModifier {
    let insets: BrowserChromeInsets
    let surfaceCornerRadius: CGFloat
    let surfacePadding: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.mask {
                if insets.leading > 0 || insets.trailing > 0 {
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .padding(.vertical, surfacePadding)
                        .padding(.leading, insets.leading + surfacePadding)
                        .padding(.trailing, insets.trailing + surfacePadding)
                } else {
                    Rectangle()
                }
            }
        }
    }
}

private struct EmptyTabSurface: View {
    let openCommandBar: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: openCommandBar)
        .help(BrowserDefaults.addressPlaceholder)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(BrowserDefaults.addressPlaceholder)
        .accessibilityIdentifier("empty-tab-surface")
    }
}

private struct BrowserSurfaceSplitDropDelegate: DropDelegate {
    let store: BrowserStore
    let size: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedID = store.draggedTabID else { return false }
        return targetTabID(for: info, draggedID: draggedID) != nil
    }

    func dropEntered(info: DropInfo) {
        updatePreview(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(info: info)
        return store.splitDropPreview == nil ? nil : DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.clearSplitDropPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard
            let draggedID = store.draggedTabID,
            let targetID = targetTabID(for: info, draggedID: draggedID)
        else {
            store.clearSplitDropPreview()
            return false
        }

        let sourcePlacement = store.sidebarPlacement(for: draggedID)
        store.splitTab(draggedID, onto: targetID, side: dropSide(for: info))
        store.finishTabDrop(draggedID, from: sourcePlacement, to: sourcePlacement ?? .regular)
        return true
    }

    private func updatePreview(info: DropInfo) {
        guard
            let draggedID = store.draggedTabID,
            let targetID = targetTabID(for: info, draggedID: draggedID)
        else {
            store.clearSplitDropPreview()
            return
        }

        store.updateSplitDropPreview(targetTabID: targetID, side: dropSide(for: info))
    }

    private func targetTabID(for info: DropInfo, draggedID: UUID) -> UUID? {
        store.splitDropTargetTabID(for: dropSide(for: info), draggedID: draggedID)
    }

    private func dropSide(for info: DropInfo) -> SplitTabDropSide {
        info.location.x < size.width / 2 ? .leading : .trailing
    }
}

private struct SplitDropPreviewOverlay: View {
    @ObservedObject var store: BrowserStore
    let preview: SplitTabDropPreview
    let cornerRadius: CGFloat

    private var previewTabs: [BrowserTab] {
        guard
            let draggedID = store.draggedTabID,
            let draggedTab = store.visibleTabsForActiveSpace.first(where: { $0.id == draggedID }),
            let targetTab = store.visibleTabsForActiveSpace.first(where: { $0.id == preview.targetTabID })
        else {
            return []
        }

        var tabs = store.isSplitViewEnabled && store.activeSplitGroupTabs.count >= 2
            ? store.activeSplitGroupTabs
            : [targetTab]
        tabs.removeAll { $0.id == draggedID }

        let targetIndex = tabs.firstIndex { $0.id == preview.targetTabID } ?? tabs.startIndex
        let insertionIndex = preview.side == .leading
            ? targetIndex
            : tabs.index(after: targetIndex)
        tabs.insert(draggedTab, at: insertionIndex)
        return Array(tabs.prefix(BrowserStore.splitViewMaxTabs))
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(previewTabs) { tab in
                SplitDropPreviewPane(tab: tab, isDragged: tab.id == store.draggedTabID)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct SplitDropPreviewPane: View {
    let tab: BrowserTab
    let isDragged: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isDragged ? 0.11 : 0.065))
                .overlay {
                    Image(systemName: isDragged ? "rectangle.split.1x2.fill" : "globe")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(isDragged ? 0.32 : 0.18))
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    Image(systemName: tab.faviconSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isDragged ? CandoaColor.primary : .secondary)

                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(isDragged ? 0.82 : 0.62))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isDragged ? CandoaColor.primary.opacity(0.62) : Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(isDragged ? 0.16 : 0.08), radius: isDragged ? 12 : 6, x: 0, y: 3)
    }
}

/// Arc's developer toolbar: local dev servers get a tinted strip above the
/// page showing the full URL. The tint is the space's theme color — Arc
/// reuses the color you picked for the space, not a dedicated developer hue.
private struct DeveloperToolbar: View {
    let url: URL
    let urlText: String
    let tintHex: String?
    let isSplitViewEnabled: Bool
    let onCopyURL: () -> Void
    let onCapturePage: () -> Void
    let onToggleSplitView: () -> Void
    let onSubmitURL: (String) -> Void
    let onSetDeveloperMode: (Bool) -> Void

    private static let arcDevStripBlueHex = "#5156D0"
    private static let storageKey = "CandoaDeveloperToolbarControlIDs"
    private static let noControlIDsValue = "none"
    private static let defaultControlIDs = DeveloperToolbarControlKind.allCases
        .filter(\.isDefaultVisible)
        .map(\.id)
        .joined(separator: ",")

    @State private var draftURL = ""
    @State private var hoveredControl: DeveloperToolbarControlKind?
    @State private var isHoveringControlMenu = false
    @State private var isSiteInfoPresented = false
    @AppStorage(Self.storageKey) private var storedControlIDs = ""
    @FocusState private var isURLFieldFocused: Bool

    private var resolvedTintHex: String {
        tintHex ?? Self.arcDevStripBlueHex
    }

    private var tint: Color {
        Color(spaceHex: resolvedTintHex)
    }

    private var foreground: Color {
        CandoaChromeStyle.prefersDarkForeground(forSpaceHex: resolvedTintHex) ? .black : .white
    }

    private var selectedControlIDs: [String] {
        if storedControlIDs == Self.noControlIDsValue {
            return []
        }

        let value = storedControlIDs.isEmpty ? Self.defaultControlIDs : storedControlIDs
        return value
            .split(separator: ",")
            .map(String.init)
            .filter { id in DeveloperToolbarControlKind.allCases.contains { $0.id == id } }
    }

    private var selectedControlIDSet: Set<String> {
        Set(selectedControlIDs)
    }

    private var visibleControls: [DeveloperToolbarControlKind] {
        let ids = selectedControlIDSet
        return DeveloperToolbarControlKind.allCases.filter { ids.contains($0.id) }
    }

    private var currentURL: URL? {
        URL(string: urlText)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $draftURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.92))
                .tint(CandoaColor.primary)
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

            HStack(spacing: 6) {
                ForEach(Array(visibleControls.enumerated()), id: \.element.id) { index, control in
                    if shouldInsertSeparator(before: index) {
                        Rectangle()
                            .fill(foreground.opacity(0.18))
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 3)
                    }

                    toolbarButton(for: control)
                }

                controlMenu
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                // Arc's strip carries a faint left→right deepening of the
                // tint, so the stripes never sit on a flat fill.
                LinearGradient(
                    colors: [tint, tint.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .background(tint.opacity(0.92))

                DiagonalStripes()
                    .fill(Color.black.opacity(0.045))
            }
        }
    }

    private var controlMenu: some View {
        Menu {
            Text("Shown Controls")

            ForEach(DeveloperToolbarControlKind.allCases) { control in
                Button {
                    toggleControl(control)
                } label: {
                    if selectedControlIDSet.contains(control.id) {
                        Label(control.title(isSplitViewEnabled: isSplitViewEnabled), systemImage: "checkmark")
                    } else {
                        Text(control.title(isSplitViewEnabled: isSplitViewEnabled))
                    }
                }
                .disabled(!control.isImplemented)
            }

            Divider()

            Button("Reset to Arc Controls") {
                storedControlIDs = Self.defaultControlIDs
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(foreground.opacity(isHoveringControlMenu ? 0.95 : 0.72))
                .frame(width: 22, height: 22)
                .background(foreground.opacity(isHoveringControlMenu ? 0.12 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHoveringControlMenu = $0 }
        .help("Customize Developer Controls")
    }

    private func toolbarButton(for control: DeveloperToolbarControlKind) -> some View {
        Button {
            perform(control)
        } label: {
            Image(systemName: control.symbolName(isSplitViewEnabled: isSplitViewEnabled))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    foreground.opacity(
                        control.isImplemented
                            ? (hoveredControl == control ? 0.95 : 0.72)
                            : 0.34
                    )
                )
                .frame(width: 22, height: 22)
                .background(foreground.opacity(hoveredControl == control && control.isImplemented ? 0.12 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!control.isImplemented)
        .onHover { isHovering in
            hoveredControl = isHovering ? control : nil
        }
        .help(control.help(isSplitViewEnabled: isSplitViewEnabled))
        .popover(
            isPresented: Binding(
                get: { control == .siteInfo && isSiteInfoPresented },
                set: { isPresented in
                    if control == .siteInfo {
                        isSiteInfoPresented = isPresented
                    }
                }
            ),
            arrowEdge: .top
        ) {
            DeveloperSiteInfoPopover(
                url: currentURL,
                urlText: urlText,
                isLocalDevelopment: url.isLocalDevelopment,
                onSetDeveloperMode: onSetDeveloperMode
            )
        }
    }

    private func shouldInsertSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return visibleControls[index].group != visibleControls[index - 1].group
    }

    private func perform(_ control: DeveloperToolbarControlKind) {
        switch control {
        case .copyURL:
            onCopyURL()
        case .capturePage:
            onCapturePage()
        case .splitView:
            onToggleSplitView()
        case .siteInfo:
            isSiteInfoPresented = true
        case .easel, .developerTools, .inspectElement, .extensions:
            break
        }
    }

    private func toggleControl(_ control: DeveloperToolbarControlKind) {
        var ids = Set(selectedControlIDs)
        if ids.contains(control.id) {
            ids.remove(control.id)
        } else {
            ids.insert(control.id)
        }

        let orderedIDs = DeveloperToolbarControlKind.allCases
            .map(\.id)
            .filter { ids.contains($0) }
        storedControlIDs = orderedIDs.isEmpty
            ? Self.noControlIDsValue
            : orderedIDs.joined(separator: ",")
    }
}

private struct DeveloperSiteInfoPopover: View {
    let url: URL?
    let urlText: String
    let isLocalDevelopment: Bool
    let onSetDeveloperMode: (Bool) -> Void

    private var hostText: String {
        url?.host(percentEncoded: false) ?? "Local page"
    }

    private var schemeText: String {
        url?.scheme?.uppercased() ?? "Unknown"
    }

    private var portText: String {
        guard let port = url?.port else { return "Default" }
        return String(port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hostText, systemImage: "info.circle")
                .font(.headline)

            Divider()

            DeveloperSiteInfoRow(title: "Address", value: urlText)
            DeveloperSiteInfoRow(title: "Scheme", value: schemeText)
            DeveloperSiteInfoRow(title: "Port", value: portText)

            Toggle("Developer Mode", isOn: Binding(
                get: { true },
                set: { isEnabled in
                    onSetDeveloperMode(isEnabled)
                }
            ))

            Text(
                isLocalDevelopment
                    ? "Enabled automatically for local development."
                    : "Enabled for this site."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

private struct DeveloperSiteInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum DeveloperToolbarControlKind: String, CaseIterable, Identifiable {
    case copyURL
    case easel
    case capturePage
    case developerTools
    case siteInfo
    case inspectElement
    case extensions
    case splitView

    var id: String { rawValue }

    var group: Int {
        switch self {
        case .copyURL:
            return 0
        case .easel, .capturePage:
            return 1
        case .developerTools, .siteInfo, .inspectElement:
            return 2
        case .extensions, .splitView:
            return 3
        }
    }

    var isDefaultVisible: Bool {
        switch self {
        case .copyURL, .capturePage, .siteInfo, .splitView:
            return true
        case .easel, .developerTools, .inspectElement, .extensions:
            return false
        }
    }

    var isImplemented: Bool {
        switch self {
        case .copyURL, .capturePage, .siteInfo, .splitView:
            return true
        case .easel, .developerTools, .inspectElement, .extensions:
            return false
        }
    }

    func title(isSplitViewEnabled: Bool) -> String {
        switch self {
        case .copyURL:
            return "Copy Link"
        case .easel:
            return "Capture to Easel"
        case .capturePage:
            return "Capture Page"
        case .developerTools:
            return "Developer Tools"
        case .siteInfo:
            return "Site Info"
        case .inspectElement:
            return "Inspect Element"
        case .extensions:
            return "Extensions"
        case .splitView:
            return isSplitViewEnabled ? BrowserCommandTitles.closeSplitView : BrowserCommandTitles.addSplitView
        }
    }

    func symbolName(isSplitViewEnabled: Bool) -> String {
        switch self {
        case .copyURL:
            return "link"
        case .easel:
            return "rectangle.on.rectangle"
        case .capturePage:
            return "camera"
        case .developerTools:
            return "terminal"
        case .siteInfo:
            return "globe"
        case .inspectElement:
            return "scope"
        case .extensions:
            return "puzzlepiece.extension"
        case .splitView:
            return isSplitViewEnabled ? "rectangle.split.1x2.fill" : "rectangle.split.1x2"
        }
    }

    var shortcutText: String {
        switch self {
        case .copyURL:
            return "⇧⌘C"
        case .capturePage:
            return "Set in Settings > Shortcuts"
        case .splitView:
            return "⌃⇧+ / ⌃⇧-"
        case .easel, .developerTools, .siteInfo, .inspectElement, .extensions:
            return "Not implemented in Candoa yet"
        }
    }

    func help(isSplitViewEnabled: Bool) -> String {
        "\(title(isSplitViewEnabled: isSplitViewEnabled))\n\(shortcutText)"
    }
}

/// Arc's developer strip isn't a flat fill: faint diagonal stripes run across
/// the tint, marking the page as a dev server at a glance. Measured from
/// Arc: dark band and gap are equal width (~1:1) at a broad period, kept low
/// contrast so the texture stays a whisper. Static geometry only — drawn
/// with the chrome, never animated.
private struct DiagonalStripes: Shape {
    var period: CGFloat = 44

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let band = period / 2
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + band, y: rect.minY))
            path.addLine(to: CGPoint(x: x + band + rect.height, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            path.closeSubpath()
            x += period
        }
        return path
    }
}

/// Zen-style loading pill: a small capsule centered at the top of the web
/// surface that pulses while the page loads, settles into a wide shimmering
/// track on long loads (3s+), and shrink-fades away once the page lands.
/// Shape, timing, and color mix mirror Zen's #zen-loading-progress-bar.
private struct PageLoadingPill: View {
    let isLoading: Bool
    let tint: Color
    let themeIsDark: Bool?

    var body: some View {
        ZStack {
            if isLoading {
                LoadingPillCore(tint: tint, themeIsDark: themeIsDark)
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .scale(scale: 0.8))
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: isLoading ? 0.4 : 0.3), value: isLoading)
        .allowsHitTesting(false)
    }
}

private struct LoadingPillCore: View {
    let tint: Color
    let themeIsDark: Bool?

    @Environment(\.colorScheme) private var colorScheme

    private var isDarkScheme: Bool {
        themeIsDark ?? (colorScheme == .dark)
    }

    @State private var isPulsedUp = false
    @State private var isLongLoad = false
    @State private var isShimmerSwept = false

    private let pillWidth: CGFloat = 80
    private let longLoadWidth: CGFloat = 160
    private let pillHeight: CGFloat = 6
    private let longLoadDelay: Duration = .seconds(3)

    var body: some View {
        Capsule()
            .fill(isLongLoad ? trackColor : pillColor)
            .overlay {
                if isLongLoad {
                    shimmer
                }
            }
            .clipShape(Capsule())
            .frame(width: isLongLoad ? longLoadWidth : pillWidth, height: pillHeight)
            .scaleEffect(isLongLoad ? 1 : (isPulsedUp ? 0.95 : 0.85))
            .opacity(isLongLoad ? 1 : (isPulsedUp ? 1 : 0.6))
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    isPulsedUp = true
                }
            }
            .task {
                try? await Task.sleep(for: longLoadDelay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    isLongLoad = true
                }
            }
    }

    /// Long-load state: the pill becomes a faint track with a tinted
    /// segment sweeping through it, like an indeterminate marquee.
    private var shimmer: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(pillColor)
                .frame(width: proxy.size.width * 0.75)
                .offset(x: isShimmerSwept ? proxy.size.width : -proxy.size.width * 0.75)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1).repeatForever(autoreverses: false).delay(0.3)
                    ) {
                        isShimmerSwept = true
                    }
                }
        }
    }

    /// Zen: color-mix(in srgb, primary, light-dark(black 50%, white 50%) 70%).
    /// color-mix premultiplies alpha, so the 50%-alpha blend at 70% weight
    /// resolves to ~54% of the blend color at 0.65 total alpha.
    private var pillColor: Color {
        let blend: NSColor = isDarkScheme ? .white : .black
        let mixed = NSColor(tint).usingColorSpace(.sRGB)?.blended(withFraction: 0.35 / 0.65, of: blend) ?? blend
        return Color(nsColor: mixed).opacity(0.65)
    }

    private var trackColor: Color {
        (isDarkScheme ? Color.white : Color.black).opacity(0.1)
    }
}

internal struct SpaceSetupCanvas: View {
    let hexes: [String]
    let intensity: Double
    let texture: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(canvasFill)

            // Whisper-level sheen when themed: anything stronger visibly
            // darkens the card against the identically-tinted chrome.
            LinearGradient(
                colors: [
                    Color.white.opacity(hexes.isEmpty ? 0.10 : 0.03),
                    Color.black.opacity(hexes.isEmpty ? 0.035 : 0.012)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            LinearGradient(
                colors: [
                    Color.white.opacity(hexes.isEmpty ? 0.10 : 0.04),
                    Color.clear,
                    Color.black.opacity(hexes.isEmpty ? 0.08 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.overlay)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(hexes.isEmpty ? 0.08 : 0.12), lineWidth: 1)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(hexes.isEmpty ? 0.08 : 0.10), lineWidth: 1)
                    .blendMode(.overlay)
            }
        }
        .compositingGroup()
        .shadow(
            color: Color.black.opacity(hexes.isEmpty ? 0.10 : 0.18),
            radius: hexes.isEmpty ? 22 : 30,
            x: 0,
            y: hexes.isEmpty ? 8 : 10
        )
        .shadow(
            color: Color.black.opacity(hexes.isEmpty ? 0.05 : 0.10),
            radius: hexes.isEmpty ? 10 : 14,
            x: -4,
            y: 1
        )
    }

    private var canvasFill: Color {
        guard let firstHex = hexes.first else {
            return CandoaChromeStyle.surfaceFill.opacity(0.88)
        }

        // The window backdrop already carries the theme color at full
        // strength; keep the card nearly transparent so chrome and canvas
        // read as one continuous surface (Zen-style).
        return Color(spaceHex: firstHex).opacity(0.08)
    }
}
