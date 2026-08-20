import AppKit
@preconcurrency import AVFoundation
import os
@preconcurrency import Speech
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let isPrivate: Bool
    @StateObject private var store: BrowserStore
    @StateObject private var updateService = AppUpdateService.shared
    @StateObject private var whatsNewService = WhatsNewService.shared

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        _store = StateObject(wrappedValue: BrowserStore(isPrivate: isPrivate))
    }
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(SettingsOption.websiteAppearance) private var websiteAppearanceValue =
        WebsiteAppearance.automatic.rawValue
    @SceneStorage("candoa.windowAutosaveID") private var windowAutosaveID = UUID().uuidString
    @State private var isSidebarVisible = true
    /// The sidebar lane: where the page card's leading edge is (`sidebarLane`,
    /// animated through `BrowserLaneEffect` so the card follows the sidebar's
    /// edge frame by frame) and the lane the page is laid out against
    /// (`sidebarLayoutLane`): the same while opening, but a close lays the
    /// page out at full width first, under the still-pinned edge, and the
    /// page then rides the edge out as a translation.
    @State private var sidebarLane: CGFloat = InterfaceStyle.sidebarWidth
    @State private var sidebarLayoutLane: CGFloat = InterfaceStyle.sidebarWidth
    @State private var sidebarToggleGeneration = 0
    /// A still of the page shown over the live web view for the length of a
    /// sidebar toggle (see `PageToggleShield`): the live page relayouts to
    /// its final lanes once, invisibly, underneath, and the still rides the
    /// moving edge at the compositor's frame rate — WebKit cannot reflow at
    /// the edge's pace, and every scheme that let the mid-reflow layout show
    /// put a strip of bare page background beside a sidebar and a jump after
    /// it.
    @State private var toggleShield: PageToggleShield?
    @State private var isSidebarHoverRevealed = false
    @State private var isSidebarRevealSuppressed = false
    @State private var isAISidebarVisible = false
    @State private var isAISidebarMounted = false
    @State private var isHistoryPresented = false
    /// Eli's lane: the panel's width once open and at rest, animated by the
    /// toggle (the page card's edge slides across the docked panel and the
    /// page lays out against the moving edge), 0 when closed. A close lays
    /// the page out at full width first, under the still-docked panel
    /// (`aiSidebarLayoutLane`), then slides the edge back across it.
    @State private var aiSidebarLane: CGFloat = 0
    @State private var aiSidebarLayoutLane: CGFloat = 0
    /// The committed panel width the lane is laid out against between resize
    /// drags; the lane follows the pointer only through the slide mask.
    @State private var reservedAISidebarInset: CGFloat = 0
    // Compositor-only trailing clip applied to the web surface while Eli
    // covers it beyond the reserved web layout during a widening resize
    // drag. It keeps the card's rounded trailing corner pinned to Eli's edge
    // without ever touching the live web layout; it must be exactly 0
    // whenever the reserved layout owns the trailing edge.
    @State private var aiSidebarSlideMaskInset: CGFloat = 0
    @State private var aiSidebarTransitionGeneration = 0
    @State private var aiSidebarUITestingState = ""
    @State private var aiSidebarMessages: [AISidebarMessage] = []
    @State private var aiSidebarMemoryWindow = EliMemoryWindow()
    @State private var pendingEliSubscriptionSubmission: EliSubmission?
    @State private var isSignOutConfirmationPresented = false
    @State private var aiSidebarResizeStartWidth: CGFloat?
    @State private var miniPlayerOrigin: CGPoint? = MiniPlayerPersistence.loadOrigin()
    @State private var miniPlayerExpandedSize = MiniPlayerPersistence.loadExpandedSize()
    @SceneStorage("candoa.aiSidebarWidth.diaLayout") private var aiSidebarWidth = 540.0
    private let sidebarWidth = InterfaceStyle.sidebarWidth
    private let sidebarDividerWidth: CGFloat = 0

    private var activeThemeAppearance: SpaceThemeAppearance {
        store.spaceThemeAppearancePreview ?? store.activeSpace?.themeAppearance ?? .automatic
    }

    // SwiftUI latches the last explicit color scheme on its window; passing
    // nil ("no preference") never releases it. So "automatic" is resolved to
    // the live system appearance instead of nil — see SystemAppearanceObserver.
    // Private windows are always dark — the native macOS private-browsing
    // identity, matching Safari — regardless of system or Space appearance.
    private var resolvedColorScheme: ColorScheme {
        if isPrivate { return .dark }
        return activeThemeAppearance.colorScheme ?? systemAppearance.colorScheme
    }

    private var websiteAppearance: WebsiteAppearance {
        WebsiteAppearance(storedValue: websiteAppearanceValue)
    }

    /// True while a text field holds the keyboard — the address bar, a tab
    /// rename, an Eli prompt. AppKit hands those the field editor, so the
    /// responder is an NSTextView rather than the control itself.
    private var isEditingTextField: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private var activeThemeHexes: [String] {
        store.activeThemeColorHexes
    }

    private var activeThemeIntensityMultiplier: Double {
        store.activeThemeIntensityMultiplier
    }

    private var sidebarTotalWidth: CGFloat {
        sidebarWidth + sidebarDividerWidth
    }

    private var isSidebarPresented: Bool {
        isSidebarVisible || isSidebarHoverRevealed
    }

    private var isSidebarOverlaying: Bool {
        isSidebarHoverRevealed && !isSidebarVisible
    }

    private var isFullWindowOnboardingPresented: Bool {
        store.isInitialOnboardingBlockingBrowsing
    }

    var body: some View {
        let currentAISidebarWidth = clampedAISidebarWidth(CGFloat(aiSidebarWidth))

        ZStack(alignment: .leading) {
            if isFullWindowOnboardingPresented {
                InitialOnboardingCanvas(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                ZStack(alignment: .topTrailing) {
                    if isHistoryPresented {
                        HistoryView(
                            repository: store.historyRepository,
                            spaceID: store.activeSpaceID,
                            clearScope: store.isPrivate ? nil : ClearBrowsingDataPrompt.CurrentSpace(
                                id: store.activeSpaceID,
                                dataStoreID: store.dataStoreID(for: store.activeSpaceID)
                            ),
                            onOpen: { visit in
                                isHistoryPresented = false
                                store.navigateActiveTab(to: visit.url)
                            },
                            onOpenInNewTab: { visit in
                                isHistoryPresented = false
                                store.navigateNewTab(to: visit.url)
                            },
                            onCopyAddress: { visit in
                                store.copyURL(visit.url)
                            },
                            onDismiss: {
                                isHistoryPresented = false
                            }
                        )
                        .id(store.activeSpaceID)
                        .padding(.leading, sidebarLane)
                        .tint(AppColor.accent)
                        .onChange(of: store.historyDismissRequestID) { _, _ in
                            isHistoryPresented = false
                        }
                    } else {
                        // Keep the WebKit host at one stable width when the left
                        // or right sidebar toggles. WebKit paints through a remote
                        // layer; resizing that host exposes or stretches the
                        // previous frame before the WebContent process catches up
                        // and makes pages flash their scrollbars. Both sidebar
                        // lanes are reserved inside WebViewContainer instead.
                        WebViewContainer(
                            store: store,
                            onToggleSidebar: toggleSidebar,
                            slideOverTrailingInset: aiSidebarSlideMaskInset,
                            toggleShield: toggleShield
                        )
                        // Both lanes, per frame: the page card's edges and
                        // the web layout follow the sidebars as they slide,
                        // Dia's push. The trailing gutter closes as Eli's
                        // edge comes in, so the card never jumps 8pt at
                        // either end of the slide. Layout lanes ride their
                        // own modifier so a shielded toggle can snap them
                        // without snapping the visual edge's animation.
                        .modifier(BrowserLayoutLaneEffect(
                            leading: sidebarLayoutLane,
                            trailing: aiSidebarLayoutLane
                        ))
                        .modifier(BrowserLaneEffect(
                            visualLeading: sidebarLane,
                            visualTrailing: aiSidebarLane,
                            trailingGutter: isAISidebarMounted && currentAISidebarWidth > 0
                                ? WebViewContainer.surfacePadding * (1 - min(1, aiSidebarLane / currentAISidebarWidth))
                                : WebViewContainer.surfacePadding
                        ))

                        if isAISidebarMounted {
                            aiSidebarLayout(width: currentAISidebarWidth)
                                .transition(.identity)
                                .zIndex(1)
                        }
                    }
                }
                // The web surface and attached Ask panel form one window row.
                // Extending only the web child into the title-bar safe area
                // pushes Ask's toolbar down and exposes a square strip above
                // its rounded outside corner.
                .ignoresSafeArea(
                    .container,
                    edges: isHistoryPresented ? [] : .top
                )

                sidebarLayout
                    // This subtree also coordinates AppKit's native window controls.
                    // One animatable progress value drives both the compositor
                    // translation and the embedded native traffic-light container.
                    // Separate SwiftUI/AppKit animations visibly drift apart.
                    // Lane-driven, not `isSidebarVisible`-driven: a close
                    // flips the logical state at once but slides only after
                    // the page has laid out for it (the shield's paint gate),
                    // and the chrome must stay parked with the lane until
                    // then. The hover reveal has no lane and keeps its flag.
                    .modifier(SidebarRevealEffect(
                        progress: isSidebarHoverRevealed
                            ? 1
                            : min(sidebarLane / max(sidebarTotalWidth, 1), 1),
                        hiddenOffset: -sidebarTotalWidth
                    ))
                    // The pinned toggle slides in `toggleSidebar`'s own
                    // transaction, with the page card's edge and the web
                    // layout; the overlay hover reveal eases here.
                    .animation(.easeOut(duration: 0.18), value: isSidebarHoverRevealed)
                    .zIndex(2)
            }

            if store.isCommandPalettePresented {
                CommandPaletteView(store: store)
                    .id(store.commandPaletteSessionID)
                    // Removal must be instant: an animated removal overlaps
                    // the committed command's web view swap, which interrupts
                    // the transition and strands an invisible palette that
                    // swallows every click in the window.
                    .transition(.identity)
                    .zIndex(10)
            }

            if store.isTabSwitcherPresented {
                // Centered on the page, not the window: the sidebar and Ask
                // lanes are inset and the title-bar safe area is ignored,
                // matching where the web view actually is.
                TabSwitcherOverlay(store: store)
                    .padding(.leading, sidebarLane)
                    .padding(.trailing, aiSidebarLane)
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(9)
            }

            if let hoveredLinkHref = store.hoveredLinkHref,
               !isFullWindowOnboardingPresented,
               !isHistoryPresented {
                LinkHoverPreviewPill(urlString: hoveredLinkHref)
                    .padding(.leading, sidebarLane + 10)
                    .padding(.trailing, aiSidebarLane + 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(8)
            }

            if let mediaTab = store.floatingMiniPlayerTab,
               let mediaState = store.floatingMiniPlayerState {
                GeometryReader { proxy in
                    let leadingInset = sidebarLane
                    let trailingInset = aiSidebarLane
                    let availableSize = CGSize(
                        width: max(1, proxy.size.width - leadingInset - trailingInset),
                        height: proxy.size.height
                    )

                    FloatingMiniPlayerContainer(
                        store: store,
                        tab: mediaTab,
                        state: mediaState,
                        availableSize: availableSize,
                        summon: store.pendingMiniPlayerSummon,
                        origin: $miniPlayerOrigin,
                        expandedSize: $miniPlayerExpandedSize
                    )
                    .frame(width: availableSize.width, height: availableSize.height, alignment: .topLeading)
                    .offset(x: leadingInset)
                }
                .ignoresSafeArea(.container, edges: .top)
                // Leaving (back to its tab, or the media ending) is a plain
                // fade over the page — the page itself is already in place.
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .overlay {
            // Zen anchors its toast container at the window's absolute
            // top-right (8px in from both edges), floating over the title
            // bar — so the pill must escape the top safe area.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .allowsHitTesting(false)

                VStack(alignment: .trailing, spacing: 8) {
                    if isSignOutConfirmationPresented {
                        SignOutConfirmationView()
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .top).combined(with: .opacity)
                            )
                    }

                    if let toast = store.copiedURLToast {
                        CopiedURLToastView(
                            toast: toast,
                            onShareInteractionChanged: { store.setCopiedURLToastSharing($0) }
                        )
                        .onHover { store.setCopiedURLToastHovered($0) }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.01, anchor: .top),
                            removal: .scale(scale: 0.5, anchor: .top).combined(with: .opacity)
                        ))
                        .id(toast.id)
                    }
                }
                .padding(.top, CopiedURLToastView.windowEdgeSpacing)
                .padding(.trailing, CopiedURLToastView.windowEdgeSpacing)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottomTrailing) {
            if BrowserStore.isUITesting {
                let stateDescription = store.uiTestingStateDescription(sidebarVisible: isSidebarVisible)
                    + ";aiVisible=\(isAISidebarVisible);aiMounted=\(isAISidebarMounted)"
                    + ";websiteAppearance=\(websiteAppearance.rawValue)"

                VStack(spacing: 0) {
                    Text(stateDescription)
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .accessibilityLabel(stateDescription)
                        .accessibilityIdentifier("ui-testing-state")

                    Text(aiSidebarUITestingState)
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .accessibilityLabel(aiSidebarUITestingState)
                        .accessibilityIdentifier("agent-ui-testing-state")
                }
            }
        }
        .sheet(isPresented: $store.isPrivacyReportPresented) {
            PrivacyReportView(onDismiss: { store.isPrivacyReportPresented = false })
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: store.copiedURLToast)
        .onChange(of: userStore.signOutGeneration) { _, generation in
            guard generation > 0 else { return }

            let hasPersonalEliAccess = EliPreferences.hasDirectEliAccess
            if !hasPersonalEliAccess {
                aiSidebarMessages = [.subscriptionGate]
                pendingEliSubscriptionSubmission = nil
            }

            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) {
                isSignOutConfirmationPresented = true
            }

            Task {
                try? await Task.sleep(for: .seconds(2))
                guard userStore.signOutGeneration == generation else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) {
                    isSignOutConfirmationPresented = false
                }
            }
        }
        .background {
            WindowBackdrop(store: store)
                .ignoresSafeArea()
        }
        .preferredColorScheme(resolvedColorScheme)
        .background(
            WindowInteractionConfigurator(
                autosaveName: "\(AppConfiguration.windowAutosaveNamePrefix).\(windowAutosaveID)",
                isPrivate: isPrivate,
                store: store
            )
        )
        .background(
            MouseMoveMonitor(
                isSidebarVisible: $isSidebarVisible,
                isSidebarHoverRevealed: $isSidebarHoverRevealed,
                isSidebarRevealSuppressed: $isSidebarRevealSuppressed
            )
        )
        .background(
            KeyboardShortcutMonitor {
                openNewTabFlow()
            } onCommandW: {
                closeTabOrWindow()
            } onReopenClosedTab: {
                store.reopenLastClosedTab()
            } onFocusAddressBar: {
                store.focusAddressBar()
            } onOpenCommandBar: {
                store.openCommandPalette()
            } onCopyURL: {
                store.copyActiveTabURL()
            } onCopyURLAsMarkdown: {
                store.copyActiveTabURL(asMarkdown: true)
            } onCaptureFullPage: {
                store.captureActiveTabPage()
            } onPinOrUnpinTab: {
                store.togglePinForActiveTab()
            } onToggleSidebar: {
                toggleSidebar()
            } onToggleAISidebar: {
                toggleAISidebar()
            } onFindInPage: {
                showFind()
            } onFindNext: {
                store.findNext()
            } onFindPrevious: {
                store.findPrevious()
            } onEscape: {
                if store.isFindBarPresented {
                    store.dismissFindBar()
                    return true
                }
                // Reader is the next escape hatch down, but only when nothing
                // nearer owns the press: the palette and any field being
                // edited cancel themselves first. Otherwise Escape falls
                // through to the page, which needs it for its own dialogs and
                // for leaving HTML full screen.
                if store.isReaderActiveForActiveTab,
                   !store.isCommandPalettePresented,
                   !isEditingTextField {
                    store.hideReaderForActiveTab()
                    return true
                }
                return false
            } onReload: {
                store.reloadActiveTab()
            } onReloadFromOrigin: {
                store.reloadActiveTabFromOrigin()
            } onStopLoading: {
                store.stopLoadingActiveTabIfLoading()
            } onClearUnpinnedTabs: {
                store.clearUnpinnedTabs()
            } onControlTab: {
                store.switchToNextRecentTab(keepsPreviewOpen: true)
            } onControlShiftTab: {
                store.switchToPreviousRecentTab(keepsPreviewOpen: true)
            } onControlReleased: {
                store.finishTabSwitcherInteraction()
            } onTabSwitcherDelete: {
                store.closeHighlightedTabInTabSwitcher()
            } onTabSwitcherEscape: {
                store.cancelTabSwitcherInteraction()
            } onCommandDigit: { digit in
                store.switchToTab(at: digit)
            } onControlDigit: { digit in
                store.switchToSpace(at: digit)
            } onGoBack: {
                store.goBack()
            } onGoForward: {
                store.goForward()
            } onZoomIn: {
                store.zoomInActiveTab()
            } onZoomOut: {
                store.zoomOutActiveTab()
            } onResetZoom: {
                store.resetZoomForActiveTab()
            } onNextTab: {
                store.switchToNextTab()
            } onPreviousTab: {
                store.switchToPreviousTab()
            } onNextSpace: {
                store.switchToNextSpace()
            } onPreviousSpace: {
                store.switchToPreviousSpace()
            } onToggleSplit: {
                toggleSplitView()
            } onSplitLayout: { layout in
                store.setSplitLayout(layout)
            } onZoomSplitPane: {
                store.toggleSplitPaneZoom()
            } onFocusSplitPane: { offset in
                store.focusAdjacentSplitPane(offset: offset)
            } onUnsplitPane: {
                store.unsplitFocusedPane()
            } onSplitWithTab: {
                store.openSplitWithCommandPalette()
            }
        )
        // isCommandPalettePresented deliberately has no .animation(value:)
        // here — the palette animates in via withAnimation at the present
        // call sites only, so its dismissal is never an animated removal
        // (see BrowserStore.presentCommandPalette).
        // Near-instant fade: the page underneath already switched on the
        // press, so any visible settle here would read as switching lag.
        .animation(.easeOut(duration: 0.08), value: store.isTabSwitcherPresented)
        // Keyed on presence, not value: moving between links swaps the text
        // instantly and only appear/disappear get the brief fade.
        .animation(.easeOut(duration: 0.1), value: store.hoveredLinkHref != nil)
        .animation(.easeOut(duration: 0.16), value: store.mediaControllerTabID)
        .focusedSceneValue(\.browserCommandActions, browserCommandActions)
        .onAppear {
            applyWebsiteAppearance()
            updateService.startCheckingForUpdates()
            store.applySplitPreviewFixtureIfNeeded()
            store.applySplitFixtureIfNeeded()
        }
        .task {
            await userStore.restoreSessionIfNeeded()
            store.reconcileAccountSetup(
                hasCompletedAccountChoice: userStore.hasCompletedAccountChoice
            )
        }
        .onOpenURL { url in
            if !userStore.handleAppleSignInCallback(url) {
                store.openExternalURL(url)
            }
        }
        .onDisappear {
            store.flushSession()
            updateService.stopCheckingForUpdates()
            if isPrivate {
                // The window is gone: tear down every web view and all
                // in-memory page residue now rather than waiting for the
                // store to deallocate.
                store.webCoordinator.purgeAllWebContent()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushSession()
            } else {
                Task {
                    await userStore.recoverSessionIfNeeded()
                    await userStore.reconcilePendingSubscriptionIfNeeded()
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task {
                await userStore.recoverSessionIfNeeded()
                await userStore.reconcilePendingSubscriptionIfNeeded()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSMenu.didBeginTrackingNotification
            )
        ) { notification in
            // The root menu posts once per menu-bar open: titles that mirror
            // inspector state (Show/Close Web Inspector, Start/Stop
            // recordings) catch up with changes made in the inspector's own
            // UI. The store only nudges observers when that state actually
            // drifted — an unconditional rebuild would strand "Reload Page
            // From Origin" as a drawn row of its own (#282).
            guard (notification.object as? NSMenu) === NSApp.mainMenu else { return }
            store.refreshDevelopMenuIfInspectorStateDrifted()
        }
        .onChange(of: store.activeTab?.url) { _, url in
            guard let url else { return }
            Task {
                await userStore.reconcilePendingSubscriptionIfNeeded(for: url)
            }
        }
        .onChange(of: store.aiSidebarToggleRequestID) { _, _ in
            toggleAISidebar()
        }
        .onChange(of: store.sidebarToggleRequestID) { _, _ in
            toggleSidebar()
        }
        .onChange(of: store.activeSpaceID) { _, _ in
            // A Space is its tabs, and they live in the sidebar. Switching
            // from the menu or the keyboard with the sidebar hidden would
            // otherwise change everything off-screen, so the switch brings
            // the sidebar back with it.
            revealSidebar()
        }
        .onChange(of: store.downloadsStore.items.first?.id) { _, newestItemID in
            // A new download (or a PDF-HUD save) with no visible response
            // reads as a dead button — the Dock already bounces the
            // Downloads stack (the modern system cue); the key window adds
            // the popover so the row is immediately visible. Phase/progress
            // updates keep the same newest id, so this fires once per
            // download.
            guard newestItemID != nil, controlActiveState == .key,
                  !store.isDownloadsPopoverPresented else { return }
            showDownloads()
        }
        .onChange(of: userStore.hasCompletedAccountChoice) { _, hasCompletedAccountChoice in
            store.reconcileAccountSetup(
                hasCompletedAccountChoice: hasCompletedAccountChoice
            )
        }
        .onChange(of: websiteAppearanceValue) { _, _ in
            applyWebsiteAppearance()
        }
        .onChange(of: systemAppearance.colorScheme) { _, _ in
            guard websiteAppearance == .automatic else { return }
            applyWebsiteAppearance()
        }
        .onChange(of: store.initialTourTip) { previousTip, currentTip in
            if previousTip == .ask, currentTip != .ask {
                closeAISidebar()
            }
        }
        .onChange(of: store.preparingInitialTourTip) { _, tip in
            guard tip == .ask else { return }
            openAISidebar()

            // The native popover needs an AppKit anchor that has completed a
            // layout pass. Mount the Eli panel first, then present its tip on
            // the next committed SwiftUI pass.
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    store.presentPreparedInitialTourTip(.ask)
                }
            }
        }
        .quickNoteActivity(for: store)
        // The dragged row's ghost, in the window's own top-left space —
        // which is what the drag source publishes — so the grab point stays
        // under the pointer exactly as it was when the row was picked up.
        .overlay(alignment: .topLeading) {
            if let ghost = store.tabDragGhost,
               let tab = store.tabs.first(where: { $0.id == ghost.tabID }) {
                TabDragGhostView(tab: tab, size: ghost.size)
                    // Hanging off the pointer, not centred on it: centred, the
                    // pill sat exactly on the drop line, and a line showing
                    // through a translucent pill is broken by the label —
                    // which reads as two drop marks instead of one.
                    .offset(
                        x: ghost.windowPoint.x + SidebarTabDragGhost.pointerOffset.width,
                        y: ghost.windowPoint.y + SidebarTabDragGhost.pointerOffset.height
                    )
                    .ignoresSafeArea()
            }
        }
    }

    private func applyWebsiteAppearance() {
        store.webCoordinator.updateWebsiteAppearance(
            websiteAppearance,
            systemUsesDarkAppearance: systemAppearance.colorScheme == .dark
        )
    }

    private func presentClearBrowsingData() {
        guard !store.isPrivate else { return }
        ClearBrowsingDataPrompt.present(
            currentSpace: ClearBrowsingDataPrompt.CurrentSpace(
                id: store.activeSpaceID,
                dataStoreID: store.dataStoreID(for: store.activeSpaceID)
            )
        )
    }

    private var browserCommandActions: BrowserCommandActions {
        BrowserCommandActions(
            newTab: openNewTabFlow,
            focusAddressBar: store.focusAddressBar,
            openCommandPalette: store.openCommandPalette,
            toggleSidebar: toggleSidebar,
            isSidebarVisible: isSidebarVisible,
            toggleAISidebar: toggleAISidebar,
            isAISidebarVisible: isAISidebarVisible,
            showHistory: showHistory,
            isHistoryVisible: isHistoryPresented,
            clearBrowsingData: presentClearBrowsingData,
            canClearBrowsingData: !store.isPrivate,
            showDownloads: showDownloads,
            isDownloadsVisible: store.isDownloadsPopoverPresented,
            showSiteInfo: showSiteInfo,
            canShowSiteInfo: store.activeTab?.url != nil,
            showPrivacyReport: { store.isPrivacyReportPresented.toggle() },
            toggleReader: store.toggleReaderForActiveTab,
            canToggleReader: store.canToggleReaderForActiveTab,
            isReaderActive: store.isReaderActiveForActiveTab,
            showQuickTour: showQuickTour,
            openExtensionGallery: { store.navigateNewTab(to: ChromeWebStore.galleryURL) },
            reloadTab: store.reloadActiveTab,
            reloadTabFromOrigin: store.reloadActiveTabFromOrigin,
            printPage: store.printActiveTab,
            canPrintActiveTab: store.canPrintActiveTab,
            openLocalFile: store.openLocalFileViaPanel,
            saveActiveTabAs: store.saveActiveTabAsWebArchive,
            exportActiveTabAsPDF: store.exportActiveTabAsPDF,
            canSaveActiveTab: store.canPrintActiveTab,
            stopLoading: store.stopLoadingActiveTab,
            isActiveTabLoading: store.activeTab?.isLoading == true,
            canReloadActiveTab: store.activeTab?.url != nil,
            goBack: store.goBack,
            goForward: store.goForward,
            goHome: store.goHome,
            returnToSearchResults: store.returnToSearchResults,
            canReturnToSearchResults: store.canReturnToSearchResults,
            closeCurrentTab: closeTabOrWindow,
            nextTab: store.switchToNextTab,
            previousTab: store.switchToPreviousTab,
            nextSpace: store.switchToNextSpace,
            previousSpace: store.switchToPreviousSpace,
            reopenClosedTab: store.reopenLastClosedTab,
            pinOrUnpinTab: store.togglePinForActiveTab,
            isActiveTabPinned: store.activeTab?.isPinned == true,
            isActiveTabFavorite: store.activeTab?.isFavorite == true,
            createSpace: store.beginSpaceCreation,
            editActiveSpace: { store.beginSpaceEditing(store.activeSpaceID) },
            spaces: store.spaces,
            activeSpaceID: store.activeSpaceID,
            selectSpace: store.requestSpaceSelection,
            canToggleFavorite: store.activeTab?.url != nil,
            toggleFavoriteForActiveTab: store.toggleFavoriteForActiveTab,
            duplicateTab: store.duplicateCurrentTab,
            clearUnpinnedTabs: store.clearUnpinnedTabs,
            copyURL: { store.copyActiveTabURL() },
            copyURLAsMarkdown: { store.copyActiveTabURL(asMarkdown: true) },
            findInPage: showFind,
            findNext: store.findNext,
            findPrevious: store.findPrevious,
            zoomIn: store.zoomInActiveTab,
            zoomOut: store.zoomOutActiveTab,
            resetZoom: store.resetZoomForActiveTab,
            toggleSplitView: toggleSplitView,
            setSplitLayout: store.setSplitLayout,
            isSplitDisplayed: store.isSplitViewDisplayed,
            toggleSplitPaneZoom: store.toggleSplitPaneZoom,
            isSplitPaneZoomed: store.isSplitPaneZoomed,
            focusSplitPane: store.focusAdjacentSplitPane,
            unsplitPane: store.unsplitFocusedPane,
            splitWithTab: store.openSplitWithCommandPalette,
            installedBrowsers: ExternalBrowserService.installedBrowsers(),
            openPageWith: { store.openActivePage(with: $0) },
            canUseDevelopTools: store.canUseDevelopTools,
            activeUserAgentPreset: store.activeUserAgentPreset,
            setUserAgentPreset: { store.setUserAgentPreset($0) },
            isCustomUserAgentActive: store.isCustomUserAgentActive,
            promptForCustomUserAgent: { store.promptForCustomUserAgent() },
            inspectablePages: store.inspectablePages,
            inspectPage: { store.inspectPage($0) },
            isWebInspectorVisible: store.isWebInspectorVisible,
            toggleWebInspector: { store.toggleWebInspector() },
            connectWebInspector: { store.connectWebInspector() },
            showJavaScriptConsole: { store.showJavaScriptConsole() },
            showPageSource: { store.showPageSource() },
            showPageResources: { store.showPageResources() },
            isRecordingTimeline: store.isRecordingTimeline,
            toggleTimelineRecording: { store.toggleTimelineRecording() },
            isSelectingElement: store.isSelectingElement,
            toggleElementSelection: { store.toggleElementSelection() },
            emptyCaches: { store.emptyCaches() },
            arrangeTabsByTitle: { store.arrangeTabs(by: .title) },
            arrangeTabsByWebsite: { store.arrangeTabs(by: .website) },
            canArrangeTabs: store.canArrangeTabs,
            canMuteActiveTab: store.canMuteActiveTab,
            isActiveTabMuted: store.isActiveTabMuted,
            toggleActiveTabMute: { store.toggleActiveTabMute() },
            canMuteOtherTabs: store.canMuteOtherTabs,
            muteOtherTabs: { store.muteOtherTabs() }
        )
    }

    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                availableUpdate: updateService.availableUpdate,
                isInstallingUpdate: updateService.isInstallingUpdate,
                automaticUpdatesEnabled: Binding(
                    get: { updateService.automaticUpdatesEnabled },
                    set: { isEnabled in
                        updateService.setAutomaticUpdatesEnabled(isEnabled)
                    }
                ),
                onUpdateBannerTapped: {
                    updateService.openAvailableUpdate()
                },
                isWhatsNewVisible: whatsNewService.isPromptVisible,
                onWhatsNewTapped: {
                    whatsNewService.acknowledge()
                    _ = store.newTab(url: WhatsNewService.pageURL)
                },
                onWhatsNewDismissed: {
                    whatsNewService.acknowledge()
                },
                onToggleSidebar: toggleSidebar,
                isSidebarPinned: isSidebarVisible,
                onRevealSidebar: revealSidebar
            )
                .frame(width: sidebarWidth)
        }
        .frame(width: sidebarTotalWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background {
            // Docked, the lane stays transparent so the shared window backdrop
            // shows through and the sidebar matches the center exactly. Only
            // the hover overlay needs its own opaque copy over the page.
            if isSidebarOverlaying {
                SidebarBackdrop(store: store)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .shadow(
            color: Color.black.opacity(isSidebarOverlaying ? 0.22 : 0),
            radius: 16,
            x: 3,
            y: 0
        )
    }

    private func aiSidebarPanel(width: CGFloat) -> some View {
        EliSidebarView(
            store: store,
            uiTestingState: $aiSidebarUITestingState,
            messages: $aiSidebarMessages,
            memoryWindow: $aiSidebarMemoryWindow,
            pendingSubscriptionSubmission: $pendingEliSubscriptionSubmission
        ) {
            toggleAISidebar()
        }
        .frame(width: width)
    }

    private func aiSidebarLayout(width: CGFloat) -> some View {
        ZStack {
            // The lane stays transparent even while the page's edge slides
            // across Eli: the web surface is clipped at that edge by the
            // lane, so the one shared window backdrop shows through here in
            // every state and can never drift in color from the center or
            // the docked lane.
            aiSidebarPanel(width: width)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Dia's chat panel: docked in place from the first frame, uncovered
        // as the page card's edge slides across it, covered again on close.
        .mask(alignment: .trailing) {
            Rectangle()
                .frame(width: max(0, min(width, aiSidebarLane + aiSidebarSlideMaskInset)))
        }
        .overlay(alignment: .leading) {
            AISidebarResizeHandle()
                .frame(width: AISidebarLayout.resizeHandleHitWidth)
                .offset(x: -AISidebarLayout.resizeHandleHitWidth / 2)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let startWidth = aiSidebarResizeStartWidth ?? width
                            if aiSidebarResizeStartWidth == nil {
                                aiSidebarResizeStartWidth = width
                            }
                            let draggedWidth = clampedAISidebarWidth(startWidth - value.translation.width)
                            aiSidebarWidth = Double(draggedWidth)
                            // While Eli widens over the still-reserved web
                            // layout, clip the card at Eli's edge so its
                            // rounded corner is never squared off mid-drag.
                            aiSidebarSlideMaskInset = max(0, draggedWidth - reservedAISidebarInset)
                        }
                        .onEnded { _ in
                            aiSidebarResizeStartWidth = nil
                            // Keep pointer-driven resizing compositor-only, then
                            // commit the WebKit viewport once when dragging ends.
                            // Releasing the slide mask in the same update keeps
                            // the visible card edge exactly in place.
                            reservedAISidebarInset = clampedAISidebarWidth(CGFloat(aiSidebarWidth))
                            aiSidebarLane = reservedAISidebarInset
                            aiSidebarLayoutLane = reservedAISidebarInset
                            aiSidebarSlideMaskInset = 0
                        }
                )
        }
        .allowsHitTesting(isAISidebarVisible)
        .accessibilityHidden(!isAISidebarVisible)
    }

    /// Dia's sidebar: it slides in and pushes the page over — the page
    /// card's edge, its toolbar and its content move with the sidebar's
    /// edge, with a touch of spring at the end — and closing pulls the page
    /// back the same way. The page is laid out against the lane frame by
    /// frame (`BrowserLaneEffect`); WebKit commits those inset changes for
    /// typical pages within a frame, so the content keeps up with the edge.
    /// It is a short burst of layout, not a steady cost.
    static let sidebarToggleAnimation = Animation.spring(response: 0.30, dampingFraction: 0.76)

    private func toggleSidebar() {
        toggleSidebar(completion: nil)
    }

    private func toggleSidebar(completion: (() -> Void)?) {
        let showing = !isSidebarVisible
        let lane = sidebarTotalWidth
        sidebarToggleGeneration += 1
        let generation = sidebarToggleGeneration
        isSidebarHoverRevealed = false
        isSidebarRevealSuppressed = !showing
        guard !reduceMotion else {
            isSidebarVisible = showing
            sidebarLane = showing ? lane : 0
            sidebarLayoutLane = showing ? lane : 0
            completion?()
            return
        }
        isSidebarVisible = showing
        if showing {
            // Opening: the sidebar slides in at once; the page rides it as a
            // still (the shield), pushed with the edge, while the live page
            // relayouts to the open lane exactly once underneath. The shield
            // fades out — a beat of crossfade, old layout onto new — only
            // once the slide has landed and the page reports the new layout
            // painted. Without a shield (no web page, splits), the page lays
            // out against the moving lane live, trailing under the edge.
            withPageToggleShield {
                guard sidebarToggleGeneration == generation else { return }
                withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                    sidebarLane = lane
                    sidebarLayoutLane = lane
                } completion: {
                    completion?()
                }
            } shielded: {
                guard sidebarToggleGeneration == generation else { return }
                sidebarLayoutLane = lane
                withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                    sidebarLane = lane
                } completion: {
                    if sidebarToggleGeneration == generation {
                        fadeToggleShield(afterPaintedLeading: lane, trailing: nil)
                    }
                    completion?()
                }
            }
            return
        }
        // Closing: same shape as opening — the still is glued to the moving
        // edge, so the strip the sidebar uncovers shows the pictured page
        // sliding back with it, never the live page's mid-reflow layout,
        // and the slide starts at once (a paint-fence hold here starved
        // rapid toggling: reversals arrived before any slow page painted,
        // and no close ever moved). The live page relayouts to full width
        // underneath at its own pace; the fade at the end waits for it.
        withPageToggleShield {
            guard sidebarToggleGeneration == generation else { return }
            withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                sidebarLane = 0
                sidebarLayoutLane = 0
            } completion: {
                completion?()
            }
        } shielded: {
            guard sidebarToggleGeneration == generation else { return }
            sidebarLayoutLane = 0
            withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                sidebarLane = 0
            } completion: {
                // Only at the end of the slide, and only if no newer toggle
                // owns the shield: fading earlier would strand a reversal
                // without its cover — a burst of toggles rides this one
                // still to the last slide's end.
                if sidebarToggleGeneration == generation {
                    fadeToggleShield(afterPaintedLeading: 0, trailing: nil)
                }
                completion?()
            }
        }
    }

    /// Runs a lane toggle behind a still of the page (see
    /// `PageToggleShield`) when there is a live web page to picture;
    /// everything else — splits, SwiftUI pages, history — reflows at the
    /// edge's own frame rate and runs the bare transition instead. A toggle
    /// that reverses mid-flight reuses the standing still: the live page has
    /// been covered since it was taken, so it is still the page the person
    /// last saw — one still rides a whole burst of toggles.
    ///
    /// A freshly captured still runs `shielded` only one presentation cycle
    /// after mounting: first drawing a window-sized bitmap costs enough of
    /// the frame that a spring started in the same update visibly skips its
    /// first hundred points.
    private func withPageToggleShield(
        _ unshielded: @escaping () -> Void,
        shielded: @escaping () -> Void
    ) {
        guard store.displayedSplitTabs.count < 2,
              !isHistoryPresented,
              !store.isInitialSpaceSetupPresented,
              !store.isCreateSpacePresented,
              let tab = store.activeTab,
              tab.url != nil,
              !tab.isWelcomePage
        else {
            toggleShield = nil
            unshielded()
            return
        }
        if let shield = toggleShield, shield.opacity == 1 {
            shielded()
            return
        }
        store.webCoordinator.captureToggleShield { capture in
            guard let capture else {
                toggleShield = nil
                unshielded()
                return
            }
            toggleShield = capture
            CATransaction.setCompletionBlock {
                DispatchQueue.main.async {
                    guard toggleShield?.id == capture.id else { return }
                    shielded()
                }
            }
        }
    }

    /// Fades the shield once the page under it has painted the given lanes
    /// (capped): the fade is the handover, so what it uncovers must already
    /// be the layout the toggle promised.
    private func fadeToggleShield(afterPaintedLeading leading: CGFloat?, trailing: CGFloat?) {
        guard let shieldID = toggleShield?.id else { return }
        store.webCoordinator.waitForPaintedLanes(leading: leading, trailing: trailing, timeout: 0.35) {
            guard toggleShield?.id == shieldID else { return }
            fadeToggleShield(over: 0.12)
        }
    }

    private func fadeToggleShield(over duration: TimeInterval) {
        guard let shieldID = toggleShield?.id, toggleShield?.opacity == 1 else { return }
        withAnimation(.easeOut(duration: duration)) {
            toggleShield?.opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            guard toggleShield?.id == shieldID, toggleShield?.opacity == 0 else { return }
            toggleShield = nil
        }
    }

    private func toggleAISidebar() {
        if isAISidebarVisible {
            closeAISidebar()
        } else {
            openAISidebar()
        }
    }

    /// Pins the sidebar open for something that needs it visible, leaving it
    /// alone when it already is.
    private func revealSidebar() {
        guard !isSidebarVisible else { return }
        toggleSidebar()
    }

    private func showQuickTour() {
        revealSidebar()
        closeAISidebar()
        store.showQuickTour()
    }

    private func showHistory() {
        if isHistoryPresented {
            isHistoryPresented = false
            return
        }
        closeAISidebar()
        isHistoryPresented = true
    }

    private func showDownloads() {
        if store.isDownloadsPopoverPresented {
            store.isDownloadsPopoverPresented = false
            return
        }
        guard isSidebarVisible else {
            // The popover anchors to the sidebar's Downloads button, so a
            // hidden sidebar must be revealed first — and have landed, or
            // the popover attaches to a button still on the move.
            toggleSidebar { [weak store] in
                store?.isDownloadsPopoverPresented = true
            }
            return
        }
        store.isDownloadsPopoverPresented = true
    }

    private func showSiteInfo() {
        if store.isSiteInfoPopoverPresented {
            store.isSiteInfoPopoverPresented = false
            return
        }
        guard isSidebarVisible else {
            // Anchored to the sidebar address pill, so a hidden sidebar must
            // be revealed first and have landed — same as showDownloads.
            toggleSidebar { [weak store] in
                store?.isSiteInfoPopoverPresented = true
            }
            return
        }
        store.isSiteInfoPopoverPresented = true
    }

    private func showFind() {
        if isHistoryPresented {
            NotificationCenter.default.post(name: .focusHistorySearch, object: nil)
        } else {
            store.showFindBar()
        }
    }

    /// Dia's chat panel: it is docked from the first frame and the page
    /// card's edge slides across to uncover it, with a touch of spring at
    /// the end; the page lays out against the moving edge frame by frame
    /// (`BrowserLaneEffect`). Closing covers it again the same way.
    private func openAISidebar() {
        guard !isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1
        let generation = aiSidebarTransitionGeneration
        let width = clampedAISidebarWidth(CGFloat(aiSidebarWidth))

        reservedAISidebarInset = width
        aiSidebarSlideMaskInset = 0
        aiSidebarResizeStartWidth = nil
        guard !reduceMotion else {
            isAISidebarMounted = true
            isAISidebarVisible = true
            aiSidebarLane = width
            aiSidebarLayoutLane = width
            return
        }
        let slide = {
            guard aiSidebarTransitionGeneration == generation else { return }
            // The still stays pinned for a trailing toggle — Eli's edge
            // slides across it, the reveal — while the live page
            // relayouts to the docked lane once, underneath.
            withPageToggleShield {
                guard aiSidebarTransitionGeneration == generation else { return }
                withAnimation(Self.sidebarToggleAnimation) {
                    isAISidebarVisible = true
                    aiSidebarLane = width
                    aiSidebarLayoutLane = width
                }
            } shielded: {
                guard aiSidebarTransitionGeneration == generation else { return }
                aiSidebarLayoutLane = width
                withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                    isAISidebarVisible = true
                    aiSidebarLane = width
                } completion: {
                    guard aiSidebarTransitionGeneration == generation else { return }
                    fadeToggleShield(afterPaintedLeading: nil, trailing: width)
                }
            }
        }
        // A reopen over a panel a cancelled close left mounted must not run
        // the mount step: zeroing the lane here teleported the edge shut
        // before sliding it back out. The panel is already rendered — just
        // retarget the slide from wherever the lane is.
        guard !isAISidebarMounted else {
            slide()
            return
        }
        // Mount first, fully covered (a view inserted and animated in the
        // same transaction starts at its final value, so the slide would
        // never play); slide the edge across it once that has committed.
        isAISidebarMounted = true
        aiSidebarLane = 0
        aiSidebarLayoutLane = 0
        CATransaction.setCompletionBlock {
            // One more turn: the panel's first render is the heaviest frame
            // of the whole toggle, and the slide should not start on it.
            DispatchQueue.main.async(execute: slide)
        }
    }

    private func closeAISidebar() {
        guard isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1
        let generation = aiSidebarTransitionGeneration

        aiSidebarResizeStartWidth = nil
        aiSidebarSlideMaskInset = 0
        // Logically closed and inert at once.
        isAISidebarVisible = false
        guard !reduceMotion else {
            isAISidebarMounted = false
            aiSidebarLane = 0
            aiSidebarLayoutLane = 0
            return
        }
        // Lay the page out at full width first, under the still-docked
        // panel — invisible there — and slide the edge back across it only
        // once the page reports it has painted that layout (capped), so the
        // slide uncovers content that is already in place, never the page's
        // margin catching up. The panel stays mounted for the slide, then
        // goes.
        // The still covers the page through the full-width relayout and
        // rides the handover: the edge slides only once the page has painted
        // for it, and the still fades across the slide onto that layout.
        withPageToggleShield {
            aiSidebarLayoutLane = 0
            store.webCoordinator.waitForTrailingLane(0, timeout: 0.4) {
                guard aiSidebarTransitionGeneration == generation else { return }
                withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                    aiSidebarLane = 0
                } completion: {
                    guard aiSidebarTransitionGeneration == generation else { return }
                    isAISidebarMounted = false
                }
            }
        } shielded: {
            guard aiSidebarTransitionGeneration == generation else { return }
            aiSidebarLayoutLane = 0
            store.webCoordinator.waitForTrailingLane(0, timeout: 0.4) {
                guard aiSidebarTransitionGeneration == generation else { return }
                withAnimation(Self.sidebarToggleAnimation, completionCriteria: .logicallyComplete) {
                    aiSidebarLane = 0
                } completion: {
                    guard aiSidebarTransitionGeneration == generation else { return }
                    fadeToggleShield(over: 0.12)
                    isAISidebarMounted = false
                }
            }
        }
    }

    private func clampedAISidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, AISidebarLayout.minWidth), AISidebarLayout.maxWidth)
    }

    private func openNewTabFlow() {
        isHistoryPresented = false
        store.openNewTab()
    }

    private func toggleSplitView() {
        store.toggleSplitView()
    }

    private func closeTabOrWindow() {
        if isHistoryPresented {
            isHistoryPresented = false
            return
        }

        if store.visibleTabsForActiveSpace.count > 1 {
            store.closeCurrentTab()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}

private struct SignOutConfirmationView: View {
    var body: some View {
        Label("Signed out", systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(InterfaceStyle.popoverBorder, lineWidth: 1)
            }
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 9, y: 3)
            .accessibilityIdentifier("sign-out-confirmation")
    }
}
