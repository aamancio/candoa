import SwiftUI

internal struct SidebarHorizontalDropLine: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(tint, lineWidth: 2)
                .background(
                    Circle()
                        .fill(InterfaceStyle.sidebarBackground)
                )
                .frame(width: SidebarDropMetrics.dropLineHeight, height: SidebarDropMetrics.dropLineHeight)

            Capsule(style: .continuous)
                .fill(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .offset(x: -1)
        }
        .frame(maxWidth: .infinity, minHeight: SidebarDropMetrics.dropLineHeight)
        // No tinted glow: it spread the indicator's colour into the rows
        // either side, which is what made a muted line still read as blue.
        .allowsHitTesting(false)
    }
}

internal struct SidebarVerticalDropLine: View {
    let tint: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(tint.opacity(0.82))
            .frame(width: 2)
            .shadow(color: tint.opacity(0.22), radius: 3, x: 1)
            .allowsHitTesting(false)
    }
}

internal extension View {
    /// Both of a row's boundaries can be marked, and each is shared with the
    /// neighbouring row, which can mark the same gap from its own side. The
    /// two must therefore land on the same pixel — the centre of the 4pt
    /// spacing — or one boundary looks like two places a tab could go, which
    /// is what a single-sided band used to avoid by simply not existing.
    ///
    /// Aligning to the row edge is not enough: the line has height and its
    /// overlay anchors the near edge, not its centre, so the two sides would
    /// sit a full line height apart — see `SidebarDropMetrics.dropLineOffset`.
    func sidebarRowDropIndicator(
        showsTop: Bool,
        showsSplit: Bool = false,
        showsBottom: Bool,
        tint: Color
    ) -> some View {
        overlay(alignment: .top) {
            if showsTop {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: -SidebarDropMetrics.dropLineOffset)
            }
        }
        .overlay {
            if showsSplit {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(InterfaceStyle.sidebarControlFillDropTarget)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.62), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottom {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: SidebarDropMetrics.dropLineOffset)
            }
        }
    }

    func sidebarEssentialDropIndicator(
        showsLeading: Bool,
        showsTrailing: Bool,
        tint: Color
    ) -> some View {
        overlay(alignment: .leading) {
            if showsLeading {
                SidebarVerticalDropLine(tint: tint)
                    .padding(.vertical, 7)
                    .offset(x: -4)
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailing {
                SidebarVerticalDropLine(tint: tint)
                    .padding(.vertical, 7)
                    .offset(x: 4)
            }
        }
    }
}
