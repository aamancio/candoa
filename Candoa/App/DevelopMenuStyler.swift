import AppKit
import SwiftUI

/// Safari shows "Reload Page From Origin" only while Option is held: it is an
/// alternate of "Reload Page" rather than a line of its own. SwiftUI has no
/// modifier for `NSMenuItem.isAlternate`, so the flag is set on the menu
/// AppKit built — and re-set whenever the menu bar begins tracking, because
/// SwiftUI rebuilds these items as the focused browser state changes and a
/// rebuilt item comes back ordinary.
///
/// AppKit only honours the flag when the alternate directly follows its base
/// item and carries the same key equivalent with a different modifier mask,
/// which is how the two are declared in the View menu.
/// The Develop menu's device row, shared between the SwiftUI item that
/// declares it and the AppKit pass that styles it.
@MainActor
enum DeviceMenuPresentation {
    static let deviceName = Host.current().localizedName ?? "Mac"

    static let systemVersionLine: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 {
            version += ".\(os.patchVersion)"
        }
        return "macOS \(version)"
    }()

    static let menuTitle = "\(deviceName)\n\(systemVersionLine)"
}

/// Safari's Develop menu carries an icon on every row and renders the
/// device row as the machine's own icon beside its name over a smaller,
/// dimmed macOS version. SwiftUI's Commands drop Label images on the menu
/// bar and flatten the newline, so everything visual lands on the AppKit
/// items instead. Styling is wiped whenever SwiftUI rebuilds the items —
/// including the rebuild the tracking notification itself triggers through
/// the browser store — so it is re-applied in a short burst after each
/// menu-bar tracking session begins; every pass is idempotent.
@MainActor
internal enum DevelopMenuStyler {
    private static var observer: NSObjectProtocol?

    /// SF Symbol per localized row title, mirroring Safari's roster.
    /// Toggling rows appear under both of their titles.
    private static let symbolsByTitle: [String: String] = [
        BrowserCommandTitles.openPageWith: "arrow.up.forward.app",
        BrowserCommandTitles.userAgent: "globe",
        BrowserCommandTitles.showWebInspector: "macwindow.on.rectangle",
        BrowserCommandTitles.closeWebInspector: "macwindow.on.rectangle",
        BrowserCommandTitles.connectWebInspector: "rectangle.connected.to.line.below",
        BrowserCommandTitles.showJavaScriptConsole: "terminal",
        BrowserCommandTitles.showPageSource: "chevron.left.forwardslash.chevron.right",
        BrowserCommandTitles.showPageResources: "folder",
        BrowserCommandTitles.startTimelineRecording: "record.circle",
        BrowserCommandTitles.stopTimelineRecording: "record.circle",
        BrowserCommandTitles.startElementSelection: "cursorarrow.rays",
        BrowserCommandTitles.stopElementSelection: "cursorarrow.rays",
        BrowserCommandTitles.emptyCaches: "xmark",
        BrowserCommandTitles.developerSettings: "gearshape",
        BrowserCommandTitles.featureFlags: "flag",
        BrowserCommandTitles.copyURL: "link",
        BrowserCommandTitles.copyURLAsMarkdown: "doc.on.doc"
    ]

