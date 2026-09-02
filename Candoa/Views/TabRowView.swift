import SwiftUI
import AppKit

private func candoaAccessibilitySlug(_ value: String) -> String {
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

struct TabRowView: View {
    let tab: BrowserTab
    let isActive: Bool
    let accentColor: Color
    let mediaState: TabMediaState?
    let onSelect: () -> Void
    let onClose: () -> Void
    var onCloseOthers: () -> Void = {}
    let onDuplicate: () -> Void
    let onOpenInSplit: () -> Void
    var onRemoveFromSplit: () -> Void = {}
    var isSplitMember = false
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onToggleMute: () -> Void
    /// A tab drag is in flight. The row under the pointer keeps its resting
    /// look while one is: a hover fill and close button there read as a
    /// third drop mark next to the line and the split ring.
    var suppressesHover: Bool = false

    @State private var isPointerInside = false

    private var isHovering: Bool { isPointerInside && !suppressesHover }

    private let closeButtonWidth: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                faviconImage
                    .opacity(tab.isLoading ? 0 : 1)

                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                }
            }
            .frame(width: 16, height: 16)

            if let audioIndicatorIcon {
                Button(action: onToggleMute) {
                    Image(systemName: audioIndicatorIcon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonTreatment(.content)
                .foregroundStyle(isActive ? InterfaceStyle.sidebarText : InterfaceStyle.sidebarIcon)
                .help(mediaState?.isMuted == true ? "Unmute Tab" : "Mute Tab")
                .transition(.opacity)
            }

            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? InterfaceStyle.sidebarText : InterfaceStyle.sidebarTextSecondary)

            Spacer(minLength: 0)

        }
        .padding(.horizontal, 8)
        // The close button floats over the trailing edge instead of holding a
        // slot in the stack, so a resting row's title is inset by the same 8pt
        // on both sides. Only a hovered row gives up room for the button.
        .padding(.trailing, isHovering ? closeButtonWidth + 8 : 0)
        .padding(.vertical, 6)
        // Zen's row height: Firefox's 36pt --tab-min-height, which Zen keeps.
        .frame(minHeight: 36)
        .overlay(alignment: .trailing) { closeButton }
        .contentShape(Rectangle())
        .background(rowBackground)
        .background(TabHoverTracker(isHovering: $isPointerInside))
        .clipShape(RoundedRectangle(cornerRadius: InterfaceStyle.sidebarRowCornerRadius, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tab-row-\(candoaAccessibilitySlug(tab.title))")
        .contextMenu {
            if mediaState?.hasMedia == true {
                Button(mediaState?.isMuted == true ? "Unmute Tab" : "Mute Tab", action: onToggleMute)
            }
            Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
            Button(BrowserCommandTitles.duplicateTab, action: onDuplicate)
            if isSplitMember {
                // Was on the group pill's chips; the pill is gone, and a
                // member still needs a way out of the split from the sidebar.
                Button("Remove from Split View", action: onRemoveFromSplit)
            } else {
                Button("Open in Split View", action: onOpenInSplit)
            }
            Button("Close Tab", action: onClose)
            Button(BrowserCommandTitles.closeOtherTabs, action: onCloseOthers)
        }
        // Hover is the fill alone — a stroke around it as well made a passing
        // pointer draw a box, and read as a selected or targeted row.
        .animation(.easeOut(duration: 0.10), value: isHovering)
        // Selection moves with a fast fade rather than a hard swap, and the
        // speaker indicator eases in instead of shoving the title sideways.
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.14), value: audioIndicatorIcon)
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
        .help("Close Tab")
        .padding(.trailing, 8)
        .opacity(isHovering ? 1 : 0)
        .accessibilityHidden(!isHovering)
    }

    // Muted shows whenever the page holds media (so the user can find and
    // unmute it later); the speaker only shows while audio is playing.
    private var audioIndicatorIcon: String? {
        guard let mediaState, mediaState.hasMedia else { return nil }
        if mediaState.isMuted { return "speaker.slash.fill" }
        if mediaState.isPlaying { return "speaker.wave.2.fill" }
        return nil
    }

    private var rowBackground: Color {
        if isActive {
            return InterfaceStyle.sidebarControlFillActive
        }
        if isHovering {
            return InterfaceStyle.sidebarControlFillHover
        }
        return Color.clear
    }

    @ViewBuilder
    private var faviconImage: some View {
        if let data = tab.faviconData,
           let nsImage = NSImage(data: data) {
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

private struct TabHoverTracker: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverChange = { isHovering = $0 }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHoverChange = { isHovering = $0 }
        view.scheduleHoverSync()
    }

    final class TrackingView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var pendingHoverSync = false

        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            // .mouseMoved matters: a row inserted under a stationary cursor
            // never gets a mouseEntered crossing, so moves inside the row are
            // the only signal that the cursor is here.
            // .enabledDuringMouseDrag keeps crossings firing during tab drag
            // sessions — without it the dragged row's exit is swallowed and
            // its hover highlight (and close button) sticks after the drop.
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeInKeyWindow,
                    .inVisibleRect,
                    .enabledDuringMouseDrag
                ],
                owner: self
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea

            super.updateTrackingAreas()
            scheduleHoverSync()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleHoverSync()
        }

        // The first syncHoverState can run before SwiftUI has sized this
        // view (bounds still .zero), reporting "outside" for a cursor that
        // is actually over the row. Re-sync once real geometry arrives.
        override func layout() {
            super.layout()
            scheduleHoverSync()
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseMoved(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            syncHoverState()
        }

        // Layout-driven syncs (updateNSView, layout, updateTrackingAreas)
        // run inside SwiftUI's view update, where writing the hover binding
        // is undefined behavior — defer those one runloop turn. Mouse event
        // handlers stay synchronous.
        func scheduleHoverSync() {
            guard !pendingHoverSync else { return }
            pendingHoverSync = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingHoverSync = false
                self.syncHoverState()
            }
        }

        private func syncHoverState() {
            guard let window else {
                onHoverChange?(false)
                return
            }

            let windowLocation = window.mouseLocationOutsideOfEventStream
            let localLocation = convert(windowLocation, from: nil)
            onHoverChange?(bounds.contains(localLocation))
        }
    }
}

/// Miniature page card shown while a tab travels: the drag preview for
/// sidebar tab drags and the cursor-following ghost during pane reorders.
/// A page-shaped ghost tells the user "you are moving this page" the way
/// AppKit drag images do. Content is suggested with placeholder lines —
/// never a live web snapshot.
struct TabDragGhost: View {
    let tab: BrowserTab
    var width: CGFloat = 168
    var height: CGFloat = 112

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                faviconImage
                    .frame(width: 13, height: 13)

                Text(displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(InterfaceStyle.sidebarText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(InterfaceStyle.sidebarControlFill)

            Rectangle()
                .fill(InterfaceStyle.surfaceBorder)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bodyLineWidths.enumerated()), id: \.offset) { _, fraction in
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: max(24, (width - 20) * fraction), height: 5)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(InterfaceStyle.surfaceFill)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(InterfaceStyle.surfaceBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
    }

    private var displayTitle: String {
        if !tab.title.isEmpty {
            return tab.title
        }
        return tab.url?.host() ?? "New Tab"
    }

    private var bodyLineWidths: [CGFloat] {
        [0.82, 0.56, 0.7]
    }

    @ViewBuilder
    private var faviconImage: some View {
        if let data = tab.faviconData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: tab.faviconSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(InterfaceStyle.sidebarIcon)
        }
    }
}
