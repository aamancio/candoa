import AppKit
import SwiftUI

struct SpaceSwipeSettleRequest: Equatable, Sendable {
    let id = UUID()
    let destination: Int
}

/// Where the sidebar's vertical scroll sits, for Zen's edge rules: the list
/// draws a hairline along whichever edge content has scrolled past
/// (`[overflowing]:not([scrolledtostart])::before` and its `::after` twin).
struct SpaceScrollEdges: Equatable, Sendable {
    var isOverflowing = false
    var isScrolledToStart = true
    var isScrolledToEnd = true

    var showsTopRule: Bool { isOverflowing && !isScrolledToStart }
    var showsBottomRule: Bool { isOverflowing && !isScrolledToEnd }
}

/// Lets fixed chrome outside the swipe carousel ride the same horizontal
/// translation as the pages — the Space label is pinned vertically but must
/// slide with its Space. The scroll view is the single source of the
/// translation (tracked amount, spring settle, reset), and every companion
/// layer receives exactly what the page layer does, animation included, so
/// the two can never drift.
@MainActor
final class SpaceSwipeTranslationRelay: ObservableObject {
    private struct WeakLayerBox {
        weak var layer: CALayer?
    }

    private var companions: [WeakLayerBox] = []

    func register(_ layer: CALayer) {
        companions.removeAll { $0.layer == nil || $0.layer === layer }
        companions.append(WeakLayerBox(layer: layer))
    }

    var layers: [CALayer] {
        companions.compactMap(\.layer)
    }
}

/// Hosts SwiftUI content that follows the swipe carousel's translation.
/// The content is laid out like the pages — three Space-wide slots offset by
/// one width — so it slides in lockstep with them.
struct SpaceSwipeCompanionView<Content: View>: NSViewRepresentable {
    let relay: SpaceSwipeTranslationRelay
    private let content: Content

    init(relay: SpaceSwipeTranslationRelay, @ViewBuilder content: () -> Content) {
        self.relay = relay
        self.content = content()
    }

    /// The translated hosting view inside a clipping shell: the pages are
    /// clipped by the scroll view's bounds, and the companion needs the same
    /// edge or the neighbouring Space's label shows beside the sidebar.
    final class Shell: NSView {
        let hostingView: NSHostingView<Content>

        init(rootView: Content) {
            hostingView = SidebarSwipeHostingView(rootView: rootView)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            hostingView.wantsLayer = true
            hostingView.layer?.masksToBounds = false
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = bounds
            addSubview(hostingView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
    }

    func makeNSView(context: Context) -> Shell {
        let shell = Shell(rootView: content)
        if let layer = shell.hostingView.layer {
            relay.register(layer)
        }
        return shell
    }

    func updateNSView(_ nsView: Shell, context: Context) {
        nsView.hostingView.rootView = content
        if let layer = nsView.hostingView.layer {
            relay.register(layer)
        }
    }

    /// Full proposed width, own content height: the companion is a band, not
    /// a fill, so nothing beneath it in the overlay loses hit-testing.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: Shell,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.hostingView.fittingSize.width
        nsView.hostingView.frame.size.width = width
        return CGSize(width: width, height: nsView.hostingView.fittingSize.height)
    }
}

/// The sidebar spans the title-bar strip, where AppKit turns any click whose
/// hit view permits window-moving into a window drag. The sidebar's own
/// controls live in that strip, so its hosting view must claim those clicks.
@MainActor
private final class SidebarSwipeHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct SpaceSwipeTrackingView<Content: View>: NSViewRepresentable {
    let isEnabled: Bool
    let contentID: UUID
    let settleRequest: SpaceSwipeSettleRequest?
    let reduceMotion: Bool
    let onGestureBegan: (Int) -> Void
    let onSwipeProgress: (CGFloat) -> Void
    let onSettleBegan: (Int) -> Void
    let onCompletion: (Int) -> Void
    let onScrollEdgesChanged: (SpaceScrollEdges) -> Void
    let translationRelay: SpaceSwipeTranslationRelay?
    private let content: Content

