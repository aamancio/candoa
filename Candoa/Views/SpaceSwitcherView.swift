import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Zen-style bottom workspace strip: a horizontal row of workspace icons
/// pinned to the bottom of the sidebar, with a trailing "add space" control.
struct SpaceSwitcherView: View {
    @ObservedObject var store: BrowserStore
    let displayedActiveSpaceID: UUID
    let onSelectSpace: (UUID) -> Void
    @State private var isHoveringDownloads = false
    @State private var isActionMenuPresented = false
    @State private var isHoveringAddSpace = false
    @State private var deletingSpace: BrowserSpace?

    var body: some View {
        HStack(spacing: 8) {
            downloadsButton

            if store.isPrivate {
                // Zen-style private strip: no workspace icons, no space
                // management — just Downloads and a New Tab control.
                Spacer()

                newTabButton
            } else {
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.spaces) { space in
                                workspaceButton(for: space)
                            }
                        }
                        .frame(minWidth: proxy.size.width, minHeight: 28, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 28)

                addSpaceButton
            }
        }
        .frame(height: 32)
        .initialTourPopover(.spaces, store: store, arrowEdge: .leading)
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
    }

    private var downloadsButton: some View {
        Button {
            store.isDownloadsPopoverPresented.toggle()
        } label: {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 15.5, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(InterfaceStyle.sidebarIcon)
                .background(bottomButtonBackground(isActive: store.isDownloadsPopoverPresented, isHovering: isHoveringDownloads))
                .overlay {
                    // Safari-style progress ring: in-flight progress stays
                    // visible after the popover closes. Exists only while a
                    // download is active, so idle costs nothing.
                    if let progress = store.downloadsStore.activeProgress {
                        Circle()
                            .trim(from: 0, to: max(0.06, progress))
                            .stroke(
                                AppColor.accent,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 23, height: 23)
                            .animation(.linear(duration: 0.2), value: progress)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHoveringDownloads = $0 }
        .help("Downloads")
        .popover(isPresented: $store.isDownloadsPopoverPresented, arrowEdge: .bottom) {
            DownloadsPopoverView(downloadsStore: store.downloadsStore) {
                store.isDownloadsPopoverPresented = false
                openDownloadsFolder()
            }
        }
    }

    @State private var isHoveringNewTab = false

    private var newTabButton: some View {
        Button {
            store.openNewTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                .background(bottomButtonBackground(isActive: false, isHovering: isHoveringNewTab))
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHoveringNewTab = $0 }
        .animation(.easeOut(duration: 0.10), value: isHoveringNewTab)
        .help(BrowserCommandTitles.newTab)
    }

    private var addSpaceButton: some View {
        Button {
            isActionMenuPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                .background(bottomButtonBackground(isActive: isActionMenuPresented, isHovering: isHoveringAddSpace))
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHoveringAddSpace = $0 }
        .animation(.easeOut(duration: 0.10), value: isHoveringAddSpace)
        .help("New Space")
        .popover(isPresented: $isActionMenuPresented, arrowEdge: .bottom) {
            SpaceActionMenu(
                store: store,
                isPresented: $isActionMenuPresented
            )
        }
    }

    private func bottomButtonBackground(isActive: Bool, isHovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? InterfaceStyle.sidebarControlFillActive : (isHovering ? InterfaceStyle.sidebarControlFillHover : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive || isHovering ? InterfaceStyle.sidebarControlStroke : Color.clear, lineWidth: 1)
            }
    }

    /// ⌃1–⌃9 switch to a space by position (KeyboardShortcutMonitor's
    /// control-digit handling); spaces past the ninth have no shortcut.
    private func switchShortcutKeys(for space: BrowserSpace) -> [String] {
        guard
            let index = store.spaces.firstIndex(where: { $0.id == space.id }),
            index < 9
        else { return [] }
        return ["⌃", "\(index + 1)"]
    }

    private func workspaceButton(for space: BrowserSpace) -> some View {
        let isActive = space.id == displayedActiveSpaceID
        let themeColor = ThemeStyle.identityColor(for: space.themeColorHex)

        return Button {
            onSelectSpace(space.id)
        } label: {
            Group {
                if let emoji = space.iconEmoji {
                    Text(emoji)
                        .font(.system(size: 13))
                        .opacity(isActive ? 1 : 0.55)
                } else {
                    Circle()
                        .fill(isActive ? themeColor : themeColor.opacity(0.50))
                        .frame(width: isActive ? 8 : 7, height: isActive ? 8 : 7)
                        .overlay {
                            if isActive {
                                Circle()
                                    .stroke(themeColor.opacity(0.28), lineWidth: 5)
                                    .frame(width: 16, height: 16)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(width: 34, height: 28)
            .background(
                bottomButtonBackground(
                    isActive: isActive,
                    isHovering: false
                )
            )
            .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .animation(.easeOut(duration: 0.20), value: isActive)
        .shortcutTooltip(space.name, keys: switchShortcutKeys(for: space))
        .accessibilityLabel(space.name)
        .contextMenu {
            Button("Edit Space...") {
                store.beginSpaceEditing(space.id)
            }

            Divider()

            Button("Move Space Left") {
                store.moveSpace(space.id, by: -1)
            }
            .disabled(store.spaces.first?.id == space.id)

            Button("Move Space Right") {
                store.moveSpace(space.id, by: 1)
            }
            .disabled(store.spaces.last?.id == space.id)

            Divider()

            Button("New Space") {
                store.beginSpaceCreation()
            }

            Button("Delete Space", role: .destructive) {
                deletingSpace = space
            }
            .disabled(store.spaces.count <= 1)
        }
        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
            guard let draggedTabID = store.draggedTabID else { return false }
            store.moveTab(draggedTabID, toSpace: space.id)
            store.draggedTabID = nil
            return true
        }
    }

    private func openDownloadsFolder() {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }

        NSWorkspace.shared.open(downloadsURL)
    }

    private var isDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { deletingSpace != nil },
            set: { isPresented in
                if !isPresented {
                    deletingSpace = nil
                }
            }
        )
    }

}

private struct DownloadsPopoverView: View {
    @ObservedObject var downloadsStore: DownloadsStore
    let onShowAllDownloads: () -> Void

    @State private var recentFiles: [DownloadListItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !downloadsStore.items.isEmpty {
                HStack {
                    Text("Downloads")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if downloadsStore.hasClearableItems {
                        // List-only: the downloaded files stay on disk.
                        Button("Clear") {
                            downloadsStore.clearSettledItems()
                        }
                        .buttonTreatment(.quiet)
                        .controlSize(.small)
                        .accessibilityIdentifier("downloads-clear")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)

                ForEach(downloadsStore.items) { item in
                    SessionDownloadRow(item: item, downloadsStore: downloadsStore)
                }
            } else if recentFiles.isEmpty {
                Text("No downloads found.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            } else {
                ForEach(recentFiles) { item in
                    DownloadItemRow(item: item)
                }
            }

            Divider()
                .padding(.vertical, 5)

            DownloadsPopoverRow(title: String(localized: "Show all downloads"), action: onShowAllDownloads)
        }
        .padding(10)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads-popover")
        .onAppear {
            // Day-based list retention is applied when the list is looked
            // at, not on a timer — same moment Safari uses.
            downloadsStore.applyListRetention()
            // One filesystem snapshot on open; the session list needs none.
            recentFiles = DownloadListItem.recentDownloads()
        }
    }
}

private struct SessionDownloadRow: View {
    let item: DownloadsStore.Item
    let downloadsStore: DownloadsStore

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .active = item.phase {
                Button {
                    downloadsStore.cancelItem(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonTreatment(.content)
                .help("Cancel Download")
                .accessibilityLabel("Cancel Download")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard case .completed = item.phase, let destination = item.destination else { return }
            NSWorkspace.shared.open(destination)
        }
        .contextMenu {
            if case .completed = item.phase, let destination = item.destination {
                Button("Open") {
                    NSWorkspace.shared.open(destination)
                }

                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch item.phase {
        case .active(let fraction):
            if let fraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .completed:
            Text("Completed")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
        case .failed(let reason):
            Text("Failed — \(reason)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
        }
    }

    private var accessibilityPhase: String {
        switch item.phase {
        case .active: String(localized: "downloading")
        case .completed: String(localized: "completed")
        case .failed: String(localized: "failed")
        case .cancelled: String(localized: "cancelled")
        }
    }

    private var icon: some View {
        Group {
            if let destination = item.destination, case .completed = item.phase {
                Image(nsImage: fileIcon(for: destination))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(InterfaceStyle.sidebarIcon)
            }
        }
        .frame(width: 32, height: 32)
    }

    private func fileIcon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}

private struct DownloadListItem: Identifiable, Equatable {
    let url: URL
    let name: String
    let date: Date
    let isDirectory: Bool

    var id: URL { url }

    static func recentDownloads(limit: Int = 6) -> [DownloadListItem] {
        guard let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isDirectoryKey
        ]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            return DownloadListItem(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                date: values.contentModificationDate ?? values.creationDate ?? .distantPast,
                isDirectory: values.isDirectory == true
            )
        }
        .sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            return lhs.date > rhs.date
        }
        .prefix(limit)
        .map { $0 }
    }
}

private struct DownloadItemRow: View {
    let item: DownloadListItem

    @State private var isHovering = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
        } label: {
            HStack(spacing: 10) {
                DownloadItemIcon(item: item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(InterfaceStyle.sidebarText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(Self.relativeDateFormatter.localizedString(for: item.date, relativeTo: Date()))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") {
                NSWorkspace.shared.open(item.url)
            }

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}

private struct DownloadItemIcon: View {
    let item: DownloadListItem

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: item.isDirectory ? 0 : 7, style: .continuous))
    }

    private var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        image.size = NSSize(width: 42, height: 42)
        return image
    }
}

private struct DownloadsPopoverRow: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }
}

private struct SpaceActionMenu: View {
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuButton(BrowserCommandTitles.createSpace, systemImage: "square.on.square") {
                store.beginSpaceCreation()
            }

            menuButton("New Folder", systemImage: "folder") {
                store.createFolder()
            }

            Divider()
                .padding(.vertical, 5)

            menuButton("New Split", systemImage: "rectangle.split.2x1") {
                // "New Split" always opens one — it must never toggle an
                // existing split closed from this menu.
                if !store.isSplitViewDisplayed {
                    store.toggleSplitView()
                }
            }

            menuButton(BrowserCommandTitles.newTab, systemImage: "plus") {
                store.openNewTab()
            }
        }
        .padding(10)
        .frame(width: 210)
    }

    private func menuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        SpaceActionMenuRow(title: title, systemImage: systemImage) {
            isPresented = false
            action()
        }
    }
}

private struct SpaceActionMenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .background(isHovering && isEnabled ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }
}

extension Color {
    init(spaceHex: String) {
        let hex = spaceHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            self = Color(red: 0.43, green: 0.55, blue: 1.0)
            return
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}
