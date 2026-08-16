import AppKit
import Combine
import Foundation
import Network
import SwiftUI

struct TabMediaState: Equatable {
    var hasMedia = false
    var isPlaying = false
    var isMuted = false
    var isMiniPlayerEligible = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// Where the video sits in the page's viewport (web view coordinates),
    /// captured while the page still has its real layout. Lets the floating
    /// mini player morph out from the video's actual on-page position.
    var pageVideoFrame: CGRect?
}

/// Snapshot taken at the moment the user switches away from the playing tab,
/// so the summoned mini player can animate from where the video was.
struct MiniPlayerSummonContext {
    var pageVideoFrame: CGRect?
}

/// Drives the return-to-tab morph: the floating player swaps to a freeze
/// frame of its video, glides back over the video's on-page rect while the
/// restored page lays itself out hidden underneath, and the actual tab
/// switch lands on an already-settled page (no top-left relayout flash).
struct MiniPlayerReturnContext {
    let tabID: UUID
    let updatesAccessTime: Bool
    let snapshot: NSImage?
    let targetFrame: CGRect?
}

enum SidebarTabDropPlacement: Equatable {
    case favorites
    case pinned
    case regular
    case folder(UUID)
}

enum SidebarTabDropEdge: Equatable {
    case before
    case split
    case after
}

enum SplitTabDropSide: Equatable {
    case leading
    case trailing
    case top
    case bottom

    /// Leading/top edges insert the dragged tab before the target pane;
    /// trailing/bottom edges insert after it.
    var insertsBeforeTarget: Bool {
        self == .leading || self == .top
    }

    /// Top/bottom drops ask for stacked rows; leading/trailing for columns.
    var isVerticalAxis: Bool {
        self == .top || self == .bottom
    }
}

struct SplitTabDropPreview: Equatable {
    var targetTabID: UUID
    var side: SplitTabDropSide
}

/// A Space switch asked for from outside the sidebar, which owns the
/// transition between Spaces.
struct SpaceSelectionRequest: Equatable {
    let requestID = UUID()
    let spaceID: UUID
}

struct SidebarTabDropIndicator: Equatable {
    var placement: SidebarTabDropPlacement
    var targetTabID: UUID?
    var edge: SidebarTabDropEdge
}

struct SidebarDroppedTabSource: Equatable {
    var tabID: UUID
    var placement: SidebarTabDropPlacement
}

enum InitialOnboardingStep: String, CaseIterable {
    case welcome
    case account
    case importData
    case space
    /// Where the address lives — sidebar pill (default) or a strip above
    /// the page. Asked once, changeable in Settings ▸ General.
    case addressBar
    case tour
    /// A CloudKit restore refilled this Mac with an existing workspace while
    /// first-run setup was still on screen. Replaces the new-user wizard with
    /// a welcome-back acknowledgment; the person already has their Spaces.
    case restoredWorkspace

    static let numberedSetupSteps: [Self] = [.importData, .space, .addressBar, .account]

    var position: Int {
        Self.numberedSetupSteps.firstIndex(of: self).map { $0 + 1 } ?? 0
    }

    var count: Int { Self.numberedSetupSteps.count }
}

enum InitialTourTip: Int, CaseIterable {
    case commandBar
    case spaces
    case ask
}

@MainActor
final class BrowserStore: ObservableObject {
    struct ClosedTabSnapshot {
        let url: URL
        /// Kept so the History menu can name the tab the way it was titled,
        /// rather than falling back to its host.
        let title: String
        let isFavorite: Bool
        let isPinned: Bool
        let spaceID: UUID
    }

    /// Chrome-tint blend state for in-flight Space swipes. A separate
    /// observable so per-frame gesture updates invalidate only the window
    /// backdrop, never every store observer.
    let chromeTransition = SpaceChromeTransition()

    static let spaceNameCharacterLimit = 24
    static let splitViewMaxTabs = 4
    static let sidebarDropSettleDelayNanoseconds: UInt64 = 480_000_000
    static let onboardingStepKey = "Candoa.InitialOnboarding.Step"
    static let hasCompletedOnboardingKey = "Candoa.InitialOnboarding.Completed"
    static let hasCompletedTourKey = "Candoa.InitialOnboarding.TourCompleted"

