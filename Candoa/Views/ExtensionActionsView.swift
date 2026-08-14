import AppKit
import SwiftUI

/// The sidebar header's extensions button: a puzzle piece that appears once
/// at least one extension is loaded, and opens the list of extension actions
/// for the active tab. Hidden entirely otherwise — the header row is width-
/// constrained, and most people have no extensions installed.
@available(macOS 15.4, *)
internal struct SidebarExtensionsButton: View {
    @ObservedObject private var manager = WebExtensionManager.shared
    @State private var isPopoverPresented = false

    var body: some View {
        if manager.hasLoadedExtensions {
            Button {
                isPopoverPresented = true
            } label: {
                Image(systemName: "puzzlepiece.extension")
            }
            .toolbarIconButton()
            .help(String(localized: "Extensions"))
            .background(ExtensionActionAnchor())
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                ExtensionActionsPopover(isPresented: $isPopoverPresented)
            }
        }
    }
}

/// Lists the loaded extensions' toolbar actions for the active tab. Clicking
/// a row performs the action: extensions with a popup get it presented from
/// the header button (via the manager's anchor registry), popup-less ones
/// fire their `action.onClicked` in the background script.
@available(macOS 15.4, *)
internal struct ExtensionActionsPopover: View {
    @Binding var isPresented: Bool
    @ObservedObject private var manager = WebExtensionManager.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(manager.actionDescriptors()) { descriptor in
                Button {
                    isPresented = false
                    // Let the popover dismiss before a popup action presents
                    // its own NSPopover from the same anchor.
                    DispatchQueue.main.async {
                        manager.performAction(for: descriptor.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            if let icon = descriptor.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "puzzlepiece.extension")
                            }
                        }
                        .frame(width: 16, height: 16)

                        Text(descriptor.label)
                            .lineLimit(1)

                        Spacer(minLength: 12)

                        if !descriptor.badgeText.isEmpty {
                            Text(descriptor.badgeText)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!descriptor.isEnabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Divider()
                .padding(.vertical, 4)

            Button {
                isPresented = false
                SettingsPaneRequest.request(.extensions)
                openSettings()
            } label: {
                Text(String(localized: "Manage Extensions…"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .padding(8)
        .frame(minWidth: 220)
        // Re-render when an extension updates its badge, icon, or enablement.
        .id(manager.actionRefreshToken)
    }
}

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
        if manager.hasLoadedExtensions {
            ForEach(manager.actionDescriptors()) { descriptor in
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

/// Invisible view that tells the manager where extension action popups
/// (WebKit-owned NSPopovers) should anchor in this window.
@available(macOS 15.4, *)
private struct ExtensionActionAnchor: NSViewRepresentable {
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                WebExtensionManager.shared.registerActionAnchor(self, for: window)
            }
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(frame: .zero)
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}
}