    init(
        isEnabled: Bool,
        contentID: UUID,
        settleRequest: SpaceSwipeSettleRequest?,
        reduceMotion: Bool,
        onGestureBegan: @escaping (Int) -> Void,
        onSwipeProgress: @escaping (CGFloat) -> Void = { _ in },
        onSettleBegan: @escaping (Int) -> Void = { _ in },
        onCompletion: @escaping (Int) -> Void,
        onScrollEdgesChanged: @escaping (SpaceScrollEdges) -> Void = { _ in },
        translationRelay: SpaceSwipeTranslationRelay? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.contentID = contentID
        self.settleRequest = settleRequest
        self.reduceMotion = reduceMotion
        self.onGestureBegan = onGestureBegan
        self.onSwipeProgress = onSwipeProgress
        self.onSettleBegan = onSettleBegan
        self.onCompletion = onCompletion
        self.onScrollEdgesChanged = onScrollEdgesChanged
        self.translationRelay = translationRelay
        self.content = content()
    }

    func makeNSView(context: Context) -> SpaceSwipeScrollView<Content> {
        let view = SpaceSwipeScrollView(rootView: content)
        view.isSwipeEnabled = isEnabled
        view.reduceMotion = reduceMotion
        view.onGestureBegan = onGestureBegan
        view.onSwipeProgress = onSwipeProgress
        view.onSettleBegan = onSettleBegan
        view.onCompletion = onCompletion
        view.onScrollEdgesChanged = onScrollEdgesChanged
        view.translationRelay = translationRelay
        view.updateContentID(contentID)
        view.updateSettleRequest(settleRequest)
        return view
    }

    func updateNSView(_ nsView: SpaceSwipeScrollView<Content>, context: Context) {
        nsView.updateRootView(content)
        nsView.isSwipeEnabled = isEnabled
        nsView.reduceMotion = reduceMotion
        nsView.onGestureBegan = onGestureBegan
        nsView.onSwipeProgress = onSwipeProgress
        nsView.onSettleBegan = onSettleBegan
        nsView.onCompletion = onCompletion
        nsView.onScrollEdgesChanged = onScrollEdgesChanged
        nsView.translationRelay = translationRelay
        nsView.updateContentID(contentID)
        nsView.updateSettleRequest(settleRequest)
    }
}

@MainActor
final class SpaceSwipeScrollView<Content: View>: NSScrollView {
    var isSwipeEnabled = false
    var reduceMotion = false
    var onGestureBegan: (Int) -> Void = { _ in }
    var onSwipeProgress: (CGFloat) -> Void = { _ in }
    var onSettleBegan: (Int) -> Void = { _ in }
    var onCompletion: (Int) -> Void = { _ in }
    var onScrollEdgesChanged: (SpaceScrollEdges) -> Void = { _ in }
    var translationRelay: SpaceSwipeTranslationRelay?

    private var reportedScrollEdges = SpaceScrollEdges()
    private nonisolated(unsafe) var scrollEdgesObserver: NSObjectProtocol?
    private let hostingView: NSHostingView<Content>
    private var contentID: UUID?
    private var settleRequestID: UUID?
    private var isTrackingSwipe = false
    private var isSettlingSwipe = false
    private var trackedSwipeAmount: CGFloat = 0
    private var discreteScrollAmount: CGFloat = 0
    private var isDiscreteScrollGestureConsumed = false
    private var lastDiscreteScrollTimestamp: TimeInterval = -.infinity
    private var animationToken = UUID()
    private let translationAnimationKey = "candoa.space-swipe.translation"
    private let discreteScrollThreshold: CGFloat = 1
    private let discreteScrollCooldown: TimeInterval = 0.2

