import AppKit
import SwiftUI

struct WindowInteractionConfigurator: NSViewRepresentable {
    let autosaveName: String
    var isPrivate = false
    /// Also hands the window's store to the History menu, which needs a source
    /// of history for whichever window is key.
    var store: BrowserStore?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView(frame: .zero)
        view.configureWindow = { [coordinator = context.coordinator] window in
            coordinator.configure(window: window, autosaveName: autosaveName, isPrivate: isPrivate)
            if let window, let store {
                BrowserMenuController.shared.register(window: window, store: store)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? WindowAttachmentView {
            view.configureWindow = { [coordinator = context.coordinator] window in
                coordinator.configure(window: window, autosaveName: autosaveName, isPrivate: isPrivate)
                if let window, let store { BrowserMenuController.shared.register(window: window, store: store) }
            }
        }
        if let window = nsView.window, let store {
            BrowserMenuController.shared.register(window: window, store: store)
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
        private var isInFullScreenTransition = false
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
            // No toolbar in (or on the way into) full screen: SwiftUI calls
            // configure on every update, including mid-transition, and a
            // toolbar present while entering makes AppKit host the titlebar
            // in an NSToolbarFullScreenWindow it then fails to hand back.
            if window.toolbar == nil,
               !isInFullScreenTransition,
               !window.styleMask.contains(.fullScreen) {
                window.toolbar = NSToolbar(
                    identifier: "CandoaWindowControlsAlignment"
                )
            }
            installFullScreenToolbarHandling(for: window)
        }

        /// The alignment toolbar exists only to place the traffic lights,
        /// and it must not exist during full screen at all. Two reasons:
        /// visually, the empty toolbar renders as a dead strip above the
        /// content; structurally, a window that ENTERS full screen with a
        /// toolbar makes AppKit host the titlebar in an
        /// NSToolbarFullScreenWindow, and on exit AppKit can fail to hand
        /// the standard window buttons back — they stay stranded in that
        /// leftover window, floating over the page (sidebar hidden) or
        /// missing from the title bar (sidebar shown). So the toolbar is
        /// removed BEFORE the transition starts and re-added only after the
        /// exit fully completes (the willExit re-add raced the transition
        /// and could still strand). didExit additionally verifies the
        /// buttons landed back in the window and rebuilds the title bar as
        /// a last resort.
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
                ) { [weak self, weak window] _ in
                    // Window notifications on .main always run on the main thread.
                    MainActor.assumeIsolated {
                        self?.isInFullScreenTransition = true
                        window?.toolbar = nil
                    }
                },
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isInFullScreenTransition = false
                    }
                },
                center.addObserver(
                    forName: NSWindow.willExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isInFullScreenTransition = true
                    }
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        self?.isInFullScreenTransition = false
                        guard
                            let closeButton = window.standardWindowButton(.closeButton),
                            closeButton.window !== window
                        else {
                            window.toolbarStyle = .unified
                            if window.toolbar == nil {
                                window.toolbar = NSToolbar(
                                    identifier: "CandoaWindowControlsAlignment"
                                )
                            }
                            return
                        }
                        // Stranded: dropping and re-inserting .titled makes
                        // AppKit rebuild the title bar and reclaim the
                        // buttons. The toolbar goes back on a LATER runloop
                        // turn — re-adding in the same turn as the rebuild
                        // leaves the buttons at the plain-titlebar position
                        // instead of the unified one (verified live).
                        window.toolbar = nil
                        window.styleMask.remove(.titled)
                        window.styleMask.insert(.titled)
                        DispatchQueue.main.async { [weak window] in
                            guard let window else { return }
                            window.toolbarStyle = .unified
                            window.toolbar = NSToolbar(
                                identifier: "CandoaWindowControlsAlignment"
                            )
                        }
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
