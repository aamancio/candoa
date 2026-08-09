import AppKit
import SwiftUI

// MARK: - Key-cap resolution

/// Translates stored shortcut strings ("Shift-Command-T") into the key-cap
/// glyphs a tooltip displays (["⇧", "⌘", "T"]).
enum ShortcutKeyCaps {
    /// Resolves the person's configured shortcut for `definition` at call time,
    /// so a rebind in Settings → Shortcuts is reflected on the next hover.
    /// Returns an empty array when the shortcut is removed or unassigned.
    static func current(for definition: ShortcutDefinition) -> [String] {
        let stored = UserDefaults.standard.string(forKey: definition.storageKey) ?? ""
        guard stored != ShortcutDefinition.removedValue else { return [] }
        return caps(from: stored.isEmpty ? definition.defaultShortcut : stored)
    }

    static func caps(from shortcut: String) -> [String] {
        guard !shortcut.isEmpty, shortcut != "None" else { return [] }

        var components = shortcut.components(separatedBy: "-")
        // A literal "-" key ("Command--") splits into trailing empty components.
        if components.last == "" {
            components.removeAll { $0.isEmpty }
            components.append("-")
        }

        return components.map { glyph(for: $0) }
    }

    private static func glyph(for component: String) -> String {
        switch component {
        case "Control": return "⌃"
        case "Option": return "⌥"
        case "Shift": return "⇧"
        case "Command": return "⌘"
        case "Tab": return "⇥"
        case "Left": return "←"
        case "Right": return "→"
        case "Up": return "↑"
        case "Down": return "↓"
        default: return component.uppercased()
        }
    }
}

// MARK: - Tooltip pill

/// The Dia-style tooltip pill: action title followed by individual key caps.
/// Deliberately dark in both appearances, and never tinted by the active
/// space theme (themes are backdrop-only).
struct ShortcutTooltipView: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.96))

            if !keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(minWidth: 18)
                            .frame(height: 18)
                            .padding(.horizontal, key.count > 1 ? 4 : 0)
                            .background(
                                Color.white.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            )
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, keys.isEmpty ? 10 : 6)
        .frame(height: 30)
        .background(
            Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.98),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .fixedSize()
    }
}

// MARK: - Presentation controller

/// Presents one shared tooltip panel at a time. The panel exists only while a
/// tooltip is on screen — it is created on show and released on hide, and it
/// never accepts mouse events, so it cannot intercept clicks or disturb the
/// hover-reveal sidebar.
///
/// Hover detection rides a local `.mouseMoved` event monitor (the same
/// mechanism as `MouseMoveMonitor`) rather than tracking areas, because the
/// chrome icons sit in the window's title-bar strip where AppKit does not
/// deliver tracking-area enter/exit events. The monitor is passive — it runs
/// only when the active app receives a genuine mouse-move — and exists only
/// while at least one tooltip anchor is installed. Main thread only.
@MainActor
final class ShortcutTooltipController {
    static let shared = ShortcutTooltipController()

    private let anchors = NSHashTable<ShortcutTooltipAnchorView>.weakObjects()
    private weak var hoveredAnchor: ShortcutTooltipAnchorView?
    private weak var anchorView: NSView?
    private var moveMonitor: Any?
    private var pendingShow: DispatchWorkItem?
    private var panel: NSPanel?
    private var dismissMonitor: Any?

    private init() {}

