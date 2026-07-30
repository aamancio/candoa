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
        (nsView as? NativeWindowControlsHost)?.configure(revealProgress: revealProgress)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? NativeWindowControlsHost)?.restoreWindowControls()
    }
}

private final class NativeWindowControlsHost: NSView {
    private weak var controlsCoordinator: NativeWindowControlsCoordinator?
    private var revealProgress: CGFloat = 1

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindowControlsIfPossible()
    }

    func configure(revealProgress: CGFloat) {
        self.revealProgress = min(max(revealProgress, 0), 1)
        attachWindowControlsIfPossible()
    }

    private func attachWindowControlsIfPossible() {
        guard let window else { return }
        let coordinator = NativeWindowControlsCoordinator.coordinator(for: window)
        controlsCoordinator = coordinator
        coordinator.attachControls(
            to: self,
            revealProgress: revealProgress
        )
    }

    func restoreWindowControls() {
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
        let isHidden: Bool
        let alphaValue: CGFloat
        let isEnabled: Bool
        let isAccessibilityElement: Bool
        let translatesAutoresizingMaskIntoConstraints: Bool

        init(button: NSButton) {
            superview = button.superview
            isHidden = button.isHidden
            alphaValue = button.alphaValue
            isEnabled = button.isEnabled
            isAccessibilityElement = button.isAccessibilityElement()
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

            if originalPlacements[key] == nil ||
               originalPlacements[key]?.superview !== button.superview {
                originalPlacements[key] = OriginalPlacement(button: button)
            }

            // NSWindow owns both the placement and behavior of its standard
            // controls. Space changes animate only the workspace strip; shared
            // window chrome stays single-owned and steady.
        }

        layoutControls(
            in: host,
            revealProgress: revealProgress
        )
    }

    func layoutControls(
        in host: NativeWindowControlsHost,
        revealProgress: CGFloat
    ) {
        guard activeHost === host, let window else { return }

        for buttonType in Self.buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)
            let placement = originalPlacements[key]
            let shouldShow = revealProgress > 0

            // Keep the native buttons participating in title-bar layout.
            // Transparency avoids AppKit's per-button hidden-state relayout
            // when the whole sidebar is hidden.
            button.isHidden = placement?.isHidden ?? false
            button.alphaValue = shouldShow
                ? (placement?.alphaValue ?? 1) * revealProgress
                : 0
            button.isEnabled = shouldShow && (placement?.isEnabled ?? true)
            button.setAccessibilityElement(
                shouldShow && (placement?.isAccessibilityElement ?? true)
            )
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
            button.isHidden = placement.isHidden
            button.alphaValue = placement.alphaValue
            button.isEnabled = placement.isEnabled
            button.setAccessibilityElement(placement.isAccessibilityElement)
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
