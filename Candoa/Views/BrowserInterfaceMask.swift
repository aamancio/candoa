import SwiftUI

/// A still of the active page, shown over the live web view for the length
/// of a sidebar toggle. The one thing WebKit cannot do at the sidebar's
/// frame rate is reflow — on heavy pages an obscured-inset relayout commits
/// every 150–250ms, while the edge springs at 60fps — so mid-toggle the
/// page's committed layout is always stale beside the moving edge: a strip
/// of bare page background where content should be, then a jump when the
/// commit lands. The shield replaces that with real pixels: the live page
/// relayouts to its final lanes exactly once, invisibly, underneath, and
/// the still rides the visual edge, compositor-only, at full frame rate.
internal struct PageToggleShield: Identifiable, Equatable {
    let id: UUID
    let image: NSImage
    /// The pictured layout viewport's size, in points. `takeSnapshot`
    /// captures the layout viewport from its own origin — the obscured
    /// lanes are not in the bitmap — so this is the size of the page as it
    /// was laid out, not the hosting view.
    let size: CGSize
    /// The lanes the pictured layout was laid out against. The bitmap's
    /// leading edge is the pictured page's leading edge, so drawing it at
    /// the visual leading edge glues the pictured page to the moving
    /// sidebar, whatever lane it was captured against.
    let anchorLeading: CGFloat
    let anchorTrailing: CGFloat
    var opacity: Double = 1

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.opacity == rhs.opacity
    }
}

/// Draws the shield between the visual lanes frame by frame: its leading
/// edge glued to the moving sidebar edge, its trailing edge pinned to the
/// card's far edge, the pictured page stretched horizontally between them —
/// the same trick macOS window resizing uses. Content by the moving edge
/// rides it (Dia's push), the far column holds its place, and the middle
/// squeezes the way a fluid page compresses, with no seam and nothing of
/// the live page's mid-reflow layout showing anywhere. A rigid translation
/// instead either exposed the live page's stale far edge or duplicated the
/// pictured one.
internal struct PageToggleShieldView: View {
    let shield: PageToggleShield
    @Environment(\.browserLaneState) private var laneState

    var body: some View {
        // Sized against the host's live bounds, not the captured size: the
        // trailing gutter closes as Eli's edge comes in, widening the host
        // under the shield by up to its 8pt — a capture-sized shield left a
        // sliver of the live page showing at the trailing edge.
        GeometryReader { proxy in
            ShieldSurface(
                image: shield.image,
                leadingEdge: laneState.visual.leading,
                trailingEdge: proxy.size.width - laneState.visual.trailing,
                imageSize: shield.size
            )
        }
        .opacity(shield.opacity)
        .allowsHitTesting(false)
    }
}

/// The shield's bitmap on bare CALayers: `contents` takes the snapshot's
/// CGImage as-is and the compositor does all the work. Drawing the same
/// bitmap through SwiftUI's `Image` rasterized the whole window-sized still
/// on the main thread at mount — one to two dropped frames exactly as a
/// slide started or reversed, felt as a stutter on every toggle.
///
/// Three segments, not one uniform stretch: the pictured page spans from
/// the moving edge to the pinned far edge, so its width changes mid-slide,
/// and a uniform stretch drifted content near the moving edge by up to nine
/// points against the sidebar riding beside it — on dark pages, where the
/// card boundary disappears, that read as the sidebar's own content coming
/// loose. Instead the 40% of the picture at each edge translates rigidly
/// with its edge, and only the middle 20% stretches to connect them: what
/// slides beside the sidebar is pixel-rigid with it, and the compression
/// lives where nothing anchors the eye.
private struct ShieldSurface: NSViewRepresentable {
    let image: NSImage
    let leadingEdge: CGFloat
    let trailingEdge: CGFloat
    let imageSize: CGSize

    func makeNSView(context: Context) -> ShieldSurfaceView {
        ShieldSurfaceView()
    }

    func updateNSView(_ view: ShieldSurfaceView, context: Context) {
        view.apply(
            image: image,
            leadingEdge: leadingEdge,
            trailingEdge: trailingEdge,
            imageSize: imageSize
        )
    }
}

final class ShieldSurfaceView: NSView {
    private let leadingSegment = CALayer()
    private let middleSegment = CALayer()
    private let trailingSegment = CALayer()
    private var appliedImage: NSImage?

