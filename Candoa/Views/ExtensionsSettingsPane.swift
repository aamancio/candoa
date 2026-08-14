import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Extensions, in Safari's master-detail shape: the installed
/// list with enable checkboxes on the left, and the selected extension's
/// detail — description, Uninstall, private-browsing consent, and a
/// plain-language permissions summary — on the right. Surfaces Safari shows
/// but Candoa can't act on yet (per-site editing, shortcuts, syncing) are
/// omitted rather than shown inert. The WKWebExtension APIs need macOS 15.4;
/// on older systems the pane says so instead of showing controls.
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
    @State private var selectedID: UUID?
    @State private var installErrorDescription: String?
    @State private var pendingRemoval: WebExtensionInstallation?

    private var selectedInstallation: WebExtensionInstallation? {
        manager.installations.first { $0.id == selectedID }
            ?? manager.installations.first
    }

    var body: some View {
        HStack(spacing: 0) {
            installedColumn
                .frame(width: 230)

            Divider()

            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
            String(localized: "Uninstall “\(pendingRemoval?.displayName ?? "")”?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button(String(localized: "Uninstall"), role: .destructive) {
                if let pendingRemoval {
                    manager.remove(pendingRemoval.id)
                    if selectedID == pendingRemoval.id {
                        selectedID = manager.installations.first?.id
                    }
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

    // MARK: - Installed column

    private var installedColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: presentInstallPanel) {
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Install Extension…"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Text(String(localized: "Installed"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            if manager.installations.isEmpty {
                Text(String(localized: "No extensions installed"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer()
            } else {
                List(selection: $selectedID) {
                    ForEach(manager.installations) { installation in
                        installedRow(installation)
                            .tag(installation.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = manager.installations.first?.id
            }
        }
    }

    private func installedRow(_ installation: WebExtensionInstallation) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { installation.isEnabled },
                set: { manager.setEnabled($0, for: installation.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            extensionIcon(installation, size: 18)

            Text(installation.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
        }
    }

    // MARK: - Detail panel

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let installation = selectedInstallation {
                    detailHeader(installation)

                    if let failure = manager.loadFailureDescriptions[installation.id] {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    privateBrowsingSection(installation)
                    permissionsSection(installation)
                } else {
                    emptyDetail
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Candoa runs Chrome and Firefox web extensions."))
                .font(.system(size: 13))
            Text(String(localized: "Choose an extension folder, or a .zip, .crx, or .xpi file."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func detailHeader(_ installation: WebExtensionInstallation) -> some View {
        HStack(alignment: .top, spacing: 14) {
            extensionIcon(installation, size: 48)

            VStack(alignment: .leading, spacing: 5) {
                (Text(installation.displayName).fontWeight(.semibold)
                    + Text(verbatim: " \(installation.version)").foregroundStyle(.secondary))
                    .font(.system(size: 14))

                if let description = manager.displayDescription(for: installation.id),
                   !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(String(localized: "Uninstall")) {
                    pendingRemoval = installation
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private func privateBrowsingSection(_ installation: WebExtensionInstallation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Private Browsing:"))
                .font(.system(size: 13, weight: .semibold))

            Toggle(String(localized: "Allow in Private Browsing"), isOn: Binding(
                get: { installation.allowsPrivateBrowsing },
                set: { manager.setAllowsPrivateBrowsing($0, for: installation.id) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!installation.isEnabled)
            .padding(.leading, 12)
        }
    }

    @ViewBuilder
    private func permissionsSection(_ installation: WebExtensionInstallation) -> some View {
        if let access = manager.websiteAccess(for: installation.id) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Permissions:"))
                    .font(.system(size: 13, weight: .semibold))

                switch access {
                case .allWebsites:
                    permissionCallout(
                        headline: String(
                            localized: "This extension can read and alter webpages you visit and see your browsing history on all websites."
                        ),
                        detail: String(
                            localized: "This includes sensitive information from webpages, including passwords, phone numbers, and credit cards."
                        )
                    )
                case .websites(let hosts):
                    permissionCallout(
                        headline: String(
                            localized: "This extension can read and alter webpages you visit on: \(hosts.joined(separator: ", "))."
                        ),
                        detail: nil
                    )
                case .none:
                    Text(String(localized: "This extension requests no access to webpages."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
            }
        }
    }

    private func permissionCallout(headline: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color(nsColor: .systemBrown))

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .systemBrown).opacity(0.16),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func extensionIcon(_ installation: WebExtensionInstallation, size: CGFloat) -> some View {
        if let icon = manager.icon(for: installation.id, size: size) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
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
                if case .installed(let installation) = try await WebExtensionManager.shared.install(from: url) {
                    selectedID = installation.id
                }
            } catch {
                installErrorDescription = error.localizedDescription
            }
        }
    }
}
