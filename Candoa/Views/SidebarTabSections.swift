import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Essential tile

internal enum SidebarTilePlacement {
    case favorite
    case pinned
}

internal struct EssentialTileView: View {
    let tab: BrowserTab
    let isActive: Bool
    let accentColor: Color
    let placement: SidebarTilePlacement
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onOpenInSplit: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous)
                    .fill(
                        isActive
                            ? AnyShapeStyle(InterfaceStyle.sidebarControlFillActive)
                            : AnyShapeStyle(InterfaceStyle.sidebarControlFill)
                    )

                faviconImage
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .clipShape(RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous))
            .overlay {
                // Zen draws no border on the selected chip — the fill alone
                // marks it.
                RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? InterfaceStyle.sidebarControlStroke
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonTreatment(.content)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .help(placement == .favorite ? tab.favoriteDisplayTitle : tab.title)
        .accessibilityLabel(placement == .favorite ? tab.favoriteDisplayTitle : tab.title)
        .accessibilityIdentifier(
            "\(placement == .favorite ? "favorite" : "pinned")-tile-"
                + sidebarAccessibilitySlug(placement == .favorite ? tab.favoriteDisplayTitle : tab.title)
        )
        .contextMenu {
            switch placement {
            case .favorite:
                Button("Remove from Favorites", action: onToggleFavorite)
                Button("Move to Pinned Tabs", action: onTogglePin)
            case .pinned:
                Button("Add to Favorites", action: onToggleFavorite)
                Button("Unpin Tab", action: onTogglePin)
            }
            Button(BrowserCommandTitles.duplicateTab, action: onDuplicate)
            Button("Open in Split View", action: onOpenInSplit)
            Button("Close Tab", action: onClose)
        }
    }

    @ViewBuilder
    private var faviconImage: some View {
        if let data = placement == .favorite ? tab.favoriteDisplayFaviconData : tab.faviconData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: placement == .favorite ? tab.favoriteDisplayFaviconSymbol : tab.faviconSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? InterfaceStyle.sidebarText : InterfaceStyle.sidebarTextSecondary)
        }
    }
}
internal struct FavoriteDropZone: View {
    let onDismiss: () -> Void

    @State private var isHoveringCloseButton = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)

            Text("Drag to add Favorites")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(InterfaceStyle.sidebarText)

            Text("Favorites keep your most used sites and apps close")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .foregroundStyle(isHoveringCloseButton ? InterfaceStyle.sidebarTextSecondary : InterfaceStyle.sidebarIcon)
            .background(
                Circle()
                    .fill(isHoveringCloseButton ? InterfaceStyle.sidebarControlFillHover : Color.clear)
            )
            .onHover { isHoveringCloseButton = $0 }
            .help("Dismiss Favorites Hint")
            .padding(6)
        }
        .background(InterfaceStyle.sidebarControlFill.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    InterfaceStyle.sidebarTextSecondary.opacity(0.26),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
        }
        .animation(.easeOut(duration: 0.10), value: isHoveringCloseButton)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("favorites-drop-zone")
    }
}

internal struct FolderSectionView: View {
    @ObservedObject var store: BrowserStore
    let folder: BrowserFolder
    @Binding var editingFolderID: UUID?
    let accentColor: Color
    let nestingLevel: Int

    @State private var draftName = ""
    @State private var isHovering = false
    @FocusState private var isNameFocused: Bool

    private var tabs: [BrowserTab] {
        let splitTabIDs = store.activeSplitGroupTabIDs
        return store.tabsInFolder(folder.id).filter { !splitTabIDs.contains($0.id) }
    }

    private var subfolders: [BrowserFolder] {
        store.subfolders(in: folder.id)
    }

    private var isEditing: Bool {
        editingFolderID == folder.id
    }

