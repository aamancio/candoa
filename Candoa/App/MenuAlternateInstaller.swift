import AppKit

@MainActor
internal enum MenuAlternateInstaller {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { applyReloadAlternate() }
        }
    }

    private static func applyReloadAlternate() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu,
                  let index = submenu.items.firstIndex(where: {
                      $0.title == BrowserCommandTitles.reloadTabFromOrigin
                  }),
                  index > 0,
                  submenu.items[index - 1].title == BrowserCommandTitles.reloadTab
            else { continue }

            let alternate = submenu.items[index]
            guard !alternate.isAlternate else { return }

            alternate.keyEquivalent = "r"
            alternate.keyEquivalentModifierMask = [.command, .option]
            alternate.isAlternate = true
            return
        }
    }
}
