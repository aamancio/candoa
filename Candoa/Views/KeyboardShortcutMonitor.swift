import AppKit
import SwiftUI

struct KeyboardShortcutMonitor: NSViewRepresentable {
    let onCommandT: () -> Void
    let onCommandW: () -> Void
    let onReopenClosedTab: () -> Void
    let onFocusAddressBar: () -> Void
    let onOpenCommandBar: () -> Void
    let onCopyURL: () -> Void
    let onCopyURLAsMarkdown: () -> Void
    let onSharePage: () -> Void
    let onCaptureFullPage: () -> Void
    let onPinOrUnpinTab: () -> Void
    let onToggleSidebar: () -> Void
    let onToggleAISidebar: () -> Void
    let onFindInPage: () -> Void
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void
    /// Returns whether Escape was used, so unused presses still reach the page.
    let onEscape: () -> Bool
    let onReload: () -> Void
    let onReloadFromOrigin: () -> Void
    let onStopLoading: () -> Bool
    let onClearUnpinnedTabs: () -> Void
    let onControlTab: () -> Void
    let onControlShiftTab: () -> Void
    let onControlReleased: () -> Void
    let onTabSwitcherDelete: () -> Bool
    let onTabSwitcherEscape: () -> Bool
    let onCommandDigit: (Int) -> Void
    let onControlDigit: (Int) -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onResetZoom: () -> Void
    let onNextTab: () -> Void
    let onPreviousTab: () -> Void
    let onNextSpace: () -> Void
    let onPreviousSpace: () -> Void
    let onToggleSplit: () -> Void
    let onSplitLayout: (SplitViewLayout) -> Void
    let onZoomSplitPane: () -> Void
    let onFocusSplitPane: (Int) -> Void
    let onUnsplitPane: () -> Void
    let onSplitWithTab: () -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        apply(to: coordinator)
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: context.coordinator)
        context.coordinator.installMonitorIfNeeded()
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.onCommandT = onCommandT
        coordinator.onCommandW = onCommandW
        coordinator.onReopenClosedTab = onReopenClosedTab
        coordinator.onFocusAddressBar = onFocusAddressBar
        coordinator.onOpenCommandBar = onOpenCommandBar
        coordinator.onCopyURL = onCopyURL
        coordinator.onCopyURLAsMarkdown = onCopyURLAsMarkdown
        coordinator.onSharePage = onSharePage
        coordinator.onCaptureFullPage = onCaptureFullPage
        coordinator.onPinOrUnpinTab = onPinOrUnpinTab
        coordinator.onToggleSidebar = onToggleSidebar
        coordinator.onToggleAISidebar = onToggleAISidebar
        coordinator.onFindInPage = onFindInPage
        coordinator.onFindNext = onFindNext
        coordinator.onFindPrevious = onFindPrevious
        coordinator.onEscape = onEscape
        coordinator.onReload = onReload
        coordinator.onReloadFromOrigin = onReloadFromOrigin
        coordinator.onStopLoading = onStopLoading
        coordinator.onClearUnpinnedTabs = onClearUnpinnedTabs
        coordinator.onControlTab = onControlTab
        coordinator.onControlShiftTab = onControlShiftTab
        coordinator.onControlReleased = onControlReleased
        coordinator.onTabSwitcherDelete = onTabSwitcherDelete
        coordinator.onTabSwitcherEscape = onTabSwitcherEscape
        coordinator.onCommandDigit = onCommandDigit
        coordinator.onControlDigit = onControlDigit
        coordinator.onGoBack = onGoBack
        coordinator.onGoForward = onGoForward
        coordinator.onZoomIn = onZoomIn
        coordinator.onZoomOut = onZoomOut
        coordinator.onResetZoom = onResetZoom
        coordinator.onNextTab = onNextTab
        coordinator.onPreviousTab = onPreviousTab
        coordinator.onNextSpace = onNextSpace
        coordinator.onPreviousSpace = onPreviousSpace
        coordinator.onToggleSplit = onToggleSplit
        coordinator.onSplitLayout = onSplitLayout
        coordinator.onZoomSplitPane = onZoomSplitPane
        coordinator.onFocusSplitPane = onFocusSplitPane
        coordinator.onUnsplitPane = onUnsplitPane
        coordinator.onSplitWithTab = onSplitWithTab
    }

    @MainActor
    final class Coordinator: NSObject {
        var onCommandT: () -> Void = {}
        var onCommandW: () -> Void = {}
        var onReopenClosedTab: () -> Void = {}
        var onFocusAddressBar: () -> Void = {}
        var onOpenCommandBar: () -> Void = {}
        var onCopyURL: () -> Void = {}
        var onCopyURLAsMarkdown: () -> Void = {}
        var onSharePage: () -> Void = {}
        var onCaptureFullPage: () -> Void = {}
        var onPinOrUnpinTab: () -> Void = {}
        var onToggleSidebar: () -> Void = {}
        var onToggleAISidebar: () -> Void = {}
        var onFindInPage: () -> Void = {}
        var onFindNext: () -> Void = {}
        var onFindPrevious: () -> Void = {}
        var onEscape: () -> Bool = { false }
        var onReload: () -> Void = {}
        var onReloadFromOrigin: () -> Void = {}
        var onStopLoading: () -> Bool = { false }
        var onClearUnpinnedTabs: () -> Void = {}
        var onControlTab: () -> Void = {}
        var onControlShiftTab: () -> Void = {}
        var onControlReleased: () -> Void = {}
        var onTabSwitcherDelete: () -> Bool = { false }
        var onTabSwitcherEscape: () -> Bool = { false }
        var onCommandDigit: (Int) -> Void = { _ in }
        var onControlDigit: (Int) -> Void = { _ in }
        var onGoBack: () -> Void = {}
        var onGoForward: () -> Void = {}
        var onZoomIn: () -> Void = {}
        var onZoomOut: () -> Void = {}
        var onResetZoom: () -> Void = {}
        var onNextTab: () -> Void = {}
        var onPreviousTab: () -> Void = {}
        var onNextSpace: () -> Void = {}
        var onPreviousSpace: () -> Void = {}
        var onToggleSplit: () -> Void = {}
        var onSplitLayout: (SplitViewLayout) -> Void = { _ in }
        var onZoomSplitPane: () -> Void = {}
        var onFocusSplitPane: (Int) -> Void = { _ in }
        var onUnsplitPane: () -> Void = {}
        var onSplitWithTab: () -> Void = {}
        /// Written only from MainActor-isolated methods; `nonisolated(unsafe)`
        /// so the nonisolated deinit can tear the monitor down.
        private nonisolated(unsafe) var monitor: Any?
        /// The monitor is app-wide (NSEvent local monitors always are), but
        /// every window mounts its own instance against its own store. Each
        /// handler therefore acts only while its window is key, or two
        /// windows would both run the side effect of every shortcut.
        weak var hostView: NSView?

        private static let closeBracketKeyCode: UInt16 = 30
        private static let openBracketKeyCode: UInt16 = 33
        private static let equalsKeyCode: UInt16 = 24
        private static let minusKeyCode: UInt16 = 27
        private static let leftArrowKeyCode: UInt16 = 123
        private static let rightArrowKeyCode: UInt16 = 124

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self else {
                    return event
                }

                // Local event monitors always fire on the main thread; the
                // AppKit handler type just isn't annotated with the isolation.
                // NSEvent is not Sendable, so only a Bool crosses back out.
                let consumed = MainActor.assumeIsolated {
                    self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard hostView?.window?.isKeyWindow == true else {
                return event
            }

            if event.type == .flagsChanged {
                if !Self.isControlPressed(event) {
                    onControlReleased()
                }
                return event
            }

            // Escape carries no modifiers, so it can never match a configured
            // shortcut. It is handled here rather than through the find bar's
            // own `onExitCommand` because the page usually holds first
            // responder, and then SwiftUI never sees the cancel command.
            if Self.isPlainEscape(event), onEscape() {
                return nil
            }

            // While Control is held for the Ctrl-Tab strip: Delete closes
            // the highlighted card, Escape abandons the strip. Consumed only
            // when a strip was actually there to act on, so ⌃Delete and
            // ⌃Escape keep their meaning for pages otherwise.
            if Self.isControlDelete(event), onTabSwitcherDelete() {
                return nil
            }

            if Self.isControlEscape(event), onTabSwitcherEscape() {
                return nil
            }

            if Self.matchesConfiguredShortcut(.newTab, event) {
                onCommandT()
                return nil
            }

            if Self.matchesConfiguredShortcut(.closeCurrentTab, event) {
                onCommandW()
                return nil
            }

            if Self.matchesConfiguredShortcut(.reopenClosedTab, event) {
                onReopenClosedTab()
                return nil
            }

            if Self.matchesConfiguredShortcut(.focusAddressBar, event) {
                onFocusAddressBar()
                return nil
            }

            if Self.matchesConfiguredShortcut(.commandBar, event) {
                onOpenCommandBar()
                return nil
            }

            if Self.matchesConfiguredShortcut(.copyURLAsMarkdown, event) {
                onCopyURLAsMarkdown()
                return nil
            }

            if Self.matchesConfiguredShortcut(.copyURL, event) {
                onCopyURL()
                return nil
            }

            if Self.matchesConfiguredShortcut(.sharePage, event) {
                onSharePage()
                return nil
            }

            if Self.matchesConfiguredShortcut(.captureFullPage, event) {
                onCaptureFullPage()
                return nil
            }

            if Self.matchesConfiguredShortcut(.pinOrUnpinTab, event) {
                onPinOrUnpinTab()
                return nil
            }

            if Self.matchesConfiguredShortcut(.toggleSidebar, event) {
                onToggleSidebar()
                return nil
            }

            if Self.matchesConfiguredShortcut(.toggleAISidebar, event) {
                onToggleAISidebar()
                return nil
            }

            if Self.matchesConfiguredShortcut(.findInPage, event) {
                onFindInPage()
                return nil
            }

            if Self.matchesConfiguredShortcut(.findNext, event) {
                onFindNext()
                return nil
            }

            if Self.matchesConfiguredShortcut(.findPrevious, event) {
                onFindPrevious()
                return nil
            }

            if Self.matchesConfiguredShortcut(.reloadTab, event) {
                onReload()
                return nil
            }

            if Self.matchesConfiguredShortcut(.reloadTabFromOrigin, event) {
                onReloadFromOrigin()
                return nil
            }

            // Command-. doubles as the system cancel key: consume it only
            // when a load was actually stopped so dialogs keep their
            // cancel behavior.
            if Self.matchesConfiguredShortcut(.stopLoading, event), onStopLoading() {
                return nil
            }

            if Self.matchesConfiguredShortcut(.goBack, event) {
                onGoBack()
                return nil
            }

            if Self.matchesConfiguredShortcut(.goForward, event) {
                onGoForward()
                return nil
            }

            if Self.matchesConfiguredShortcut(.clearUnpinnedTabs, event) {
                onClearUnpinnedTabs()
                return nil
            }

            if Self.matchesConfiguredShortcut(.previousRecentTab, event) {
                onControlShiftTab()
                return nil
            }

            if Self.matchesConfiguredShortcut(.nextRecentTab, event) {
                onControlTab()
                return nil
            }

            if let digit = Self.digit(for: event, requiring: .command) {
                onCommandDigit(digit)
                return nil
            }

            if let digit = Self.digit(for: event, requiring: .control) {
                onControlDigit(digit)
                return nil
            }

            if Self.matchesConfiguredShortcut(.toggleSplitView, event) {
                onToggleSplit()
                return nil
            }

            if Self.matchesConfiguredShortcut(.splitLayoutHorizontal, event) {
                onSplitLayout(.horizontal)
                return nil
            }

            if Self.matchesConfiguredShortcut(.splitLayoutVertical, event) {
                onSplitLayout(.vertical)
                return nil
            }

            if Self.matchesConfiguredShortcut(.zoomSplitPane, event) {
                onZoomSplitPane()
                return nil
            }

            if Self.matchesConfiguredShortcut(.focusNextSplitPane, event) {
                onFocusSplitPane(1)
                return nil
            }

            if Self.matchesConfiguredShortcut(.focusPreviousSplitPane, event) {
                onFocusSplitPane(-1)
                return nil
            }

            if Self.matchesConfiguredShortcut(.unsplitPane, event) {
                onUnsplitPane()
                return nil
            }

            if Self.matchesConfiguredShortcut(.splitWithTab, event) {
                onSplitWithTab()
                return nil
            }

            if Self.matchesConfiguredShortcut(.zoomIn, event) {
                onZoomIn()
                return nil
            }

            if Self.matchesConfiguredShortcut(.zoomOut, event) {
                onZoomOut()
                return nil
            }

            if Self.matchesConfiguredShortcut(.resetZoom, event) {
                onResetZoom()
                return nil
            }

            if Self.matchesConfiguredShortcut(.nextTab, event) {
                onNextTab()
                return nil
            }

            if Self.matchesConfiguredShortcut(.previousTab, event) {
                onPreviousTab()
                return nil
            }

            if Self.matchesConfiguredShortcut(.nextSpace, event) {
                onNextSpace()
                return nil
            }

            if Self.matchesConfiguredShortcut(.previousSpace, event) {
                onPreviousSpace()
                return nil
            }

            return event
        }

        private static func isCommandT(_ event: NSEvent) -> Bool {
            matchesConfiguredShortcut(.newTab, event)
        }

        private static func isCommandW(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return modifiers == .command &&
                event.charactersIgnoringModifiers?.lowercased() == "w"
        }

        private static func isGoBack(_ event: NSEvent) -> Bool {
            matchesKey(event, keyCode: openBracketKeyCode, modifiers: .command) ||
                matchesKey(event, keyCode: leftArrowKeyCode, modifiers: .command)
        }

        private static func isGoForward(_ event: NSEvent) -> Bool {
            matchesKey(event, keyCode: closeBracketKeyCode, modifiers: .command) ||
                matchesKey(event, keyCode: rightArrowKeyCode, modifiers: .command)
        }

        private static func isControlTab(_ event: NSEvent) -> Bool {
            let modifiers = normalizedModifiers(for: event)
            return modifiers == .control && event.keyCode == 48
        }

        private static func isControlShiftTab(_ event: NSEvent) -> Bool {
            let modifiers = normalizedModifiers(for: event)
            return modifiers == [.control, .shift] && event.keyCode == 48
        }

        private static func isControlDelete(_ event: NSEvent) -> Bool {
            normalizedModifiers(for: event) == .control && (event.keyCode == 51 || event.keyCode == 117)
        }

        private static func isControlEscape(_ event: NSEvent) -> Bool {
            normalizedModifiers(for: event) == .control && event.keyCode == 53
        }

        private static func isPlainEscape(_ event: NSEvent) -> Bool {
            normalizedModifiers(for: event).isEmpty && event.keyCode == 53
        }

        private static func isControlPressed(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
        }

        private static func digit(for event: NSEvent, requiring modifier: NSEvent.ModifierFlags) -> Int? {
            guard normalizedModifiers(for: event) == modifier else { return nil }
            guard
                let characters = event.charactersIgnoringModifiers,
                characters.count == 1,
                let digit = Int(characters),
                (1...9).contains(digit)
            else {
                return nil
            }
            return digit
        }

        private static func matchesKey(_ event: NSEvent, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
            event.keyCode == keyCode && normalizedModifiers(for: event) == modifiers
        }

        private static func matchesZoomKey(_ event: NSEvent, keyCode: UInt16) -> Bool {
            guard event.keyCode == keyCode else { return false }
            let modifiers = normalizedModifiers(for: event)
            return modifiers == .command || modifiers == [.command, .shift]
        }

        private static func normalizedModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])
        }

        private static func matchesConfiguredShortcut(_ definition: ShortcutDefinition, _ event: NSEvent) -> Bool {
            let storedShortcut = UserDefaults.standard.string(forKey: definition.storageKey) ?? ""
            guard storedShortcut != ShortcutDefinition.removedValue else { return false }

            guard let shortcut = shortcutString(for: event) else { return false }

            if storedShortcut.isEmpty {
                let defaultShortcuts = [definition.defaultShortcut] + definition.alternateDefaultShortcuts
                return defaultShortcuts.contains(shortcut)
            }

            return storedShortcut != "None" && shortcut == storedShortcut
        }

        private static func shortcutString(for event: NSEvent) -> String? {
            let modifiers = normalizedModifiers(for: event)
            guard !modifiers.isEmpty else { return nil }

            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Control") }
            if modifiers.contains(.option) { parts.append("Option") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Command") }

            let key = keyString(for: event)
            guard !key.isEmpty else { return nil }
            parts.append(key)
            return parts.joined(separator: "-")
        }

        private static func keyString(for event: NSEvent) -> String {
            switch event.keyCode {
            case 48: return "Tab"
            case 123: return "Left"
            case 124: return "Right"
            case 125: return "Down"
            case 126: return "Up"
            default:
                return event.charactersIgnoringModifiers?.uppercased() ?? ""
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
