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
    @State private var isReturning = false

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
        let isMorphing = isSummoning || isReturning
        let morph: MorphTarget? = {
            if isReturning { return returnTarget(restingFrame: restingFrame) }
            if isSummoning { return summonStart(restingFrame: restingFrame) }
            return nil
        }()
        let size = restingFrame.size

        ZStack {
            FloatingMiniPlayerView(
                store: store,
                tab: tab,
                state: state,
                size: size,
                hidesControls: isMorphing,
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
        .onChange(of: store.miniPlayerReturn != nil) { _, hasReturn in
            if hasReturn {
                startReturn()
            } else if isReturning {
                // Interrupted by another switch: the player floats on, so it
                // snaps back to its corner without replaying any animation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isReturning = false
                }
            }
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
    /// object gliding between page and corner. That only works when most of
    /// the rect is actually on screen — from a scrolled-away rect the player
    /// would streak offscreen, so fall back to a scale-fade at the corner.
    private func morphTarget(pageFrame: CGRect?, restingFrame: CGRect) -> MorphTarget {
        if let pageFrame {
            let bounds = CGRect(origin: .zero, size: availableSize)
            let visible = pageFrame.intersection(bounds)
            let pageArea = pageFrame.width * pageFrame.height
            let contentArea = max(availableSize.width * availableSize.height, 1)
            // A rect that dominates the content area (YouTube's player on a
            // big window) would make the morph read as a fullscreen
            // transition, not a PiP handoff — those take the quiet corner
            // fade instead.
            if pageArea > 0,
               visible.width * visible.height >= pageArea * 0.5,
               pageArea / contentArea <= 0.5 {
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

    private func returnTarget(restingFrame: CGRect) -> MorphTarget {
        morphTarget(pageFrame: store.miniPlayerReturn?.targetFrame, restingFrame: restingFrame)
    }

    private func settleSummonIfNeeded() {
        guard isSummoning else { return }
        store.consumeMiniPlayerSummon()
        // One runloop hop so the start frame commits before the morph;
        // flipping the flag in the same transaction collapses both frames
        // into a single keyframe and nothing animates.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                isSummoning = false
            }
        }
    }

    private func startReturn() {
        guard !isReturning else { return }
        // A return can land while the summon morph is still in flight; the
        // return owns the transform from here on.
        isSummoning = false
        withAnimation(.spring(response: 0.40, dampingFraction: 0.86)) {
            isReturning = true
        } completion: {
            store.finishMiniPlayerReturn()
        }
    }
}

private struct FloatingMiniPlayerView: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let state: TabMediaState
    let size: CGSize
    let hidesControls: Bool
    @Binding var isProgressScrubbing: Bool

    @State private var isHovering = false

    var body: some View {
        ZStack {
            MiniPlayerWebViewHost(tabID: tab.id, store: store)
                .allowsHitTesting(false)

            // During the return morph the live web view has been handed back
            // to the page (relayouting hidden underneath), so the player
            // shows the freeze frame captured at hand-back instead.
            if let freezeFrame = store.miniPlayerReturn?.snapshot {
                Image(nsImage: freezeFrame)
                    .resizable()
                    .scaledToFill()
            }

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

private struct MiniPlayerControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .bold))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.92))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(isHovering ? 0.06 : 0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

private struct MiniPlayerSeekButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.92))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .frame(width: 52, height: 64)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct MiniPlayerPlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 13) {
                    Capsule(style: .continuous)
                        .frame(width: 10, height: 58)
                    Capsule(style: .continuous)
                        .frame(width: 10, height: 58)
                }
                .opacity(isPlaying ? 1 : 0)
                .scaleEffect(isPlaying ? 1 : 0.72)

                Image(systemName: "play.fill")
                    .font(.system(size: 48, weight: .regular))
                    .opacity(isPlaying ? 0 : 1)
                    .scaleEffect(isPlaying ? 0.72 : 1)
            }
            .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.94))
            .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.30, dampingFraction: 0.78), value: isPlaying)
        }
        .buttonTreatment(.content)
        .onHover { isHovering = $0 }
        .help(isPlaying ? "Pause" : "Play")
    }
}

