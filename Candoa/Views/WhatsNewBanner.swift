import SwiftUI

/// Post-update pill in the update-banner slot: activating it opens the hosted
/// What's New page in a new tab, and the hover close dismisses it quietly.
internal struct WhatsNewBanner: View {
    let action: () -> Void
    let dismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("See What's New")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            // The tint alone is nearly transparent, so the pill floats over
            // the tab list rather than sitting on it: the material underneath
            // is what makes it read as a chip of its own.
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? InterfaceStyle.updateBannerFillHover : InterfaceStyle.updateBannerFill)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(InterfaceStyle.updateBannerStroke, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonTreatment(.content)
        .accessibilityIdentifier("sidebar-whats-new-banner")
        .overlay(alignment: .trailing) {
            if isHovering {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(InterfaceStyle.sidebarText.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .accessibilityIdentifier("sidebar-whats-new-dismiss")
                .help("Dismiss")
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Candoa updated — see what's new")
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }
}
