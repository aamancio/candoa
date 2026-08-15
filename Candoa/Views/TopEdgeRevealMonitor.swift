import AppKit
import SwiftUI

/// Reveals the hidden-sidebar address strip while the pointer is at the
/// window's top edge.
///
/// A local mouse-moved monitor rather than SwiftUI hover or a tracking area:
/// the strip floats over a WKWebView, and neither of those reliably sees the
/// pointer there. This mirrors how the sidebar's own edge reveal works.
///
/// Two distances, not one: the pointer only has to reach the very top to
/// reveal the strip, but it can travel down across the strip's own controls —
/// the lock, the address, the copy button — before it hides again.
struct TopEdgeRevealMonitor: NSViewRepresentable {
    let isEnabled: Bool
    @Binding var isRevealed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = MouseMovedOptInView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitorIfNeeded()
        updateCoordinator(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        updateCoordinator(context.coordinator)
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.isEnabled = isEnabled
        coordinator.isRevealed = $isRevealed
        if !isEnabled, isRevealed {
            isRevealed = false
        }
    }

    /// Windows do not deliver `.mouseMoved` unless something asks for it, and
    /// over a WKWebView nothing in this window does — the pointer would cross
    /// the top edge in silence. The view also stays out of the page's way:
    /// it spans the surface only to measure from its top edge.
    private final class MouseMovedOptInView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    final class Coordinator {
        var isEnabled = false
        var isRevealed: Binding<Bool>?
        weak var view: NSView?
        private var monitor: Any?

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self, isEnabled,
                      let view, let window = view.window else {
                    return event
                }

                // Measured against the web surface, not the window: the card
                // is inset from the window's edges and the strip sits at the
                // card's top. Events can also arrive windowless (moves that
                // begin outside the window), where locationInWindow is
                // already screen-relative — so the pointer is read from the
                // screen and converted once, for both kinds.
                let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                guard window.contentLayoutRect.insetBy(dx: -8, dy: -8).contains(inWindow) else {
                    return event
                }

                let pointer = view.convert(inWindow, from: nil)
                // Above the card — the window's own top chrome — counts as
                // the top edge: a fast upward flick can skip the band
                // entirely otherwise.
                let distanceFromTop = max(view.bounds.maxY - pointer.y, 0)

                if distanceFromTop <= AddressBarRevealConfiguration.revealDistanceFromTopEdge {
                    isRevealed?.wrappedValue = true
                } else if isRevealed?.wrappedValue == true,
                          distanceFromTop > AddressBarRevealConfiguration.hideDistanceFromTopEdge {
                    isRevealed?.wrappedValue = false
                }

                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