    init(rootView: Content) {
        hostingView = SidebarSwipeHostingView(rootView: rootView)
        super.init(frame: .zero)

        drawsBackground = false
        backgroundColor = .clear
        contentView.drawsBackground = false
        contentView.backgroundColor = .clear
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        documentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false

        // The clip view's bounds move on every scroll; the edge rules follow.
        contentView.postsBoundsChangedNotifications = true
        let clipView = contentView
        scrollEdgesObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reportScrollEdgesIfChanged()
            }
        }
    }

    deinit {
        if let scrollEdgesObserver {
            NotificationCenter.default.removeObserver(scrollEdgesObserver)
        }
    }

    private func reportScrollEdgesIfChanged() {
        let visible = contentView.bounds
        let documentHeight = hostingView.frame.height
        let tolerance: CGFloat = 0.5
        let edges = SpaceScrollEdges(
            isOverflowing: documentHeight > visible.height + tolerance,
            isScrolledToStart: visible.minY <= tolerance,
            isScrolledToEnd: visible.maxY >= documentHeight - tolerance
        )
        guard edges != reportedScrollEdges else { return }
        reportedScrollEdges = edges
        onScrollEdgesChanged(edges)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        layoutHostingView()
        reportScrollEdgesIfChanged()
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }

    func updateRootView(_ rootView: Content) {
        hostingView.rootView = rootView
        hostingView.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func updateContentID(_ newContentID: UUID) {
        guard contentID != newContentID else { return }
        contentID = newContentID
        animationToken = UUID()
        for layer in translatedLayers {
            layer.removeAnimation(forKey: translationAnimationKey)
        }
        applySwipeAmount(0)
        isTrackingSwipe = false
        isSettlingSwipe = false
        trackedSwipeAmount = 0
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    func updateSettleRequest(_ request: SpaceSwipeSettleRequest?) {
        guard let request, settleRequestID != request.id else { return }
        settleRequestID = request.id

        DispatchQueue.main.async { [weak self] in
            guard let self, self.contentID != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.resetVerticalScrollPosition()
            self.settleSwipe(to: request.destination)
        }
    }

    private func layoutHostingView() {
        let viewportWidth = max(contentSize.width, 1)
        hostingView.frame.size.width = viewportWidth
        hostingView.invalidateIntrinsicContentSize()
        let contentHeight = max(hostingView.fittingSize.height, contentSize.height)
        hostingView.frame = NSRect(x: 0, y: 0, width: viewportWidth, height: contentHeight)

        if isTrackingSwipe {
            applySwipeAmount(trackedSwipeAmount)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if isSettlingSwipe {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                return
            }
            super.scrollWheel(with: event)
            return
        }

        if isTrackingSwipe {
            return
        }

        let isHorizontalScroll =
            !event.modifierFlags.contains(.shift) &&
            event.scrollingDeltaX != 0 &&
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        // trackSwipeEvent's handler never runs when the person has disabled
        // system swipe tracking ("Swipe between pages"), which would leave
        // the swipe begun but permanently unfinished. Route those scrolls
        // through the discrete handler instead.
        let canTrackNativeSwipe =
            NSEvent.isSwipeTrackingFromScrollEventsEnabled &&
            event.hasPreciseScrollingDeltas &&
            (event.phase.contains(.began) || event.phase.contains(.changed))
        if isSwipeEnabled,
           isHorizontalScroll,
           !canTrackNativeSwipe,
           event.momentumPhase.isEmpty {
            handleDiscreteHorizontalScroll(event)
            return
        }

        guard
            isSwipeEnabled,
            isHorizontalScroll,
            canTrackNativeSwipe
        else {
            super.scrollWheel(with: event)
            return
        }

        isTrackingSwipe = true
        trackedSwipeAmount = 0
        resetVerticalScrollPosition()
        onGestureBegan(event.scrollingDeltaX > 0 ? -1 : 1)

        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: -1,
            max: 1
        ) { [weak self] gestureAmount, _, isComplete, stop in
            guard let self else {
                stop.pointee = true
                return
            }

            guard self.isSwipeEnabled else {
                stop.pointee = true
                self.finishNativeSwipe(at: 0)
                return
            }

            self.trackedSwipeAmount = gestureAmount
            self.applySwipeAmount(gestureAmount)
            self.onSwipeProgress(gestureAmount)

            if isComplete {
                self.finishNativeSwipe(at: gestureAmount)
            }
        }
    }

    private func handleDiscreteHorizontalScroll(_ event: NSEvent) {
        if event.phase.contains(.began) {
            discreteScrollAmount = 0
            isDiscreteScrollGestureConsumed = false
        }

        defer {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                discreteScrollAmount = 0
                isDiscreteScrollGestureConsumed = false
            }
        }

        guard !isDiscreteScrollGestureConsumed else { return }

        let lineDistance = event.hasPreciseScrollingDeltas
            ? max(horizontalLineScroll, 1)
            : 1
        discreteScrollAmount += event.scrollingDeltaX / lineDistance

        guard abs(discreteScrollAmount) >= discreteScrollThreshold else { return }
        guard event.timestamp - lastDiscreteScrollTimestamp >= discreteScrollCooldown else {
            if !event.phase.isEmpty {
                isDiscreteScrollGestureConsumed = true
            }
            return
        }

        let destination = discreteScrollAmount > 0 ? -1 : 1
        discreteScrollAmount = 0
        isDiscreteScrollGestureConsumed = !event.phase.isEmpty
        lastDiscreteScrollTimestamp = event.timestamp
        resetVerticalScrollPosition()
        onGestureBegan(destination)
        settleSwipe(to: destination)
    }

    private func finishNativeSwipe(at gestureAmount: CGFloat) {
        guard isTrackingSwipe else { return }
        isTrackingSwipe = false
        trackedSwipeAmount = 0
        let destination = -Int(gestureAmount.rounded())
        onCompletion(destination)
    }

    /// The page layer plus every companion the relay knows about.
    private var translatedLayers: [CALayer] {
        [hostingView.layer].compactMap { $0 } + (translationRelay?.layers ?? [])
    }

    private func applySwipeAmount(_ amount: CGFloat) {
        let translationX = amount * max(contentSize.width, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in translatedLayers {
            layer.setAffineTransform(CGAffineTransform(translationX: translationX, y: 0))
        }
        CATransaction.commit()
    }

    private func resetVerticalScrollPosition() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    private func settleSwipe(to destination: Int) {
        guard !isSettlingSwipe else { return }
        isSettlingSwipe = true
        isTrackingSwipe = false
        onSettleBegan(destination)

        let token = UUID()
        animationToken = token

        guard !reduceMotion, let layer = hostingView.layer else {
            applySwipeAmount(-CGFloat(destination))
            finishSettlement(to: destination, token: token)
            return
        }

        let targetX = -CGFloat(destination) * max(contentSize.width, 1)
        let currentX = (
            layer.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber
        )?.doubleValue ?? (
            layer.value(forKeyPath: "transform.translation.x") as? NSNumber
        )?.doubleValue ?? 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for translated in translatedLayers {
            translated.setAffineTransform(CGAffineTransform(translationX: targetX, y: 0))
        }
        CATransaction.commit()

        let animation = CASpringAnimation(keyPath: "transform.translation.x")
        animation.fromValue = currentX
        animation.toValue = targetX
        animation.mass = 1
        animation.stiffness = 500
        animation.damping = 45
        animation.initialVelocity = 0
        animation.duration = 0.20

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                self?.finishSettlement(to: destination, token: token)
            }
        }
        for translated in translatedLayers {
            translated.add(animation, forKey: translationAnimationKey)
        }
        CATransaction.commit()
    }

    private func finishSettlement(to destination: Int, token: UUID) {
        guard animationToken == token else { return }
        isSettlingSwipe = false
        trackedSwipeAmount = 0
        onCompletion(destination)
    }
}
