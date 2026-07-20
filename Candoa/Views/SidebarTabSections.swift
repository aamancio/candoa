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
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isActive
                            ? AnyShapeStyle(accentColor.opacity(0.18))
                            : AnyShapeStyle(CandoaInterfaceStyle.sidebarControlFill)
                    )

                faviconImage
                    .frame(width: 18, height: 18)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? accentColor.opacity(0.34)
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .help(placement == .favorite ? tab.favoriteDisplayTitle : tab.title)
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isActive ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarTextSecondary)
        }
    }
}
internal struct SidebarSplitGroupView: View {
    @ObservedObject var store: BrowserStore
    let tabs: [BrowserTab]
    let accentColor: Color

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                SidebarSplitGroupChip(
                    tab: tab,
                    isActive: store.activeSplitGroupTabIDs.contains(tab.id),
                    showsCloseButton: isHovering,
                    accentColor: accentColor,
                    onSelect: { select(tab) },
                    onClose: { store.closeTab(tab.id) },
                    onDuplicate: { store.duplicateTab(tab.id) },
                    onOpenInSplit: { store.openSplitView(with: tab.id) },
                    onToggleFavorite: { store.toggleFavorite(tab.id) },
                    onTogglePin: { store.togglePin(tab.id) }
                )
                .opacity(store.shouldHideSidebarTab(tab.id, placement: .regular) ? 0 : 1)
                .onDrag {
                    store.beginTabDrag(tab.id)
                }
            }
        }
        .padding(4)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? CandoaInterfaceStyle.sidebarControlFillHover : CandoaInterfaceStyle.sidebarControlFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHovering ? CandoaInterfaceStyle.sidebarControlStroke : Color.clear,
                    lineWidth: 1
                )
        }
        .onHover { isHovering = $0 }
        .contextMenu {
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
    let onOpenInSplit: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovering = false
    @State private var isHoveringCloseButton = false

    var body: some View {
        HStack(spacing: 6) {
            faviconImage
                .frame(width: 16, height: 16)

            Spacer(minLength: 2)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
            .background(
                Circle()
                    .fill(isHoveringCloseButton ? CandoaInterfaceStyle.sidebarControlFillHover : Color.clear)
            )
            .opacity(showsCloseButton ? 1 : 0)
            .accessibilityHidden(!showsCloseButton)
            .help("Close Tab")
            .onHover { isHoveringCloseButton = $0 }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .contentShape(Rectangle())
        .background(chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.title)
        .contextMenu {
            Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
            Button(BrowserCommandTitles.duplicateTab, action: onDuplicate)
            Button("Open in Split View", action: onOpenInSplit)
            Button("Close Tab", action: onClose)
        }
        .animation(.easeOut(duration: 0.10), value: showsCloseButton)
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .animation(.easeOut(duration: 0.10), value: isHoveringCloseButton)
    }

    private var chipBackground: Color {
        if isHovering {
            return CandoaInterfaceStyle.sidebarControlFillHover
        }
        if isActive {
            return accentColor.opacity(0.12)
        }
        return Color.clear
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
                .foregroundStyle(isActive ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarIcon)
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
                .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)

            Text("Drag to add Favorites")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarText)

            Text("Favorites keep your most used sites and apps close")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
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
            .buttonStyle(.plain)
            .foregroundStyle(isHoveringCloseButton ? CandoaInterfaceStyle.sidebarTextSecondary : CandoaInterfaceStyle.sidebarIcon)
            .background(
                Circle()
                    .fill(isHoveringCloseButton ? CandoaInterfaceStyle.sidebarControlFillHover : Color.clear)
            )
            .onHover { isHoveringCloseButton = $0 }
            .help("Dismiss Favorites Hint")
            .padding(6)
        }
        .background(CandoaInterfaceStyle.sidebarControlFill.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    CandoaInterfaceStyle.sidebarTextSecondary.opacity(0.26),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
        }
        .animation(.easeOut(duration: 0.10), value: isHoveringCloseButton)
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
                        isSplit: store.activeSplitGroupTabIDs.contains(tab.id),
                        accentColor: accentColor,
                        mediaState: store.mediaStates[tab.id],
                        onSelect: { store.switchTab(to: tab.id) },
                        onClose: { store.closeTab(tab.id) },
                        onDuplicate: { store.duplicateTab(tab.id) },
                        onOpenInSplit: { store.openSplitView(with: tab.id) },
                        onToggleFavorite: { store.toggleFavorite(tab.id) },
                        onTogglePin: { store.togglePin(tab.id) },
                        onToggleMute: { store.toggleMediaMute(tabID: tab.id) }
                    )
                    .padding(.leading, CGFloat(nestingLevel + 1) * 12)
                    .opacity(store.shouldHideSidebarTab(tab.id, placement: .folder(folder.id)) ? 0 : 1)
                    .sidebarRowDropIndicator(
                        showsTop: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                            placement: .folder(folder.id),
                            targetTabID: tab.id,
                            edge: .before
                        ),
                        showsSplit: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                            placement: .folder(folder.id),
                            targetTabID: tab.id,
                            edge: .split
                        ),
                        showsBottom: store.activeSidebarDropIndicator == SidebarTabDropIndicator(
                            placement: .folder(folder.id),
                            targetTabID: tab.id,
                            edge: .after
                        ),
                        tint: accentColor
                    )
                    .onDrag {
                        store.beginTabDrag(tab.id)
                    }
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
                .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)

            if isEditing {
                TextField("Folder Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(CandoaInterfaceStyle.sidebarText)
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
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(CandoaInterfaceStyle.sidebarText)
            }

            SidebarDisclosureChevron(
                isExpanded: folder.isExpanded,
                isVisible: hasFolderContents,
                opacity: isHovering || folder.isExpanded ? 0.82 : 0.48
            )
                .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, CGFloat(nestingLevel) * 12)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .background(isHovering ? CandoaInterfaceStyle.sidebarControlFillHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