    var selectsRecentlyUsedTabOnClose: Bool {
        boolSetting(SettingsOption.selectRecentlyUsedOnClose, default: true)
    }

    var defaultSearchProviderID: String? {
        UserDefaults.standard.string(forKey: SettingsOption.defaultSearchProvider)
    }

    func boolSetting(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }

    @Published var spaces: [BrowserSpace]
    @Published var folders: [BrowserFolder]
    @Published var tabs: [BrowserTab]
    @Published var activeSpaceID: UUID
    @Published var activeTabID: UUID? {
        didSet {
            guard oldValue != activeTabID else { return }
            markActiveTabAsActivated()
            handleActiveTabChange(from: oldValue)
        }
    }
    @Published var splitTabIDs: [UUID] = []
    /// Width fractions for the split panes, parallel to `splitTabIDs` and
    /// normalized to sum to 1. Empty whenever no split group exists.
    @Published var splitPaneRatios: [Double] = []
    /// How the split group's panes are arranged (columns, rows, or a grid).
    @Published var splitLayout: SplitViewLayout = .horizontal
    @Published var isSplitViewEnabled = false
    /// The focused pane fills the surface alone while the split stays intact
    /// behind it. Deliberately not part of `BrowserWindowState`: zoom is a
    /// way of looking at a split, not a property of it, so it never persists
    /// and never syncs — a relaunch comes back to every pane on screen. Read
    /// through `zoomedSplitTabID` / `isSplitPaneZoomed`, which validate it
    /// against the displayed group.
    @Published var isSplitPaneZoomRequested = false
    /// Domains with service-worker registrations in the active window's data
    /// store, for Develop ▸ Service Workers; refreshed as the menu bar opens.
    /// Split groups stashed per Space while another Space is frontmost, so
    /// switching away and back revives the split. In-memory only: the
    /// persisted window state carries the frontmost Space's split.
    var suspendedSplitStatesBySpace: [UUID: SuspendedSplitState] = [:]
    @Published var isCommandPalettePresented = false
    @Published var commandPaletteInitialText = ""
    @Published var commandPaletteResumeQuery = ""
    @Published var commandPaletteSessionID = UUID()
    @Published var commandPalettePrefersCurrentTabNavigation = false
    @Published var commandPaletteWasOpenedFromSidebarAddress = false
    @Published var commandPaletteOpensNewTab = false
    /// The palette is choosing what to split the current pane with: rows are
    /// the Space's other tabs (a pick joins the split) and a typed address
    /// opens in a fresh pane. Keyboard route to what a sidebar drag does.
    @Published var commandPaletteSplitsWithSelection = false
    @Published var isCreateSpacePresented = false
    @Published var isDownloadsPopoverPresented = false
    @Published var isSiteInfoPopoverPresented = false
    @Published var isPrivacyReportPresented = false
    /// Transient reader-mode mirrors, written by the web coordinator: which
    /// tabs' pages qualify for Reader, and which are showing it right now.
    /// Never persisted — reader state belongs to the live web view.
    @Published var readerAvailableTabIDs: Set<UUID> = []
    @Published var readerActiveTabIDs: Set<UUID> = []
    @Published var editingSpaceID: UUID?
    @Published var editingFolderID: UUID?
    /// Spaces whose pinned area is folded away behind the Space header, the
    /// way Arc collapses a Space's pinned tabs when its title is clicked.
    /// A view preference, not workspace state: kept in UserDefaults, never
    /// synced.
    @Published var collapsedPinnedSpaceIDs: Set<UUID> = BrowserStore.loadCollapsedPinnedSpaceIDs() {
        didSet { BrowserStore.saveCollapsedPinnedSpaceIDs(collapsedPinnedSpaceIDs) }
    }
    @Published var initialOnboardingStep: InitialOnboardingStep?
    @Published var initialTourTip: InitialTourTip?
    @Published var preparingInitialTourTip: InitialTourTip?
    var initialTourReturnTabID: UUID? = nil
    @Published var spaceThemeAppearancePreview: SpaceThemeAppearance?
    @Published var isSpaceThemeColorPreviewActive = false
    @Published var spaceThemeColorHexPreview: String?
    @Published var spaceThemeAuxiliaryHexPreviews: [String] = []
    @Published var spaceThemeOpacityPreview: Double?
    @Published var spaceThemeTexturePreview: Double?
    @Published var addressFocusRequestID = UUID()
    /// A Space switch asked for from outside the sidebar — the menu, or a
    /// keyboard shortcut. The sidebar owns the swipe transition between
    /// Spaces, so it fulfils these and animates them like its own clicks.
    @Published var spaceSelectionRequest: SpaceSelectionRequest?

