import AppKit
import Combine
import Foundation
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
}

struct SplitTabDropPreview: Equatable {
    var targetTabID: UUID
    var side: SplitTabDropSide
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

enum PinnedCloseShortcutBehavior: String {
    case resetUnloadSwitch = "reset-unload-switch"
    case unloadSwitch = "unload-switch"
    case resetSwitch = "reset-switch"
    case switchOnly = "switch"
    case resetOnly = "reset"
    case close = "close"

    init(settingValue: String?) {
        self = settingValue.flatMap(Self.init(rawValue:)) ?? .resetUnloadSwitch
    }

    var resetsURL: Bool {
        switch self {
        case .resetUnloadSwitch, .resetSwitch, .resetOnly:
            return true
        case .unloadSwitch, .switchOnly, .close:
            return false
        }
    }

    var unloadsWebView: Bool {
        switch self {
        case .resetUnloadSwitch, .unloadSwitch:
            return true
        case .resetSwitch, .switchOnly, .resetOnly, .close:
            return false
        }
    }

    var switchesToNextTab: Bool {
        switch self {
        case .resetUnloadSwitch, .unloadSwitch, .resetSwitch, .switchOnly:
            return true
        case .resetOnly, .close:
            return false
        }
    }
}

enum InitialOnboardingStep: String, CaseIterable {
    case welcome
    case account
    case importData
    case space
    case tour

    static let numberedSetupSteps: [Self] = [.importData, .space, .account]

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
        let isFavorite: Bool
        let isPinned: Bool
        let spaceID: UUID
    }

    static let spaceNameCharacterLimit = 24
    static let splitViewMaxTabs = 4
    static let sidebarDropSettleDelayNanoseconds: UInt64 = 480_000_000
    static let onboardingStepKey = "Candoa.InitialOnboarding.Step"
    static let hasCompletedOnboardingKey = "Candoa.InitialOnboarding.Completed"
    static let hasCompletedTourKey = "Candoa.InitialOnboarding.TourCompleted"

    var ignoresPendingTabsWhenCycling: Bool {
        boolSetting(CandoaSettingsOption.ignorePendingTabsWhenCycling, default: false)
    }

    var scopesControlTabToCurrentGroup: Bool {
        boolSetting(CandoaSettingsOption.ctrlTabCyclesWithinScope, default: false)
    }

    var selectsRecentlyUsedTabOnClose: Bool {
        boolSetting(CandoaSettingsOption.selectRecentlyUsedOnClose, default: true)
    }

    var pinnedCloseShortcutBehavior: PinnedCloseShortcutBehavior {
        PinnedCloseShortcutBehavior(
            settingValue: UserDefaults.standard.string(forKey: CandoaSettingsOption.pinnedCloseShortcutBehavior)
        )
    }

    var defaultSearchProviderID: String? {
        UserDefaults.standard.string(forKey: CandoaSettingsOption.defaultSearchProvider)
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
    @Published var isSplitViewEnabled = false
    @Published var isCommandPalettePresented = false
    @Published var commandPaletteInitialText = ""
    @Published var commandPaletteResumeQuery = ""
    @Published var commandPaletteSessionID = UUID()
    @Published var commandPalettePrefersCurrentTabNavigation = false
    @Published var commandPaletteWasOpenedFromSidebarAddress = false
    @Published var commandPaletteOpensNewTab = false
    @Published var isCreateSpacePresented = false
    @Published var editingSpaceID: UUID?
    @Published var editingFolderID: UUID?
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
    @Published var isTabSwitcherPresented = false
    @Published var tabSwitcherTabs: [BrowserTab] = []
    @Published var tabSwitcherSelectedTabID: UUID?
    @Published var canGoBack = false
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
    @Published var mediaStates: [UUID: TabMediaState] = [:]
    @Published var mediaControllerTabID: UUID?
    @Published var dismissedMiniPlayerTabID: UUID?
    @Published var retainedPausedMiniPlayerTabID: UUID?
    @Published var iCloudWorkspaceSyncEnabled =
        CandoaCloudKitEntitlements.hasConfiguredContainer && CandoaSyncPreferences.syncsWorkspaceWithICloud
    @Published var iCloudHistorySyncEnabled =
        CandoaCloudKitEntitlements.hasConfiguredContainer && CandoaSyncPreferences.syncsHistoryWithICloud
    @Published var syncRestartMessage: String?
    @Published var copiedURLToast: CopiedURLToast?
    @Published var uiTestingVisibleFolderPopoverDescription = "none"
    @Published var uiTestingCommandPaletteQuery = ""
    @Published var uiTestingLastCommandDescription = "none"

    /// Deliberately not @Published: it's consumed by the mini player's mount
    /// (which the activeTabID change already triggers), and publishing it
    /// would cause a redundant view update per tab switch.
    var pendingMiniPlayerSummon: MiniPlayerSummonContext?

    @Published var miniPlayerReturn: MiniPlayerReturnContext?

    var recentlyClosedTabs: [ClosedTabSnapshot] = []
    static let recentlyClosedTabLimit = 50

    let navigationService: NavigationService
    let webCoordinator: WebViewCoordinator

    let persistenceService: PersistenceService
    let workspaceRepository: any WorkspaceRepository
    let historyRepository: any HistoryRepository
    let faviconService: FaviconService
    let browserImportService: BrowserImportService
    var saveCancellable: AnyCancellable?
    var remoteChangeCancellable: AnyCancellable?
    var tabSwitcherHideWorkItem: DispatchWorkItem?
    var tabSwitcherShowWorkItem: DispatchWorkItem?
    var copiedURLToastHideWorkItem: DispatchWorkItem?
    var isCopiedURLToastSharing = false
    var tabSwitcherCandidates: [BrowserTab] = []
    /// True from the first Control-Tab press until the interaction commits
    /// (Control release or auto-hide). The overlay can outlive the
    /// interaction by its fade-out; this is the state that must not.
    var isTabSwitcherCycling = false
    /// The mini player's return morph defers the actual switch; until it
    /// lands, recency cycling must treat the destination as current or a
    /// rapid Ctrl-Tab walks past it into the wrong tab.
    var pendingMiniPlayerReturnTabID: UUID?
    var isApplyingRemoteState = false
    var needsWorkspaceSaveAfterRepair = false
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
        BrowserSpace.defaultThemeColorHex,
        "#74E0AA",
        "#E0A84F",
        "#DA6A72",
        "#9B7BE5",
        "#5CA8D8",
        "#D17FB3",
        "#8E9A5B"
    ]

