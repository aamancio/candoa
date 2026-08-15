import AppKit
import SwiftUI

internal struct SplitDividerDragState: Equatable {
    var dividerIndex: Int
    var translation: CGFloat
}

internal struct SplitPaneReorderState: Equatable {
    var sourceIndex: Int
    var location: CGPoint
}

/// The draggable handle between two adjacent split panes. It rides in the
/// panes' 8pt gutter, shows the axis-appropriate resize cursor on hover, and
/// highlights while dragging (the panes themselves commit their new lengths
/// on release). Double-click resets the whole split to equal panes.
internal struct SplitPaneDivider: View {
    /// The axis panes are laid out along: .horizontal dividers sit between
    /// columns (a vertical line), .vertical dividers between rows.
    let axis: Axis
    let isDragging: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(
                    isDragging
                        ? AppColor.accent.opacity(0.85)
                        : Color.primary.opacity(isHovering ? 0.28 : 0)
                )
                .frame(
                    width: axis == .horizontal ? (isDragging ? 3 : 2) : nil,
                    height: axis == .vertical ? (isDragging ? 3 : 2) : nil
                )
                .frame(
                    maxWidth: axis == .vertical ? .infinity : nil,
                    maxHeight: axis == .horizontal ? .infinity : nil
                )
                .padding(axis == .horizontal ? .vertical : .horizontal, 10)
        }
        .onHover { isHovering = $0 }
        .aiSidebarCursor(
            axis == .horizontal ? AISidebarResizeCursor.horizontal : AISidebarResizeCursor.vertical
        )
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    onDragChanged(axis == .horizontal ? value.translation.width : value.translation.height)
                }
                .onEnded { value in
                    onDragEnded(axis == .horizontal ? value.translation.width : value.translation.height)
                }
        )
        .onTapGesture(count: 2, perform: onReset)
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .animation(.easeOut(duration: 0.10), value: isDragging)
        .help("Drag to resize panes; double-click for equal panes")
    }
}

/// Zen-style control pill at a pane's top center, revealed on hover: a
/// six-dot grab area that drags the pane to another slot (the target pane
/// highlights, the reorder commits on release — panes never relayout
/// mid-drag), a zoom toggle that gives the pane the whole surface and back,
/// and an unsplit button. The pill's footprint is small so the rest of the
/// page's top edge stays clickable.
///
/// A zoomed pane's pill drops to the zoom control alone and stops hiding
/// itself: with the other panes off screen it is the only sign that a split
/// is still waiting underneath, and forgetting you are in a mode is the one
/// real cost of zoom. Moving or unsplitting a pane means nothing while it is
/// the only one showing, so those controls step aside for the way out.
internal struct SplitPaneControlPill: View {
    /// The pointer is over the pane (reported by the pane host's tracking
    /// area) — the discoverable way the pill reveals itself.
    let isPaneHovered: Bool
    let isDraggingThisPane: Bool
    let isZoomed: Bool
    let paneIndex: Int
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onUnsplit: () -> Void
    let onToggleZoom: () -> Void

    @State private var isHovering = false

    private var isRevealed: Bool {
        isZoomed || isPaneHovered || isHovering || isDraggingThisPane
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isZoomed {
                gripDots
                .frame(width: 34, height: 20)
                .contentShape(Rectangle())
                // Grab cursors live in the AppKit layer: the open hand
                // as a re-asserted hover cursor (WebKit fights one-shot
                // pushes over web content), the closed hand from the
                // NSView's mouseDown — SwiftUI's zero-distance
                // DragGesture does not track dependably on macOS, so the
                // press itself must be caught natively.
                .modifier(SplitPaneGripCursorModifier())
                .gesture(
                    DragGesture(
                        minimumDistance: 2,
                        coordinateSpace: .named(WebViewContainer.splitRowCoordinateSpace)
                    )
                    .onChanged { value in
                        onDragChanged(value.location)
                    }
                    .onEnded { value in
                        onDragEnded(value.location)
                    }
                )
                .help("Drag to move this pane")
                .accessibilityElement()
                .accessibilityLabel("Move Pane")
                .accessibilityIdentifier("split-pane-grip-\(paneIndex)")
            }

            Button(action: onToggleZoom) {
                Image(
                    systemName: isZoomed
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
            }
            .buttonTreatment(.content)
            .foregroundStyle(isZoomed ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.secondary))
            .help(isZoomed ? BrowserCommandTitles.showAllSplitPanes : BrowserCommandTitles.zoomSplitPane)
            .accessibilityLabel(isZoomed ? BrowserCommandTitles.showAllSplitPanes : BrowserCommandTitles.zoomSplitPane)
            .accessibilityIdentifier("split-pane-zoom-\(paneIndex)")

            if !isZoomed {
                // Unsplit used to wear the outward-arrows glyph, which now
                // belongs to zoom — two buttons in one pill cannot both mean
                // "make this bigger". The door glyph says what unsplit
                // actually does: this pane leaves the group.
                Button(action: onUnsplit) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonTreatment(.content)
                .foregroundStyle(.secondary)
                .help("Unsplit — Move Back to Tab List")
                .accessibilityLabel("Unsplit")
                .accessibilityIdentifier("split-pane-unsplit-\(paneIndex)")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(InterfaceStyle.popoverBorder, lineWidth: 1)
        }
        // Not 0: fully transparent views stop hit-testing, and the pill must
        // keep its hover/click footprint while visually absent.
        .opacity(isRevealed ? 1 : 0.02)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isRevealed)
    }

    private var gripDots: some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(
                                isDraggingThisPane
                                    ? AppColor.accent
                                    : Color.secondary
                            )
                            .frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
    }
}