private enum MiniPlayerResizeEdge: String, CaseIterable, Identifiable {
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var isCorner: Bool {
        switch self {
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return true
        case .top, .bottom, .leading, .trailing:
            return false
        }
    }

    var anchorsTrailing: Bool {
        switch self {
        case .leading, .topLeading, .bottomLeading:
            return true
        case .top, .bottom, .trailing, .topTrailing, .bottomTrailing:
            return false
        }
    }

    var anchorsBottom: Bool {
        switch self {
        case .top, .topLeading, .topTrailing:
            return true
        case .bottom, .leading, .trailing, .bottomLeading, .bottomTrailing:
            return false
        }
    }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom:
            return .resizeUpDown
        case .leading, .trailing:
            return MiniPlayerResizeCursor.horizontal
        case .topLeading:
            return MiniPlayerResizeCursor.topLeft
        case .topTrailing:
            return MiniPlayerResizeCursor.topRight
        case .bottomLeading:
            return MiniPlayerResizeCursor.bottomLeft
        case .bottomTrailing:
            return MiniPlayerResizeCursor.bottomRight
        }
    }

    func width(in size: CGSize) -> CGFloat {
        switch self {
        case .top, .bottom:
            return size.width
        case .leading, .trailing:
            return MiniPlayerLayout.resizeHitThickness
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return MiniPlayerLayout.resizeCornerLength
        }
    }

    func height(in size: CGSize) -> CGFloat {
        switch self {
        case .top, .bottom:
            return MiniPlayerLayout.resizeHitThickness
        case .leading, .trailing:
            return size.height
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return MiniPlayerLayout.resizeCornerLength
        }
    }

    func position(in size: CGSize) -> CGPoint {
        let edgeInset = MiniPlayerLayout.resizeHitThickness / 2
        let cornerInset = MiniPlayerLayout.resizeCornerLength / 2

        switch self {
        case .top:
            return CGPoint(x: size.width / 2, y: edgeInset)
        case .bottom:
            return CGPoint(x: size.width / 2, y: size.height - edgeInset)
        case .leading:
            return CGPoint(x: edgeInset, y: size.height / 2)
        case .trailing:
            return CGPoint(x: size.width - edgeInset, y: size.height / 2)
        case .topLeading:
            return CGPoint(x: cornerInset, y: cornerInset)
        case .topTrailing:
            return CGPoint(x: size.width - cornerInset, y: cornerInset)
        case .bottomLeading:
            return CGPoint(x: cornerInset, y: size.height - cornerInset)
        case .bottomTrailing:
            return CGPoint(x: size.width - cornerInset, y: size.height - cornerInset)
        }
    }

    func widthDelta(for translation: CGSize) -> CGFloat {
        let candidates: [CGFloat]

        switch self {
        case .top:
            candidates = [-translation.height * MiniPlayerLayout.aspectRatio]
        case .bottom:
            candidates = [translation.height * MiniPlayerLayout.aspectRatio]
        case .leading:
            candidates = [-translation.width]
        case .trailing:
            candidates = [translation.width]
        case .topLeading:
            candidates = [
                -translation.width,
                -translation.height * MiniPlayerLayout.aspectRatio
            ]
        case .topTrailing:
            candidates = [
                translation.width,
                -translation.height * MiniPlayerLayout.aspectRatio
            ]
        case .bottomLeading:
            candidates = [
                -translation.width,
                translation.height * MiniPlayerLayout.aspectRatio
            ]
        case .bottomTrailing:
            candidates = [
                translation.width,
                translation.height * MiniPlayerLayout.aspectRatio
            ]
        }

        return candidates.max { abs($0) < abs($1) } ?? 0
    }
}

