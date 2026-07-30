import AppKit
import SwiftUI

struct SpaceSwipeSettleRequest: Equatable, Sendable {
    let id = UUID()
    let destination: Int
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
        hostingView = NSHostingView(rootView: rootView)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        layoutHostingView()
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
        hostingView.layer?.removeAnimation(forKey: translationAnimationKey)
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
        let canTrackNativeSwipe =
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

    private func applySwipeAmount(_ amount: CGFloat) {
        guard let layer = hostingView.layer else { return }
        let translationX = amount * max(contentSize.width, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(translationX: translationX, y: 0))
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
        layer.setAffineTransform(CGAffineTransform(translationX: targetX, y: 0))
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
        layer.add(animation, forKey: translationAnimationKey)
        CATransaction.commit()
    }

    private func finishSettlement(to destination: Int, token: UUID) {
        guard animationToken == token else { return }
        isSettlingSwipe = false
        trackedSwipeAmount = 0
        onCompletion(destination)
    }
}
