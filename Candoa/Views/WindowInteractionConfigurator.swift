import AppKit
import SwiftUI

struct WindowInteractionConfigurator: NSViewRepresentable {
    let autosaveName: String
    var isPrivate = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView(frame: .zero)
        view.configureWindow = { [coordinator = context.coordinator] window in
            coordinator.configure(window: window, autosaveName: autosaveName, isPrivate: isPrivate)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? WindowAttachmentView {
            view.configureWindow = { [coordinator = context.coordinator] window in
                coordinator.configure(window: window, autosaveName: autosaveName, isPrivate: isPrivate)
            }
        }
        context.coordinator.configure(
            window: nsView.window,
            autosaveName: autosaveName,
            isPrivate: isPrivate
        )
    }

    private final class WindowAttachmentView: NSView {
        var configureWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private static let minimumWindowSize = NSSize(
            width: AppConfiguration.minimumWindowWidth,
            height: AppConfiguration.minimumWindowHeight
        )

        private weak var configuredWindow: NSWindow?
        private var configuredAutosaveName: String?
        private weak var fullScreenObservedWindow: NSWindow?
        private nonisolated(unsafe) var fullScreenObservers: [NSObjectProtocol] = []

        deinit {
            fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func configure(window: NSWindow?, autosaveName: String, isPrivate: Bool = false) {
            guard let window else { return }
            configureWindowInterface(for: window)

            if isPrivate {
                // Untitled elsewhere, but the Window menu and Mission
                // Control list windows by title — the one place a private
                // window must identify itself. titleVisibility stays
                // .hidden, so nothing changes in the title bar itself.
                window.title = String(localized: "Private Browsing")
                // No restoration and no frame autosave: a private window
                // leaves nothing behind, not even its geometry.
                window.isRestorable = false
            }

            guard configuredWindow !== window || configuredAutosaveName != autosaveName else {
                return
            }

            configuredWindow = window
            configuredAutosaveName = autosaveName
            if isPrivate {
                window.setFrame(
                    Self.initialWindowFrame(for: window),
                    display: window.isVisible,
                    animate: false
                )
                return
            }
            let restoredSavedFrame = window.setFrameUsingName(autosaveName)
            if !restoredSavedFrame {
                window.setFrame(
                    Self.initialWindowFrame(for: window),
                    display: window.isVisible,
                    animate: false
                )
            }
            _ = window.setFrameAutosaveName(autosaveName)
        }

        private func configureWindowInterface(for window: NSWindow) {
            window.minSize = Self.minimumWindowSize
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.isMovableByWindowBackground = false

            // A unified-toolbar title bar makes AppKit center its own
            // standard window buttons lower, in line with the sidebar
            // header. The buttons stay AppKit-owned and AppKit-placed; the
            // sidebar only reserves space under them.
            window.toolbarStyle = .unified
            if window.toolbar == nil, !window.styleMask.contains(.fullScreen) {
                window.toolbar = NSToolbar(
                    identifier: "CandoaWindowControlsAlignment"
                )
            }
            installFullScreenToolbarHandling(for: window)
        }

        /// The alignment toolbar exists only to place the traffic lights; in
        /// full screen those are hidden, and the empty toolbar would render
        /// as a dead strip above the content. Drop it for the duration and
        /// restore it on the way out so the buttons land aligned again.
        private func installFullScreenToolbarHandling(for window: NSWindow) {
            guard fullScreenObservedWindow !== window else { return }
            fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
            fullScreenObservedWindow = window

            let center = NotificationCenter.default
            fullScreenObservers = [
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    // Window notifications on .main always run on the main thread.
                    MainActor.assumeIsolated {
                        window?.toolbar = nil
                    }
                },
                center.addObserver(
                    forName: NSWindow.willExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window, window.toolbar == nil else { return }
                        window.toolbar = NSToolbar(
                            identifier: "CandoaWindowControlsAlignment"
                        )
                    }
                }
            ]
        }

        private static func initialWindowFrame(for window: NSWindow) -> NSRect {
            let screen = window.screen ?? NSScreen.main
            return screen?.visibleFrame ?? NSRect(
                x: 0,
                y: 0,
                width: AppConfiguration.minimumWindowWidth,
                height: AppConfiguration.minimumWindowHeight
            )
        }
    }
}

extension SpaceThemeAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

/// Tracks the macOS system appearance so "automatic" can resolve to an
/// explicit color scheme. SwiftUI latches the last non-nil
/// `preferredColorScheme` on its window, so we can never pass nil to mean
/// "follow the system" — we follow it ourselves instead.
@MainActor
final class SystemAppearanceObserver: ObservableObject {
    @Published var colorScheme: ColorScheme

    private var observer: NSObjectProtocol?

    init() {
        colorScheme = Self.currentSystemColorScheme()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.colorScheme = Self.currentSystemColorScheme()
            }
        }
    }

    private static func currentSystemColorScheme() -> ColorScheme {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark
            : .light
    }
}
