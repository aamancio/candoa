import SwiftUI

/// Reserves native interface space without ever changing the live WKWebView's frame.
/// Keep this at the WebViewContainer boundary: moving the reservation into a
/// parent HStack makes WebKit stretch a stale remote-layer frame on every
/// sidebar toggle.
/// The interface lanes this frame. `visual` is where the page card's edges
/// are (mask, border, the chrome inside the card); `layout` is the lane the
/// web page is laid out against. They differ only mid-toggle: while a
/// sidebar opens the page is laid out against the moving lane live, and
/// while one closes the page has already been laid out against the final
/// lane (under the still-pinned edge) and only the visual edge moves, the
/// page translating with it — so no empty page ever shows beside a sidebar.
internal struct BrowserLaneState: Equatable {
    var visual = BrowserInterfaceInsets()
    var layout = BrowserInterfaceInsets()
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
/// frame's value to the subtree (Dia's push: the page card's edge, the
/// chrome inside it and — on open — the web layout follow the sidebar's
/// edge frame by frame; WebKit commits an inset change for typical pages
/// within a frame or two, and the pane host translates the page by
/// whatever its layout trails).
internal struct BrowserLaneEffect: @MainActor AnimatableModifier {
    var visualLeading: CGFloat
    var visualTrailing: CGFloat
    var layoutLeading: CGFloat
    var layoutTrailing: CGFloat
    var trailingGutter: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(visualLeading, visualTrailing),
                AnimatablePair(AnimatablePair(layoutLeading, layoutTrailing), trailingGutter)
            )
        }
        set {
            visualLeading = newValue.first.first
            visualTrailing = newValue.first.second
            layoutLeading = newValue.second.first.first
            layoutTrailing = newValue.second.first.second
            trailingGutter = newValue.second.second
        }
    }

    // Half-point steps: the spring's settling tail would otherwise feed the
    // web process a run of sub-pixel relayouts for nothing.
    private func snapped(_ value: CGFloat) -> CGFloat {
        max(0, (value * 2).rounded() / 2)
    }

    func body(content: Content) -> some View {
        content.environment(
            \.browserLaneState,
            BrowserLaneState(
                visual: BrowserInterfaceInsets(leading: snapped(visualLeading), trailing: snapped(visualTrailing)),
                layout: BrowserInterfaceInsets(leading: snapped(layoutLeading), trailing: snapped(layoutTrailing)),
                trailingGutter: snapped(trailingGutter)
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
