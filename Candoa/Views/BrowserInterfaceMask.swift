import SwiftUI

/// Reserves native interface space without ever changing the live WKWebView's frame.
/// Keep this at the WebViewContainer boundary: moving the reservation into a
/// parent HStack makes WebKit stretch a stale remote-layer frame on every
/// sidebar toggle.
/// The interface lanes the page is laid out and clipped against, as they
/// are *this frame*. Written per frame by `BrowserLaneEffect` while a
/// sidebar toggles, so the page card's edge, the web layout and the chrome
/// inside the card all move together — the way Dia pushes the page.
internal struct BrowserLaneState: Equatable {
    var insets = BrowserInterfaceInsets()
    /// The gutter between the page card and the trailing lane: the window's
    /// 8pt when nothing is docked there, 0 once Eli is, and in between while
    /// Eli's edge is on the move.
    var trailingGutter: CGFloat = 8
}

private struct BrowserLaneStateKey: EnvironmentKey {
    static let defaultValue = BrowserLaneState()
}

extension EnvironmentValues {
    internal var browserLaneState: BrowserLaneState {
        get { self[BrowserLaneStateKey.self] }
        set { self[BrowserLaneStateKey.self] = newValue }
    }
}

/// Interpolates the lanes through an animated transaction and hands each
/// frame's value to the subtree. The web host below re-lays the page out
/// against the interpolated lane every frame, so the page content follows
/// the sidebar's edge live (Dia's push) rather than snapping at either end;
/// WebKit commits an inset change for typical pages within a frame.
internal struct BrowserLaneEffect: @MainActor AnimatableModifier {
    var leading: CGFloat
    var trailing: CGFloat
    var trailingGutter: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(leading, AnimatablePair(trailing, trailingGutter)) }
        set {
            leading = newValue.first
            trailing = newValue.second.first
            trailingGutter = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        // Half-point steps: the spring's settling tail would otherwise feed
        // the web process a run of sub-pixel relayouts for nothing.
        content.environment(
            \.browserLaneState,
            BrowserLaneState(
                insets: BrowserInterfaceInsets(
                    leading: max(0, (leading * 2).rounded() / 2),
                    trailing: max(0, (trailing * 2).rounded() / 2)
                ),
                trailingGutter: max(0, (trailingGutter * 2).rounded() / 2)
            )
        )
    }
}

internal struct BrowserInterfaceMaskModifier: ViewModifier {
    let insets: BrowserInterfaceInsets
    let slideOverTrailingInset: CGFloat
    let surfaceCornerRadius: CGFloat
    let surfacePadding: CGFloat
    let trailingSurfacePadding: CGFloat
    let drawsFullSurfaceBorder: Bool

    // The trailing lane is reserved either persistently (insets) or
    // transiently while Eli covers the page beyond the reserved layout.
    // Both clip the same way, so every trailing measurement uses their sum.
    private var leadingInset: CGFloat {
        insets.leading
    }

    private var trailingInset: CGFloat {
        insets.trailing + slideOverTrailingInset
    }

    func body(content: Content) -> some View {
        content
            .mask {
                if leadingInset > 0 || trailingInset > 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .padding(.vertical, surfacePadding)
                            .padding(.leading, leadingInset + surfacePadding)
                            .padding(.trailing, trailingInset + trailingSurfacePadding)

                        // Preserve the surface's existing top, trailing, and
                        // bottom shadow. Only the interface regions need clipping.
                        Rectangle()
                            .padding(
                                .leading,
                                leadingInset > 0
                                    ? leadingInset + surfacePadding + surfaceCornerRadius
                                    : 0
                            )
                            .padding(
                                .trailing,
                                trailingInset > 0
                                    ? trailingInset + surfacePadding + surfaceCornerRadius
                                    : 0
                            )
                    }
                } else {
                    Rectangle()
                }
            }
            .overlay {
                if drawsFullSurfaceBorder {
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                        .padding(.vertical, surfacePadding)
                        .padding(.leading, leadingInset + surfacePadding)
                        .padding(.trailing, trailingInset + trailingSurfacePadding)
                        .allowsHitTesting(false)
                } else {
                    // Split panes own their individual borders. Add only sides
                    // introduced by this mask so shared edges are not repainted.
                    if leadingInset > 0 {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: surfaceCornerRadius + 1)
                            }
                            .padding(.vertical, surfacePadding)
                            .padding(.leading, leadingInset + surfacePadding)
                            .padding(.trailing, trailingInset + trailingSurfacePadding)
                            .allowsHitTesting(false)
                    }

                    if trailingInset > 0 {
                        RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                            .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
                            .mask(alignment: .trailing) {
                                Rectangle()
                                    .frame(width: surfaceCornerRadius + 1)
                            }
                            .padding(.vertical, surfacePadding)
                            .padding(.leading, leadingInset + surfacePadding)
                            .padding(.trailing, trailingInset + trailingSurfacePadding)
                            .allowsHitTesting(false)
                    }
                }
            }
    }
}
