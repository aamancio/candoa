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
    let isSplit: Bool
    let accentColor: Color
    let mediaState: TabMediaState?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onOpenInSplit: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onToggleMute: () -> Void

    @State private var isHovering = false

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
                .candoaButton(.content)
                .foregroundStyle(isActive ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarIcon)
                .help(mediaState?.isMuted == true ? "Unmute Tab" : "Mute Tab")
                .transition(.opacity)
            }

            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarTextSecondary)

            Spacer(minLength: 8)

            if isSplit {
                Image(systemName: "rectangle.split.2x1")
                    .font(.caption)
                    .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .candoaButton(.content)
            .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
            .help("Close Tab")
            .opacity(isHovering ? 1 : 0)
            .accessibilityHidden(!isHovering)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .background(rowBackground)
        .background(TabHoverTracker(isHovering: $isHovering))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            Button("Open in Split View", action: onOpenInSplit)
            Button("Close Tab", action: onClose)
        }
        .overlay {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CandoaInterfaceStyle.sidebarControlStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.10), value: isHovering)
        // Selection moves with a fast fade rather than a hard swap, and the
        // speaker indicator eases in instead of shoving the title sideways.
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.14), value: audioIndicatorIcon)
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
            return accentColor.opacity(0.18)
        }
        if isHovering {
            return CandoaInterfaceStyle.sidebarControlFillHover
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
                .foregroundStyle(isActive ? CandoaInterfaceStyle.sidebarText : CandoaInterfaceStyle.sidebarIcon)
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
                    .foregroundStyle(CandoaInterfaceStyle.sidebarText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(CandoaInterfaceStyle.sidebarControlFill)

            Rectangle()
                .fill(CandoaInterfaceStyle.surfaceBorder)
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
            .background(CandoaInterfaceStyle.surfaceFill)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
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
                .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
        }
    }
}