    /// Bumped when something outside the window asks for the full-window
    /// History view to close — opening a page from the History menu, where
    /// leaving the view up would hide the page that was just opened.
    @Published var historyDismissRequestID = UUID()
    @Published var isTabSwitcherPresented = false
    @Published var tabSwitcherTabs: [BrowserTab] = []
    @Published var tabSwitcherSelectedTabID: UUID?
    /// Preview thumbnails captured from the first Control-Tab press, so the
    /// hold-to-reveal delay doubles as capture time and the overlay appears
    /// already populated. Kept across interactions: a stale-but-instant
    /// thumbnail beats an empty card, and a fresh capture replaces it.
    @Published var tabSwitcherSnapshots: [UUID: NSImage] = [:]
    @Published var canGoBack = false
    /// Whether the active tab can jump back to the search results it came
    /// from. Refreshed alongside canGoBack, because the back list itself
    /// publishes nothing when it changes.
    @Published var canReturnToSearchResults = false
    @Published var canGoForward = false
    @Published var draggedTabID: UUID?
    @Published var sidebarDropIndicator: SidebarTabDropIndicator?
    @Published var splitDropPreview: SplitTabDropPreview?
    @Published var settlingDroppedTabID: UUID?
    @Published var settlingDroppedTabSource: SidebarDroppedTabSource?
    var tabDragSessionWatcher: Timer?
    var dropSourceClearTask: Task<Void, Never>?
    @Published var isFindBarPresented = false
    @Published var findQuery = ""
    /// Bumped every time Find in Page is invoked. The find field watches this
    /// rather than its own `onAppear` so a second Command-F — when the bar is
    /// already up — refocuses and selects the query, the way Safari does.
    @Published var findFocusRequestID = UUID()
    /// Bumped when something outside the window chrome asks for Eli — the
    /// developer bar's Chat button. Sidebar visibility itself lives in the
    /// view that owns the layout.
    @Published var aiSidebarToggleRequestID = UUID()
    /// Position of the current match among all of them, or nil when there is
    /// nothing to count yet — an empty query, or a page the in-page find
    /// engine could not tally.
    @Published var findTally: WebViewCoordinator.FindTally?
    /// Resolved destination of the link under the pointer in a visible pane,
    /// shown as a transient pill over the page's bottom-leading corner.
    @Published var hoveredLinkHref: String?
    /// Navigation and WebContent failures that need recovery UI, per tab.
    /// Entries clear when a navigation commits content again.
    @Published var tabLoadFailures: [UUID: TabLoadFailure] = [:]
    /// Exists only while an offline failure is on screen, so reconnection
    /// can retry automatically; cancelled the moment no offline failure
    /// remains. Never runs during normal browsing.
    var offlineRecoveryMonitor: NWPathMonitor?
    var offlineMonitorSawUnsatisfiedPath = false
    @Published var mediaStates: [UUID: TabMediaState] = [:]
    @Published var mediaControllerTabID: UUID?
    @Published var dismissedMiniPlayerTabID: UUID?
    @Published var retainedPausedMiniPlayerTabID: UUID?
    @Published var copiedURLToast: CopiedURLToast?
    @Published var uiTestingVisibleFolderPopoverDescription = "none"
    @Published var uiTestingCommandPaletteQuery = ""
    @Published var uiTestingLastCommandDescription = "none"
    /// A tab drag is over the Space header. Kept by the drag *source*, from
    /// the pointer's screen position, because the header's platform view is
    /// unreachable to AppKit's destination search — see
    /// TabDragSourceAnchorView.
    @Published var isSpaceHeaderDropTargeted = false
    @Published var uiTestingWebsiteAppearanceDescription = "pending"
    @Published var uiTestingPopupDiagnostics: [String] = []
    @Published var uiTestingWebAuthEvents: [String] = []

