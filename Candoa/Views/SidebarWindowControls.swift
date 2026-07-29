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

    var body: some View {
        NativeWindowControlsView(
            revealProgress: revealProgress
        )
    }
}
internal struct NativeWindowControlsView: NSViewRepresentable {
    let revealProgress: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NativeWindowControlsHost()
        view.configure(revealProgress: revealProgress)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NativeWindowControlsHost)?.configure(
            revealProgress: revealProgress
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? NativeWindowControlsHost)?.restoreWindowControls()
    }
}

private final class NativeWindowControlsHost: NSView {
    private weak var controlsCoordinator: NativeWindowControlsCoordinator?
    private var revealProgress: CGFloat = 1
    private var attachmentGeneration = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindowControlsIfPossible()

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
            self.attachWindowControlsIfPossible()
        }
    }

    func configure(revealProgress: CGFloat) {
        self.revealProgress = min(max(revealProgress, 0), 1)
        attachWindowControlsIfPossible()
    }

    private func attachWindowControlsIfPossible() {
        guard let window else { return }
        let coordinator = NativeWindowControlsCoordinator.coordinator(for: window)
        controlsCoordinator = coordinator
        coordinator.attachControls(to: self, revealProgress: revealProgress)
    }

    func restoreWindowControls() {
        attachmentGeneration += 1
        controlsCoordinator?.detachControls(from: self)
        controlsCoordinator = nil
    }

    override func layout() {
        super.layout()
        controlsCoordinator?.layoutControls(
            in: self,
            revealProgress: revealProgress
        )
    }
}

@MainActor
private final class NativeWindowControlsCoordinator {
    @MainActor
    private final class OriginalPlacement {
        weak var superview: NSView?
        let frame: NSRect
        let isHidden: Bool
        let translatesAutoresizingMaskIntoConstraints: Bool

        init(button: NSButton) {
            superview = button.superview
            frame = button.frame
            isHidden = button.isHidden
            translatesAutoresizingMaskIntoConstraints = button.translatesAutoresizingMaskIntoConstraints
        }
    }

    private static let coordinators = NSMapTable<NSWindow, NativeWindowControlsCoordinator>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton
    ]
    private static let fallbackButtonSize = NSSize(width: 14, height: 14)
    private static let leadingInset: CGFloat = 4
    private static let buttonSpacing: CGFloat = 6

    private weak var window: NSWindow?
    private weak var activeHost: NativeWindowControlsHost?
    private var originalPlacements: [Int: OriginalPlacement] = [:]

    private init(window: NSWindow) {
        self.window = window
    }

    static func coordinator(for window: NSWindow) -> NativeWindowControlsCoordinator {
        if let existing = coordinators.object(forKey: window) {
            return existing
        }

        let coordinator = NativeWindowControlsCoordinator(window: window)
        coordinators.setObject(coordinator, forKey: window)
        return coordinator
    }

    func attachControls(
        to host: NativeWindowControlsHost,
        revealProgress: CGFloat
    ) {
        guard let window else { return }
        activeHost = host

        for buttonType in Self.buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            if originalPlacements[key] == nil,
               !(button.superview is NativeWindowControlsHost) {
                originalPlacements[key] = OriginalPlacement(button: button)
            }

            if button.superview !== host {
                button.removeFromSuperview()
                host.addSubview(button)
            }
            button.translatesAutoresizingMaskIntoConstraints = true
        }

        layoutControls(in: host, revealProgress: revealProgress)
    }

    func layoutControls(
        in host: NativeWindowControlsHost,
        revealProgress: CGFloat
    ) {
        guard activeHost === host, let window else { return }

        var nextX = Self.leadingInset
        for buttonType in Self.buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let currentSize = button.frame.size
            let buttonSize = currentSize.width > 0 && currentSize.height > 0
                ? currentSize
                : Self.fallbackButtonSize
            button.isHidden = revealProgress <= 0
            button.frame = NSRect(
                x: nextX,
                y: (host.bounds.height - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
            nextX += buttonSize.width + Self.buttonSpacing
        }
    }

    func detachControls(from host: NativeWindowControlsHost) {
        guard activeHost === host else { return }
        restoreControls()
    }

    private func restoreControls() {
        guard let window else { return }

        for buttonType in Self.buttonTypes {
            guard
                let button = window.standardWindowButton(buttonType),
                let placement = originalPlacements[Int(buttonType.rawValue)],
                let originalSuperview = placement.superview
            else {
                continue
            }

            if button.superview !== originalSuperview {
                button.removeFromSuperview()
                originalSuperview.addSubview(button)
            }
            button.translatesAutoresizingMaskIntoConstraints =
                placement.translatesAutoresizingMaskIntoConstraints
            button.frame = placement.frame
            button.isHidden = placement.isHidden
        }

        activeHost = nil
    }
}

// MARK: - Toolbar icon button

internal struct ToolbarIconButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .candoaButton(.content)
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
