import AppKit
import SwiftUI

enum MiniPlayerLayout {
    static let margin: CGFloat = 10
    static let topMargin: CGFloat = margin
    static let resizeHitThickness: CGFloat = 10
    static let resizeCornerLength: CGFloat = 18
    static let defaultAspectRatio: CGFloat = 16.0 / 9.0
    /// Shorts and TikTok clips are 9:16, cinema trailers run past 2.4:1;
    /// past those a report is more likely garbage than a video worth a
    /// two-storey (or letterbox-slit) player.
    static let aspectRatioLimits: ClosedRange<CGFloat> = 0.4...3.0
    /// The player is sized along its long edge, so a portrait video gets a
    /// portrait player of the same stature instead of a frame the same
    /// width — 430pt wide at 9:16 would stand 764pt tall.
    static let defaultLongEdge: CGFloat = 430
    static let minimumLongEdge: CGFloat = 360
    static let maximumLongEdge: CGFloat = 760

    static func normalizedAspectRatio(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite, proposed > 0 else { return defaultAspectRatio }
        return min(max(proposed, aspectRatioLimits.lowerBound), aspectRatioLimits.upperBound)
    }

    /// A size's long edge — width for a landscape player, height for a
    /// portrait one: the one number the player's size is kept in.
    static func longEdge(of size: CGSize) -> CGFloat {
        max(size.width, size.height)
    }

    static func clampedSize(longEdge: CGFloat, aspectRatio: CGFloat, in availableSize: CGSize) -> CGSize {
        let aspect = normalizedAspectRatio(aspectRatio)
        let availableWidth = max(120, availableSize.width - margin * 2)
        let availableHeight = max(80, availableSize.height - margin * 2)
        // Both edges have to fit, so both bound the long one.
        let widthLimit = aspect >= 1 ? availableWidth : availableWidth / aspect
        let heightLimit = aspect >= 1 ? availableHeight * aspect : availableHeight
        let maximum = min(maximumLongEdge, widthLimit, heightLimit)
        let minimum = min(minimumLongEdge, maximum)
        let clamped = min(max(longEdge, minimum), maximum)

        return aspect >= 1
            ? CGSize(width: clamped, height: clamped / aspect)
            : CGSize(width: clamped * aspect, height: clamped)
    }

    static func defaultOrigin(for size: CGSize, in availableSize: CGSize) -> CGPoint {
        CGPoint(
            x: margin,
            y: max(margin, availableSize.height - size.height - margin)
        )
    }

    static func clampedOrigin(_ proposed: CGPoint, size: CGSize, in availableSize: CGSize) -> CGPoint {
        let maxX = max(margin, availableSize.width - size.width - margin)
        let maxY = max(margin, availableSize.height - size.height - margin)

        return CGPoint(
            x: min(max(proposed.x, margin), maxX),
            y: min(max(proposed.y, topMargin), maxY)
        )
    }
}

/// The floating player keeps its dragged position and resized size across
/// appearances and launches. The size is one number — the long edge — since
/// the other follows from the video's shape, and a stale off-window origin
/// self-heals through the container's clamping.
@MainActor
enum MiniPlayerPersistence {
    private static let originXKey = "miniPlayerOriginX"
    private static let originYKey = "miniPlayerOriginY"
    private static let longEdgeKey = "miniPlayerExpandedLongEdge"
    /// Pre-portrait installs stored a width, which for the 16:9 players of
    /// that era is the same measurement.
    private static let legacyWidthKey = "miniPlayerExpandedWidth"

    static func loadOrigin() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: originXKey) != nil,
            defaults.object(forKey: originYKey) != nil
        else {
            return nil
        }
        return CGPoint(x: defaults.double(forKey: originXKey), y: defaults.double(forKey: originYKey))
    }

    static func loadLongEdge() -> CGFloat {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: longEdgeKey)
        if stored > 0 { return stored }
        let legacy = defaults.double(forKey: legacyWidthKey)
        return legacy > 0 ? legacy : MiniPlayerLayout.defaultLongEdge
    }

    static func save(origin: CGPoint?, longEdge: CGFloat) {
        guard !BrowserStore.isUITesting else { return }
        let defaults = UserDefaults.standard
        if let origin {
            defaults.set(Double(origin.x), forKey: originXKey)
            defaults.set(Double(origin.y), forKey: originYKey)
        }
        defaults.set(Double(longEdge), forKey: longEdgeKey)
    }
}

