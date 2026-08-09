import SwiftUI

/// Calm, accurate transparency about tracker blocking. WebKit's content
/// rules are deliberately opaque — the network process never reports what it
/// blocked — so this report describes the protection itself: whether it is
/// on, how it works, and the exact list it enforces. Nothing per-request is
/// counted or stored, which keeps the browsing-history and battery
/// guarantees trivially true.
struct PrivacyReportView: View {
    @AppStorage(SettingsOption.strictTrackingProtection)
    private var strictTrackingProtection = true

    let onDismiss: () -> Void

    @State private var expandedCategoryIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection

                    Divider()

                    protectionListSection

                    Divider()

                    retentionSection
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 540)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy-report")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Privacy Report")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-report-done")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        strictTrackingProtection
                            ? "Tracking protection is on"
                            : "Tracking protection is off"
                    )
                    .font(.system(size: 13, weight: .medium))

                    Text(
                        strictTrackingProtection
                            ? "Requests to known trackers are stopped inside WebKit's network process, before they ever leave this Mac."
                            : "Pages load without tracker blocking. You can turn it back on in Candoa's Privacy settings."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: strictTrackingProtection ? "shield.fill" : "shield.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(strictTrackingProtection ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("privacy-report-status")

            Text("Candoa's protection list is compiled into WebKit content rules once. A blocked request simply never happens — no script watches the pages you visit, and no extra work runs while you browse.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
    }

    // MARK: - Protection list

    private var protectionListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's blocked")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Third-party requests to every domain below are blocked on all sites. First-party requests are left alone, so the sites you visit keep working — including sign-ins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ContentBlockerService.protectionCategories) { category in
                categoryRow(for: category)
            }
        }
    }

    private func categoryRow(for category: TrackerProtectionCategory) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedCategoryIDs.contains(category.id) },
                set: { isExpanded in
                    if isExpanded {
                        expandedCategoryIDs.insert(category.id)
                    } else {
                        expandedCategoryIDs.remove(category.id)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(category.domains, id: \.self) { domain in
                    Text(verbatim: domain)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(category.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // The count is the number of rules in the compiled list —
                // a static fact about the protection, not a measurement.
                Text(verbatim: "\(category.domains.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .accessibilityIdentifier("privacy-report-category-\(category.id)")
    }

    // MARK: - Retention

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What Candoa keeps")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Nothing. Candoa doesn't record which requests were blocked or keep a per-site tally, so this report never contains your browsing history and there is no report data to clear.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("privacy-report-retention")
        }
    }
}