    private var hasFolderContents: Bool {
        !subfolders.isEmpty || !tabs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            folderHeader

            if folder.isExpanded {
                ForEach(subfolders) { subfolder in
                    FolderSectionView(
                        store: store,
                        folder: subfolder,
                        editingFolderID: $editingFolderID,
                        accentColor: accentColor,
                        nestingLevel: nestingLevel + 1
                    )
                }

                ForEach(tabs) { tab in
                    TabRowView(
                        tab: tab,
                        isActive: tab.id == store.activeTabID && !store.isNewTabPaletteActive,
                        accentColor: accentColor,
                        mediaState: store.mediaStates[tab.id],
                        onSelect: { store.switchTab(to: tab.id) },
                        onClose: { store.closeTab(tab.id) },
                        onCloseOthers: { store.closeOtherTabs(keeping: tab.id) },
                        onDuplicate: { store.duplicateTab(tab.id) },
                        onOpenInSplit: { store.openSplitView(with: tab.id) },
                        onRemoveFromSplit: { store.removeTabFromSplit(tab.id) },
                        isSplitMember: store.activeSplitGroupTabIDs.contains(tab.id),
                        onToggleFavorite: { store.toggleFavorite(tab.id) },
                        onTogglePin: { store.togglePin(tab.id) },
                        onToggleMute: { store.toggleMediaMute(tabID: tab.id) },
                            suppressesHover: store.draggedTabID != nil
                    )
                    .padding(.leading, CGFloat(nestingLevel + 1) * 12)
                    .sidebarRowDropIndicator(
                        showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                            placement: .folder(folder.id),
                            targetTabID: tab.id,
                            edge: .before
                        ),
                        splitSide: store.sidebarSplitDropSide(
                            for: tab.id,
                            placement: .folder(folder.id)
                        ),
                        showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                            placement: .folder(folder.id),
                            targetTabID: tab.id,
                            edge: .after
                        ),
                        tint: accentColor
                    )
                    .background(TabDragSourceBackground(store: store, tabID: tab.id))
                    .onDrop(
                        of: [UTType.text],
                        delegate: FolderTabDropDelegate(
                            folder: folder,
                            targetTab: tab,
                            tabs: tabs,
                            store: store
                        )
                    )
                }