    static func install() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply() }
            // SwiftUI rebuilds triggered by the same notification (the
            // store nudge, the service-worker refresh) land on later
            // run-loop turns and hand back plain items; sweep behind them
            // while the menu is likely still open.
            for delay in [0.05, 0.15, 0.35, 0.7, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { apply() }
                }
            }
        }
    }

    private static func apply() {
        guard let mainMenu = NSApp.mainMenu,
              let developMenu = mainMenu.items.first(where: {
                  $0.submenu?.items.contains(where: isDeviceItem) == true
              })?.submenu
        else { return }

        for item in developMenu.items {
            if isDeviceItem(item) {
                styleDeviceItem(item)
            } else if item.image == nil,
                      let symbol = symbolsByTitle[item.title],
                      let icon = NSImage(
                          systemSymbolName: symbol,
                          accessibilityDescription: nil
                      ) {
                item.image = icon
            }
        }
    }

    private static func isDeviceItem(_ item: NSMenuItem) -> Bool {
        item.title == DeviceMenuPresentation.menuTitle
    }

    private static let iconSide: CGFloat = 24
    /// Canvas geometry picks the menu's layout mode: at 28pt and wider the
    /// device row gets the independent layout Safari's has (icon flush
    /// with the glyph column, text indented past it); narrower canvases
    /// join the shared icon column and poke left of the small glyphs. The
    /// trailing pad keeps the width above the threshold, the half-point
    /// leading pad lands the art on Safari's exact column position.
    private static let iconLeadingPad: CGFloat = 0.5
    private static let iconTrailingPad: CGFloat = 4

    /// NSImage.computerName carries transparent padding around the device
    /// art, which reads as an indent beside the menu's edge-to-edge SF
    /// Symbols. Crop to the art's alpha bounding box and draw it flush
    /// left, vertically centered, at Safari's proportions.
    private static func machineIcon() -> NSImage? {
        guard let machine = NSImage(named: NSImage.computerName) else { return nil }

        let probe = 64
        var buffer = [UInt8](repeating: 0, count: probe * probe * 4)
        guard let context = CGContext(
            data: &buffer, width: probe, height: probe,
            bitsPerComponent: 8, bytesPerRow: probe * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        machine.draw(in: NSRect(x: 0, y: 0, width: probe, height: probe))
        NSGraphicsContext.restoreGraphicsState()

        var minX = probe, maxX = -1, minY = probe, maxY = -1
        for y in 0..<probe {
            for x in 0..<probe where buffer[(y * probe + x) * 4 + 3] > 16 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Buffer rows run top-down while the image's coordinate space is
        // bottom-up, so the y range flips.
        let unit = machine.size.width / CGFloat(probe)
        let art = NSRect(
            x: CGFloat(minX) * unit,
            y: CGFloat(probe - 1 - maxY) * unit,
            width: CGFloat(maxX - minX + 1) * unit,
            height: CGFloat(maxY - minY + 1) * unit
        )

        let height = iconSide * art.height / art.width
        let canvasHeight = max(height, iconSide)
        let canvas = NSImage(
            size: NSSize(
                width: iconLeadingPad + iconSide + iconTrailingPad,
                height: canvasHeight
            ),
            flipped: false
        ) { _ in
            machine.draw(
                in: NSRect(
                    x: iconLeadingPad,
                    y: (canvasHeight - height) / 2,
                    width: iconSide,
                    height: height
                ),
                from: art,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        return canvas
    }

    /// Safari's device row: name over a dimmed subtitle with the machine's
    /// icon centered across both lines. The subtitled item is the system's
    /// own two-line layout; the icon then needs the private
    /// `-[NSMenuItem _setImageSize:]`, because item images are otherwise
    /// clamped to standard glyph size no matter the image's own size —
    /// probed with respondsToSelector, so a removed SPI just leaves the
    /// standard small icon. Pre-14.4 the two lines come from an attributed
    /// title with the small icon.
    private static func styleDeviceItem(_ item: NSMenuItem) {
        if item.attributedTitle == nil {
            let title = NSMutableAttributedString(
                string: DeviceMenuPresentation.deviceName + "\n",
                attributes: [.font: NSFont.menuFont(ofSize: 0)]
            )
            title.append(NSAttributedString(
                string: DeviceMenuPresentation.systemVersionLine,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            item.attributedTitle = title
        }

        let hasActionImageSelector = NSSelectorFromString("_hasActionImage")
        let alreadyStyled = item.image != nil
            || (item.responds(to: hasActionImageSelector)
                && item.method(for: hasActionImageSelector).map {
                    unsafeBitCast($0, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(item, hasActionImageSelector)
                } == true)
        if !alreadyStyled, let icon = machineIcon() {
            // The action-image slot is the leading icon column (where the
            // menu also places SF-symbol images); a plain item.image is a
            // content image with its own, more inset placement.
            let actionSelector = NSSelectorFromString("_setActionImage:")
            if item.responds(to: actionSelector) {
                _ = item.perform(actionSelector, with: icon)
                // The private setter posts no item-changed notification, so
                // whether the menu's column layout includes the icon was a
                // race against first layout; announce the change so the
                // geometry is recomputed deterministically.
                item.menu?.itemChanged(item)
            } else {
                item.image = icon
            }
            // Lifts the standard glyph-size clamp; a removed SPI just
            // leaves the standard small icon.
            let selector = NSSelectorFromString("_setImageSize:")
            if item.responds(to: selector), let method = item.method(for: selector) {
                let setImageSize = unsafeBitCast(
                    method,
                    to: (@convention(c) (AnyObject, Selector, NSSize) -> Void).self
                )
                setImageSize(item, selector, icon.size)
            }
        }

        guard let deviceSubmenu = item.submenu else { return }
        for row in deviceSubmenu.items {
            if row.title == "Candoa" {
                if row.image == nil,
                   let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
                    appIcon.size = NSSize(width: 16, height: 16)
                    row.image = appIcon
                }
            } else if row.isEnabled {
                row.indentationLevel = 1
            }
        }
    }
}