struct FloatingMiniPlayerContainer: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let state: TabMediaState
    let availableSize: CGSize
    /// Where the page lane sits within `availableSize`: the summon glide's
    /// start rect comes from the page (lane-relative), while the player
    /// itself roams the whole window.
    let pageLaneFrame: CGRect
    @Binding var origin: CGPoint?
    /// The player's size, kept as its long edge: the short one follows from
    /// the video's shape, which changes under the player as the page moves
    /// from a landscape clip to a portrait short.
    @Binding var expandedLongEdge: CGFloat

    @State private var dragStartOrigin: CGPoint?
    @State private var resizeStartOrigin: CGPoint?
    @State private var resizeStartSize: CGSize?
    @State private var isProgressScrubbing = false
    // Captured into @State at mount: the store consumes the pending summon
    // right away, and the container is re-inited every second by playback
    // progress updates — reading the (now nil) prop mid-morph would yank the
    // in-flight animation to the fallback frame.
    @State private var summon: MiniPlayerSummonContext?
    @State private var isSummoning: Bool
    // True for the summon glide's whole flight (the summoning flag flips at
    // its start), so the controls stay out of a moving player.
    @State private var isGliding = false

    init(
        store: BrowserStore,
        tab: BrowserTab,
        state: TabMediaState,
        availableSize: CGSize,
        pageLaneFrame: CGRect? = nil,
        summon: MiniPlayerSummonContext?,
        origin: Binding<CGPoint?>,
        expandedLongEdge: Binding<CGFloat>
    ) {
        self.store = store
        self.tab = tab
        self.state = state
        self.availableSize = availableSize
        self.pageLaneFrame = pageLaneFrame ?? CGRect(origin: .zero, size: availableSize)
        self._origin = origin
        self._expandedLongEdge = expandedLongEdge
        // The summon morph must render its first frame at the on-page video
        // rect, so the flag has to be true before the initial body pass —
        // starting it from onAppear would commit the corner frame first.
        self._summon = State(initialValue: summon)
        self._isSummoning = State(initialValue: summon != nil)
    }

    /// The player's shape: the video's own, so a portrait short gets a
    /// portrait player rather than pillarboxed bands inside a 16:9 frame.
    private var aspectRatio: CGFloat {
        MiniPlayerLayout.normalizedAspectRatio(state.videoAspectRatio)
    }

    private var currentSize: CGSize {
        MiniPlayerLayout.clampedSize(
            longEdge: expandedLongEdge,
            aspectRatio: aspectRatio,
            in: availableSize
        )
    }

    private var currentOrigin: CGPoint {
        let size = currentSize
        let proposed = origin ?? MiniPlayerLayout.defaultOrigin(for: size, in: availableSize)
        return MiniPlayerLayout.clampedOrigin(proposed, size: size, in: availableSize)
    }

    var body: some View {
        let restingFrame = CGRect(origin: currentOrigin, size: currentSize)
        let isMorphing = isSummoning || isGliding
        let morph: MorphTarget? = isSummoning ? summonStart(restingFrame: restingFrame) : nil
        let size = restingFrame.size

        ZStack {
            FloatingMiniPlayerView(
                store: store,
                tab: tab,
                state: state,
                size: size,
                hidesControls: isMorphing,
                summonPageFrame: summonPageFrame,
                isProgressScrubbing: $isProgressScrubbing
            )

            if !isMorphing {
                ForEach(MiniPlayerResizeEdge.allCases) { edge in
                    MiniPlayerResizeHandle(edge: edge)
                        .frame(width: edge.width(in: size), height: edge.height(in: size))
                        .position(edge.position(in: size))
                        .highPriorityGesture(resizeGesture(edge, in: availableSize))
                        .zIndex(edge.isCorner ? 4 : 3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        // Hit testing and the drag gesture must attach to the sized frame;
        // .position expands to fill the whole content area, so applying them
        // after it would swallow scroll and click events over the page.
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .gesture(dragGesture(in: availableSize))
        // Both morphs are layer transforms over the resting layout, not
        // animated frames: live-resizing the hosted web view every tick
        // (while the strip-down script is restyling the page) drops frames
        // and the player visibly teleports instead of gliding.
        .scaleEffect(
            x: (morph?.frame.width ?? size.width) / max(size.width, 1),
            y: (morph?.frame.height ?? size.height) / max(size.height, 1)
        )
        .opacity(morph?.fades == true ? 0 : 1)
        .position(
            x: morph?.frame.midX ?? restingFrame.midX,
            y: morph?.frame.midY ?? restingFrame.midY
        )
        .onAppear {
            clampLayout()
            settleSummonIfNeeded()
        }
        .onChange(of: availableSize) { _, _ in
            clampLayout()
        }
        // A clip of a different shape took over (a feed swiped from a short
        // to a landscape video): the player reshapes around its own centre,
        // so it stays where the eye left it.
        .onChange(of: aspectRatio) { previousAspect, _ in
            reshape(from: previousAspect)
        }
    }

    private func dragGesture(in availableSize: CGSize) -> some Gesture {
        // Track in global space: the gesture is attached to the view being
        // moved, so local-space translations shift under the cursor each
        // frame and the player jitters.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard !isProgressScrubbing else {
                    dragStartOrigin = nil
                    return
                }

                if dragStartOrigin == nil {
                    dragStartOrigin = currentOrigin
                }

                let startOrigin = dragStartOrigin ?? currentOrigin
                let nextOrigin = CGPoint(
                    x: startOrigin.x + value.translation.width,
                    y: startOrigin.y + value.translation.height
                )

                origin = MiniPlayerLayout.clampedOrigin(nextOrigin, size: currentSize, in: availableSize)
            }
            .onEnded { _ in
                dragStartOrigin = nil
                clampLayout()
            }
    }

    private func resizeGesture(_ edge: MiniPlayerResizeEdge, in availableSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if resizeStartSize == nil {
                    resizeStartSize = currentSize
                }
                if resizeStartOrigin == nil {
                    resizeStartOrigin = currentOrigin
                }

                let startSize = resizeStartSize ?? currentSize
                let startOrigin = resizeStartOrigin ?? currentOrigin
                let aspect = aspectRatio
                let nextWidth = startSize.width + edge.widthDelta(
                    for: value.translation,
                    aspectRatio: aspect
                )
                let nextSize = MiniPlayerLayout.clampedSize(
                    longEdge: aspect >= 1 ? nextWidth : nextWidth / aspect,
                    aspectRatio: aspect,
                    in: availableSize
                )
                let rightEdge = startOrigin.x + startSize.width
                let bottomEdge = startOrigin.y + startSize.height
                let nextOrigin = CGPoint(
                    x: edge.anchorsTrailing ? rightEdge - nextSize.width : startOrigin.x,
                    y: edge.anchorsBottom ? bottomEdge - nextSize.height : startOrigin.y
                )

                expandedLongEdge = MiniPlayerLayout.longEdge(of: nextSize)
                origin = MiniPlayerLayout.clampedOrigin(
                    nextOrigin,
                    size: nextSize,
                    in: availableSize
                )
            }
            .onEnded { _ in
                resizeStartOrigin = nil
                resizeStartSize = nil
                clampLayout()
            }
    }

    private func clampLayout() {
        let size = currentSize
        expandedLongEdge = MiniPlayerLayout.longEdge(of: size)
        origin = MiniPlayerLayout.clampedOrigin(currentOrigin, size: size, in: availableSize)
        MiniPlayerPersistence.save(origin: origin, longEdge: expandedLongEdge)
    }

    /// Keeps the player's centre put across a shape change — growing it from
    /// its top-left would send a portrait player marching down the window.
    private func reshape(from previousAspect: CGFloat) {
        let previousSize = MiniPlayerLayout.clampedSize(
            longEdge: expandedLongEdge,
            aspectRatio: previousAspect,
            in: availableSize
        )
        let previousOrigin = MiniPlayerLayout.clampedOrigin(
            origin ?? MiniPlayerLayout.defaultOrigin(for: previousSize, in: availableSize),
            size: previousSize,
            in: availableSize
        )
        let center = CGPoint(
            x: previousOrigin.x + previousSize.width / 2,
            y: previousOrigin.y + previousSize.height / 2
        )
        let size = currentSize
        origin = MiniPlayerLayout.clampedOrigin(
            CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            size: size,
            in: availableSize
        )
        MiniPlayerPersistence.save(origin: origin, longEdge: expandedLongEdge)
    }

    private struct MorphTarget {
        var frame: CGRect
        var fades: Bool
    }

    /// The player hosts the same video the page was showing, so anchoring a
    /// morph at the video's on-page rect makes the handoff read as one
    /// object gliding between page and corner — the way macOS PiP lifts a
    /// video out of Safari, whatever its size. That only works when most of
    /// the rect is actually on screen — from a scrolled-away rect the player
    /// would streak offscreen, so fall back to a scale-fade at the corner.
    private func morphTarget(pageFrame: CGRect?, restingFrame: CGRect) -> MorphTarget {
        if let pageFrame {
            // Page-relative rect into the player's (window) space.
            let windowFrame = pageFrame.offsetBy(dx: pageLaneFrame.minX, dy: pageLaneFrame.minY)
            let visible = windowFrame.intersection(pageLaneFrame)
            let pageArea = pageFrame.width * pageFrame.height
            if pageArea > 0, visible.width * visible.height >= pageArea * 0.5 {
                return MorphTarget(frame: windowFrame, fades: false)
            }
        }

        return MorphTarget(
            frame: restingFrame.insetBy(
                dx: restingFrame.width * 0.08,
                dy: restingFrame.height * 0.08
            ),
            fades: true
        )
    }

    private func summonStart(restingFrame: CGRect) -> MorphTarget {
        morphTarget(pageFrame: summon?.pageVideoFrame, restingFrame: restingFrame)
    }

    /// The on-page rect the glide starts from, when it morphs from the
    /// page (nil for the corner fade): the web view host scales the page's
    /// own video into the player for the flight.
    private var summonPageFrame: CGRect? {
        guard let summon, let pageFrame = summon.pageVideoFrame else { return nil }
        return morphTarget(pageFrame: pageFrame, restingFrame: .zero).fades ? nil : pageFrame
    }

    private func settleSummonIfNeeded() {
        guard isSummoning else { return }
        store.consumeMiniPlayerSummon()
        // One runloop hop so the start frame commits before the morph;
        // flipping the flag in the same transaction collapses both frames
        // into a single keyframe and nothing animates.
        isGliding = true
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                isSummoning = false
            } completion: {
                isGliding = false
                // Landed: later (re)adoptions of the web view are plain.
                summon = nil
                store.miniPlayerSummonGlideDidEnd(tabID: tab.id)
            }
        }
    }

}

