import AppKit
import SwiftUI

/// Arc-style top-level Extensions menu: each loaded extension's action for
/// the frontmost window's active tab, then management. Safari has no menu to
/// copy here — its extensions live in the toolbar and Settings — so the menu
/// mirrors the sidebar button's popover instead.
internal struct ExtensionsCommands: Commands {
    var body: some Commands {
        CommandMenu("Extensions") {
            if #available(macOS 15.4, *) {
                ExtensionsMenuItems()
            } else {
                Button(String(localized: "Extensions require macOS 15.4 or later.")) {}
                    .disabled(true)
            }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionsMenuItems: View {
    @ObservedObject private var manager = WebExtensionManager.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // actionDescriptors already reflects the focused window: in a
        // private window it lists only extensions granted private access.
        let descriptors = manager.actionDescriptors()
        if !descriptors.isEmpty {
            ForEach(descriptors) { descriptor in
                Button {
                    manager.performAction(for: descriptor.id)
                } label: {
                    if let icon = descriptor.icon {
                        Label {
                            Text(descriptor.label)
                        } icon: {
                            Image(nsImage: icon)
                        }
                    } else {
                        Text(descriptor.label)
                    }
                }
                .disabled(!descriptor.isEnabled)
            }

            Divider()
        }

        Button(String(localized: "Manage Extensions…")) {
            SettingsPaneRequest.request(.extensions)
            openSettings()
        }
    }
}
