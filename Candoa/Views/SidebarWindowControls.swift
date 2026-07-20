import AppKit
import SwiftUI

// MARK: - Window controls

@MainActor
internal struct SidebarRevealEffect: @MainActor AnimatableModifier {
    var progress: CGFloat
    let hiddenOffset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .transformEffect(CGAffineTransform(
                translationX: hiddenOffset * (1 - progress),
                y: 0
            ))
            .environment(\.sidebarRevealProgress, progress)
    }
}

private struct SidebarRevealProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private extension EnvironmentValues {
    var sidebarRevealProgress: CGFloat {
        get { self[SidebarRevealProgressKey.self] }
        set { self[SidebarRevealProgressKey.self] = newValue }
    }
}

internal struct WindowControlsView: View {
    @Environment(\.sidebarRevealProgress) private var revealProgress
    let hiddenOffset: CGFloat

    var body: some View {
        NativeWindowControlsView(
            revealProgress: revealProgress,
            hiddenOffset: hiddenOffset
        )
    }
}
internal struct NativeWindowControlsView: NSViewRepresentable {
    let revealProgress: CGFloat
    let hiddenOffset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NativeWindowControlsHost()
        view.configure(revealProgress: revealProgress, hiddenOffset: hiddenOffset)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NativeWindowControlsHost)?.configure(
            revealProgress: revealProgress,
            hiddenOffset: hiddenOffset
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? NativeWindowControlsHost)?.restoreWindowControls()
    }
}

private final class NativeWindowControlsHost: NSView {
    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton
    ]
    private static let fallbackButtonSize = NSSize(width: 14, height: 14)
    private weak var attachedWindow: NSWindow?
    private var originalFrames: [Int: NSRect] = [:]
    private var originalHiddenStates: [Int: Bool] = [:]
    private var revealProgress: CGFloat = 1
    private var hiddenOffset: CGFloat = 0
    private var attachmentGeneration = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindowControls()

        guard let window else { return }
        attachmentGeneration += 1
        let generation = attachmentGeneration

        // SwiftUI applies the hidden-title-bar style after representable views
        // attach. AppKit may rebuild the title-bar container in that pass, so
        // reclaim and position the same native buttons once the window interface
        // has settled. This is a one-shot setup correction, not a timer.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.window === window,
                  self.attachmentGeneration == generation else { return }
            self.attachWindowControls()
        }
    }

    func configure(revealProgress: CGFloat, hiddenOffset: CGFloat) {
        self.revealProgress = min(max(revealProgress, 0), 1)
        self.hiddenOffset = hiddenOffset
        attachWindowControls()
    }

    func attachWindowControls() {
        guard let window else { return }

        if let attachedWindow, attachedWindow !== window {
            restoreWindowControls()
        }

        attachedWindow = window

        for buttonType in Self.buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            if originalFrames[key] == nil {
                originalFrames[key] = button.frame
                originalHiddenStates[key] = button.isHidden
            }
        }

        layoutWindowControls()
    }

    func restoreWindowControls() {
        guard let attachedWindow else { return }

        attachmentGeneration += 1

        for buttonType in Self.buttonTypes {
            guard let button = attachedWindow.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            if let originalFrame = originalFrames[key] {
                button.frame = originalFrame
            }

            if let wasHidden = originalHiddenStates[key] {
                button.isHidden = wasHidden
            }
        }

        originalFrames.removeAll()
        originalHiddenStates.removeAll()
        self.attachedWindow = nil
    }

    override func layout() {
        super.layout()
        layoutWindowControls()
    }

    private func layoutWindowControls() {
        guard let attachedWindow else { return }

        for buttonType in Self.buttonTypes {
            guard let button = attachedWindow.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            // The controls belong to the sidebar, not the web-content lane.
            // Keep AppKit as their owner and hide them at the landed closed
            // state so a later title-bar layout pass cannot expose them over
            // the active WKWebView.
            guard revealProgress > 0 else {
                button.isHidden = true
                continue
            }

            let currentSize = button.frame.size
            let buttonSize = currentSize.width > 0 && currentSize.height > 0
                ? currentSize
                : Self.fallbackButtonSize
            button.isHidden = false
            let originalFrame = originalFrames[key] ?? button.frame
            button.frame = NSRect(
                origin: CGPoint(
                    x: originalFrame.minX + hiddenOffset * (1 - revealProgress),
                    y: originalFrame.minY
                ),
                size: buttonSize
            )
        }
    }
}

// MARK: - Toolbar icon button

internal struct ToolbarIconButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 25, height: 25)
            .offset(y: -2)
            .contentShape(Rectangle())
    }
}

internal extension View {
    func toolbarIconButton() -> some View {
        modifier(ToolbarIconButtonModifier())
    }
}

// MARK: - Shared interface styling

/// Candoa's semantic color tokens. Native controls follow the person's macOS
/// accent preference; explicit blue uses Apple's adaptable system blue.
