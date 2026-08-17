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
                .frame(width: 7, height: 7)

            Capsule(style: .continuous)
                .fill(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .offset(x: -1)
        }
        .frame(maxWidth: .infinity)
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
    /// A row shows the insertion line on whichever edge the pointer is
    /// nearest. There is no third, whole-row state: the sidebar reorders and
    /// only reorders, so nothing competes with the boundary for the row's
    /// middle. Split drops are marked on the page surface instead.
    func sidebarRowDropIndicator(
        showsTop: Bool,
        showsBottom: Bool,
        tint: Color
    ) -> some View {
        overlay(alignment: .top) {
            if showsTop {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: -2)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottom {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: 2)
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
