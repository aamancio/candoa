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

/// The row previewing what a split would look like: the tab it already holds
/// squeezed into one pane, a divide, and a ghost pane on the side the dragged
/// tab would take.
///
/// A highlight over the whole row said "this row is the target" and stopped
/// there — which of the two panes you were about to land in was left to the
/// person to guess. Zen answers it by putting a translucent
/// `zen-split-fake-tab` into the row on the drop side so the row becomes a
/// small picture of the result; this is that.
private struct SidebarSplitPreview: ViewModifier {
    let side: SplitTabDropSide?

    func body(content: Content) -> some View {
        if let side {
            let ghostLeads = side.insertsBeforeTarget
            content
                // The existing tab moves into the pane it keeps. Cropping it
                // in place instead would eat the favicon and start the title
                // mid-word, which reads as a glitch rather than a preview.
                // `visualEffect` is a paint-time offset, so the row's drop
                // target does not move out from under the pointer.
                .visualEffect { view, proxy in
                    view.offset(
                        x: ghostLeads
                            ? (proxy.size.width + SidebarDropMetrics.splitPreviewGap) / 2
                            : 0
                    )
                }
                // Applied after the offset, so it is not carried along with
                // the content: the pane stays put while the tab slides into
                // it. Without this the keeper half is only visible on a row
                // that happens to be hovered or active — on any other row
                // the preview was one block floating beside a title, with no
                // second pane and no divide to read.
                // Both panes are painted from the same two layers so they
                // composite to the same grey. Painting only the ghost's half
                // opaque put it on a different backdrop from the keeper —
                // one fill over the lane, the same fill over
                // `sidebarBackground` — and the two halves came out 78 and 70.
                .background {
                    // One background, not two: a second `.background` stacks
                    // *behind* the first, so an opaque base added that way
                    // hides the fills instead of sitting under them.
                    ZStack {
                        paneBase()
                        paneFills(ghostLeads: ghostLeads)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    ghostCover(ghostLeads: ghostLeads)
                }
        } else {
            content
        }
    }

    /// One opaque ground under the whole row, so neither pane is compositing
    /// its fill over the lane while the other composites over paint.
    private func paneBase() -> some View {
        Rectangle().fill(InterfaceStyle.sidebarBackground)
    }

    /// The pane the row keeps. Only that one: the ghost's half is painted by
    /// the cover on top, and filling it here as well laid the same
    /// translucent tone down twice, which came out two levels darker than
    /// its opposite number.
    private func paneFills(ghostLeads: Bool) -> some View {
        GeometryReader { proxy in
            let pane = paneWidth(in: proxy.size.width)
            HStack(spacing: 0) {
                if ghostLeads {
                    Color.clear.frame(width: pane + SidebarDropMetrics.splitPreviewGap)
                }
                paneShape()
                    .frame(width: pane)
                if !ghostLeads { Color.clear }
            }
        }
    }

    /// Redraws the ghost's half — and the divide — over the top, because the
    /// row's own title is still painted there: it is offset at paint time
    /// only, so its far end runs on under the divide and into the empty pane.
    ///
    /// Covering rather than masking is deliberate. A SwiftUI mask takes hit
    /// testing with it, so masking the row to its keeper pane made that half
    /// stop answering drag updates and the drop routing flickered between the
    /// row and the section behind it.
    private func ghostCover(ghostLeads: Bool) -> some View {
        GeometryReader { proxy in
            let pane = paneWidth(in: proxy.size.width)
            HStack(spacing: 0) {
                if !ghostLeads {
                    Color.clear.frame(width: pane)
                }
                ZStack {
                    paneBase()
                    HStack(spacing: 0) {
                        if !ghostLeads {
                            Color.clear.frame(width: SidebarDropMetrics.splitPreviewGap)
                        }
                        paneShape()
                            .frame(width: pane)
                        if ghostLeads {
                            Color.clear.frame(width: SidebarDropMetrics.splitPreviewGap)
                        }
                    }
                }
                .frame(width: pane + SidebarDropMetrics.splitPreviewGap)
                if ghostLeads {
                    Color.clear.frame(width: pane)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    /// One pane. Rounded on every corner and inset all round, which is what
    /// `zen-split-fake-tab` is — `border-radius` plus a margin, not a shape
    /// squared off where the two meet. Both panes are drawn from this, so
    /// they match; giving only the ghost a radius while the keeper stayed a
    /// full-height slab is what made them look like different objects.
    private func paneShape() -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(InterfaceStyle.sidebarControlFillDropTarget)
            .padding(.vertical, SidebarDropMetrics.splitPreviewInset)
    }

    private func paneWidth(in rowWidth: CGFloat) -> CGFloat {
        max((rowWidth - SidebarDropMetrics.splitPreviewGap) / 2, 0)
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
        splitSide: SplitTabDropSide? = nil,
        showsBottom: Bool,
        tint: Color
    ) -> some View {
        // The split preview masks and shifts the row's own content, so it
        // goes on first: the insertion lines sit outside the row's bounds
        // and a mask applied over them would clip them away.
        modifier(SidebarSplitPreview(side: splitSide))
        .overlay(alignment: .top) {
            if showsTop {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: -SidebarDropMetrics.dropLineOffset)
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
