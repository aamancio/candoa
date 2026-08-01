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

/// Where AppKit actually placed the standard window buttons, measured in the
/// coordinate space of the sidebar's reserved controls frame. The header
/// aligns its icons to `controlsCenterOffsetY`, and Space swipes ride the
/// `controls` snapshots so the native buttons never move or reparent.
@MainActor
internal final class WindowControlsGeometry: ObservableObject {
    internal struct ControlSnapshot {
        internal let frame: CGRect
        internal let image: NSImage?
    }

    @Published internal private(set) var controls: [ControlSnapshot] = []
    @Published internal private(set) var controlsCenterOffsetY: CGFloat = 0

    /// Passing nil `images` keeps the previously captured snapshots (used
    /// when frames move but a fresh capture would bake in hover glyphs).
    internal func apply(
        frames: [CGRect],
        images: [NSImage?]?,
        centerOffsetY: CGFloat
    ) {
        let resolvedImages = images ?? controls.map(\.image)
        controls = frames.enumerated().map { index, frame in
            ControlSnapshot(
                frame: frame,
                image: index < resolvedImages.count ? resolvedImages[index] : nil
            )
        }
        if controlsCenterOffsetY != centerOffsetY {
            controlsCenterOffsetY = centerOffsetY
        }
    }
}

/// Stand-in traffic lights shown only while a Space swipe is in flight. They
/// are snapshots of the real AppKit buttons drawn at the measured native
/// position, so the swipe can carry them across pages while the real buttons
/// stay AppKit-owned, faded out in place.
internal struct FauxWindowControlsView: View {
    @ObservedObject var geometry: WindowControlsGeometry

