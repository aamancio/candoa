import SwiftUI

/// Native recovery surface shown over a pane whose navigation failed or
/// whose WebContent process died. The web view stays mounted underneath;
/// this cover disappears the moment a navigation commits real content.
struct TabRecoveryView: View {
    let failure: TabLoadFailure
    let onRetry: () -> Void

    private var failedHost: String? {
        failure.failedURL?.host(percentEncoded: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: failure.symbolName)
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(.quaternary.opacity(0.5), in: Circle())
                .padding(.bottom, 16)

            Text(failure.title)
                .font(.title2.weight(.semibold))
                .padding(.bottom, 6)

            if let failedHost {
                Text(failedHost)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 380)
                    .padding(.bottom, 6)
            }

            Text(failure.guidance)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.bottom, 22)

            Button(failure.retryTitle, action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AppColor.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("tab-recovery-retry")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InterfaceStyle.workspaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-recovery-view")
    }
}
