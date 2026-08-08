import SwiftUI

/// The user-facing trust surface for the displayed site: effective origin,
/// what the connection can truthfully claim, and the per-site permission
/// decisions Candoa supports. Anchored to the sidebar address pill's leading
/// icon and reachable from View ▸ Site Info.
struct SiteInfoPopoverView: View {
    @ObservedObject var store: BrowserStore
    let url: URL
    let tabID: UUID?

    @AppStorage(SitePermissionConfiguration.storageKey)
    private var permissionOverrides = ""

    // Captured once when the popover opens — a deliberate snapshot, not an
    // observation, so showing Site Info never adds steady-state work.
    @State private var securitySummary: SiteSecuritySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            connectionSection

            if originKey != nil {
                Divider()
                permissionsSection
            } else {
                Divider()
                Text("Site permissions aren't available for this page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            securitySummary = store.siteSecuritySummary(for: tabID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("site-info-popover")
    }

    private var originKey: String? {
        SitePermissionConfiguration.originKey(for: url)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("site-info-host")

            if let originKey {
                Text(originKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var displayName: String {
        if url.isFileURL {
            return url.lastPathComponent.isEmpty ? url.path() : url.lastPathComponent
        }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(connectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: connectionSymbol)
                    .font(.system(size: 13, weight: .medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("site-info-connection")

            if let certificateLine {
                Text(certificateLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionTitle: LocalizedStringKey {
        switch securitySummary?.connection {
        case .secure:
            return "Encrypted connection"
        case .mixedContent:
            return "Partially encrypted"
        case .insecure:
            return "Not encrypted"
        case .localDevelopment:
            return "Local development server"
        case .localFile:
            return "Local file"
        case nil:
            // No live web view to ask (a hibernated tab, for instance) —
            // saying nothing beats claiming more than is known.
            return "Connection state unavailable"
        }
    }

    private var connectionDetail: LocalizedStringKey {
        switch securitySummary?.connection {
        case .secure:
            return "Information you exchange with this site is encrypted in transit."
        case .mixedContent:
            return "This page loaded some content over an unencrypted connection."
        case .insecure:
            return "Information you send to this site can be read by others."
        case .localDevelopment:
            return "This page is served from a local address on this Mac."
        case .localFile:
            return "This page is a file on this Mac, not a website."
        case nil:
            return "Open the page to check its connection."
        }
    }

    private var connectionSymbol: String {
        switch securitySummary?.connection {
        case .secure:
            return "lock.fill"
        case .mixedContent:
            return "lock.trianglebadge.exclamationmark"
        case .insecure:
            return "lock.slash"
        case .localDevelopment:
            return "hammer"
        case .localFile:
            return "doc"
        case nil:
            return "questionmark.circle"
        }
    }

    private var certificateLine: String? {
        guard let summary = securitySummary, let subject = summary.certificateSubject else {
            return nil
        }
        if let expiry = summary.certificateExpiry {
            let formatted = expiry.formatted(date: .abbreviated, time: .omitted)
            return String(localized: "Certificate: \(subject), expires \(formatted)")
        }
        return String(localized: "Certificate: \(subject)")
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(SitePermission.allCases) { permission in
                permissionRow(for: permission)
            }

            if SitePermissionConfiguration.hasDecisions(
                for: url,
                storedOverrides: permissionOverrides
            ) {
                Button("Reset Permissions") {
                    store.resetSitePermissions(for: url)
                }
                .font(.caption)
                .accessibilityIdentifier("site-info-reset")
            }
        }
    }

    private func permissionRow(for permission: SitePermission) -> some View {
        HStack(spacing: 8) {
            Label(permissionTitle(for: permission), systemImage: permissionSymbol(for: permission))
                .font(.system(size: 12))

            Spacer(minLength: 12)

            Picker(
                permissionTitle(for: permission),
                selection: Binding(
                    get: {
                        SitePermissionConfiguration.decision(
                            for: permission,
                            url: url,
                            storedOverrides: permissionOverrides
                        )
                    },
                    set: { store.setSitePermission($0, for: permission, url: url) }
                )
            ) {
                if permission.supportsAsking {
                    Text("Ask").tag(SitePermissionDecision.ask)
                }
                Text("Allow").tag(SitePermissionDecision.allow)
                Text(permission.supportsAsking ? "Deny" : "Block")
                    .tag(SitePermissionDecision.deny)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("site-info-permission-\(permission.rawValue)")
        }
    }

    private func permissionTitle(for permission: SitePermission) -> LocalizedStringKey {
        switch permission {
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        case .popupWindows:
            return "Pop-up Windows"
        }
    }

    private func permissionSymbol(for permission: SitePermission) -> String {
        switch permission {
        case .camera:
            return "video"
        case .microphone:
            return "mic"
        case .popupWindows:
            return "macwindow.on.rectangle"
        }
    }
}
