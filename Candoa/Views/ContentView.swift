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
    @State private var isSidebarHoverRevealed = false
    @State private var isSidebarRevealSuppressed = false
    @State private var isAISidebarVisible = false
    @State private var isAISidebarMounted = false
    @State private var isAISidebarReservingWebLayout = false
    @State private var isHistoryPresented = false
    @State private var reservedAISidebarInset: CGFloat = 0
    // Compositor-only trailing clip applied to the web surface while Eli
    // covers it beyond the reserved web layout: during a widening resize
    // drag, and during a close's paint-fence hold, where the page has
    // already expanded under the still-mounted panel. It keeps the card's
    // rounded trailing corner pinned to Eli's edge without ever touching the
    // live WKWebView's frame; it must be exactly 0 whenever the reserved
    // layout owns the trailing edge.
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
        let currentAISidebarInset = isAISidebarMounted
            ? currentAISidebarWidth
            : 0

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
                        .padding(.leading, isSidebarVisible ? sidebarTotalWidth : 0)
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
                            visibleInterfaceInsets: BrowserInterfaceInsets(
                                leading: isSidebarVisible ? sidebarTotalWidth : 0
                            ),
                            attachesToTrailingPanel: isAISidebarMounted,
                            onToggleSidebar: toggleSidebar,
                            slideOverTrailingInset: aiSidebarSlideMaskInset
                        )
                        // Resize WebKit once, after Eli has finished sliding over
                        // this lane. Keeping this out of the animation avoids
                        // per-frame web layout while placing WebKit's own overlay
                        // scroller at the visible page edge.
                        .padding(
                            .trailing,
                            isAISidebarReservingWebLayout ? reservedAISidebarInset : 0
                        )

                        if isAISidebarMounted {
                            aiSidebarLayout(width: currentAISidebarWidth)
                                .transition(
                                    reduceMotion
                                        ? .identity
                                        : .move(edge: .trailing)
                                )
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
                    .modifier(SidebarRevealEffect(
                        progress: isSidebarPresented ? 1 : 0,
                        hiddenOffset: -sidebarTotalWidth
                    ))
                    // A pinned show/hide must snap with the one-time WKWebView
                    // frame update above. Only the overlay hover reveal may slide;
                    // otherwise the sidebar temporarily separates from content.
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
                    .padding(.leading, isSidebarVisible ? sidebarTotalWidth : 0)
                    .padding(.trailing, isAISidebarReservingWebLayout ? reservedAISidebarInset : 0)
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(9)
            }

            if let hoveredLinkHref = store.hoveredLinkHref,
               !isFullWindowOnboardingPresented,
               !isHistoryPresented {
                LinkHoverPreviewPill(urlString: hoveredLinkHref)
                    .padding(.leading, (isSidebarVisible ? sidebarTotalWidth : 0) + 10)
                    .padding(.trailing, currentAISidebarInset + 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(8)
            }

            if let mediaTab = store.floatingMiniPlayerTab,
               let mediaState = store.floatingMiniPlayerState {
                GeometryReader { proxy in
                    let leadingInset = isSidebarVisible ? sidebarTotalWidth : 0
                    let trailingInset = currentAISidebarInset
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
                .transition(.scale(scale: 0.98, anchor: .bottomLeading).combined(with: .opacity))
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
            // The lane stays transparent even while Eli slides over the page:
            // the web surface is clipped at Eli's moving edge by
            // slideOverTrailingInset, so the one shared window backdrop shows
            // through here in every state and can never drift in color from
            // the center or the docked lane.
            aiSidebarPanel(width: width)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
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
                            aiSidebarSlideMaskInset = 0
                        }
                )
        }
        .allowsHitTesting(isAISidebarVisible)
        .accessibilityHidden(!isAISidebarVisible)
    }

    // The pinned toggle deliberately snaps in a single frame: sidebar
    // translation, mask lane, and WebKit obscured insets all switch in one
    // commit, so the sidebar can never separate from the content beside it.
    // Only the pointer-driven hover reveal slides, as a floating overlay.
    private func toggleSidebar() {
        if isSidebarVisible {
            isSidebarVisible = false
            isSidebarHoverRevealed = false
            isSidebarRevealSuppressed = true
        } else {
            isSidebarVisible = true
            isSidebarHoverRevealed = false
            isSidebarRevealSuppressed = false
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
        isSidebarVisible = true
        isSidebarHoverRevealed = false
        isSidebarRevealSuppressed = false
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
            // hidden sidebar must be revealed first. Presenting in the same
            // transaction races the reveal commit and anchors nowhere
            // (see the two-beat handoff pattern) — defer to its completion.
            toggleSidebar()
            CATransaction.setCompletionBlock { [weak store] in
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
            // be revealed first — same two-beat handoff as showDownloads.
            toggleSidebar()
            CATransaction.setCompletionBlock { [weak store] in
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

    private func openAISidebar() {
        guard !isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1

        // Open snaps in one commit, matching the pinned left sidebar: the
        // panel appears docked, the card ends at its edge with the rounded
        // corner from its own clip shape, and the single native WKWebView
        // resize happens in the same frame.
        reservedAISidebarInset = clampedAISidebarWidth(CGFloat(aiSidebarWidth))
        isAISidebarReservingWebLayout = true
        isAISidebarMounted = true
        isAISidebarVisible = true
        aiSidebarSlideMaskInset = 0
    }

    private func closeAISidebar() {
        guard isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1
        let generation = aiSidebarTransitionGeneration

        aiSidebarResizeStartWidth = nil
        // Close also snaps, but in two invisible beats: expand the page once
        // while Eli still covers the changing edge — the slide mask takes
        // over the exact visible card edge in the same unanimated update —
        // then remove the panel only after WebKit has painted the widened
        // layout, so the snap uncovers real content instead of the page's
        // background fill. The panel lingers for the fence (typically a
        // frame or two, capped at 250ms) but is logically closed and inert
        // immediately.
        isAISidebarVisible = false
        isAISidebarReservingWebLayout = false
        aiSidebarSlideMaskInset = clampedAISidebarWidth(CGFloat(aiSidebarWidth))
        // The CATransaction completion is guaranteed to run only after the
        // handoff above has rendered; a main-queue async block is not.
        CATransaction.setCompletionBlock {
            guard aiSidebarTransitionGeneration == generation else { return }
            store.waitForWebContentPaint(at: .trailing, timeout: 0.25) {
                guard aiSidebarTransitionGeneration == generation else { return }
                isAISidebarMounted = false
                aiSidebarSlideMaskInset = 0
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
