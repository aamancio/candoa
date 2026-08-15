import SwiftUI

/// Reserves native interface space without ever changing the live WKWebView's frame.
/// Keep this at the WebViewContainer boundary: moving the reservation into a
/// parent HStack makes WebKit stretch a stale remote-layer frame on every
/// sidebar toggle.
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
