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
    let onCompletion: (Int) -> Void
    private let content: Content

    init(
        isEnabled: Bool,
        contentID: UUID,
        settleRequest: SpaceSwipeSettleRequest?,
        reduceMotion: Bool,
        onGestureBegan: @escaping (Int) -> Void,
        onCompletion: @escaping (Int) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.contentID = contentID
        self.settleRequest = settleRequest
        self.reduceMotion = reduceMotion
        self.onGestureBegan = onGestureBegan
        self.onCompletion = onCompletion
        self.content = content()
    }

    func makeNSView(context: Context) -> SpaceSwipeScrollView<Content> {
        let view = SpaceSwipeScrollView(rootView: content)
        view.isSwipeEnabled = isEnabled
        view.reduceMotion = reduceMotion
        view.onGestureBegan = onGestureBegan
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
    var onCompletion: (Int) -> Void = { _ in }

    private let hostingView: NSHostingView<Content>
    private var contentID: UUID?
    private var settleRequestID: UUID?
    private var isTrackingSwipe = false
    private var isSettlingSwipe = false
    private var trackedSwipeAmount: CGFloat = 0
    private var animationToken = UUID()
    private let translationAnimationKey = "candoa.space-swipe.translation"

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
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutHostingView()
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
            event.scrollingDeltaX != 0 &&
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)

        if isSwipeEnabled,
           isHorizontalScroll,
           event.phase.isEmpty,
           event.momentumPhase.isEmpty {
            let destination = event.scrollingDeltaX > 0 ? -1 : 1
            resetVerticalScrollPosition()
            onGestureBegan(destination)
            settleSwipe(to: destination)
            return
        }

        guard
            isSwipeEnabled,
            NSEvent.isSwipeTrackingFromScrollEventsEnabled,
            event.hasPreciseScrollingDeltas,
            isHorizontalScroll,
            event.phase.contains(.began) || event.phase.contains(.changed)
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

            if isComplete {
                self.finishNativeSwipe(at: gestureAmount)
            }
        }
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

struct SpaceSwipeSidebarBackdrop: View {
    let space: BrowserSpace

    private var intensityMultiplier: Double {
        let normalizedOpacity = (space.themeOpacity - 0.3) / 0.6
        return min(1.45, max(0.25, 0.25 + normalizedOpacity * 1.2))
    }

    var body: some View {
        if let themeHex = space.themeColorHex {
            ZStack {
                CandoaInterfaceStyle.neutralWindowBackdrop
                Color(spaceHex: themeHex)
                    .opacity(0.050)
                SpaceThemeBackdrop(
                    hexes: [themeHex],
                    intensity: 0.16 * intensityMultiplier,
                    texture: space.themeTexture
                )
                CandoaInterfaceStyle.sidebarSurfaceOverlay
            }
        } else {
            CandoaInterfaceStyle.sidebarBackground
                .overlay(CandoaInterfaceStyle.sidebarSurfaceOverlay)
        }
    }
}
