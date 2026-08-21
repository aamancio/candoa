import AppKit

/// Builds the custom section of the Dock icon's right-click menu, matching
/// Safari's: New Window and New Private Window above the Dock's own
/// Options / Show All Windows / Hide / Quit rows (issue #234).
///
/// The items don't open windows themselves. Each one finds the File menu
/// row SwiftUI built for the same command — by its localized title, the way
/// `MenuAlternateInstaller` does — and fires that row's action, so a Dock
/// click and File ▸ New Window stay one code path (Space choice, window
/// placement, the private window's ready-to-type palette).
@MainActor
internal enum DockMenuBuilder {
    static let newWindowTitle = String(localized: "New Window")
    static let newPrivateWindowTitle = String(localized: "New Private Window")

    static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for title in [newWindowTitle, newPrivateWindowTitle] {
            let item = NSMenuItem(title: title, action: #selector(DockMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = DockMenuTarget.shared
            item.representedObject = title
            menu.addItem(item)
        }
        return menu
    }

    /// The main-menu row carrying `title`, searched one level down from the
    /// menu bar — New Window and New Private Window both live in File.
    static func mainMenuItem(titled title: String, in mainMenu: NSMenu?) -> NSMenuItem? {
        guard let mainMenu else { return nil }
        for topLevelItem in mainMenu.items {
            if let match = topLevelItem.submenu?.items.first(where: { $0.title == title }) {
                return match
            }
        }
        return nil
    }

    /// Sends the matching main-menu row's action through the responder
    /// chain exactly as a click on that row would.
    @discardableResult
    static func performMainMenuItem(titled title: String, in mainMenu: NSMenu? = NSApp.mainMenu) -> Bool {
        guard let item = mainMenuItem(titled: title, in: mainMenu), let action = item.action else {
            return false
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
}

@MainActor
private final class DockMenuTarget: NSObject {
    static let shared = DockMenuTarget()

    @objc func fire(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        DockMenuBuilder.performMainMenuItem(titled: title)
    }
}
