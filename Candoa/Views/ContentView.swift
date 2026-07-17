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
    @SceneStorage("candoa.windowAutosaveID") private var windowAutosaveID = UUID().uuidString
    @State private var isSidebarVisible = true
    @State private var isSidebarHoverRevealed = false
    @State private var isSidebarRevealSuppressed = false
    @State private var isAISidebarVisible = false
    @State private var isAISidebarMounted = false
    @State private var isAISidebarInsetApplied = false
    @State private var aiSidebarTransitionGeneration = 0
    @State private var aiSidebarUITestingState = ""
    @State private var aiSidebarResizeStartWidth: CGFloat?
    @State private var miniPlayerOrigin: CGPoint?
    @State private var miniPlayerExpandedSize = MiniPlayerLayout.defaultExpandedSize
    @SceneStorage("candoa.aiSidebarWidth") private var aiSidebarWidth = 480.0
    private let sidebarWidth = CandoaChromeStyle.sidebarWidth
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
                WebViewContainer(
                    store: store,
                    visibleChromeInsets: BrowserChromeInsets(
                        leading: isSidebarVisible ? sidebarTotalWidth : 0,
                        trailing: isAISidebarInsetApplied ? currentAISidebarWidth : 0
                    )
                )
                    .ignoresSafeArea(.container, edges: .top)
                    // A pinned sidebar (Cmd-S) pushes the content aside; the
                    // hover-reveal stays a pure overlay so a quick peek never
                    // resizes the page. The inset is intentionally not animated:
                    // animating it would resize the WKWebView frame every frame
                    // (battery cost), so the content reflows once while the
                    // sidebar slides into the reserved gap.
                    // WebKit reserves each chrome lane once through native
                    // obscured-content insets while the WKWebView itself remains
                    // full-window. Resizing its remote viewport here would expose
                    // the opposite edge for a frame while WebKit repaints.

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
                    // inset above. Only the overlay hover reveal may slide;
                    // otherwise the sidebar temporarily separates from content.
                    .animation(.easeOut(duration: 0.18), value: isSidebarHoverRevealed)
                    .zIndex(2)

                if isAISidebarMounted {
                    aiSidebarLayout(width: currentAISidebarWidth)
                        .transition(.identity)
                        .zIndex(3)
                }
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
                    let trailingInset = isAISidebarInsetApplied ? currentAISidebarWidth : 0
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

                if let toast = store.copiedURLToast {
                    CopiedURLToastView(
                        toast: toast,
                        themeColorHex: store.activeThemeColorHexes.first,
                        onShareInteractionChanged: { store.setCopiedURLToastSharing($0) }
                    )
                    .onHover { store.setCopiedURLToastHovered($0) }
                    .padding(.top, CopiedURLToastView.windowEdgeSpacing)
                    .padding(.trailing, CopiedURLToastView.windowEdgeSpacing)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.01, anchor: .top),
                        removal: .scale(scale: 0.5, anchor: .top).combined(with: .opacity)
                    ))
                    .id(toast.id)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottomTrailing) {
            if BrowserStore.isUITesting {
                let stateDescription = store.uiTestingStateDescription(sidebarVisible: isSidebarVisible)
                    + ";aiVisible=\(isAISidebarVisible);aiMounted=\(isAISidebarMounted)"

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
                store.showFindBar()
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
            updateService.startCheckingForUpdates()
        }
        .onOpenURL { url in
            store.openExternalURL(url)
        }
        .onDisappear {
            store.flushSession()
            updateService.stopCheckingForUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushSession()
            }
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

    private var browserCommandActions: BrowserCommandActions {
        BrowserCommandActions(
            newTab: openNewTabFlow,
            focusAddressBar: store.focusAddressBar,
            openCommandPalette: store.openCommandPalette,
            toggleSidebar: toggleSidebar,
            toggleAISidebar: toggleAISidebar,
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
            clearUnpinnedTabs: store.clearUnpinnedTabs,
            copyURL: { store.copyActiveTabURL() },
            copyURLAsMarkdown: { store.copyActiveTabURL(asMarkdown: true) },
            findInPage: store.showFindBar,
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
            setHistoryICloudSyncEnabled: store.setHistoryICloudSyncEnabled
        )
    }

    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                availableUpdate: updateService.availableUpdate,
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
        .overlay(alignment: .trailing) {
            if isSidebarPresented {
                Rectangle()
                    .fill(CandoaChromeStyle.sidebarSeparator)
                    .frame(width: 1)
                    .allowsHitTesting(false)
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
        EliSidebarView(store: store, uiTestingState: $aiSidebarUITestingState) {
            toggleAISidebar()
        }
        .frame(width: width)
        .overlay(alignment: .leading) {
            AISidebarResizeHandle(isResizing: aiSidebarResizeStartWidth != nil)
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
                        }
                )
        }
    }

    private func aiSidebarLayout(width: CGFloat) -> some View {
        aiSidebarPanel(width: width)
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .ignoresSafeArea(.container, edges: .top)
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

    private func openAISidebar() {
        guard !isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1
        let generation = aiSidebarTransitionGeneration

        isAISidebarVisible = true
        isAISidebarMounted = true

        // Let the native panel commit before WebKit reserves its lane. The
        // panel briefly overlays the page, so an empty strip can never appear.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard aiSidebarTransitionGeneration == generation,
                      isAISidebarVisible,
                      isAISidebarMounted else { return }
                isAISidebarInsetApplied = true
            }
        }
    }

    private func closeAISidebar() {
        guard isAISidebarVisible else { return }
        aiSidebarTransitionGeneration += 1
        let generation = aiSidebarTransitionGeneration

        aiSidebarResizeStartWidth = nil
        isAISidebarVisible = false
        isAISidebarInsetApplied = false

        // Expand the page behind the panel first, then release the panel after
        // SwiftUI has committed the unobscured WebKit layout.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard aiSidebarTransitionGeneration == generation,
                      !isAISidebarVisible else { return }
                isAISidebarMounted = false
            }
        }
    }

    private func clampedAISidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, AISidebarLayout.minWidth), AISidebarLayout.maxWidth)
    }

    private func openNewTabFlow() {
        store.openNewTabCommandPalette()
    }

    private func addSplitView() {
        guard !store.isSplitViewEnabled else { return }
        store.toggleSplitView()
    }

    private func closeTabOrWindow() {
        if store.visibleTabsForActiveSpace.count > 1 {
            store.closeCurrentTab()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}