/// Grab-cursor feedback for the pane grip, handled in AppKit because both
/// halves fail in SwiftUI: hover cursors over web content are re-asserted
/// away by WebKit, and a zero-distance DragGesture does not track dependably
/// on macOS, so mouse-down must be caught natively. The NSView owns every
/// cursor assertion; SwiftUI-side hover sets were racing WebKit's tracking
/// areas within the same event and the alternation read as flicker.
private struct SplitPaneGripCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SplitPaneGripCursorView())
    }
}

private struct SplitPaneGripCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> SplitPaneGripCursorNSView {
        SplitPaneGripCursorNSView()
    }

    func updateNSView(_ nsView: SplitPaneGripCursorNSView, context: Context) {}
}

private final class SplitPaneGripCursorNSView: NSView {
    private var monitor: Any?
    private var hasPushedClosedHand = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
            popClosedHandIfNeeded()
        } else {
            installMonitorIfNeeded()
        }
    }

    // SwiftUI's hosting view hit-tests its gesture regions to itself, so
    // this view never receives mouse events directly — the monitor sees
    // them before dispatch, the same way the pane focus and tab drag
    // monitors do. Presses and drags pass through untouched (the SwiftUI
    // drag gesture needs them); only mouseMoved inside the grip is
    // swallowed, so WebKit never processes those moves and cannot answer
    // them with a page-cursor change.
    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            // Local event monitors always run on the main thread. NSEvent is
            // not Sendable, so the isolated closure returns only the swallow
            // decision rather than the event itself.
            let swallowed = MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
            return swallowed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns true when the event was consumed for the grip's cursor.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard isEventInside(event) else { return false }
            if !hasPushedClosedHand {
                hasPushedClosedHand = true
                NSCursor.closedHand.push()
            }
            return false
        case .leftMouseUp:
            popClosedHandIfNeeded()
            return false
        case .mouseMoved:
            guard isEventInside(event), !hasPushedClosedHand else { return false }
            // Swallowing the move starves WebKit of the event, so its
            // asynchronous web-process round trip can't land a page cursor
            // AFTER ours — that late reply is why the hand only appeared
            // once the pointer rested. The deferred re-assert still covers
            // replies already in flight from moves just outside the grip.
            NSCursor.openHand.set()
            assertCursorAfterWebKit(.openHand)
            return true
        case .leftMouseDragged:
            // The grip drag keeps the fist wherever the pointer travels.
            // Never swallowed: the SwiftUI drag gesture tracks these.
            guard hasPushedClosedHand else { return false }
            assertCursorAfterWebKit(.closedHand)
            return false
        default:
            return false
        }
    }

    private func isEventInside(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let location = convert(event.locationInWindow, from: nil)
        return bounds.contains(location) && visibleRect.contains(location)
    }

    // WebKit answers earlier mouse moves asynchronously (web-process IPC),
    // so a cursor it decided moments ago can land after a synchronous set.
    // Re-asserting on the next runloop turn wins over those stragglers.
    private func assertCursorAfterWebKit(_ cursor: NSCursor) {
        DispatchQueue.main.async { [weak self] in
            guard self?.window != nil else { return }
            cursor.set()
        }
    }

    private func popClosedHandIfNeeded() {
        guard hasPushedClosedHand else { return }
        hasPushedClosedHand = false
        NSCursor.pop()
    }
}
