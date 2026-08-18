import AppKit
import SwiftUI

@main
struct CandoaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var userStore = UserStore()

    init() {
        // Candoa has no tab bar — tabs live in the sidebar. Left on, AppKit's
        // automatic window tabbing injects "Hide Tab Bar" and "Show All Tabs"
        // into View and "Merge All Windows" into Window, all advertising a
        // surface the app doesn't have. Set before any scene is built.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(id: AppConfiguration.browserWindowSceneID) {
            ContentView()
                .environmentObject(userStore)
                .tint(AppColor.accent)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
            AboutCommands()
            BrowserCommands(userStore: userStore)
            // Separate struct: BrowserCommands' builder is at the
            // ten-element limit. Declared last so the menu lands after
            // Develop, before Window.
            ExtensionsCommands()
        }

        // Private windows: same interface, but the store persists nothing
        // and web content runs against a non-persistent data store. The
        // empty external-events set keeps URLs from other apps out of
        // private windows — they always open ordinarily unless the user
        // explicitly chooses otherwise.
        WindowGroup(id: AppConfiguration.privateBrowserWindowSceneID) {
            ContentView(isPrivate: true)
                .environmentObject(userStore)
                .tint(AppColor.accent)
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
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environmentObject(userStore)
                .tint(AppColor.accent)
        }

        // Help ▸ Acknowledgments. The same Credits.rtf also feeds the
        // standard About panel, which picks it up from the bundle on its own.
        Window(
            BrowserCommandTitles.acknowledgments,
            id: AppConfiguration.acknowledgmentsWindowSceneID
        ) {
            AcknowledgmentsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 380)
        // Without this, the scene injects its own "Acknowledgments" row into
        // the Window menu, duplicating the Help menu entry.
        .commandsRemoved()

        // Help ▸ Report an Issue…. Its own scene so it opens with no browser
        // window key, the same way Acknowledgments does.
        Window(
            BrowserCommandTitles.reportAProblemWindowTitle,
            id: AppConfiguration.reportProblemWindowSceneID
        ) {
            ReportProblemView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        // Develop ▸ Feature Flags…, Safari's WebKit experimental-feature
        // panel.
        Window(
            BrowserCommandTitles.featureFlagsWindowTitle,
            id: AppConfiguration.featureFlagsWindowSceneID
        ) {
            FeatureFlagsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 620)
        .commandsRemoved()
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
