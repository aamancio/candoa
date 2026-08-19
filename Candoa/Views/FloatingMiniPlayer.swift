import AppKit
import SwiftUI

enum MiniPlayerLayout {
    static let margin: CGFloat = 10
    static let topMargin: CGFloat = margin
    static let resizeHitThickness: CGFloat = 10
    static let resizeCornerLength: CGFloat = 18
    static let aspectRatio: CGFloat = 16.0 / 9.0
    static let defaultExpandedSize = CGSize(width: 430, height: 242)
    static let minimumExpandedWidth: CGFloat = 360
    static let maximumExpandedWidth: CGFloat = 760

    static func clampedExpandedSize(_ proposed: CGSize, in availableSize: CGSize) -> CGSize {
        let availableWidth = max(120, availableSize.width - margin * 2)
        let availableHeight = max(80, availableSize.height - margin * 2)
        let maximumWidth = min(maximumExpandedWidth, availableWidth, availableHeight * aspectRatio)
        let minimumWidth = min(minimumExpandedWidth, maximumWidth)
        let width = min(max(proposed.width, minimumWidth), maximumWidth)

        return CGSize(width: width, height: width / aspectRatio)
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

/// The floating player keeps its dragged position and resized width across
/// appearances and launches. Height is derived from width (fixed aspect), and
/// a stale off-window origin self-heals through the container's clamping.
@MainActor
enum MiniPlayerPersistence {
    private static let originXKey = "miniPlayerOriginX"
    private static let originYKey = "miniPlayerOriginY"
    private static let widthKey = "miniPlayerExpandedWidth"

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

    static func loadExpandedSize() -> CGSize {
        let width = UserDefaults.standard.double(forKey: widthKey)
        guard width > 0 else { return MiniPlayerLayout.defaultExpandedSize }
        return CGSize(width: width, height: width / MiniPlayerLayout.aspectRatio)
    }

    static func save(origin: CGPoint?, expandedSize: CGSize) {
        guard !BrowserStore.isUITesting else { return }
        let defaults = UserDefaults.standard
        if let origin {
            defaults.set(Double(origin.x), forKey: originXKey)
            defaults.set(Double(origin.y), forKey: originYKey)
        }
        defaults.set(Double(expandedSize.width), forKey: widthKey)
    }
}

struct FloatingMiniPlayerContainer: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let state: TabMediaState
    let availableSize: CGSize
    @Binding var origin: CGPoint?
    @Binding var expandedSize: CGSize

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
        summon: MiniPlayerSummonContext?,
        origin: Binding<CGPoint?>,
        expandedSize: Binding<CGSize>
    ) {
        self.store = store
        self.tab = tab
        self.state = state
        self.availableSize = availableSize
        self._origin = origin
        self._expandedSize = expandedSize
        // The summon morph must render its first frame at the on-page video
        // rect, so the flag has to be true before the initial body pass —
        // starting it from onAppear would commit the corner frame first.
        self._summon = State(initialValue: summon)
        self._isSummoning = State(initialValue: summon != nil)
    }

    private var currentSize: CGSize {
        MiniPlayerLayout.clampedExpandedSize(expandedSize, in: availableSize)
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
                let nextSize = MiniPlayerLayout.clampedExpandedSize(
                    CGSize(width: startSize.width + edge.widthDelta(for: value.translation), height: 0),
                    in: availableSize
                )
                let rightEdge = startOrigin.x + startSize.width
                let bottomEdge = startOrigin.y + startSize.height
                let nextOrigin = CGPoint(
                    x: edge.anchorsTrailing ? rightEdge - nextSize.width : startOrigin.x,
                    y: edge.anchorsBottom ? bottomEdge - nextSize.height : startOrigin.y
                )

                expandedSize = nextSize
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
        expandedSize = MiniPlayerLayout.clampedExpandedSize(expandedSize, in: availableSize)
        origin = MiniPlayerLayout.clampedOrigin(currentOrigin, size: size, in: availableSize)
        MiniPlayerPersistence.save(origin: origin, expandedSize: expandedSize)
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
            let bounds = CGRect(origin: .zero, size: availableSize)
            let visible = pageFrame.intersection(bounds)
            let pageArea = pageFrame.width * pageFrame.height
            if pageArea > 0, visible.width * visible.height >= pageArea * 0.5 {
                return MorphTarget(frame: pageFrame, fades: false)
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

    var body: some View {
        ZStack {
            MiniPlayerWebViewHost(tabID: tab.id, summonPageFrame: summonPageFrame, store: store)
                .allowsHitTesting(false)

            // Controls stay invisible while morphing so the page-anchored
            // frame reads as the page's own video, not a floating panel.
            LinearGradient(
                colors: [
                    Color.black.opacity(isHovering ? 0.20 : 0.04),
                    Color.black.opacity(isHovering ? 0.05 : 0.02),
                    Color.black.opacity(isHovering ? 0.18 : 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(hidesControls ? 0 : 1)

            expandedControls
                .opacity(isHovering && !hidesControls ? 1 : 0)
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

    private var expandedControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MiniPlayerControlButton(title: "Back to Tab", systemImage: "arrow.up.left") {
                    store.focusMediaTab()
                }

                Spacer(minLength: 8)

                MiniPlayerControlButton(title: "Minimize", systemImage: "minus") {
                    store.minimizeMiniPlayer()
                }

                MiniPlayerControlButton(title: "Close", systemImage: "xmark") {
                    store.dismissMiniPlayer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            HStack(spacing: 18) {
                MiniPlayerSeekButton(systemImage: "gobackward.15", help: "Back 15 Seconds") {
                    store.seekMedia(by: -15)
                }

                MiniPlayerPlayPauseButton(isPlaying: state.isPlaying) {
                    store.toggleMiniPlayerPlayback()
                }

                MiniPlayerSeekButton(systemImage: "goforward.15", help: "Forward 15 Seconds") {
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
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

}
