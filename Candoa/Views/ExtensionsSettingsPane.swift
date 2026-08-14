import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Extensions: install, list, enable/disable, and remove web
/// extensions. The WKWebExtension APIs need macOS 15.4; on older systems the
/// pane says so instead of showing controls.
internal struct ExtensionsSettingsPane: View {
    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionsSettingsContent()
        } else {
            SettingsPane {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSectionTitle(String(localized: "Extensions"))

                    SettingsCard {
                        SettingsRow(
                            systemImage: "puzzlepiece.extension",
                            title: String(localized: "Extensions aren't available"),
                            subtitle: String(localized: "Extensions require macOS 15.4 or later.")
                        ) {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionsSettingsContent: View {
    @ObservedObject private var manager = WebExtensionManager.shared
    @State private var installErrorDescription: String?
    @State private var pendingRemoval: WebExtensionInstallation?

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle(String(localized: "Extensions"))

                SettingsCard {
                    if manager.installations.isEmpty {
                        SettingsRow(
                            systemImage: "puzzlepiece.extension",
                            title: String(localized: "No extensions installed"),
                            subtitle: String(
                                localized: "Candoa runs Chrome and Firefox web extensions."
                            )
                        ) {
                            EmptyView()
                        }
                    } else {
                        ForEach(Array(manager.installations.enumerated()), id: \.element.id) { index, installation in
                            installationRow(installation)

                            if index < manager.installations.count - 1 {
                                SettingsDivider()
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(String(localized: "Install Extension…"), action: presentInstallPanel)
                        .controlSize(.small)

                    Text(String(localized: "Choose an extension folder, or a .zip, .crx, or .xpi file."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
            }
        }
        .alert(
            String(localized: "Couldn't install the extension."),
            isPresented: Binding(
                get: { installErrorDescription != nil },
                set: { if !$0 { installErrorDescription = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(installErrorDescription ?? "")
        }
        .confirmationDialog(
            String(localized: "Remove “\(pendingRemoval?.displayName ?? "")”?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button(String(localized: "Remove"), role: .destructive) {
                if let pendingRemoval {
                    manager.remove(pendingRemoval.id)
                }
                pendingRemoval = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(String(localized: "This deletes the extension and the data it stored in Candoa."))
        }
    }

    private func installationRow(_ installation: WebExtensionInstallation) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon = manager.icon(for: installation.id, size: 20) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(installation.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                Text(subtitle(for: installation))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if installation.isEnabled {
                    Toggle(String(localized: "Allow in Private Browsing"), isOn: Binding(
                        get: { installation.allowsPrivateBrowsing },
                        set: { manager.setAllowsPrivateBrowsing($0, for: installation.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 32)

            Toggle("", isOn: Binding(
                get: { installation.isEnabled },
                set: { manager.setEnabled($0, for: installation.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button(String(localized: "Remove")) {
                pendingRemoval = installation
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func subtitle(for installation: WebExtensionInstallation) -> String {
        if let failure = manager.loadFailureDescriptions[installation.id] {
            return failure
        }
        return installation.version
    }

    private func presentInstallPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.folder, .zip]
        for fileExtension in ["crx", "xpi"] {
            if let type = UTType(filenameExtension: fileExtension) {
                contentTypes.append(type)
            }
        }
        panel.allowedContentTypes = contentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                _ = try await WebExtensionManager.shared.install(from: url)
            } catch {
                installErrorDescription = error.localizedDescription
            }
        }
    }
}