    /// Tabs created locally since the last snapshot save. A remote-state
    /// apply must not drop these: they exist only in memory, so a snapshot
    /// loaded mid-race (e.g. a CloudKit import seconds after a sign-in popup
    /// opens) predates them and would otherwise silently destroy them.
    var unsyncedLocalTabIDs: Set<UUID> = []

    /// Deliberately not @Published: it's consumed by the mini player's mount
    /// (which the activeTabID change already triggers), and publishing it
    /// would cause a redundant view update per tab switch.
    var pendingMiniPlayerSummon: MiniPlayerSummonContext?

    @Published var miniPlayerReturn: MiniPlayerReturnContext?

    var recentlyClosedTabs: [ClosedTabSnapshot] = []
    static let recentlyClosedTabLimit = 50

    /// The inspector-dependent Develop-menu state as of the last menu-bar
    /// open (or menu-driven toggle); see
    /// `refreshDevelopMenuIfInspectorStateDrifted()`. Not published — it
    /// exists to decide whether a nudge is needed, never to drive views.
    var lastTrackedInspectorMenuState = [false, false, false]

    /// Private-browsing mode: web content runs against a non-persistent
    /// data store, and nothing this store does is written anywhere —
    /// no workspace snapshot, no history, no CloudKit, no restoration.
    ///
    /// Policy for the explicit surfaces:
    /// - Downloads and page captures still land in ~/Downloads: they are
    ///   deliberate user acts that produce a file, exactly as in Safari.
    /// - Sharing and copy-URL remain available for the same reason.
    /// - Printing: not implemented anywhere yet (issue #31); when it lands
    ///   it inherits this policy (allowed, no persisted print history).
    /// - Passkeys/WebAuthn stay available: credentials are OS-mediated and
    ///   never touch the site data store.
    let isPrivate: Bool

    let navigationService: NavigationService
    let webCoordinator: WebViewCoordinator
    /// Ordinary windows share the app-wide list; a private window owns an
    /// ephemeral one so its downloads never surface elsewhere or persist.
    let downloadsStore: DownloadsStore

    let persistenceService: PersistenceService
    let workspaceRepository: any WorkspaceRepository
    let historyRepository: any HistoryRepository
    let faviconService: FaviconService
    let browserImportService: BrowserImportService
    var saveCancellable: AnyCancellable?
    var remoteChangeCancellable: AnyCancellable?
    var uiTestingRemoteRestoreCancellable: AnyCancellable?
    var uiTestingWebAuthEventCancellable: AnyCancellable?
    var downloadsChangeCancellable: AnyCancellable?
    var uiTestingDownloadFixtureCancellable: AnyCancellable?
    var uiTestingTabSwitcherCancellable: AnyCancellable?
    var tabSwitcherHideWorkItem: DispatchWorkItem?
    var tabSwitcherShowWorkItem: DispatchWorkItem?
    var copiedURLToastHideWorkItem: DispatchWorkItem?
    var isCopiedURLToastSharing = false
    var tabSwitcherCandidates: [BrowserTab] = []
    /// True from the first Control-Tab press until the interaction commits
    /// (Control release or auto-hide). The overlay can outlive the
    /// interaction by its fade-out; this is the state that must not.
    var isTabSwitcherCycling = false
    /// One sweep of stale persisted thumbnails per run, deferred to the
    /// first switcher interaction so launch does no snapshot disk work.
    var hasPrunedPersistedTabSnapshots = false
    /// The mini player's return morph defers the actual switch; until it
    /// lands, recency cycling must treat the destination as current or a
    /// rapid Ctrl-Tab walks past it into the wrong tab.
    var pendingMiniPlayerReturnTabID: UUID?
    var isApplyingRemoteState = false
    var needsWorkspaceSaveAfterRepair = false
    /// One in-flight memory extraction per Space; a second conversation
    /// ending while one runs is skipped rather than queued.
    var eliMemoryExtractionTasks: [UUID: Task<Void, Never>] = [:]
    /// Transcript length at the last extraction per Space, so reopening and
    /// re-closing an unchanged conversation never re-extracts it.
    var eliMemoryLastExtractedTurnCounts: [UUID: Int] = [:]
    let spaceSymbols = [
        "circle.grid.2x2",
        "sparkle",
        "briefcase",
        "house",
        "paintpalette",
        "graduationcap",
        "bolt",
        "leaf"
    ]
    let spaceThemeColors = [
        BrowserSpace.blueThemeColorHex,
        "#74E0AA",
        "#E0A84F",
        "#DA6A72",
        "#9B7BE5",
        "#5CA8D8",
        "#D17FB3",
        "#8E9A5B"
    ]