    /// Bitmap share translating rigidly with each edge; the remainder in
    /// the middle absorbs the width change.
    private static let rigidShare: CGFloat = 0.4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The segments run past this view's trailing edge mid-slide; the
        // page card's own mask is the clip that matters.
        layer?.masksToBounds = false
        for (segment, rect) in [
            (leadingSegment, CGRect(x: 0, y: 0, width: Self.rigidShare, height: 1)),
            (middleSegment, CGRect(x: Self.rigidShare, y: 0, width: 1 - 2 * Self.rigidShare, height: 1)),
            (trailingSegment, CGRect(x: 1 - Self.rigidShare, y: 0, width: Self.rigidShare, height: 1))
        ] {
            segment.anchorPoint = .zero
            segment.contentsGravity = .resize
            segment.contentsRect = rect
            layer?.addSublayer(segment)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func apply(image: NSImage, leadingEdge: CGFloat, trailingEdge: CGFloat, imageSize: CGSize) {
        // Every assignment here lands exactly where the driving frame's
        // values say — CALayer's implicit .25s animations would trail the
        // spring otherwise.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if appliedImage !== image {
            appliedImage = image
            let contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            leadingSegment.contents = contents
            middleSegment.contents = contents
            trailingSegment.contents = contents
        }
        let rigidWidth = imageSize.width * Self.rigidShare
        let height = imageSize.height
        leadingSegment.frame = CGRect(x: leadingEdge, y: 0, width: rigidWidth, height: height)
        trailingSegment.frame = CGRect(x: trailingEdge - rigidWidth, y: 0, width: rigidWidth, height: height)
        middleSegment.frame = CGRect(
            x: leadingEdge + rigidWidth,
            y: 0,
            width: max(trailingEdge - rigidWidth - (leadingEdge + rigidWidth), 1),
            height: height
        )
        CATransaction.commit()
    }
}

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

/// Interpolates the visual lanes through an animated transaction and hands
/// each frame's value to the subtree (Dia's push: the page card's edge and
/// the chrome inside it follow the sidebar's edge frame by frame).
///
/// The web-layout lanes ride a separate modifier (`BrowserLayoutLaneEffect`)
/// deliberately: an `animatableData` vector snaps or animates as a whole, so
/// a toggle that snaps the layout lane (one relayout under the shield) while
/// animating the visual edge in the same update would teleport the visual
/// edge a hundred points before the spring caught it. Separate modifiers,
/// separate vectors, separate transactions.
internal struct BrowserLaneEffect: @MainActor AnimatableModifier {
    var visualLeading: CGFloat
    var visualTrailing: CGFloat
    var trailingGutter: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get {
            AnimatablePair(AnimatablePair(visualLeading, visualTrailing), trailingGutter)
        }
        set {
            visualLeading = newValue.first.first
            visualTrailing = newValue.first.second
            trailingGutter = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content.environment(
            \.browserLaneState,
            BrowserLaneState(
                visual: BrowserInterfaceInsets(
                    leading: browserLaneSnapped(visualLeading),
                    trailing: browserLaneSnapped(visualTrailing)
                ),
                layout: BrowserInterfaceInsets(),
                trailingGutter: browserLaneSnapped(trailingGutter)
            )
        )
    }
}

/// The lanes the web page is laid out against, applied inside
/// `BrowserLaneEffect` (it overwrites the placeholder layout lanes that
/// modifier put in the environment). Shielded toggles snap these once;
/// bare toggles (splits, SwiftUI pages) animate them with the visual edge.
internal struct BrowserLayoutLaneEffect: @MainActor AnimatableModifier {
    var leading: CGFloat
    var trailing: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(leading, trailing) }
        set {
            leading = newValue.first
            trailing = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content.transformEnvironment(\.browserLaneState) { state in
            state.layout = BrowserInterfaceInsets(
                leading: browserLaneSnapped(leading),
                trailing: browserLaneSnapped(trailing)
            )
        }
    }
}

// Half-point steps: the spring's settling tail would otherwise feed the
// web process a run of sub-pixel relayouts for nothing.
private func browserLaneSnapped(_ value: CGFloat) -> CGFloat {
    max(0, (value * 2).rounded() / 2)
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