private enum MiniPlayerResizeCursor {
    static var horizontal: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.columnResize(directions: .all)
        }
        return .resizeLeftRight
    }

    static var topLeft: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topLeft, directions: .all)
        }
        return northwestSoutheastFallback
    }

    static var topRight: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topRight, directions: .all)
        }
        return northeastSouthwestFallback
    }

    static var bottomLeft: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomLeft, directions: .all)
        }
        return northeastSouthwestFallback
    }

    static var bottomRight: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return northwestSoutheastFallback
    }

    nonisolated(unsafe) private static let northwestSoutheastFallback = fallbackResizeCursor(
        from: CGPoint(x: 4, y: 14),
        to: CGPoint(x: 14, y: 4)
    )

    nonisolated(unsafe) private static let northeastSouthwestFallback = fallbackResizeCursor(
        from: CGPoint(x: 14, y: 14),
        to: CGPoint(x: 4, y: 4)
    )

    private static func fallbackResizeCursor(from start: CGPoint, to end: CGPoint) -> NSCursor {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            appendLine(to: path, from: start, to: end)
            appendArrowHead(to: path, tip: start, tail: end)
            appendArrowHead(to: path, tip: end, tail: start)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 4
            path.stroke()

            NSColor.black.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 2
            path.stroke()

            return true
        }

        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private static func appendLine(to path: NSBezierPath, from start: CGPoint, to end: CGPoint) {
        path.move(to: start)
        path.line(to: end)
    }

    private static func appendArrowHead(to path: NSBezierPath, tip: CGPoint, tail: CGPoint) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let headLength: CGFloat = 5
        let spread: CGFloat = 0.72

        for offset in [-spread, spread] {
            let backAngle = angle + .pi + offset
            let point = CGPoint(
                x: tip.x + CGFloat(cos(Double(backAngle))) * headLength,
                y: tip.y + CGFloat(sin(Double(backAngle))) * headLength
            )
            appendLine(to: path, from: tip, to: point)
        }
    }
}

private struct MiniPlayerResizeHandle: View {
    let edge: MiniPlayerResizeEdge

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .candoaCursor(edge.cursor)
            .help("Resize")
    }
}

internal struct CursorHoverModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content
            .background(CursorRectView(cursor: cursor))
            .onContinuousHover { phase in
                if case .active = phase {
                    cursor.set()
                }
            }
            .onHover { isHovering in
                if isHovering {
                    cursor.set()
                }
            }
    }
}

internal struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        let view = CursorRectNSView(frame: .zero)
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
    }
}

internal final class CursorRectNSView: NSView {
    var cursor: NSCursor = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}

extension View {
    // Cursor for chrome floating over web content: WebKit re-asserts its
    // own cursor on every mouse move, so a one-shot push is not enough —
    // this pairs an AppKit cursor rect with continuous re-assertion.
    func candoaCursor(_ cursor: NSCursor) -> some View {
        modifier(CursorHoverModifier(cursor: cursor))
    }
}

private struct MiniPlayerProgressBar: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onScrubbingChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isScrubbing = false
    @State private var scrubbedTime: Double?

    private var progress: CGFloat {
        guard duration > 0, displayedTime.isFinite, duration.isFinite else { return 0 }
        return CGFloat(min(max(displayedTime / duration, 0), 1))
    }

    private var displayedTime: Double {
        scrubbedTime ?? currentTime
    }

    private var isSeekable: Bool {
        duration > 0 && duration.isFinite
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))

                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(5, proxy.size.width * progress))
            }
            .frame(height: isHovering ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: proxy.size.width))
        }
        .frame(height: 16)
        .disabled(!isSeekable)
        .candoaCursor(isSeekable ? .pointingHand : .arrow)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .onChange(of: currentTime) { _, _ in
            if !isScrubbing, scrubbedTime != nil {
                scrubbedTime = nil
            }
        }
        .onDisappear {
            onScrubbingChanged(false)
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isScrubbing = true
                onScrubbingChanged(true)
                seek(toXPosition: value.location.x, width: width)
            }
            .onEnded { value in
                seek(toXPosition: value.location.x, width: width)
                isScrubbing = false
                onScrubbingChanged(false)
            }
    }

    private func seek(toXPosition xPosition: CGFloat, width: CGFloat) {
        guard isSeekable, width > 0 else { return }

        let ratio = min(max(xPosition / width, 0), 1)
        let targetTime = Double(ratio) * duration
        scrubbedTime = targetTime
        onSeek(targetTime)
    }
}