private struct FloatingMiniPlayerView: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let state: TabMediaState
    let size: CGSize
    let hidesControls: Bool
    let summonPageFrame: CGRect?
    @Binding var isProgressScrubbing: Bool

    @State private var isHovering = false

    private var showsControls: Bool {
        (isHovering || BrowserStore.uiTestingForcesMiniPlayerControls) && !hidesControls
    }

    var body: some View {
        ZStack {
            MiniPlayerWebViewHost(tabID: tab.id, summonPageFrame: summonPageFrame, store: store)
                .allowsHitTesting(false)

            // Controls stay invisible while morphing so the page-anchored
            // frame reads as the page's own video, not a floating panel.
            LinearGradient(
                colors: [
                    Color.black.opacity(showsControls ? 0.20 : 0.04),
                    Color.black.opacity(showsControls ? 0.05 : 0.02),
                    Color.black.opacity(showsControls ? 0.18 : 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(hidesControls ? 0 : 1)

            expandedControls
                .opacity(showsControls ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    Color.white.opacity(hidesControls ? 0 : (isHovering ? 0.18 : 0.12)),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(hidesControls ? 0 : 0.26), radius: 18, y: 8)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.20), value: isHovering)
    }

    /// A portrait player is barely wider than the transport row, so below
    /// this the controls lose their labels and come down a size rather than
    /// spilling over the edges.
    private var isCompact: Bool { size.width < 320 }

    private var expandedControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: isCompact ? 6 : 10) {
                MiniPlayerControlButton(
                    title: "Back to Tab",
                    systemImage: "arrow.up.left",
                    showsTitle: !isCompact
                ) {
                    store.focusMediaTab()
                }

                Spacer(minLength: 8)

                MiniPlayerControlButton(
                    title: "Minimize",
                    systemImage: "minus",
                    showsTitle: !isCompact
                ) {
                    store.minimizeMiniPlayer()
                }

                MiniPlayerControlButton(
                    title: "Close",
                    systemImage: "xmark",
                    showsTitle: !isCompact
                ) {
                    store.dismissMiniPlayer()
                }
            }
            .padding(.horizontal, isCompact ? 10 : 16)
            .padding(.top, isCompact ? 10 : 12)

            Spacer()

            HStack(spacing: isCompact ? 10 : 18) {
                MiniPlayerSeekButton(
                    systemImage: "gobackward.15",
                    help: "Back 15 Seconds",
                    isCompact: isCompact
                ) {
                    store.seekMedia(by: -15)
                }

                MiniPlayerPlayPauseButton(isPlaying: state.isPlaying, isCompact: isCompact) {
                    store.toggleMiniPlayerPlayback()
                }

                MiniPlayerSeekButton(
                    systemImage: "goforward.15",
                    help: "Forward 15 Seconds",
                    isCompact: isCompact
                ) {
                    store.seekMedia(by: 15)
                }
            }

            Spacer()

            MiniPlayerProgressBar(
                currentTime: state.currentTime,
                duration: state.duration,
                onSeek: store.seekMedia(to:),
                onScrubbingChanged: { isProgressScrubbing = $0 }
            )
                .padding(.horizontal, isCompact ? 10 : 14)
                .padding(.bottom, 10)
        }
    }

}