    init(
        isPrivate: Bool = false,
        persistenceService: PersistenceService = .shared,
        workspaceRepository: (any WorkspaceRepository)? = nil,
        historyRepository: (any HistoryRepository)? = nil,
        navigationService: NavigationService = .shared,
        faviconService: FaviconService? = nil,
        browserImportService: BrowserImportService? = nil,
        webCoordinator: WebViewCoordinator? = nil,
        restoresWebViews: Bool = true
    ) {
        self.isPrivate = isPrivate
        self.persistenceService = persistenceService
        self.workspaceRepository = workspaceRepository ?? (isPrivate
            ? EphemeralWorkspaceRepository()
            : CoreDataWorkspaceRepository(persistence: persistenceService))
        self.historyRepository = historyRepository ?? (isPrivate
            ? PrivateBrowsingHistoryRepository(base: CoreDataHistoryRepository(persistence: persistenceService))
            : CoreDataHistoryRepository(persistence: persistenceService))
        self.navigationService = navigationService
        self.faviconService = faviconService ?? (isPrivate ? .makeEphemeral() : .shared)
        self.browserImportService = browserImportService
            ?? Self.uiTestingBrowserImportService()
            ?? BrowserImportService()
        self.webCoordinator = webCoordinator ?? WebViewCoordinator(isPrivate: isPrivate)
        self.downloadsStore = isPrivate ? DownloadsStore() : .shared

        // Private windows never restore anything — not the persisted
        // workspace, and not a UI-testing fixture either: fixtures describe
        // the ordinary window's world.
        let restoredState = isPrivate
            ? nil
            : Self.uiTestingFixtureState() ?? self.workspaceRepository.loadWorkspace()
        var shouldPresentInitialSpaceSetup = false

        if let restoredState, !restoredState.spaces.isEmpty {
            spaces = restoredState.spaces
            folders = restoredState.folders
            tabs = restoredState.tabs
            activeSpaceID = restoredState.spaces.contains(where: { $0.id == restoredState.activeSpaceID })
                ? restoredState.activeSpaceID
                : restoredState.spaces[0].id
            activeTabID = restoredState.tabs.contains(where: { $0.id == restoredState.activeTabID })
                ? restoredState.activeTabID
                : restoredState.tabs.first(where: { $0.spaceID == activeSpaceID })?.id
            splitTabIDs = restoredState.isSplitViewEnabled
                ? Self.validSplitGroupIDs(
                    restoredState.splitTabIDs,
                    activeTabID: activeTabID,
                    activeSpaceID: activeSpaceID,
                    tabs: restoredState.tabs,
                    // Legacy sessions stored only the non-active members (one
                    // ID for a two-pane split); newer sessions store the full
                    // group, which may be suspended with the active tab
                    // outside it — the active tab must not be absorbed then.
                    includesActiveTabID: restoredState.splitTabIDs.count < 2
                )
                : []
            isSplitViewEnabled = restoredState.isSplitViewEnabled && splitTabIDs.count >= 2
            splitPaneRatios = isSplitViewEnabled
                ? Self.paneRatios(
                    for: splitTabIDs,
                    carriedFrom: restoredState.splitTabIDs,
                    previousRatios: restoredState.splitPaneRatios
                )
                : []
            splitLayout = isSplitViewEnabled
                ? SplitViewLayout(rawValue: restoredState.splitLayout) ?? .horizontal
                : .horizontal
        } else {
            // New workspaces start neutral while following the system's
            // light or dark appearance. Blue remains an optional Space theme.
            let defaultSpace = BrowserSpace(
                name: "",
                symbolName: "circle.grid.2x2",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            spaces = [defaultSpace]
            folders = []
            tabs = []
            activeSpaceID = defaultSpace.id
            activeTabID = nil
            splitTabIDs = []
            splitPaneRatios = []
            splitLayout = .horizontal
            isSplitViewEnabled = false
            shouldPresentInitialSpaceSetup = !isPrivate && (restoredState?.spaces.isEmpty ?? true)
        }

        self.webCoordinator.attach(store: self)
        self.webCoordinator.updateWebsiteAppearance(
            WebsiteAppearance(
                storedValue: UserDefaults.standard.string(forKey: SettingsOption.websiteAppearance)
            ),
            systemUsesDarkAppearance: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        )
        repairSessionState()
        markActiveTabAsActivated()
        shouldPresentInitialSpaceSetup = !isPrivate
            && (shouldPresentInitialSpaceSetup || needsInitialSpaceSetup())
        let storedOnboardingStep = UserDefaults.standard.string(forKey: Self.onboardingStepKey)
            .flatMap(InitialOnboardingStep.init(rawValue:))
        let hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: Self.hasCompletedOnboardingKey
        )
        if isPrivate {
            // Onboarding belongs to the ordinary window; a private window is
            // always ready to browse and persists no onboarding progress.
            setInitialOnboardingStep(nil, persists: false)
        } else if let uiTestingOnboardingStep = Self.uiTestingOnboardingStep {
            setInitialOnboardingStep(uiTestingOnboardingStep, persists: false)
        } else if Self.isUITesting {
            setInitialOnboardingStep(nil, persists: false)
        } else if !hasCompletedOnboarding,
                  let storedOnboardingStep {
            let resumableStep: InitialOnboardingStep
            switch storedOnboardingStep {
            case .tour:
                resumableStep = shouldPresentInitialSpaceSetup ? .space : .tour
            case .restoredWorkspace:
                // Quit at the welcome-back card: the restored workspace is
                // already in the local store, so show the card again — unless
                // the workspace vanished, which restarts new-user setup.
                resumableStep = shouldPresentInitialSpaceSetup ? .welcome : .restoredWorkspace
            case .welcome, .account, .importData, .space, .addressBar:
                resumableStep = storedOnboardingStep
            }
            setInitialOnboardingStep(resumableStep)
        } else if shouldPresentInitialSpaceSetup {
            setInitialOnboardingStep(.welcome)
        } else if !UserStore.hasStoredAccountDecision {
            // Signing out clears the account decision but deliberately keeps
            // the current session browsing. The next launch returns to the
            // account gate so the Mac regains an explicit account state.
            setInitialOnboardingStep(.account)
        } else {
            if !UserDefaults.standard.bool(forKey: Self.hasCompletedTourKey) {
                setInitialOnboardingStep(.tour)
            } else {
                setInitialOnboardingStep(nil)
            }
        }
        if restoresWebViews {
            restoreVisibleWebViews()
        }
        updateNavigationState()
        if !isPrivate {
            // Private windows neither autosave nor listen for CloudKit
            // deltas — remote state must never stomp an ephemeral session.
            configureAutosave()
            configureRemoteSyncObservation()
        }
        if needsWorkspaceSaveAfterRepair {
            needsWorkspaceSaveAfterRepair = false
            flushSession()
        }
        // The downloads list lives in its own (possibly shared) store;
        // republish its changes so views observing this store — and the
        // UI-testing state element — refresh with it.
        downloadsChangeCancellable = downloadsStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        configureUITestingDownloadFixtureTrigger()
        configureUITestingTabSwitcherTrigger()
        seedUITestingSpaceMemoryIfNeeded()
    }

}