    func register(_ anchor: ShortcutTooltipAnchorView) {
        anchors.add(anchor)
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            // Local event monitors always run on the main thread.
            MainActor.assumeIsolated {
                ShortcutTooltipController.shared.handleMouseMoved(event)
            }
            return event
        }
    }

    func unregister(_ anchor: ShortcutTooltipAnchorView) {
        anchors.remove(anchor)
        dismiss(for: anchor)
        if hoveredAnchor === anchor {
            hoveredAnchor = nil
        }
        if anchors.count == 0, let moveMonitor {
            NSEvent.removeMonitor(moveMonitor)
            self.moveMonitor = nil
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        let target = anchors.allObjects.first { anchor in
            guard let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor else {
                return false
            }

            // Moves over parts of the title-bar strip arrive windowless and
            // carry screen coordinates (see MouseMoveMonitor); convert those
            // into the anchor's window before hit-testing.
            let locationInWindow: NSPoint
            if let eventWindow = event.window {
                guard eventWindow === window else { return false }
                locationInWindow = event.locationInWindow
            } else {
                guard window.isKeyWindow else { return false }
                locationInWindow = window.convertPoint(fromScreen: event.locationInWindow)
            }
            return anchor.bounds.contains(anchor.convert(locationInWindow, from: nil))
        }

        if target !== hoveredAnchor {
            if let hoveredAnchor {
                dismiss(for: hoveredAnchor)
            }
            hoveredAnchor = target
            if let target {
                schedule(anchor: target, content: target.content)
            }
        } else if let target, pendingShow != nil {
            // Arc-style timing: the delay counts from when the pointer comes
            // to REST, not from when it enters the icon — every move restarts
            // the countdown, so a hand still in motion never pops the
            // tooltip. Once shown (pendingShow is nil), moves inside the
            // icon leave it up, matching system tooltips.
            schedule(anchor: target, content: target.content)
        }
    }

    private func schedule(
        anchor: NSView,
        delay: TimeInterval = 0.7,
        content: @escaping () -> (title: String, keys: [String])
    ) {
        cancelPendingShow()
        hidePanel()
        anchorView = anchor

        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            self.pendingShow = nil
            let content = content()
            self.show(anchor: anchor, title: content.title, keys: content.keys)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismiss(for anchor: NSView) {
        guard anchorView === anchor else { return }
        cancelPendingShow()
        hidePanel()
        anchorView = nil
    }

    private func show(anchor: NSView, title: String, keys: [String]) {
        guard let window = anchor.window, window.isVisible else { return }

        let hosting = NSHostingView(rootView: ShortcutTooltipView(title: title, keys: keys))
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.setFrameOrigin(origin(for: panel, anchor: anchor, window: window))

        self.panel = panel
        panel.orderFront(nil)
        installDismissMonitor()
    }

    /// Centers the tooltip below the anchor, clamped inside the screen so it
    /// never clips at window edges; flips above the anchor when there is no
    /// room underneath.
    private func origin(for panel: NSPanel, anchor: NSView, window: NSWindow) -> NSPoint {
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(
            x: anchorRect.midX - size.width / 2,
            y: anchorRect.minY - size.height - 6
        )

        if let limit = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, limit.minX + 8), limit.maxX - size.width - 8)
            if origin.y < limit.minY + 4 {
                origin.y = anchorRect.maxY + 6
            }
        }
        return origin
    }

    /// Any click, scroll, or key press dismisses the tooltip immediately,
    /// mirroring system tooltip behavior. The monitor lives only while the
    /// panel is visible.
    private func installDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { event in
            // Local event monitors always run on the main thread.
            MainActor.assumeIsolated {
                ShortcutTooltipController.shared.cancelPendingShow()
                ShortcutTooltipController.shared.hidePanel()
            }
            return event
        }
    }

    private func cancelPendingShow() {
        pendingShow?.cancel()
        pendingShow = nil
    }

    private func hidePanel() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }
}

// MARK: - View modifier

/// Marks the hoverable footprint of a chrome icon. The shared controller's
/// mouse-move monitor hit-tests these anchors to drive tooltip show/hide.
final class ShortcutTooltipAnchorView: NSView {
    var content: () -> (title: String, keys: [String]) = { ("", []) }

    // The anchor is purely an invisible measurement view; opting out of
    // hit-testing ensures it can never swallow the button's clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ShortcutTooltipController.shared.unregister(self)
        } else {
            ShortcutTooltipController.shared.register(self)
        }
    }
}

private struct ShortcutTooltipAnchor: NSViewRepresentable {
    let content: () -> (title: String, keys: [String])

    func makeNSView(context: Context) -> ShortcutTooltipAnchorView {
        let view = ShortcutTooltipAnchorView(frame: .zero)
        view.content = content
        return view
    }

    func updateNSView(_ nsView: ShortcutTooltipAnchorView, context: Context) {
        nsView.content = content
    }
}

private struct ShortcutTooltipModifier: ViewModifier {
    let title: String
    let keyCaps: (() -> [String])?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let keyCaps {
            let title = title
            content
                .background(
                    ShortcutTooltipAnchor {
                        (title, keyCaps())
                    }
                )
                .accessibilityLabel(title)
        } else {
            // The pill exists to surface key caps; icons without a shortcut
            // keep the plain system tooltip.
            content.help(title)
        }
    }
}

extension View {
    /// Replaces `.help()` on chrome icons that have a keyboard shortcut with
    /// the Dia-style tooltip pill showing the person's configured key caps.
    /// Without a shortcut definition it falls back to the plain system
    /// `.help()` tooltip.
    func shortcutTooltip(
        _ title: String,
        shortcut: ShortcutDefinition? = nil
    ) -> some View {
        modifier(
            ShortcutTooltipModifier(
                title: title,
                keyCaps: shortcut.map { definition in
                    { ShortcutKeyCaps.current(for: definition) }
                }
            )
        )
    }

    /// Pill variant for shortcuts that are not user-configurable
    /// (e.g. the hardwired ⌃1–⌃9 space switching). Empty `keys` falls back
    /// to the plain system `.help()` tooltip.
    func shortcutTooltip(
        _ title: String,
        keys: [String]
    ) -> some View {
        modifier(
            ShortcutTooltipModifier(
                title: title,
                keyCaps: keys.isEmpty ? nil : { keys }
            )
        )
    }
}
