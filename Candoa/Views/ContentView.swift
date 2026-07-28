import AppKit
@preconcurrency import AVFoundation
import os
@preconcurrency import Speech
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = BrowserStore()
    @StateObject private var updateService = AppUpdateService.shared
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(CandoaSettingsOption.websiteAppearance) private var websiteAppearanceValue =
        WebsiteAppearance.dark.rawValue
    @AppStorage(DeveloperModeConfiguration.storageKey) private var developerModeOverrides = ""
    @SceneStorage("candoa.windowAutosaveID") private var windowAutosaveID = UUID().uuidString
    @State private var isSidebarVisible = true
    @State private var isSidebarHoverRevealed = false
    @State private var isSidebarRevealSuppressed = false
    @State private var isAISidebarVisible = false
    @State private var isAISidebarMounted = false
    @State private var isAISidebarReservingWebLayout = false
    @State private var isHistoryPresented = false
    @State private var reservedAISidebarInset: CGFloat = 0
    @State private var aiSidebarTransitionGeneration = 0
    @State private var aiSidebarUITestingState = ""
    @State private var aiSidebarMessages: [AISidebarMessage] = []
    @State private var pendingEliSubscriptionSubmission: EliSubmission?
    @State private var isSignOutConfirmationPresented = false
    @State private var aiSidebarResizeStartWidth: CGFloat?
    @State private var miniPlayerOrigin: CGPoint?
    @State private var miniPlayerExpandedSize = MiniPlayerLayout.defaultExpandedSize
    @SceneStorage("candoa.aiSidebarWidth.diaLayout") private var aiSidebarWidth = 540.0
    private let sidebarWidth = CandoaInterfaceStyle.sidebarWidth
    private let sidebarDividerWidth: CGFloat = 0

    private var activeThemeAppearance: SpaceThemeAppearance {
        store.spaceThemeAppearancePreview ?? store.activeSpace?.themeAppearance ?? .automatic
    }

    // SwiftUI latches the last explicit color scheme on its window; passing
    // nil ("no preference") never releases it. So "automatic" is resolved to
    // the live system appearance instead of nil — see SystemAppearanceObserver.
    private var resolvedColorScheme: ColorScheme {
        activeThemeAppearance.colorScheme ?? systemAppearance.colorScheme
    }

    private var websiteAppearance: WebsiteAppearance {
        WebsiteAppearance(storedValue: websiteAppearanceValue)
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
                        .tint(CandoaColor.accent)
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
                            attachesToTrailingPanel: isAISidebarMounted
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
                TabSwitcherOverlay(store: store)
                    .zIndex(9)
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
        .animation(.spring(duration: 0.5, bounce: 0.2), value: store.copiedURLToast)
        .onChange(of: userStore.signOutGeneration) { _, generation in
            guard generation > 0 else { return }

            let hasPersonalEliAccess =
                CandoaEliPreferences.usesPersonalOpenAIKey && CandoaEliKeychain.hasAPIKey
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
            CandoaWindowBackdrop(store: store)
                .ignoresSafeArea()
        }
        .preferredColorScheme(resolvedColorScheme)
        .background(
            WindowInteractionConfigurator(
                autosaveName: "\(AppConfiguration.windowAutosaveNamePrefix).\(windowAutosaveID)"
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
            } onReload: {
                store.reloadActiveTab()
            } onClearUnpinnedTabs: {
                store.clearUnpinnedTabs()
            } onControlTab: {
                store.switchToNextRecentTab(keepsPreviewOpen: true)
            } onControlShiftTab: {
                store.switchToPreviousRecentTab(keepsPreviewOpen: true)
            } onControlReleased: {
                store.finishTabSwitcherInteraction()
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
            } onAddSplit: {
                addSplitView()
            } onCloseSplit: {
                store.closeSplitView()
            }
        )
        // isCommandPalettePresented deliberately has no .animation(value:)
        // here — the palette animates in via withAnimation at the present
        // call sites only, so its dismissal is never an animated removal
        // (see BrowserStore.presentCommandPalette).
        .animation(.easeOut(duration: 0.14), value: store.isTabSwitcherPresented)
        .animation(.easeOut(duration: 0.16), value: store.mediaControllerTabID)
        .focusedSceneValue(\.browserCommandActions, browserCommandActions)
        .alert(
            "Relaunch Candoa",
            isPresented: Binding(
                get: { store.syncRestartMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.syncRestartMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.syncRestartMessage = nil
            }
        } message: {
            Text(store.syncRestartMessage ?? "")
        }
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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushSession()
            } else {
                Task {
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
                await userStore.reconcilePendingSubscriptionIfNeeded()
            }
        }
        .onChange(of: store.activeTab?.url) { _, url in
            guard let url else { return }
            Task {
                await userStore.reconcilePendingSubscriptionIfNeeded(for: url)
            }
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
    }

    private func applyWebsiteAppearance() {
        store.webCoordinator.updateWebsiteAppearance(
            websiteAppearance,
            systemUsesDarkAppearance: systemAppearance.colorScheme == .dark
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
            showQuickTour: showQuickTour,
            reloadTab: store.reloadActiveTab,
            goBack: store.goBack,
            goForward: store.goForward,
            closeCurrentTab: closeTabOrWindow,
            nextTab: store.switchToNextTab,
            previousTab: store.switchToPreviousTab,
            nextSpace: store.switchToNextSpace,
            previousSpace: store.switchToPreviousSpace,
            reopenClosedTab: store.reopenLastClosedTab,
            pinOrUnpinTab: store.togglePinForActiveTab,
            isActiveTabPinned: store.activeTab?.isPinned == true,
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
            addSplitView: addSplitView,
            closeSplitView: store.closeSplitView,
            isWorkspaceICloudSyncEnabled: store.iCloudWorkspaceSyncEnabled,
            isHistoryICloudSyncEnabled: store.iCloudHistorySyncEnabled,
            setWorkspaceICloudSyncEnabled: store.setWorkspaceICloudSyncEnabled,
            setHistoryICloudSyncEnabled: store.setHistoryICloudSyncEnabled,
            isDeveloperModeAvailable: store.activeTab?.url != nil,
            isDeveloperModeEnabled: store.activeTab?.url.map {
                DeveloperModeConfiguration.isEnabled(
                    for: $0,
                    storedOverrides: developerModeOverrides
                )
            } ?? false,
            setDeveloperMode: { isEnabled in
                guard let url = store.activeTab?.url else { return }
                store.setDeveloperMode(isEnabled, for: url)
            }
        )
    }

    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                availableUpdate: updateService.availableUpdate,
                automaticUpdatesEnabled: Binding(
                    get: { updateService.automaticUpdatesEnabled },
                    set: { isEnabled in
                        updateService.setAutomaticUpdatesEnabled(isEnabled)
                    }
                ),
                windowControlsHiddenOffset: -sidebarTotalWidth,
                onUpdateBannerTapped: {
                    updateService.openAvailableUpdate()
                },
                onToggleSidebar: toggleSidebar
            )
                .frame(width: sidebarWidth)
        }
        .frame(width: sidebarTotalWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background {
            // The sidebar retains the Space tint but has its own restrained
            // semantic tone, matching native macOS sidebar separation.
            if isSidebarPresented {
                CandoaSidebarBackdrop(store: store)
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
            pendingSubscriptionSubmission: $pendingEliSubscriptionSubmission
        ) {
            toggleAISidebar()
        }
        .frame(width: width)
    }

    private func aiSidebarLayout(width: CGFloat) -> some View {
        ZStack {
            CandoaInterfaceStyle.workspaceBackground

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
                            aiSidebarWidth = Double(clampedAISidebarWidth(startWidth - value.translation.width))
                        }
                        .onEnded { _ in
                            aiSidebarResizeStartWidth = nil
                            // Keep pointer-driven resizing compositor-only, then
                            // commit the WebKit viewport once when dragging ends.
                            reservedAISidebarInset = clampedAISidebarWidth(CGFloat(aiSidebarWidth))
                        }
                )
        }
        .allowsHitTesting(isAISidebarVisible)
        .accessibilityHidden(!isAISidebarVisible)
    }

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

    private func showQuickTour() {
        if !isSidebarVisible {
            isSidebarVisible = true
            isSidebarHoverRevealed = false
            isSidebarRevealSuppressed = false
        }
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
        let generation = aiSidebarTransitionGeneration

        // Mount the panel in a trailing overlay, then reveal it. The live
        // WKWebView stays at its current size for the animated portion.
        isAISidebarReservingWebLayout = false
        reservedAISidebarInset = clampedAISidebarWidth(CGFloat(aiSidebarWidth))
        withAnimation(aiSidebarAnimation) {
            isAISidebarMounted = true
            isAISidebarVisible = true
        }

        let delay = reduceMotion ? 0 : AISidebarLayout.slideAnimationDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard aiSidebarTransitionGeneration == generation,
                  isAISidebarVisible else { return }
            // The panel now fully covers the changing edge. Commit one native
            // WebKit resize without animation so its system overlay scroller
            // belongs to the page instead of a synthetic interface gutter.
            isAISidebarReservingWebLayout = true
        }
    }

    private func closeAISidebar() {
        guard isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1

        aiSidebarResizeStartWidth = nil
        // Expand the page once while Eli still covers the changing edge, then
        // move only the sidebar surface.
        isAISidebarReservingWebLayout = false
        withAnimation(aiSidebarAnimation) {
            isAISidebarVisible = false
            isAISidebarMounted = false
        }
    }

    private func clampedAISidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, AISidebarLayout.minWidth), AISidebarLayout.maxWidth)
    }

    private var aiSidebarAnimation: Animation? {
        reduceMotion
            ? nil
            : .easeInOut(duration: AISidebarLayout.slideAnimationDuration)
    }

    private func openNewTabFlow() {
        isHistoryPresented = false
        store.openNewTabCommandPalette()
    }

    private func addSplitView() {
        guard !store.isSplitViewEnabled else { return }
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
                    .stroke(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
            }
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 9, y: 3)
            .accessibilityIdentifier("sign-out-confirmation")
    }
}
