import AppKit
import SwiftUI

struct MouseMoveMonitor: NSViewRepresentable {
    @Binding var isSidebarVisible: Bool
    @Binding var isSidebarHoverRevealed: Bool
    @Binding var isSidebarRevealSuppressed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
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
        coordinator.isSidebarVisible = $isSidebarVisible
        coordinator.isSidebarHoverRevealed = $isSidebarHoverRevealed
        coordinator.isSidebarRevealSuppressed = $isSidebarRevealSuppressed
    }

    final class Coordinator {
        var isSidebarVisible: Binding<Bool>?
        var isSidebarHoverRevealed: Binding<Bool>?
        var isSidebarRevealSuppressed: Binding<Bool>?
        weak var view: NSView?
        private var monitor: Any?

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                // Windowless events carry screen coordinates, not window-local
                // ones, so the edge math below would misfire on them.
                guard let self, event.window != nil, isSidebarVisible?.wrappedValue == false else {
                    return event
                }

                let xPosition = event.locationInWindow.x
                if isSidebarRevealSuppressed?.wrappedValue == true {
                    if xPosition > SidebarRevealConfiguration.suppressionResetDistance {
                        isSidebarRevealSuppressed?.wrappedValue = false
                    }
                    return event
                }

                if xPosition <= SidebarRevealConfiguration.revealDistanceFromLeftEdge {
                    isSidebarHoverRevealed?.wrappedValue = true
                } else if isSidebarHoverRevealed?.wrappedValue == true &&
                            xPosition > SidebarRevealConfiguration.hideDistanceFromLeftEdge {
                    isSidebarHoverRevealed?.wrappedValue = false
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