                if store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                    placement: .folder(folder.id),
                    targetTabID: nil,
                    edge: .after
                ) {
                    SidebarHorizontalDropLine(tint: accentColor)
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                }
            }
        }
        .onAppear {
            draftName = folder.name
            if isEditing {
                focusNameField()
            }
        }
        .onChange(of: folder.name) { _, newValue in
            if !isEditing {
                draftName = newValue
            }
        }
        .onChange(of: isEditing) { _, newValue in
            if newValue {
                draftName = folder.name
                focusNameField()
            } else {
                isNameFocused = false
            }
        }
    }

    private var folderHeader: some View {
        HStack(spacing: 8) {
            SidebarFolderIcon()
                .foregroundStyle(InterfaceStyle.sidebarIcon)

            if isEditing {
                TextField("Folder Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .focused($isNameFocused)
                    .lineLimit(1)
                    .onSubmit(commitRename)
                    .onExitCommand {
                        draftName = folder.name
                        editingFolderID = nil
                    }
            } else {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(InterfaceStyle.sidebarText)
            }

            SidebarDisclosureChevron(
                isExpanded: folder.isExpanded,
                isVisible: hasFolderContents,
                opacity: isHovering || folder.isExpanded ? 0.82 : 0.48
            )
                .foregroundStyle(InterfaceStyle.sidebarIcon)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, CGFloat(nestingLevel) * 12)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background(isHovering ? InterfaceStyle.sidebarControlFillHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if !isEditing {
                store.toggleFolderExpanded(folder.id)
            }
        }
        .onDrop(
            of: [UTType.text],
            delegate: FolderTabDropDelegate(
                folder: folder,
                targetTab: nil,
                tabs: tabs,
                store: store
            )
        )
        .contextMenu {
            Button("Rename Folder") {
                editingFolderID = folder.id
            }

            Button("New Subfolder") {
                _ = store.createSubfolder(in: folder.id)
            }

            Button("Delete Folder", role: .destructive) {
                store.deleteFolder(folder.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.name)
        .accessibilityIdentifier("folder-row-\(sidebarAccessibilitySlug(folder.name))")
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: folder.isExpanded)
    }

    private func focusNameField() {
        DispatchQueue.main.async {
            isNameFocused = true
        }
    }

    private func commitRename() {
        store.renameFolder(folder.id, to: draftName)
    }
}

// MARK: - Pinned separator

/// Zen's `.pinned-tabs-container-separator`: a 22px row holding a hairline
/// and the Close-all-unpinned button. Measurements from vertical-tabs.css —
/// `padding: 0 5px` on macOS plus `margin: auto 4px` on the rule (9pt inset),
/// `light-dark(rgba(0,0,0,.1), rgba(255,255,255,.1))` for the line, and a
/// 10px/500 label that sits at half opacity while the sidebar is hovered
/// (`zen-has-implicit-hover`) and full when the pointer reaches it.
internal struct PinnedSeparatorRow: View {
    let showsClear: Bool
    let onClear: () -> Void

    @State private var isHoveringRow = false
    @State private var isHoveringClear = false

    private var revealsClear: Bool { showsClear && isHoveringRow }

    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(InterfaceStyle.zenHairline)
                .frame(height: 1)
                .padding(.horizontal, 4)

            if revealsClear {
                Button(action: onClear) {
                    Text("Clear")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(InterfaceStyle.sidebarText)
                        .padding(.horizontal, 4)
                        .frame(height: 20)
                        .contentShape(Rectangle())
                }
                .buttonTreatment(.content)
                .opacity(isHoveringClear ? 1 : 0.5)
                .onHover { isHoveringClear = $0 }
                .shortcutTooltip(
                    BrowserCommandTitles.clearUnpinnedTabs,
                    shortcut: .clearUnpinnedTabs
                )
                .accessibilityIdentifier("sidebar-clear-unpinned-button")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { isHoveringRow = $0 }
        .animation(.easeOut(duration: 0.15), value: revealsClear)
        .animation(.easeOut(duration: 0.15), value: isHoveringClear)
    }
}

// MARK: - Space header

/// Arc's Space title row. At rest it is the icon and the name; on hover the
/// row fills, a chevron takes the icon's place, and a ⋯ button appears at
/// the trailing edge. Clicking the row folds the pinned area away (the
/// chevron turns to point at what's hidden); the ⋯ button and a right-click
/// open the same Space menu.
internal struct SpaceHeaderRow: View {
    @ObservedObject var store: BrowserStore
    let space: BrowserSpace
    let isDropTargeted: Bool
    /// Whether the Space has pinned tabs or folders under the title. Arc's
    /// header only turns into a disclosure when there is something to fold:
    /// with nothing pinned, hover shows just the ⋯ — no fill, no chevron, and
    /// a click does nothing.
    let hasCollapsibleContent: Bool
    /// Pointer presence over the header band, kept by the band's own event
    /// monitor — see SpaceSwipeCompanionHover for why onHover is not enough.
    @ObservedObject var hover: SpaceSwipeCompanionHover

    @State private var isHoveringMore = false
    @State private var deletingSpace: BrowserSpace?

    private var isCollapsed: Bool { store.isPinnedAreaCollapsed(in: space.id) }
    private var isHoveringRow: Bool { hover.isPointerInside && store.draggedTabID == nil }
    /// The disclosure treatment — fill and chevron — needs something to fold.
    private var showsDisclosureChrome: Bool { isHoveringRow && hasCollapsibleContent }

    var body: some View {
        HStack(spacing: 8) {
            // The tab rows' 16pt icon column: an 18pt box here pushed the
            // Space name 2pt right of every tab title below it.
            ZStack {
                if showsDisclosureChrome {
                    SidebarDisclosureChevron(
                        isExpanded: !isCollapsed,
                        isVisible: true,
                        opacity: 0.82
                    )
                    .foregroundStyle(InterfaceStyle.sidebarIcon)
                } else {
                    spaceIcon
                }
            }
            .frame(width: 16, height: 16)

            Text(space.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13, weight: .medium))

            Spacer(minLength: 0)

            if isHoveringRow {
                Menu {
                    spaceMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(InterfaceStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(
                                isHoveringMore
                                    ? InterfaceStyle.sidebarControlFillHover
                                    : Color.clear
                            )
                        )
                        .contentShape(Circle())
                }
                // .button + .plain: the borderless menu style tints its label
                // with the accent, and Arc's ⋯ is the row's own grey.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { isHoveringMore = $0 }
                .help("Space Options")
                .accessibilityLabel("Space Options")
                .accessibilityIdentifier("sidebar-space-options-button")
                .transition(.opacity)
            }
        }
        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background(
            isDropTargeted
                ? InterfaceStyle.sidebarControlFillDropTarget
                : (showsDisclosureChrome ? InterfaceStyle.sidebarControlFillHover : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous))
        .onTapGesture {
            guard hasCollapsibleContent else { return }
            store.togglePinnedAreaCollapsed(in: space.id)
        }
        .contextMenu { spaceMenuItems }
        .alert("Delete Space", isPresented: isDeleteAlertPresented, presenting: deletingSpace) { space in
            Button("Delete", role: .destructive) {
                store.deleteSpace(space.id)
                deletingSpace = nil
            }

            Button("Cancel", role: .cancel) {
                deletingSpace = nil
            }
        } message: { space in
            Text("Delete \"\(space.name)\" and close its tabs?")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(space.name)
        .accessibilityValue(hasCollapsibleContent ? (isCollapsed ? "Collapsed" : "Expanded") : "")
        .accessibilityIdentifier("sidebar-space-header")
        .animation(.easeOut(duration: 0.10), value: isHoveringRow)
        .animation(.easeOut(duration: 0.10), value: showsDisclosureChrome)
        .animation(.easeOut(duration: 0.10), value: isDropTargeted)
    }

    @ViewBuilder
    private var spaceIcon: some View {
        if space.symbolName != BrowserSpace.noIconSymbolName {
            if let emoji = space.iconEmoji {
                // A 14pt emoji glyph is wider than the 16pt column, and a
                // Text squeezed under its ideal width truncates — on a single
                // glyph that reads as a clipped edge. fixedSize keeps it whole,
                // centred on the column.
                Text(emoji)
                    .font(.system(size: 14))
                    .fixedSize()
            } else {
                Image(systemName: space.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    /// Arc's Space menu, trimmed to what Candoa has: icon, name and theme
    /// live in one editor here, so all three rows open it; profiles, live
    /// folders, sharing and export have no counterpart yet.
    @ViewBuilder
    private var spaceMenuItems: some View {
        Button("Change Space Icon…") { store.beginSpaceEditing(space.id) }
        Button("Rename Space…") { store.beginSpaceEditing(space.id) }
        Button("Edit Theme Color…") { store.beginSpaceEditing(space.id) }

        Divider()

        Button("New Folder") {
            store.switchSpace(to: space.id)
            let folder = store.createFolder()
            store.editingFolderID = folder.id
        }

        Divider()

        Button("New Space") { store.beginSpaceCreation() }

        Divider()

        Button("Delete Space", role: .destructive) { deletingSpace = space }
            .disabled(store.spaces.count <= 1)
    }

    private var isDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { deletingSpace != nil },
            set: { if !$0 { deletingSpace = nil } }
        )
    }
}

// MARK: - Drag ghost

/// The see-through copy of a dragged row, following the pointer. Drawn here
/// rather than handed to AppKit as a drag image so it ends the instant the
/// mouse comes up — AppKit dissolves its own image over the drop point, and
/// with the source row staying put that read as the tab being listed twice.
internal struct TabDragGhostView: View {
    let tab: BrowserTab
    let size: CGSize

    var body: some View {
        HStack(spacing: 8) {
            favicon
                .frame(width: 16, height: 16)

            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(InterfaceStyle.sidebarText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: InterfaceStyle.sidebarRowCornerRadius,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous)
                .fill(InterfaceStyle.sidebarControlFillActive.opacity(0.5))
        }
        .compositingGroup()
        // See-through enough to read as a copy, solid enough that the drop
        // line does not show through the pill and break in two.
        .opacity(0.96)
        .shadow(color: .black.opacity(0.28), radius: 9, y: 2)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var favicon: some View {
        if let data = tab.faviconData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: tab.faviconSymbol)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(InterfaceStyle.sidebarIcon)
        }
    }
}

internal struct SidebarSplitGroupView: View {
    @ObservedObject var store: BrowserStore
    let tabs: [BrowserTab]
    let accentColor: Color

    @State private var isHovering = false

    /// The pair is drawn at this member's place in the list, so dragging the
    /// row is dragging it; the other member follows because the pair renders
    /// wherever the first one lands.
    private var anchorTabID: UUID {
        tabs.first?.id ?? UUID()
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                SidebarSplitGroupChip(
                    tab: tab,
                    // Only the focused pane's chip lights up; membership alone
                    // must not make every chip in the pill read as active.
                    isActive: tab.id == store.activeTabID && !store.isNewTabPaletteActive,
                    showsCloseButton: isHovering,
                    accentColor: accentColor,
                    onSelect: { select(tab) },
                    onClose: { store.closeTab(tab.id) },
                    onDuplicate: { store.duplicateTab(tab.id) },
                    onRemoveFromSplit: { store.removeTabFromSplit(tab.id) },
                    onToggleFavorite: { store.toggleFavorite(tab.id) },
                    onTogglePin: { store.togglePin(tab.id) }
                )
            }
        }
        .padding(4)
        .frame(minHeight: 36)
        // The row drags as one thing. A drag source per chip meant grabbing
        // the pair picked up whichever half was under the pointer, which is
        // not what the row looks like it is; taking a single pane out of the
        // split is Remove from Split View on the chip's menu.
        .background(TabDragSourceBackground(store: store, tabID: anchorTabID))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? InterfaceStyle.sidebarControlFillHover : InterfaceStyle.sidebarControlFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHovering ? InterfaceStyle.sidebarControlStroke : Color.clear,
                    lineWidth: 1
                )
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Menu("Split Layout") {
                Button(BrowserCommandTitles.splitLayoutHorizontal) { store.setSplitLayout(.horizontal) }
                Button(BrowserCommandTitles.splitLayoutVertical) { store.setSplitLayout(.vertical) }
            }
            Button(BrowserCommandTitles.closeSplitView, action: store.closeSplitView)
        }
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }

    private func select(_ tab: BrowserTab) {
        if store.activeSplitGroupTabIDs.contains(tab.id) {
            store.focusSplitTab(tab.id)
        } else {
            store.switchTab(to: tab.id)
        }
    }
}

