import SwiftUI

internal struct SidebarHorizontalDropLine: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(tint.opacity(0.92), lineWidth: 2)
                .background(
                    Circle()
                        .fill(InterfaceStyle.sidebarBackground)
                )
                .frame(width: 7, height: 7)

            Capsule(style: .continuous)
                .fill(tint.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .offset(x: -1)
        }
        .frame(maxWidth: .infinity)
        .shadow(color: tint.opacity(0.22), radius: 3, y: 1)
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
                    .offset(y: -2)
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