    init(
        persistenceService: PersistenceService = .shared,
        workspaceRepository: (any WorkspaceRepository)? = nil,
        historyRepository: (any HistoryRepository)? = nil,
        navigationService: NavigationService = .shared,
        faviconService: FaviconService = .shared,
        browserImportService: BrowserImportService? = nil,
        webCoordinator: WebViewCoordinator = WebViewCoordinator(),
        restoresWebViews: Bool = true
    ) {
        self.persistenceService = persistenceService
        self.workspaceRepository = workspaceRepository ?? CoreDataWorkspaceRepository(persistence: persistenceService)
        self.historyRepository = historyRepository ?? CoreDataHistoryRepository(persistence: persistenceService)
        self.navigationService = navigationService
        self.faviconService = faviconService
        self.browserImportService = browserImportService
            ?? Self.uiTestingBrowserImportService()
            ?? BrowserImportService()
        self.webCoordinator = webCoordinator

        let restoredState = Self.uiTestingFixtureState() ?? self.workspaceRepository.loadWorkspace()
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
                    includesActiveTabID: true
                )
                : []
            isSplitViewEnabled = restoredState.isSplitViewEnabled && splitTabIDs.count >= 2
        } else {
            // New workspaces start neutral while following the system's
            // light or dark appearance. Candoa blue is the action accent.
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
            isSplitViewEnabled = false
            shouldPresentInitialSpaceSetup = restoredState?.spaces.isEmpty ?? true
        }

        self.webCoordinator.attach(store: self)
        repairSessionState()
        markActiveTabAsActivated()
        shouldPresentInitialSpaceSetup = shouldPresentInitialSpaceSetup || needsInitialSpaceSetup()
        if let uiTestingOnboardingStep = Self.uiTestingOnboardingStep {
            setInitialOnboardingStep(uiTestingOnboardingStep, persists: false)
        } else if Self.isUITesting {
            setInitialOnboardingStep(nil, persists: false)
        } else if shouldPresentInitialSpaceSetup {
            let storedStep = UserDefaults.standard.string(forKey: Self.onboardingStepKey)
                .flatMap(InitialOnboardingStep.init(rawValue:))
            let resumableStep: InitialOnboardingStep
            switch storedStep {
            case .account where CandoaAccountKeychain.accessToken != nil
                || !CandoaDistributionCapabilities.supportsNativeAppleSignIn:
                resumableStep = .tour
            case .tour:
                resumableStep = .space
            case .welcome, .account, .importData, .space:
                resumableStep = storedStep ?? .welcome
            case .none:
                resumableStep = .welcome
            }
            setInitialOnboardingStep(resumableStep)
        } else if !UserDefaults.standard.bool(forKey: Self.hasCompletedTourKey),
                  UserDefaults.standard.string(forKey: Self.onboardingStepKey) == InitialOnboardingStep.tour.rawValue {
            setInitialOnboardingStep(.tour)
        } else if CandoaAccountKeychain.accessToken == nil,
                  CandoaDistributionCapabilities.supportsNativeAppleSignIn {
            setInitialOnboardingStep(.account)
        }
        if restoresWebViews {
            restoreVisibleWebViews()
        }
        updateNavigationState()
        configureAutosave()
        configureRemoteSyncObservation()
        if needsWorkspaceSaveAfterRepair {
            needsWorkspaceSaveAfterRepair = false
            flushSession()
        }
    }

}