    private static let fallbackColors: [Color] = [
        Color(red: 255 / 255, green: 95 / 255, blue: 87 / 255),
        Color(red: 254 / 255, green: 188 / 255, blue: 46 / 255),
        Color(red: 40 / 255, green: 200 / 255, blue: 64 / 255)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(geometry.controls.indices, id: \.self) { index in
                let control = geometry.controls[index]

                Group {
                    if let image = control.image {
                        Image(nsImage: image)
                    } else {
                        Circle()
                            .fill(Self.fallbackColors[index % Self.fallbackColors.count])
                            .frame(width: 12, height: 12)
                    }
                }
                .frame(width: control.frame.width, height: control.frame.height)
                .offset(x: control.frame.minX, y: control.frame.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

internal struct WindowControlsView: View {
    let isSuppressed: Bool
    let geometry: WindowControlsGeometry

    @Environment(\.sidebarRevealProgress) private var revealProgress

    private var isRevealSlideInFlight: Bool {
        revealProgress > 0.0001 && revealProgress < 0.9999
    }

    var body: some View {
        NativeWindowControlsView(
            revealProgress: revealProgress,
            isSuppressed: isSuppressed,
            geometry: geometry
        )
        .overlay(alignment: .topLeading) {
            // The real AppKit buttons never move, so while the sidebar slides
            // they stay hidden in place and these snapshots ride the
            // translation instead — the same trick Space swipes use. At full
            // reveal the measured frames coincide with the native positions,
            // so the swap back to the live buttons is pixel-identical.
            if isRevealSlideInFlight, !isSuppressed {
                FauxWindowControlsView(geometry: geometry)
            }
        }
    }
}

internal struct NativeWindowControlsView: NSViewRepresentable {
    let revealProgress: CGFloat
    let isSuppressed: Bool
    let geometry: WindowControlsGeometry

    func makeNSView(context: Context) -> NSView {
        let view = NativeWindowControlsHost()
        view.configure(
            revealProgress: revealProgress,
            isSuppressed: isSuppressed,
            geometry: geometry
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NativeWindowControlsHost)?.configure(
            revealProgress: revealProgress,
            isSuppressed: isSuppressed,
            geometry: geometry
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? NativeWindowControlsHost)?.restoreWindowControls()
    }
}

private final class NativeWindowControlsHost: NSView {
    private weak var controlsCoordinator: NativeWindowControlsCoordinator?
    private var revealProgress: CGFloat = 1
    private var isSuppressed = false
    private var geometry: WindowControlsGeometry?
    private var lastPublishedFrames: [CGRect]?
    private var needsImageRecapture = true
    private var isSnapshotRetryScheduled = false
    private var windowStateObservers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowKeyState()
        attachWindowControlsIfPossible()
        needsLayout = true
    }

    func configure(
        revealProgress: CGFloat,
        isSuppressed: Bool,
        geometry: WindowControlsGeometry
    ) {
        self.revealProgress = min(max(revealProgress, 0), 1)
        self.isSuppressed = isSuppressed
        self.geometry = geometry
        attachWindowControlsIfPossible()
        needsLayout = true
    }

    private func attachWindowControlsIfPossible() {
        guard let window else { return }
        let coordinator = NativeWindowControlsCoordinator.coordinator(for: window)
        controlsCoordinator = coordinator
        coordinator.attachControls(
            to: self,
            revealProgress: revealProgress,
            isSuppressed: isSuppressed
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
            revealProgress: revealProgress,
            isSuppressed: isSuppressed
        )
        publishGeometryIfNeeded()
    }

    /// The real buttons grey out when the window resigns key; refresh the
    /// swipe snapshots so faux and native never disagree.
    private func observeWindowKeyState() {
        windowStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowStateObservers = []

        guard let window else { return }
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ]
        windowStateObservers = notifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.needsImageRecapture = true
                    self?.needsLayout = true
                }
            }
        }
    }

    private func publishGeometryIfNeeded() {
        guard
            let coordinator = controlsCoordinator,
            let geometry,
            let measurement = coordinator.measureControls(in: self)
        else { return }

        let framesChanged = measurement.frames != lastPublishedFrames
        guard framesChanged || needsImageRecapture else { return }
        lastPublishedFrames = measurement.frames

        // Hovering the button group makes AppKit draw rollover glyphs
        // (with legacy artwork through this render path); never bake those
        // into the swipe snapshots. Keep the last clean set and retry.
        if coordinator.isPointerOverButtonGroup() {
            needsImageRecapture = true
            scheduleSnapshotRetry()
            if framesChanged {
                geometry.apply(
                    frames: measurement.frames,
                    images: nil,
                    centerOffsetY: measurement.centerOffsetY
                )
            }
            return
        }

        needsImageRecapture = false
        geometry.apply(
            frames: measurement.frames,
            images: coordinator.captureButtonImages(),
            centerOffsetY: measurement.centerOffsetY
        )
    }

    private func scheduleSnapshotRetry() {
        guard !isSnapshotRetryScheduled else { return }
        isSnapshotRetryScheduled = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.isSnapshotRetryScheduled = false
            if self.needsImageRecapture {
                self.publishGeometryIfNeeded()
            }
        }
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

    struct Measurement: Equatable {
        let frames: [CGRect]
        let centerOffsetY: CGFloat
    }

    func attachControls(
        to host: NativeWindowControlsHost,
        revealProgress: CGFloat,
        isSuppressed: Bool
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
            // controls. Space swipes animate faux snapshots; the real buttons
            // only fade in place and stay single-owned.
        }

        layoutControls(
            in: host,
            revealProgress: revealProgress,
            isSuppressed: isSuppressed
        )
    }

    func layoutControls(
        in host: NativeWindowControlsHost,
        revealProgress: CGFloat,
        isSuppressed: Bool
    ) {
        guard activeHost === host, let window else { return }
        let effectiveProgress = isSuppressed ? 0 : revealProgress

        for buttonType in Self.buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)
            let placement = originalPlacements[key]
            // The buttons cannot ride the sidebar's translation, so they show
            // only at full reveal; while a reveal slide is in flight the faux
            // snapshots in WindowControlsView carry their appearance instead.
            // Fading them by partial progress here would leave them ghosting
            // at their absolute window position, detached from the sidebar.
            let shouldShow = effectiveProgress >= 0.9999

            // Keep the native buttons participating in title-bar layout.
            // Transparency avoids AppKit's per-button hidden-state relayout
            // when the whole sidebar is hidden.
            button.isHidden = placement?.isHidden ?? false
            button.alphaValue = shouldShow ? (placement?.alphaValue ?? 1) : 0
            button.isEnabled = shouldShow && (placement?.isEnabled ?? true)
            button.setAccessibilityElement(
                shouldShow && (placement?.isAccessibilityElement ?? true)
            )
        }
    }

    func measureControls(in host: NativeWindowControlsHost) -> Measurement? {
        guard activeHost === host, let window, host.window === window else { return nil }

        var frames: [CGRect] = []
        for buttonType in Self.buttonTypes {
            guard
                let button = window.standardWindowButton(buttonType),
                let superview = button.superview
            else { continue }
            frames.append(host.convert(button.frame, from: superview))
        }
        guard let first = frames.first else { return nil }

        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        return Measurement(
            frames: frames,
            centerOffsetY: union.midY - host.bounds.midY
        )
    }

    /// One entry per button, aligned with `measureControls` frames; a failed
    /// capture yields nil in place so images never shift onto the wrong slot.
    func captureButtonImages() -> [NSImage?] {
        guard let window else { return [] }

        return Self.buttonTypes.map { buttonType -> NSImage? in
            guard
                let button = window.standardWindowButton(buttonType),
                button.superview != nil,
                button.bounds.width > 0,
                button.bounds.height > 0,
                let representation = button.bitmapImageRepForCachingDisplay(in: button.bounds)
            else {
                return nil
            }

            button.cacheDisplay(in: button.bounds, to: representation)
            let image = NSImage(size: button.bounds.size)
            image.addRepresentation(representation)
            return image
        }
    }

    /// True when the pointer sits over the traffic-light group, i.e. when
    /// AppKit would render the buttons with their rollover glyphs.
    func isPointerOverButtonGroup() -> Bool {
        guard let window else { return false }

        var groupRect: CGRect?
        for buttonType in Self.buttonTypes {
            guard
                let button = window.standardWindowButton(buttonType),
                let superview = button.superview
            else { continue }
            let frameInWindow = superview.convert(button.frame, to: nil)
            groupRect = groupRect.map { $0.union(frameInWindow) } ?? frameInWindow
        }
        guard let groupRect else { return false }

        let screenRect = window.convertToScreen(groupRect.insetBy(dx: -10, dy: -10))
        return screenRect.contains(NSEvent.mouseLocation)
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
