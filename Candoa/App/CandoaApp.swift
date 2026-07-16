import AppKit
import SwiftUI

@main
struct CandoaApp: App {
    @NSApplicationDelegateAdaptor(CandoaAppDelegate.self) private var appDelegate
    @StateObject private var userStore = UserStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(userStore)
                .tint(CandoaColor.primary)
                .frame(
                    minWidth: AppConfiguration.minimumWindowWidth,
                    minHeight: AppConfiguration.minimumWindowHeight
                )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: Self.initialWindowSize.width,
            height: Self.initialWindowSize.height
        )
        .commands {
            BrowserCommands()
        }

        Settings {
            CandoaSettingsView()
                .environmentObject(userStore)
                .tint(CandoaColor.primary)
        }
    }

    private static var initialWindowSize: CGSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return CGSize(
                width: AppConfiguration.minimumWindowWidth,
                height: AppConfiguration.minimumWindowHeight
            )
        }

        return CGSize(width: visibleFrame.width, height: visibleFrame.height)
    }
}

@MainActor
private final class CandoaAppDelegate: NSObject, NSApplicationDelegate {
    private let appearanceChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockIcon()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: appearanceChangedNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func systemAppearanceDidChange(_ notification: Notification) {
        updateDockIcon()
    }

    private func updateDockIcon() {
        CandoaDockIconPreference.updateApplicationIcon()
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(BrowserCommandTitles.newTab) {
                actions?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.reopenClosedTab) {
                actions?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandGroup(after: .textEditing) {
            Button(BrowserCommandTitles.findInPage) {
                actions?.findInPage()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.findNext) {
                actions?.findNext()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.findPrevious) {
                actions?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandGroup(after: .help) {
            Button(String(localized: "Quick Tour…")) {
                actions?.showQuickTour()
            }
            .disabled(actions == nil)
        }

        CommandMenu("Browser") {
            Button(BrowserCommandTitles.focusAddressBar) {
                actions?.focusAddressBar()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.commandBar) {
                actions?.openCommandPalette()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.toggleSidebar) {
                actions?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.toggleAISidebar) {
                actions?.toggleAISidebar()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.reloadTab) {
                actions?.reloadTab()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.back) {
                actions?.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.forward) {
                actions?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.closeCurrentTab) {
                actions?.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.pinOrUnpinTab) {
                actions?.pinOrUnpinTab()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.clearUnpinnedTabs) {
                actions?.clearUnpinnedTabs()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.copyURL) {
                actions?.copyURL()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.copyURLAsMarkdown) {
                actions?.copyURLAsMarkdown()
            }
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.zoomIn) {
                actions?.zoomIn()
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.zoomOut) {
                actions?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(actions == nil)

            Button(BrowserCommandTitles.resetZoom) {
                actions?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.addSplitView) {
                actions?.addSplitView()
            }
            .disabled(actions == nil)

            Button(BrowserCommandTitles.closeSplitView) {
                actions?.closeSplitView()
            }
            .disabled(actions == nil)

            Divider()

            Button(BrowserCommandTitles.nextTab) {
                actions?.nextTab()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.previousTab) {
                actions?.previousTab()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.nextSpace) {
                actions?.nextSpace()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Button(BrowserCommandTitles.previousSpace) {
                actions?.previousSpace()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(actions == nil)

            Divider()

            Menu("iCloud Sync") {
                Button(
                    actions?.isWorkspaceICloudSyncEnabled == true
                        ? BrowserCommandTitles.disableWorkspaceICloudSync
                        : BrowserCommandTitles.enableWorkspaceICloudSync
                ) {
                    guard let actions else { return }
                    actions.setWorkspaceICloudSyncEnabled(!actions.isWorkspaceICloudSyncEnabled)
                }
                .disabled(actions == nil)

                Button(
                    actions?.isHistoryICloudSyncEnabled == true
                        ? BrowserCommandTitles.disableHistoryICloudSync
                        : BrowserCommandTitles.enableHistoryICloudSync
                ) {
                    guard let actions else { return }
                    actions.setHistoryICloudSyncEnabled(!actions.isHistoryICloudSyncEnabled)
                }
                .disabled(actions == nil || actions?.isWorkspaceICloudSyncEnabled != true)
            }
        }
    }
}

struct BrowserCommandActions {
    var newTab: () -> Void
    var focusAddressBar: () -> Void
    var openCommandPalette: () -> Void
    var toggleSidebar: () -> Void
    var toggleAISidebar: () -> Void
    var showQuickTour: () -> Void
    var reloadTab: () -> Void
    var goBack: () -> Void
    var goForward: () -> Void
    var closeCurrentTab: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var nextSpace: () -> Void
    var previousSpace: () -> Void
    var reopenClosedTab: () -> Void
    var pinOrUnpinTab: () -> Void
    var clearUnpinnedTabs: () -> Void
    var copyURL: () -> Void
    var copyURLAsMarkdown: () -> Void
    var findInPage: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var resetZoom: () -> Void
    var addSplitView: () -> Void
    var closeSplitView: () -> Void
    var isWorkspaceICloudSyncEnabled: Bool
    var isHistoryICloudSyncEnabled: Bool
    var setWorkspaceICloudSyncEnabled: (Bool) -> Void
    var setHistoryICloudSyncEnabled: (Bool) -> Void
}

private struct BrowserCommandActionsKey: FocusedValueKey {
    typealias Value = BrowserCommandActions
}

extension FocusedValues {
    var browserCommandActions: BrowserCommandActions? {
        get { self[BrowserCommandActionsKey.self] }
        set { self[BrowserCommandActionsKey.self] = newValue }
    }
}
