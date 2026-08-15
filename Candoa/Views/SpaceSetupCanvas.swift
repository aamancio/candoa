import AppKit
import SwiftUI

internal struct SpaceSetupCanvas: View {
    let hexes: [String]
    let intensity: Double
    let texture: Double

    var body: some View {
        if hexes.isEmpty {
            neutralCanvas
        } else {
            themedCanvas
        }
    }

    private var neutralCanvas: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(InterfaceStyle.workspaceBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
            }
    }

    private var themedCanvas: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let highlight = Color(nsColor: .highlightColor)
        let shadow = Color(nsColor: .shadowColor)

        return ZStack {
            shape.fill(canvasFill)

            LinearGradient(
                colors: [highlight.opacity(0.03), shadow.opacity(0.012)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(shape)

            LinearGradient(
                colors: [highlight.opacity(0.04), .clear, shadow.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.overlay)
            .clipShape(shape)
        }
        .overlay {
            shape.stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: shadow.opacity(0.18), radius: 30, y: 10)
        .shadow(color: shadow.opacity(0.10), radius: 14, x: -4, y: 1)
    }

    private var canvasFill: Color {
        guard let firstHex = hexes.first else {
            // This is the visible empty-workspace surface. Keep it on the
            // semantic under-page role instead of compositing the darker
            // control background over the window backdrop.
            return InterfaceStyle.workspaceBackground
        }

        // The window backdrop already carries the theme color at full
        // strength; keep the card nearly transparent so interface and canvas
        // read as one continuous surface (Zen-style).
        return Color(spaceHex: firstHex).opacity(0.08)
    }
}

/// Explainer shown on the empty content surface of a private window,
/// describing exactly what Candoa's private browsing does and doesn't
/// keep. Onboarding-sheet style: icon badge, lede, symbol feature rows.
/// Replaced by web content as soon as a tab opens.
internal struct PrivateBrowsingExplainer: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(.quaternary.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .padding(.bottom, 16)

            Text("Private Browsing")
                .font(.title.weight(.semibold))
                .padding(.bottom, 4)

            Text("Browse without leaving a trace on this Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 18) {
                featureRow(
                    symbol: "clock.arrow.circlepath",
                    title: String(localized: "No history"),
                    detail: String(
                        localized: "Pages you visit and searches you make aren't saved."
                    )
                )
                featureRow(
                    symbol: "wind",
                    title: String(localized: "Nothing sticks"),
                    detail: String(
                        localized: "Cookies, logins, and site data vanish when you close this window."
                    )
                )
                featureRow(
                    symbol: "square.grid.2x2",
                    title: String(localized: "Outside your Spaces"),
                    detail: String(
                        localized: "Tabs here never join your workspace or sync with iCloud."
                    )
                )
                featureRow(
                    symbol: "arrow.down.circle",
                    title: String(localized: "Downloads are kept"),
                    detail: String(
                        localized: "Files you save stay in your Downloads folder."
                    )
                )
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 40)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("private-browsing-explainer")
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