internal struct SidebarSplitGroupChip: View {
    let tab: BrowserTab
    let isActive: Bool
    let showsCloseButton: Bool
    let accentColor: Color
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onRemoveFromSplit: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovering = false
    @State private var isHoveringCloseButton = false

    private let closeButtonWidth: CGFloat = 16

    var body: some View {
        faviconImage
            .frame(width: 16, height: 16)
            .padding(.horizontal, 8)
            // The close button floats over the trailing edge instead of holding
            // a slot, so a resting chip centres its favicon rather than pinning
            // it left of a reserved gap. Only a hovered pill makes room.
            .padding(.trailing, showsCloseButton ? closeButtonWidth + 6 : 0)
            .frame(maxWidth: .infinity, minHeight: 28)
            .overlay(alignment: .trailing) { closeButton }
            .contentShape(Rectangle())
        .background(chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("split-chip-\(sidebarAccessibilitySlug(tab.title))")
        .contextMenu {
            Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
            Button(BrowserCommandTitles.duplicateTab, action: onDuplicate)
            Button("Remove from Split View", action: onRemoveFromSplit)
            Button("Close Tab", action: onClose)
        }
        .animation(.easeOut(duration: 0.10), value: showsCloseButton)
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .animation(.easeOut(duration: 0.10), value: isHoveringCloseButton)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: closeButtonWidth, height: closeButtonWidth)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .foregroundStyle(InterfaceStyle.sidebarIcon)
        .background(
            Circle()
                .fill(isHoveringCloseButton ? InterfaceStyle.sidebarControlFillHover : Color.clear)
        )
        .padding(.trailing, 8)
        .opacity(showsCloseButton ? 1 : 0)
        .accessibilityHidden(!showsCloseButton)
        .help("Close Tab")
        .onHover { isHoveringCloseButton = $0 }
    }

    /// Both chips are pills; the focused one is only brighter. An unfilled
    /// chip left the group looking like one tab nested inside another.
    private var chipBackground: Color {
        if isHovering {
            return InterfaceStyle.sidebarControlFillHover
        }
        if isActive {
            return InterfaceStyle.sidebarControlFillActive
        }
        return InterfaceStyle.sidebarSplitChipFill
    }

    @ViewBuilder
    private var faviconImage: some View {
        if let data = tab.faviconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: tab.faviconSymbol)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(isActive ? InterfaceStyle.sidebarText : InterfaceStyle.sidebarIcon)
        }
    }
}
