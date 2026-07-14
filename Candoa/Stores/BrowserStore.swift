import AppKit
import Combine
import Foundation
import SwiftUI
import Vision

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

private struct SidebarDroppedTabSource: Equatable {
    var tabID: UUID
    var placement: SidebarTabDropPlacement
}

private enum PinnedCloseShortcutBehavior: String {
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

@MainActor
final class BrowserStore: ObservableObject {
    private struct ClosedTabSnapshot {
        let url: URL
        let isFavorite: Bool
        let isPinned: Bool
        let spaceID: UUID
    }

    static let spaceNameCharacterLimit = 24
    static let splitViewMaxTabs = 4
    private static let sidebarDropSettleDelayNanoseconds: UInt64 = 480_000_000

    private var ignoresPendingTabsWhenCycling: Bool {
        boolSetting(CandoaSettingsOption.ignorePendingTabsWhenCycling, default: false)
    }

    private var scopesControlTabToCurrentGroup: Bool {
        boolSetting(CandoaSettingsOption.ctrlTabCyclesWithinScope, default: false)
    }

    private var selectsRecentlyUsedTabOnClose: Bool {
        boolSetting(CandoaSettingsOption.selectRecentlyUsedOnClose, default: true)
    }

    private var pinnedCloseShortcutBehavior: PinnedCloseShortcutBehavior {
        PinnedCloseShortcutBehavior(
            settingValue: UserDefaults.standard.string(forKey: CandoaSettingsOption.pinnedCloseShortcutBehavior)
        )
    }

    private var defaultSearchProviderID: String? {
        UserDefaults.standard.string(forKey: CandoaSettingsOption.defaultSearchProvider)
    }

    private func boolSetting(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }

    @Published private(set) var spaces: [BrowserSpace]
    @Published private(set) var folders: [BrowserFolder]
    @Published private(set) var tabs: [BrowserTab]
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
    @Published private(set) var commandPalettePrefersCurrentTabNavigation = false
    @Published private(set) var commandPaletteWasOpenedFromSidebarAddress = false
    @Published private(set) var commandPaletteOpensNewTab = false
    @Published var isCreateSpacePresented = false
    @Published var editingSpaceID: UUID?
    @Published var editingFolderID: UUID?
    @Published private(set) var isInitialSpaceSetupPresented = false
    @Published private(set) var spaceThemeAppearancePreview: SpaceThemeAppearance?
    @Published private(set) var isSpaceThemeColorPreviewActive = false
    @Published private(set) var spaceThemeColorHexPreview: String?
    @Published private(set) var spaceThemeAuxiliaryHexPreviews: [String] = []
    @Published private(set) var spaceThemeOpacityPreview: Double?
    @Published private(set) var spaceThemeTexturePreview: Double?
    @Published var addressFocusRequestID = UUID()
    @Published private(set) var isTabSwitcherPresented = false
    @Published private(set) var tabSwitcherTabs: [BrowserTab] = []
    @Published private(set) var tabSwitcherSelectedTabID: UUID?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var draggedTabID: UUID?
    @Published private(set) var sidebarDropIndicator: SidebarTabDropIndicator?
    @Published private(set) var splitDropPreview: SplitTabDropPreview?
    @Published private var settlingDroppedTabID: UUID?
    @Published private var settlingDroppedTabSource: SidebarDroppedTabSource?
    private var tabDragSessionWatcher: Timer?
    private var dropSourceClearTask: Task<Void, Never>?
    @Published var isFindBarPresented = false
    @Published var findQuery = ""
    @Published var mediaStates: [UUID: TabMediaState] = [:]
    @Published var mediaControllerTabID: UUID?
    @Published var dismissedMiniPlayerTabID: UUID?
    @Published var retainedPausedMiniPlayerTabID: UUID?
    @Published private(set) var iCloudWorkspaceSyncEnabled =
        CandoaCloudKitEntitlements.hasConfiguredContainer && CandoaSyncPreferences.syncsWorkspaceWithICloud
    @Published private(set) var iCloudHistorySyncEnabled =
        CandoaCloudKitEntitlements.hasConfiguredContainer && CandoaSyncPreferences.syncsHistoryWithICloud
    @Published var syncRestartMessage: String?
    @Published private(set) var copiedURLToast: CopiedURLToast?
    @Published private(set) var uiTestingVisibleFolderPopoverDescription = "none"
    @Published private(set) var uiTestingCommandPaletteQuery = ""
    @Published private(set) var uiTestingLastCommandDescription = "none"

    /// Deliberately not @Published: it's consumed by the mini player's mount
    /// (which the activeTabID change already triggers), and publishing it
    /// would cause a redundant view update per tab switch.
    var pendingMiniPlayerSummon: MiniPlayerSummonContext?

    @Published var miniPlayerReturn: MiniPlayerReturnContext?

    private var recentlyClosedTabs: [ClosedTabSnapshot] = []
    private static let recentlyClosedTabLimit = 50

    let navigationService: NavigationService
    let webCoordinator: WebViewCoordinator

    private let persistenceService: PersistenceService
    private let workspaceRepository: any WorkspaceRepository
    private let historyRepository: any HistoryRepository
    private let faviconService: FaviconService
    private var saveCancellable: AnyCancellable?
    private var remoteChangeCancellable: AnyCancellable?
    private var tabSwitcherHideWorkItem: DispatchWorkItem?
    private var tabSwitcherShowWorkItem: DispatchWorkItem?
    private var copiedURLToastHideWorkItem: DispatchWorkItem?
    private var isCopiedURLToastSharing = false
    private var tabSwitcherCandidates: [BrowserTab] = []
    /// True from the first Control-Tab press until the interaction commits
    /// (Control release or auto-hide). The overlay can outlive the
    /// interaction by its fade-out; this is the state that must not.
    private var isTabSwitcherCycling = false
    /// The mini player's return morph defers the actual switch; until it
    /// lands, recency cycling must treat the destination as current or a
    /// rapid Ctrl-Tab walks past it into the wrong tab.
    var pendingMiniPlayerReturnTabID: UUID?
    private var isApplyingRemoteState = false
    private var needsWorkspaceSaveAfterRepair = false
    private let spaceSymbols = [
        "circle.grid.2x2",
        "sparkle",
        "briefcase",
        "house",
        "paintpalette",
        "graduationcap",
        "bolt",
        "leaf"
    ]
    private let spaceThemeColors = [
        "#6E8BFF",
        "#74E0AA",
        "#E0A84F",
        "#DA6A72",
        "#9B7BE5",
        "#5CA8D8",
        "#D17FB3",
        "#8E9A5B"
    ]

    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
    }

    var activeSpace: BrowserSpace? {
        spaces.first { $0.id == activeSpaceID }
    }

    func uiTestingStateDescription(sidebarVisible: Bool) -> String {
        guard Self.isUITesting else { return "" }

        let activeTitle = activeTab?.title ?? "none"
        let activeURL = activeTab?.url?.absoluteString ?? "none"
        let tabTitles = visibleTabsForActiveSpace.map(\.title).joined(separator: "|")
        let folderNames = folders
            .filter { $0.spaceID == activeSpaceID }
            .map(\.name)
            .joined(separator: "|")
        let activeSpaceName = activeSpace?.name ?? "none"

        return [
            "setup=\(isInitialSpaceSetupPresented)",
            "palette=\(isCommandPalettePresented)",
            "newTabPalette=\(isNewTabPaletteActive)",
            "find=\(isFindBarPresented)",
            "sidebar=\(sidebarVisible)",
            "space=\(activeSpaceName)",
            "active=\(activeTitle)",
            "url=\(activeURL)",
            "tabs=\(tabTitles)",
            "folders=\(folderNames)",
            "popover=\(uiTestingVisibleFolderPopoverDescription)",
            "query=\(uiTestingCommandPaletteQuery)",
            "command=\(uiTestingLastCommandDescription)"
        ].joined(separator: ";")
    }

    func setUITestingCommandPaletteQuery(_ query: String) {
        guard Self.isUITesting else { return }
        uiTestingCommandPaletteQuery = query
    }

    func setUITestingLastCommandDescription(_ description: String) {
        guard Self.isUITesting else { return }
        uiTestingLastCommandDescription = description
    }

    func setUITestingFolderPopover(folderName: String, entries: [String]) {
        guard Self.isUITesting else { return }
        uiTestingVisibleFolderPopoverDescription = "\(folderName):\(entries.joined(separator: "|"))"
    }

    func clearUITestingFolderPopover(folderName: String) {
        guard Self.isUITesting else { return }
        if uiTestingVisibleFolderPopoverDescription.hasPrefix("\(folderName):") {
            uiTestingVisibleFolderPopoverDescription = "none"
        }
    }

    var activeThemeColorHexes: [String] {
        if isSpaceThemeColorPreviewActive {
            guard let spaceThemeColorHexPreview else { return [] }
            return [spaceThemeColorHexPreview] + spaceThemeAuxiliaryHexPreviews
        }

        guard !isSpaceSetupPresented else { return [] }
        return activeSpace?.themeColorHex.map { [$0] } ?? []
    }

    var activeThemeOpacity: Double {
        if let spaceThemeOpacityPreview {
            return spaceThemeOpacityPreview
        }

        guard !isSpaceSetupPresented else { return 0.5 }
        return activeSpace?.themeOpacity ?? 0.5
    }

    var activeThemeTexture: Double {
        if let spaceThemeTexturePreview {
            return spaceThemeTexturePreview
        }

        guard !isSpaceSetupPresented else { return 0 }
        return activeSpace?.themeTexture ?? 0
    }

    var activeThemeIntensityMultiplier: Double {
        let normalizedOpacity = (activeThemeOpacity - 0.3) / 0.6
        return min(1.45, max(0.25, 0.25 + normalizedOpacity * 1.2))
    }

    var isSpaceSetupPresented: Bool {
        isCreateSpacePresented || isInitialSpaceSetupPresented || editingSpaceID != nil
    }

    var editingSpace: BrowserSpace? {
        guard let editingSpaceID else { return nil }
        return spaces.first { $0.id == editingSpaceID }
    }

    var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var activeSplitTab: BrowserTab? {
        activeSplitTabs.first
    }

    var activeSplitTabs: [BrowserTab] {
        let activeID = activeTabID
        return splitGroupTabIDs()
            .filter { $0 != activeID }
            .compactMap(tab)
    }

    var activeSplitGroupTabs: [BrowserTab] {
        splitGroupTabIDs().compactMap(tab)
    }

    var activeSplitGroupTabIDs: Set<UUID> {
        Set(splitGroupTabIDs())
    }

    var activeSidebarDropIndicator: SidebarTabDropIndicator? {
        draggedTabID == nil ? nil : sidebarDropIndicator
    }

    var visibleTabsForActiveSpace: [BrowserTab] {
        visibleTabs(in: activeSpaceID)
    }

    var favoriteTabsForActiveSpace: [BrowserTab] {
        tabs
            .filter { $0.spaceID == activeSpaceID && $0.isFavorite }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var pinnedTabsForActiveSpace: [BrowserTab] {
        tabs
            .filter { $0.spaceID == activeSpaceID && $0.folderID == nil && $0.isPinned && !$0.isFavorite }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var foldersForActiveSpace: [BrowserFolder] {
        folders
            .filter { $0.spaceID == activeSpaceID && $0.parentFolderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var folderedTabsForActiveSpace: [BrowserTab] {
        folders
            .filter { $0.spaceID == activeSpaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { folder in
                tabsInFolder(folder.id)
            }
    }

    var regularTabsForActiveSpace: [BrowserTab] {
        tabs
            .filter { $0.spaceID == activeSpaceID && $0.folderID == nil && !$0.isFavorite && !$0.isPinned }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func visibleTabs(in spaceID: UUID) -> [BrowserTab] {
        let favorites = tabs
            .filter { $0.spaceID == spaceID && $0.isFavorite }
            .sorted { $0.sortOrder < $1.sortOrder }
        let pinned = tabs
            .filter { $0.spaceID == spaceID && $0.folderID == nil && $0.isPinned && !$0.isFavorite }
            .sorted { $0.sortOrder < $1.sortOrder }
        let foldered = folders
            .filter { $0.spaceID == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { folder in
                tabsInFolder(folder.id)
            }
        let regular = tabs
            .filter { $0.spaceID == spaceID && $0.folderID == nil && !$0.isFavorite && !$0.isPinned }
            .sorted { $0.sortOrder < $1.sortOrder }

        return favorites + pinned + foldered + regular
    }

    func tabsInFolder(_ folderID: UUID) -> [BrowserTab] {
        tabs
            .filter { $0.folderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func subfolders(in folderID: UUID) -> [BrowserFolder] {
        folders
            .filter { $0.parentFolderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func tabsInFolderTree(_ folderID: UUID) -> [BrowserTab] {
        tabsInFolder(folderID) + subfolders(in: folderID).flatMap { tabsInFolderTree($0.id) }
    }

    private func descendantFolderIDs(of folderID: UUID) -> Set<UUID> {
        subfolders(in: folderID).reduce(into: Set<UUID>()) { result, folder in
            result.insert(folder.id)
            result.formUnion(descendantFolderIDs(of: folder.id))
        }
    }

    init(
        persistenceService: PersistenceService = .shared,
        workspaceRepository: (any WorkspaceRepository)? = nil,
        historyRepository: (any HistoryRepository)? = nil,
        navigationService: NavigationService = .shared,
        faviconService: FaviconService = .shared,
        webCoordinator: WebViewCoordinator = WebViewCoordinator(),
        restoresWebViews: Bool = true
    ) {
        self.persistenceService = persistenceService
        self.workspaceRepository = workspaceRepository ?? CoreDataWorkspaceRepository(persistence: persistenceService)
        self.historyRepository = historyRepository ?? CoreDataHistoryRepository(persistence: persistenceService)
        self.navigationService = navigationService
        self.faviconService = faviconService
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
            // Neutral by default: no theme color, chrome follows the system.
            // The window reads as plain native gray (light or dark per the
            // system); a space color is something the user opts into.
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
        isInitialSpaceSetupPresented = shouldPresentInitialSpaceSetup
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

    private static func uiTestingFixtureState() -> BrowserWindowState? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CANDOA_UI_TESTING"] == "1" else { return nil }
        let fixture = environment["CANDOA_UI_TESTING_FIXTURE"]

        if fixture == "ask" {
            return testingBotFixtureState(includesSeedTabs: false)
        }

        if fixture == "cross-space-duplicate-url" {
            return crossSpaceDuplicateURLFixtureState()
        }

        if fixture == "legacy-saved-tab-navigation" {
            return legacySavedTabNavigationFixtureState()
        }

        if fixture == "inactive-favorites" {
            return inactiveFavoritesFixtureState()
        }

        return testingBotFixtureState(includesSeedTabs: true)
    }

    private static func crossSpaceDuplicateURLFixtureState() -> BrowserWindowState {
        let inactiveSpaceID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let activeSpaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let inactiveGoogleTabID = UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
        let activeStartTabID = UUID(uuidString: "24242424-2424-2424-2424-242424242424")!
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)

        let inactiveSpace = BrowserSpace(
            id: inactiveSpaceID,
            name: "Reference",
            symbolName: "book.closed",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let activeSpace = BrowserSpace(
            id: activeSpaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeColorHex: "#6E8BFF",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let tabs = [
            BrowserTab(
                id: inactiveGoogleTabID,
                title: "Google",
                url: URL(string: "https://www.google.com")!,
                faviconSymbol: "magnifyingglass",
                spaceID: inactiveSpaceID,
                sortOrder: 0,
                lastAccessedAt: fixtureDate.addingTimeInterval(-120)
            ),
            BrowserTab(
                id: activeStartTabID,
                title: "Apple",
                url: URL(string: "https://www.apple.com")!,
                faviconSymbol: "apple.logo",
                spaceID: activeSpaceID,
                sortOrder: 0,
                lastAccessedAt: fixtureDate
            )
        ]

        return BrowserWindowState(
            spaces: [inactiveSpace, activeSpace],
            folders: [],
            tabs: tabs,
            activeSpaceID: activeSpaceID,
            activeTabID: activeStartTabID
        )
    }

    private static func legacySavedTabNavigationFixtureState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let tabID = UUID(uuidString: "45454545-4545-4545-4545-454545454545")!
        let space = BrowserSpace(
            id: spaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeColorHex: "#6E8BFF",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let legacyFavorite = BrowserTab(
            id: tabID,
            title: "Google",
            url: URL(string: "https://www.google.com/?hl=en&gl=us")!,
            faviconSymbol: "magnifyingglass",
            favoriteTitle: "YouTube",
            favoriteURL: URL(string: "https://www.youtube.com/")!,
            favoriteFaviconSymbol: "play.rectangle.fill",
            isFavorite: true,
            spaceID: spaceID
        )

        return BrowserWindowState(
            spaces: [space],
            folders: [],
            tabs: [legacyFavorite],
            activeSpaceID: spaceID,
            activeTabID: tabID
        )
    }

    private static func inactiveFavoritesFixtureState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let currentTabID = UUID(uuidString: "67676767-6767-6767-6767-676767676767")!
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
        let space = BrowserSpace(
            id: spaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let tabs = [
            BrowserTab(
                id: currentTabID,
                title: "Current",
                url: URL(string: "https://example.com/current")!,
                spaceID: spaceID,
                lastAccessedAt: fixtureDate,
                hasBeenActivated: true
            ),
            BrowserTab(
                title: "Saved One",
                url: URL(string: "https://example.com/saved-one")!,
                isFavorite: true,
                spaceID: spaceID,
                lastAccessedAt: fixtureDate.addingTimeInterval(-60),
                hasBeenActivated: false
            ),
            BrowserTab(
                title: "Saved Two",
                url: URL(string: "https://example.com/saved-two")!,
                isFavorite: true,
                spaceID: spaceID,
                lastAccessedAt: fixtureDate.addingTimeInterval(-120),
                hasBeenActivated: false
            )
        ]

        return BrowserWindowState(
            spaces: [space],
            folders: [],
            tabs: tabs,
            activeSpaceID: spaceID,
            activeTabID: currentTabID
        )
    }

    private static func testingBotFixtureState(includesSeedTabs: Bool) -> BrowserWindowState {
        let testingBotSpaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let workFolderID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let secondFolderID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let appleTabID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let amazonTabID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let granolaTabID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let xTabID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let webKitTabID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let testingBotSpace = BrowserSpace(
            id: testingBotSpaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeColorHex: "#6E8BFF",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )

        guard includesSeedTabs else {
            return BrowserWindowState(
                spaces: [testingBotSpace],
                folders: [],
                tabs: [],
                activeSpaceID: testingBotSpaceID,
                activeTabID: nil
            )
        }

        let folders = [
            BrowserFolder(
                id: workFolderID,
                name: "Work",
                spaceID: testingBotSpaceID,
                sortOrder: 0,
                isExpanded: false
            ),
            BrowserFolder(
                id: secondFolderID,
                name: "Second",
                spaceID: testingBotSpaceID,
                parentFolderID: workFolderID,
                sortOrder: 0,
                isExpanded: true
            )
        ]

        let tabs = [
            BrowserTab(
                id: appleTabID,
                title: "Apple",
                url: URL(string: "https://www.apple.com")!,
                faviconSymbol: "apple.logo",
                spaceID: testingBotSpaceID,
                sortOrder: 0
            ),
            BrowserTab(
                id: amazonTabID,
                title: "amazon.com",
                url: URL(string: "https://www.amazon.com")!,
                faviconSymbol: "shippingbox.fill",
                isPinned: true,
                spaceID: testingBotSpaceID,
                sortOrder: 0
            ),
            BrowserTab(
                id: granolaTabID,
                title: "Granola",
                url: URL(string: "https://granola.ai")!,
                faviconSymbol: "g.circle.fill",
                isPinned: true,
                folderID: workFolderID,
                spaceID: testingBotSpaceID,
                sortOrder: 0
            ),
            BrowserTab(
                id: xTabID,
                title: "Home / X",
                url: URL(string: "https://x.com/home")!,
                faviconSymbol: "xmark",
                isPinned: true,
                folderID: secondFolderID,
                spaceID: testingBotSpaceID,
                sortOrder: 0
            ),
            BrowserTab(
                id: webKitTabID,
                title: "WebKit Documentation",
                url: URL(string: "https://developer.apple.com/documentation/webkit")!,
                faviconSymbol: "shield.fill",
                isPinned: true,
                folderID: workFolderID,
                spaceID: testingBotSpaceID,
                sortOrder: 1
            )
        ]

        return BrowserWindowState(
            spaces: [testingBotSpace],
            folders: folders,
            tabs: tabs,
            activeSpaceID: testingBotSpaceID,
            activeTabID: appleTabID
        )
    }

    func focusAddressBar() {
        guard !isInitialSpaceSetupPresented else { return }

        if isCommandPalettePresented {
            dismissCommandPalette()
            return
        }

        let activeURL = activeTab?.url
        commandPaletteInitialText = activeURL?.absoluteString ?? ""
        commandPaletteResumeQuery = activeURL.flatMap(navigationService.searchQuery(from:)) ?? ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = true
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = false
        presentCommandPalette()
        addressFocusRequestID = UUID()
    }

    func focusSidebarAddressBar() {
        guard !isInitialSpaceSetupPresented else { return }

        if isCommandPalettePresented {
            dismissCommandPalette()
            return
        }

        let activeURL = activeTab?.url
        commandPaletteInitialText = activeURL?.absoluteString ?? ""
        commandPaletteResumeQuery = activeURL.flatMap(navigationService.searchQuery(from:)) ?? ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = true
        commandPaletteWasOpenedFromSidebarAddress = true
        commandPaletteOpensNewTab = false
        presentCommandPalette()
        addressFocusRequestID = UUID()
    }

    func openCommandPalette() {
        guard !isInitialSpaceSetupPresented else { return }

        commandPaletteInitialText = ""
        commandPaletteResumeQuery = ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = false
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = false
        presentCommandPalette()
    }

    func openNewTabCommandPalette() {
        guard !isInitialSpaceSetupPresented else { return }

        commandPaletteInitialText = ""
        commandPaletteResumeQuery = ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = false
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = true
        presentCommandPalette()
    }

    /// Presentation animates; dismissal deliberately does not. An animated
    /// removal keeps the palette in the hierarchy for the transition's
    /// duration, and a committed command's web view swap landing in that
    /// window interrupts the transition — stranding an invisible palette
    /// that swallows every mouse click until ⌘T is pressed again.
    private func presentCommandPalette() {
        guard !isCommandPalettePresented else { return }

        withAnimation(.easeOut(duration: 0.14)) {
            isCommandPalettePresented = true
        }
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
        commandPalettePrefersCurrentTabNavigation = false
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = false

        // The palette's TextField unmounts while the window's field editor is
        // still bound to it. Without an explicit hand-back the orphaned field
        // editor stays first responder and the window drops mouse events.
        if let window = NSApp.keyWindow {
            window.endEditing(for: nil)
            window.makeFirstResponder(nil)
        }
    }

    /// Arc-style ⌘T: no tab exists yet — the sidebar's New Tab button takes
    /// the selection highlight while the palette is open, and the real tab is
    /// only created when a result is picked.
    var isNewTabPaletteActive: Bool {
        isCommandPalettePresented && commandPaletteOpensNewTab
    }

    func consumeCommandPaletteNewTabIntent() -> Bool {
        let opensNewTab = commandPaletteOpensNewTab
        commandPaletteOpensNewTab = false
        return opensNewTab
    }

    func beginSpaceCreation() {
        guard !isInitialSpaceSetupPresented else { return }
        dismissCommandPalette()
        editingSpaceID = nil
        isCreateSpacePresented = true
    }

    func beginSpaceEditing(_ id: UUID) {
        guard !isInitialSpaceSetupPresented, spaces.contains(where: { $0.id == id }) else { return }
        dismissCommandPalette()
        isCreateSpacePresented = false
        switchSpace(to: id)
        editingSpaceID = id
    }

    @discardableResult
    func dataStoreID(for spaceID: UUID) -> UUID {
        spaces.first(where: { $0.id == spaceID })?.dataStoreID ?? spaceID
    }

    static func limitedSpaceNameInput(_ name: String) -> String {
        String(name.prefix(spaceNameCharacterLimit))
    }

    static func normalizedSpaceName(_ name: String) -> String {
        limitedSpaceNameInput(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func createSpace(
        name: String? = nil,
        symbolName: String? = nil,
        themeColorHex: String? = nil,
        themeAppearance: SpaceThemeAppearance = .automatic,
        themeOpacity: Double = 0.5,
        themeTexture: Double = 0,
        dataStoreID: UUID? = nil
    ) -> BrowserSpace {
        let spaceNumber = spaces.count + 1
        let paletteIndex = spaces.count % spaceSymbols.count
        let resolvedName = name
            .map(Self.normalizedSpaceName)
            .flatMap { $0.isEmpty ? nil : $0 }

        let space = BrowserSpace(
            name: resolvedName ?? "Space \(spaceNumber)",
            symbolName: symbolName ?? spaceSymbols[paletteIndex],
            themeColorHex: themeColorHex,
            themeAppearance: themeAppearance,
            themeOpacity: themeOpacity,
            themeTexture: themeTexture,
            dataStoreID: dataStoreID ?? UUID()
        )
        spaces.append(space)
        switchSpace(to: space.id)
        flushSession()
        return space
    }

    func completeInitialSpaceSetup(
        name: String,
        symbolName: String,
        themeColorHex: String?,
        themeAppearance: SpaceThemeAppearance = .automatic,
        themeOpacity: Double = 0.5,
        themeTexture: Double = 0,
        dataStoreID: UUID? = nil
    ) {
        let normalizedName = Self.normalizedSpaceName(name)
        guard !normalizedName.isEmpty else { return }

        if spaces.isEmpty {
            let defaultSpace = BrowserSpace(
                name: normalizedName,
                symbolName: symbolName,
                themeColorHex: themeColorHex,
                themeAppearance: themeAppearance,
                themeOpacity: themeOpacity,
                themeTexture: themeTexture,
                dataStoreID: dataStoreID
            )
            spaces = [defaultSpace]
            activeSpaceID = defaultSpace.id
        }

        let targetSpaceID = spaces.contains(where: { $0.id == activeSpaceID })
            ? activeSpaceID
            : spaces[0].id

        guard let index = spaces.firstIndex(where: { $0.id == targetSpaceID }) else { return }
        let previousDataStoreID = spaces[index].dataStoreID

        spaces[index].name = normalizedName
        spaces[index].symbolName = symbolName
        spaces[index].themeColorHex = themeColorHex
        spaces[index].themeAppearance = themeAppearance
        spaces[index].themeOpacity = min(0.9, max(0.3, themeOpacity))
        spaces[index].themeTexture = min(1, max(0, themeTexture))
        if let dataStoreID {
            spaces[index].dataStoreID = dataStoreID
        }

        activeSpaceID = spaces[index].id
        isInitialSpaceSetupPresented = false
        isCreateSpacePresented = false
        recreateWebViewsIfNeeded(
            in: spaces[index].id,
            previousDataStoreID: previousDataStoreID,
            nextDataStoreID: spaces[index].dataStoreID
        )
        repairSessionState()
        updateNavigationState()
        flushSession()
    }

    func renameSpace(_ id: UUID, to name: String) {
        let normalizedName = Self.normalizedSpaceName(name)
        guard !normalizedName.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = normalizedName
        flushSession()
    }

    func updateSpace(
        _ id: UUID,
        name: String,
        symbolName: String,
        themeColorHex: String?,
        themeAppearance: SpaceThemeAppearance,
        themeOpacity: Double,
        themeTexture: Double
    ) {
        let normalizedName = Self.normalizedSpaceName(name)
        guard !normalizedName.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return }

        spaces[index].name = normalizedName
        spaces[index].symbolName = symbolName
        spaces[index].themeColorHex = themeColorHex
        spaces[index].themeAppearance = themeAppearance
        spaces[index].themeOpacity = min(0.9, max(0.3, themeOpacity))
        spaces[index].themeTexture = min(1, max(0, themeTexture))

        editingSpaceID = nil
        updateNavigationState()
        flushSession()
    }

    func updateSpaceTheme(_ id: UUID, colorHex: String?) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].themeColorHex = colorHex
        flushSession()
    }

    func updateSpaceThemeControls(_ id: UUID, opacity: Double, texture: Double) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].themeOpacity = min(0.9, max(0.3, opacity))
        spaces[index].themeTexture = min(1, max(0, texture))
        flushSession()
    }

    func updateSpaceThemeAppearance(_ id: UUID, appearance: SpaceThemeAppearance) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].themeAppearance = appearance
        flushSession()
    }

    func previewSpaceThemeAppearance(_ appearance: SpaceThemeAppearance) {
        guard spaceThemeAppearancePreview != appearance else { return }
        spaceThemeAppearancePreview = appearance
    }

    func previewSpaceThemeColors(primaryHex: String?, auxiliaryHexes: [String] = []) {
        let normalizedAuxiliaryHexes = primaryHex == nil ? [] : auxiliaryHexes
        guard
            !isSpaceThemeColorPreviewActive ||
            spaceThemeColorHexPreview != primaryHex ||
            spaceThemeAuxiliaryHexPreviews != normalizedAuxiliaryHexes
        else { return }

        if !isSpaceThemeColorPreviewActive {
            isSpaceThemeColorPreviewActive = true
        }
        if spaceThemeColorHexPreview != primaryHex {
            spaceThemeColorHexPreview = primaryHex
        }
        if spaceThemeAuxiliaryHexPreviews != normalizedAuxiliaryHexes {
            spaceThemeAuxiliaryHexPreviews = normalizedAuxiliaryHexes
        }
    }

    func previewSpaceThemeControls(opacity: Double, texture: Double) {
        let clampedOpacity = min(0.9, max(0.3, opacity))
        let clampedTexture = min(1, max(0, texture))
        if spaceThemeOpacityPreview != clampedOpacity {
            spaceThemeOpacityPreview = clampedOpacity
        }
        if spaceThemeTexturePreview != clampedTexture {
            spaceThemeTexturePreview = clampedTexture
        }
    }

    func clearSpaceThemePreview() {
        spaceThemeAppearancePreview = nil
        isSpaceThemeColorPreviewActive = false
        spaceThemeColorHexPreview = nil
        spaceThemeAuxiliaryHexPreviews = []
        spaceThemeOpacityPreview = nil
        spaceThemeTexturePreview = nil
    }

    func clearSpaceThemeAppearancePreview() {
        clearSpaceThemePreview()
    }

    func cycleSpaceIcon(_ id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let currentSymbolIndex = spaceSymbols.firstIndex(of: spaces[index].symbolName) ?? -1
        let nextSymbolIndex = (currentSymbolIndex + 1 + spaceSymbols.count) % spaceSymbols.count
        spaces[index].symbolName = spaceSymbols[nextSymbolIndex]
        flushSession()
    }

    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let deletedSpaceIndex = spaces.firstIndex(where: { $0.id == id }) else { return }

        if editingSpaceID == id {
            editingSpaceID = nil
        }

        let removedTabIDs = tabs.filter { $0.spaceID == id }.map(\.id)
        tabs.removeAll { $0.spaceID == id }
        folders.removeAll { $0.spaceID == id }
        removedTabIDs.forEach { webCoordinator.removeWebView(for: $0) }

        spaces.remove(at: deletedSpaceIndex)

        if activeSpaceID == id {
            let replacementIndex = min(deletedSpaceIndex, spaces.count - 1)
            activeSpaceID = spaces[replacementIndex].id
            activeTabID = visibleTabsForActiveSpace.first?.id
        } else if removedTabIDs.contains(where: { $0 == activeTabID }) {
            activeTabID = visibleTabsForActiveSpace.first?.id
        }

        if !activeSplitGroupTabIDs.isDisjoint(with: removedTabIDs) {
            splitTabIDs = []
            isSplitViewEnabled = false
        }
        if let editingFolderID, !folders.contains(where: { $0.id == editingFolderID }) {
            self.editingFolderID = nil
        }

        repairSessionState()
        updateNavigationState()
        flushSession()
    }

    func moveSpace(_ id: UUID, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + offset
        guard spaces.indices.contains(targetIndex) else { return }
        spaces.swapAt(index, targetIndex)
        flushSession()
    }

    func moveTab(_ tabID: UUID, toSpace targetSpaceID: UUID) {
        guard
            spaces.contains(where: { $0.id == targetSpaceID }),
            let tabIndex = tabs.firstIndex(where: { $0.id == tabID })
        else {
            return
        }

        let sourceSpaceID = tabs[tabIndex].spaceID
        guard sourceSpaceID != targetSpaceID else { return }

        let sourceDataStoreID = dataStoreID(for: sourceSpaceID)
        let targetDataStoreID = dataStoreID(for: targetSpaceID)
        tabs[tabIndex].spaceID = targetSpaceID
        tabs[tabIndex].folderID = nil
        tabs[tabIndex].sortOrder = nextSortOrder(
            spaceID: targetSpaceID,
            isFavorite: tabs[tabIndex].isFavorite,
            isPinned: tabs[tabIndex].isPinned,
            folderID: nil
        )

        if sourceDataStoreID != targetDataStoreID {
            webCoordinator.removeWebView(for: tabID)
        }

        if activeTabID == tabID {
            switchTab(to: tabID)
            if let movedTab = tabs.first(where: { $0.id == tabID }) {
                webCoordinator.ensureLoaded(movedTab)
            }
        } else if activeSplitGroupTabIDs.contains(tabID) {
            splitTabIDs.removeAll { $0 == tabID }
            isSplitViewEnabled = splitTabIDs.count >= 2
            if !isSplitViewEnabled {
                splitTabIDs = []
            }
            updateNavigationState()
        }

        normalizeSortOrder()
        flushSession()
    }

    @discardableResult
    func newTab(
        url: URL? = nil,
        favorite: Bool = false,
        pinned: Bool = false,
        folderID: UUID? = nil,
        in spaceID: UUID? = nil
    ) -> BrowserTab {
        let targetSpaceID = spaceID ?? activeSpaceID
        let targetFolderID = folderID.flatMap { folder in
            folders.contains(where: { $0.id == folder && $0.spaceID == targetSpaceID }) ? folder : nil
        }
        let isPinned = (pinned || targetFolderID != nil) && !favorite
        var tab = BrowserTab(
            title: title(for: url),
            url: url,
            faviconSymbol: faviconService.placeholderSymbol(for: url),
            isFavorite: favorite,
            isPinned: isPinned,
            folderID: favorite ? nil : targetFolderID,
            spaceID: targetSpaceID,
            sortOrder: nextSortOrder(
                spaceID: targetSpaceID,
                isFavorite: favorite,
                isPinned: isPinned,
                folderID: favorite ? nil : targetFolderID
            )
        )
        if favorite {
            tab.favoriteTitle = tab.title
            tab.favoriteURL = tab.url
            tab.favoriteFaviconSymbol = tab.faviconSymbol
            tab.favoriteFaviconData = tab.faviconData
        }

        tabs.insert(tab, at: 0)
        switchTab(to: tab.id)

        if let url {
            webCoordinator.load(url, in: tab.id)
        }

        return tab
    }

    func closeCurrentTab() {
        guard let activeTabID else { return }
        if performPinnedCloseShortcutIfNeeded(activeTabID) {
            return
        }
        closeTab(activeTabID)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let previousSplitGroupIDs = splitGroupTabIDs()
        let wasSplitGroupTab = previousSplitGroupIDs.contains(id)
        let wasActiveTab = activeTabID == id
        let replacementTabID = wasActiveTab ? replacementTabIDAfterClosing(id) : nil
        let closingTab = tabs[index]
        rememberClosedTab(closingTab)
        tabs.remove(at: index)
        webCoordinator.removeWebView(for: id)
        mediaStates[id] = nil
        if mediaControllerTabID == id {
            mediaControllerTabID = nil
        }

        if wasSplitGroupTab {
            let remainingGroupIDs = previousSplitGroupIDs.filter { $0 != id }
            let nextActiveID = wasActiveTab
                ? remainingGroupIDs.first
                : activeTabID
            applySplitGroup(remainingGroupIDs, activeID: nextActiveID)
            if activeTabID == nil {
                activeTabID = tabs
                    .filter { $0.spaceID == activeSpaceID }
                    .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                    .first?.id
            }
            updateNavigationState()
        } else if activeTabID == id {
            activeTabID = replacementTabID
            updateNavigationState()
        }
    }

    private func performPinnedCloseShortcutIfNeeded(_ id: UUID) -> Bool {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            tab.isPinned || tab.isFavorite
        else {
            return false
        }

        let behavior = pinnedCloseShortcutBehavior
        guard behavior != .close else {
            closeTab(id)
            return true
        }

        let nextTabID = behavior.switchesToNextTab
            ? replacementTabIDAfterClosing(id, prefersRecentlyUsed: false)
            : nil

        if behavior.resetsURL {
            resetSavedURLIfAvailable(for: id, loadsWebView: !behavior.unloadsWebView)
        }

        if let nextTabID {
            switchTab(to: nextTabID)
        }

        if behavior.unloadsWebView {
            unloadWebView(for: id)
        }

        updateNavigationState()
        return true
    }

    private func replacementTabIDAfterClosing(_ id: UUID, prefersRecentlyUsed: Bool? = nil) -> UUID? {
        guard let closingTab = tabs.first(where: { $0.id == id }) else { return nil }
        let candidates = tabs.filter { $0.id != id && $0.spaceID == closingTab.spaceID }
        guard !candidates.isEmpty else { return nil }

        if prefersRecentlyUsed ?? selectsRecentlyUsedTabOnClose {
            return candidates
                .sorted {
                    if $0.lastAccessedAt == $1.lastAccessedAt {
                        return $0.sortOrder < $1.sortOrder
                    }
                    return $0.lastAccessedAt > $1.lastAccessedAt
                }
                .first?.id
        }

        let orderedVisibleTabs = visibleTabs(in: closingTab.spaceID)
        guard
            let closingIndex = orderedVisibleTabs.firstIndex(where: { $0.id == id })
        else {
            return candidates
                .sorted { $0.sortOrder < $1.sortOrder }
                .first?.id
        }

        let remainingVisibleTabs = orderedVisibleTabs.filter { $0.id != id }
        guard !remainingVisibleTabs.isEmpty else { return nil }

        if closingIndex < remainingVisibleTabs.count {
            return remainingVisibleTabs[closingIndex].id
        }
        return remainingVisibleTabs.last?.id
    }

    private func resetSavedURLIfAvailable(for tabID: UUID, loadsWebView: Bool) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            let savedURL = tabs[index].favoriteURL
        else {
            return
        }

        let title = tabs[index].favoriteDisplayTitle
        setURL(savedURL, title: title, for: tabID)

        if loadsWebView {
            webCoordinator.load(savedURL, in: tabID)
        }
    }

    private func unloadWebView(for tabID: UUID) {
        webCoordinator.removeWebView(for: tabID)
        mediaStates[tabID] = nil
        if mediaControllerTabID == tabID {
            mediaControllerTabID = nil
        }
    }

    func duplicateCurrentTab() {
        guard let tab = activeTab else { return }
        _ = newTab(
            url: tab.isFavorite ? tab.favoriteURL ?? tab.url : tab.url,
            favorite: tab.isFavorite,
            pinned: tab.isPinned,
            folderID: tab.folderID,
            in: tab.spaceID
        )
    }

    func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        _ = newTab(
            url: tab.isFavorite ? tab.favoriteURL ?? tab.url : tab.url,
            favorite: tab.isFavorite,
            pinned: tab.isPinned,
            folderID: tab.folderID,
            in: tab.spaceID
        )
    }

    @discardableResult
    func createPopupTab(url: URL?, in spaceID: UUID) -> BrowserTab {
        let tab = BrowserTab(
            title: title(for: url),
            url: url,
            faviconSymbol: faviconService.placeholderSymbol(for: url),
            spaceID: spaceID,
            sortOrder: nextSortOrder(spaceID: spaceID, isFavorite: false, isPinned: false, folderID: nil)
        )

        tabs.insert(tab, at: 0)
        switchTab(to: tab.id)
        return tab
    }

    func reopenLastClosedTab() {
        guard let snapshot = recentlyClosedTabs.popLast() else { return }
        let targetSpaceID = spaces.contains(where: { $0.id == snapshot.spaceID })
            ? snapshot.spaceID
            : activeSpaceID
        _ = newTab(url: snapshot.url, favorite: snapshot.isFavorite, pinned: snapshot.isPinned, in: targetSpaceID)
    }

    func clearUnpinnedTabs() {
        regularTabsForActiveSpace.map(\.id).forEach(closeTab)
    }

    func togglePinForActiveTab() {
        guard let activeTabID else { return }
        togglePin(activeTabID)
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let pinned = !tabs[index].isPinned
        tabs[index].isFavorite = false
        tabs[index].folderID = nil
        tabs[index].isPinned = pinned
        tabs[index].sortOrder = nextSortOrder(
            spaceID: tabs[index].spaceID,
            isFavorite: false,
            isPinned: pinned,
            folderID: nil
        )
        normalizeSortOrder()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let favorite = !tabs[index].isFavorite
        tabs[index].isFavorite = favorite
        tabs[index].folderID = nil
        if favorite {
            tabs[index].isPinned = false
            captureFavoriteSnapshot(at: index)
        } else {
            clearFavoriteSnapshot(at: index)
        }
        tabs[index].sortOrder = nextSortOrder(
            spaceID: tabs[index].spaceID,
            isFavorite: favorite,
            isPinned: tabs[index].isPinned,
            folderID: nil
        )
        normalizeSortOrder()
    }

    func addTabToFavorites(_ id: UUID, before targetID: UUID? = nil) {
        moveTabToPlacement(id, isFavorite: true, isPinned: false, folderID: nil, before: targetID)
    }

    func activateFavorite(_ id: UUID) {
        switchTab(to: id)
    }

    @discardableResult
    func createFolder(named name: String = "New Folder", parentFolderID: UUID? = nil) -> BrowserFolder {
        let resolvedParentID = parentFolderID.flatMap { parentID in
            folders.contains { $0.id == parentID && $0.spaceID == activeSpaceID } ? parentID : nil
        }
        let folder = BrowserFolder(
            name: uniqueFolderName(base: name, in: activeSpaceID),
            spaceID: activeSpaceID,
            parentFolderID: resolvedParentID,
            sortOrder: nextFolderSortOrder(spaceID: activeSpaceID, parentFolderID: resolvedParentID)
        )
        folders.append(folder)
        if let resolvedParentID, let parentIndex = folders.firstIndex(where: { $0.id == resolvedParentID }) {
            folders[parentIndex].isExpanded = true
        }
        editingFolderID = folder.id
        flushSession()
        return folder
    }

    @discardableResult
    func createSubfolder(in parentFolderID: UUID) -> BrowserFolder? {
        guard folders.contains(where: { $0.id == parentFolderID && $0.spaceID == activeSpaceID }) else {
            return nil
        }
        return createFolder(named: "New Folder", parentFolderID: parentFolderID)
    }

    func renameFolder(_ id: UUID, to name: String) {
        let normalizedName = normalizedFolderName(name)
        guard !normalizedName.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = normalizedName
        editingFolderID = nil
        flushSession()
    }

    func toggleFolderExpanded(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isExpanded.toggle()
        flushSession()
    }

    func setFolderExpanded(_ id: UUID, _ isExpanded: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].isExpanded != isExpanded else { return }
        folders[index].isExpanded = isExpanded
        flushSession()
    }

    func revealFolder(_ id: UUID) {
        var changed = false
        var currentID: UUID? = id
        var seen = Set<UUID>()

        while let folderID = currentID, seen.insert(folderID).inserted {
            guard let index = folders.firstIndex(where: { $0.id == folderID }) else { break }
            if !folders[index].isExpanded {
                folders[index].isExpanded = true
                changed = true
            }
            currentID = folders[index].parentFolderID
        }

        if changed {
            flushSession()
        }
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let deletedFolderIDs = descendantFolderIDs(of: id).union([id])
        folders.removeAll { deletedFolderIDs.contains($0.id) }
        if let currentEditingFolderID = editingFolderID, deletedFolderIDs.contains(currentEditingFolderID) {
            editingFolderID = nil
        }

        for index in tabs.indices where tabs[index].folderID.map(deletedFolderIDs.contains) == true {
            tabs[index].folderID = nil
            tabs[index].isFavorite = false
            tabs[index].isPinned = true
            tabs[index].sortOrder = nextSortOrder(
                spaceID: folder.spaceID,
                isFavorite: false,
                isPinned: true,
                folderID: nil
            )
        }

        normalizeSortOrder()
        flushSession()
    }

    func moveTabToFolder(
        _ tabID: UUID,
        folderID: UUID,
        before targetID: UUID? = nil,
        appendToEnd: Bool = false
    ) {
        moveTabToPlacement(
            tabID,
            isFavorite: false,
            isPinned: true,
            folderID: folderID,
            before: targetID,
            appendToEnd: appendToEnd
        )
    }

    func switchToTab(at position: Int) {
        let visibleTabs = visibleTabsForActiveSpace
        guard position >= 1, position <= visibleTabs.count else { return }
        switchTab(to: visibleTabs[position - 1].id)
    }

    func switchToSpace(at position: Int) {
        guard position >= 1, position <= spaces.count else { return }
        switchSpace(to: spaces[position - 1].id)
    }

    func copyActiveTabURL(asMarkdown: Bool = false) {
        guard let tab = activeTab, let url = tab.url else { return }
        let value = asMarkdown ? "[\(tab.title)](\(url.absoluteString))" : url.absoluteString
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        presentCopiedURLToast(
            title: asMarkdown ? "Copied URL as Markdown" : "Copied current URL",
            url: url
        )
    }

    func captureActiveTabPage() {
        guard let tab = activeTab, let url = tab.url else { return }

        webCoordinator.captureVisiblePage(for: tab.id) { [weak self] image in
            guard let self, let image else { return }
            guard
                let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:]),
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            else {
                return
            }

            let host = url.host(percentEncoded: false)?
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "/", with: "-") ?? "page"
            let fileURL = downloadsURL.appendingPathComponent("Candoa Capture - \(host).png")

            do {
                try pngData.write(to: fileURL, options: .atomic)
                presentCopiedURLToast(title: "Captured Page", url: fileURL)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func presentCopiedURLToast(title: String, url: URL) {
        isCopiedURLToastSharing = false
        copiedURLToast = CopiedURLToast(id: UUID(), title: title, url: url)
        scheduleCopiedURLToastDismissal()
    }

    /// Zen keeps the toast alive while hovered and restarts the dismissal
    /// timer on mouse-out.
    func setCopiedURLToastHovered(_ hovered: Bool) {
        guard copiedURLToast != nil, !isCopiedURLToastSharing else { return }
        if hovered {
            copiedURLToastHideWorkItem?.cancel()
            copiedURLToastHideWorkItem = nil
        } else {
            scheduleCopiedURLToastDismissal()
        }
    }

    /// While the share picker spawned from the toast is open, the toast must
    /// not auto-dismiss (tearing down its anchor would close the picker).
    func setCopiedURLToastSharing(_ sharing: Bool) {
        guard copiedURLToast != nil else {
            isCopiedURLToastSharing = false
            return
        }
        isCopiedURLToastSharing = sharing
        if sharing {
            copiedURLToastHideWorkItem?.cancel()
            copiedURLToastHideWorkItem = nil
        } else {
            scheduleCopiedURLToastDismissal()
        }
    }

    private func scheduleCopiedURLToastDismissal() {
        copiedURLToastHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.copiedURLToast = nil
                self.copiedURLToastHideWorkItem = nil
            }
        }
        copiedURLToastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func showFindBar() {
        guard activeTab != nil else { return }
        isFindBarPresented = true
    }

    func dismissFindBar() {
        guard isFindBarPresented else { return }
        isFindBarPresented = false
        if let activeTabID {
            webCoordinator.clearFindSelection(in: activeTabID)
        }
    }

    func findNext() {
        performFind(forward: true)
    }

    func findPrevious() {
        performFind(forward: false)
    }

    func zoomInActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.zoomIn(tabID: activeTabID)
    }

    func zoomOutActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.zoomOut(tabID: activeTabID)
    }

    func resetZoomForActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.resetZoom(tabID: activeTabID)
    }

    private func performFind(forward: Bool) {
        guard let activeTabID, !findQuery.isEmpty else { return }
        webCoordinator.find(findQuery, forward: forward, in: activeTabID)
    }

    private func rememberClosedTab(_ tab: BrowserTab) {
        guard let url = tab.isFavorite ? tab.favoriteURL ?? tab.url : tab.url else { return }
        recentlyClosedTabs.append(ClosedTabSnapshot(
            url: url,
            isFavorite: tab.isFavorite,
            isPinned: tab.isPinned,
            spaceID: tab.spaceID
        ))
        if recentlyClosedTabs.count > Self.recentlyClosedTabLimit {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedTabLimit)
        }
    }

    func switchTab(to id: UUID) {
        switchTab(to: id, updatesAccessTime: true)
    }

    private func switchTab(to id: UUID, updatesAccessTime: Bool) {
        guard tabs.contains(where: { $0.id == id }) else { return }

        // Switching to the floating player's own tab morphs the player back
        // into the page instead of swapping abruptly; the real switch lands
        // in finishMiniPlayerReturn once the morph completes. Ctrl-Tab
        // preview cycling keeps the instant swap — a morph per cycle step
        // would fight the switcher.
        if miniPlayerReturn == nil, floatingMiniPlayerTab?.id == id, !isTabSwitcherPresented {
            beginMiniPlayerReturn(tabID: id, updatesAccessTime: updatesAccessTime)
            return
        }

        if let returning = miniPlayerReturn {
            guard returning.tabID != id else { return }
            // A different switch interrupts the in-flight return; clearing
            // the context lets the player re-adopt its web view and float on.
            miniPlayerReturn = nil
        }

        performSwitchTab(to: id, updatesAccessTime: updatesAccessTime)
    }

    func performSwitchTab(to id: UUID, updatesAccessTime: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Any landed switch resolves the return morph's pending destination —
        // either the morph just finished or another switch interrupted it.
        pendingMiniPlayerReturnTabID = nil
        if updatesAccessTime {
            tabs[index].lastAccessedAt = Date()
        }
        let existingSplitGroupIDs = splitGroupTabIDs()
        activeSpaceID = tabs[index].spaceID
        activeTabID = id
        if existingSplitGroupIDs.contains(id) {
            applySplitGroup(existingSplitGroupIDs, activeID: id)
        } else if isSplitViewEnabled {
            closeSplitView()
        }
        updateNavigationState()
    }

    func switchSpace(to id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        activeSpaceID = id

        if let existingTab = tabs
            .filter({ $0.spaceID == id })
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first {
            activeTabID = existingTab.id
        } else {
            activeTabID = nil
        }

        closeSplitView()

        updateNavigationState()
    }

    func switchToNextTab() {
        switchTab(offset: 1)
    }

    func switchToPreviousTab() {
        switchTab(offset: -1)
    }

    func switchToNextRecentTab(keepsPreviewOpen: Bool = false) {
        switchTabInRecentOrder(offset: 1, keepsPreviewOpen: keepsPreviewOpen)
    }

    func switchToPreviousRecentTab(keepsPreviewOpen: Bool = false) {
        switchTabInRecentOrder(offset: -1, keepsPreviewOpen: keepsPreviewOpen)
    }

    func finishTabSwitcherInteraction() {
        // Releasing Control commits whatever the cycling selected. Until now
        // only the preview selection moved, so a held interaction never
        // switched tabs behind the overlay.
        let landedTabID = tabSwitcherSelectedTabID ?? activeTabID
        if let selectedTabID = tabSwitcherSelectedTabID, selectedTabID != activeTabID {
            switchTab(to: selectedTabID, updatesAccessTime: false)
        } else if pendingMiniPlayerReturnTabID != nil, pendingMiniPlayerReturnTabID != landedTabID {
            // Re-selecting the current tab while a return morph is still in
            // flight cancels that pending switch — the newest intent wins.
            pendingMiniPlayerReturnTabID = nil
        }

        // The interaction ends when Control lifts, not when the overlay's
        // fade does: stamp the landed tab as most recent now (the switch
        // itself may still be deferred behind the mini player's return
        // morph) and stop treating the frozen candidate list as live, so a
        // press during the fade starts a fresh toggle from the landed tab
        // instead of cycling deeper into the old list.
        isTabSwitcherCycling = false
        if let landedTabID, let index = tabs.firstIndex(where: { $0.id == landedTabID }) {
            tabs[index].lastAccessedAt = Date()
        }

        // Quick tap: Control was released before the preview appeared, so the
        // switch stays silent — just commit the interaction.
        if tabSwitcherShowWorkItem != nil {
            hideTabSwitcher()
            return
        }

        guard isTabSwitcherPresented else { return }

        tabSwitcherHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideTabSwitcher()
            }
        }
        tabSwitcherHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    func switchToNextSpace() {
        switchSpace(offset: 1)
    }

    func switchToPreviousSpace() {
        switchSpace(offset: -1)
    }

    func toggleSplitView() {
        if isSplitViewEnabled {
            isSplitViewEnabled = false
            splitTabIDs = []
            return
        }

        openSplitView(with: replacementSplitTab(excluding: activeTabID)?.id)
    }

    func openSplitView(with tabID: UUID?) {
        guard let activeTabID else { return }
        let candidateID = tabID == activeTabID ? replacementSplitTab(excluding: activeTabID)?.id : tabID
        var groupIDs = isSplitViewEnabled ? splitGroupTabIDs() : [activeTabID]

        if let candidateID, tabs.contains(where: { $0.id == candidateID && $0.spaceID == activeSpaceID }) {
            if !groupIDs.contains(candidateID) {
                groupIDs.append(candidateID)
            }
        } else {
            let tab = newInternalBlankTab(in: activeSpaceID)
            self.activeTabID = activeTabID
            groupIDs.append(tab.id)
        }

        if !groupIDs.contains(activeTabID) {
            groupIDs.insert(activeTabID, at: 0)
        }
        applySplitGroup(groupIDs, activeID: activeTabID)
        updateNavigationState()
    }

    func splitTab(_ draggedID: UUID, onto targetID: UUID, side: SplitTabDropSide = .leading) {
        guard
            draggedID != targetID,
            let draggedTab = tabs.first(where: { $0.id == draggedID }),
            let targetTab = tabs.first(where: { $0.id == targetID }),
            draggedTab.spaceID == targetTab.spaceID
        else {
            return
        }

        activeSpaceID = targetTab.spaceID
        var groupIDs: [UUID]
        if isSplitViewEnabled, splitGroupTabIDs().contains(targetID) {
            let existingGroupIDs = splitGroupTabIDs()
            guard existingGroupIDs.contains(draggedID) || existingGroupIDs.count < Self.splitViewMaxTabs else { return }
            groupIDs = Self.insertingSplitTab(draggedID, beside: targetID, side: side, in: existingGroupIDs)
        } else {
            groupIDs = side == .leading ? [draggedID, targetID] : [targetID, draggedID]
        }

        applySplitGroup(groupIDs, activeID: draggedID)
        updateNavigationState()
    }

    func focusSplitTab(_ id: UUID) {
        guard isSplitViewEnabled, activeSplitGroupTabIDs.contains(id), let activeTabID, activeTabID != id else {
            switchTab(to: id)
            return
        }

        let groupIDs = splitGroupTabIDs()
        applySplitGroup(groupIDs, activeID: id)
        updateNavigationState()
    }

    func closeSplitView() {
        isSplitViewEnabled = false
        splitTabIDs = []
    }

    func reorderTabs(_ orderedIDs: [UUID], isFavorite: Bool, isPinned: Bool, folderID: UUID? = nil) {
        for (offset, id) in orderedIDs.enumerated() {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            let wasFavorite = tabs[index].isFavorite
            tabs[index].isFavorite = isFavorite
            tabs[index].isPinned = isPinned && !isFavorite
            tabs[index].folderID = isFavorite ? nil : folderID
            tabs[index].sortOrder = Double(offset)
            if isFavorite {
                if !wasFavorite || tabs[index].favoriteURL == nil {
                    captureFavoriteSnapshot(at: index)
                }
            } else if wasFavorite {
                clearFavoriteSnapshot(at: index)
            }
        }
    }

    func moveTabToPlacement(
        _ tabID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID? = nil,
        before targetID: UUID? = nil,
        appendToEnd: Bool = false
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let spaceID = tabs[index].spaceID
        let resolvedFolderID = isFavorite ? nil : folderID.flatMap { folderID in
            folders.contains(where: { $0.id == folderID && $0.spaceID == spaceID }) ? folderID : nil
        }
        let resolvedPinned = (isPinned || resolvedFolderID != nil) && !isFavorite
        let wasFavorite = tabs[index].isFavorite
        tabs[index].isFavorite = isFavorite
        tabs[index].isPinned = resolvedPinned
        tabs[index].folderID = resolvedFolderID
        if isFavorite {
            if !wasFavorite || tabs[index].favoriteURL == nil {
                captureFavoriteSnapshot(at: index)
            }
        } else if wasFavorite {
            clearFavoriteSnapshot(at: index)
        }

        guard let targetID,
              tabs.contains(where: {
                  $0.id == targetID &&
                  $0.spaceID == spaceID &&
                  $0.isFavorite == isFavorite &&
                  $0.isPinned == resolvedPinned &&
                  $0.folderID == resolvedFolderID
              })
        else {
            tabs[index].sortOrder = appendToEnd
                ? lastSortOrder(
                    spaceID: spaceID,
                    isFavorite: isFavorite,
                    isPinned: resolvedPinned,
                    folderID: resolvedFolderID
                )
                : nextSortOrder(
                    spaceID: spaceID,
                    isFavorite: isFavorite,
                    isPinned: resolvedPinned,
                    folderID: resolvedFolderID
                )
            normalizeSortOrder()
            return
        }

        var orderedIDs = tabs
            .filter {
                $0.spaceID == spaceID &&
                $0.isFavorite == isFavorite &&
                $0.isPinned == resolvedPinned &&
                $0.folderID == resolvedFolderID
            }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)

        orderedIDs.removeAll { $0 == tabID }
        let targetIndex = orderedIDs.firstIndex(of: targetID) ?? orderedIDs.endIndex
        orderedIDs.insert(tabID, at: targetIndex)
        reorderTabs(orderedIDs, isFavorite: isFavorite, isPinned: resolvedPinned, folderID: resolvedFolderID)
    }

    func beginTabDrag(_ tabID: UUID) -> NSItemProvider {
        dropSourceClearTask?.cancel()
        dropSourceClearTask = nil
        settlingDroppedTabID = nil
        settlingDroppedTabSource = nil
        draggedTabID = tabID
        clearSidebarDropIndicator()
        clearSplitDropPreview()
        startTabDragSessionWatcher(for: tabID)
        return NSItemProvider(object: tabID.uuidString as NSString)
    }

    func sidebarPlacement(for tabID: UUID) -> SidebarTabDropPlacement? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        if tab.isFavorite { return .favorites }
        if let folderID = tab.folderID { return .folder(folderID) }
        if tab.isPinned { return .pinned }
        return .regular
    }

    func shouldHideSidebarTab(_ tabID: UUID, placement: SidebarTabDropPlacement) -> Bool {
        if draggedTabID == tabID { return true }
        if settlingDroppedTabID == tabID { return true }
        return settlingDroppedTabSource == SidebarDroppedTabSource(tabID: tabID, placement: placement)
    }

    func updateSidebarDropIndicator(
        placement: SidebarTabDropPlacement,
        targetTabID: UUID?,
        edge: SidebarTabDropEdge
    ) {
        let indicator = SidebarTabDropIndicator(
            placement: placement,
            targetTabID: targetTabID,
            edge: edge
        )
        guard sidebarDropIndicator != indicator else { return }
        sidebarDropIndicator = indicator
    }

    func clearSidebarDropIndicator() {
        guard sidebarDropIndicator != nil else { return }
        sidebarDropIndicator = nil
    }

    func splitDropTargetTabID(for side: SplitTabDropSide, draggedID: UUID) -> UUID? {
        guard let activeTabID else { return nil }
        let groupIDs = splitGroupTabIDs()
        let candidateID: UUID?

        if isSplitViewEnabled, groupIDs.count >= 2 {
            if !groupIDs.contains(draggedID), groupIDs.count >= Self.splitViewMaxTabs {
                return nil
            }

            let orderedIDs = side == .leading ? groupIDs : groupIDs.reversed()
            candidateID = orderedIDs.first { $0 != draggedID }
        } else {
            candidateID = activeTabID == draggedID ? nil : activeTabID
        }

        guard
            let candidateID,
            tabs.contains(where: { $0.id == candidateID && $0.spaceID == activeSpaceID })
        else {
            return nil
        }
        return candidateID
    }

    func updateSplitDropPreview(targetTabID: UUID, side: SplitTabDropSide) {
        let preview = SplitTabDropPreview(targetTabID: targetTabID, side: side)
        guard splitDropPreview != preview else { return }
        splitDropPreview = preview
    }

    func clearSplitDropPreview() {
        guard splitDropPreview != nil else { return }
        splitDropPreview = nil
    }

    func finishTabDrag() {
        draggedTabID = nil
        clearSidebarDropIndicator()
        clearSplitDropPreview()
        tabDragSessionWatcher?.invalidate()
        tabDragSessionWatcher = nil
        dropSourceClearTask?.cancel()
        dropSourceClearTask = nil
        settlingDroppedTabID = nil
        settlingDroppedTabSource = nil
    }

    func finishTabDrop(
        _ tabID: UUID,
        from sourcePlacement: SidebarTabDropPlacement?,
        to destinationPlacement: SidebarTabDropPlacement
    ) {
        draggedTabID = nil
        clearSidebarDropIndicator()
        clearSplitDropPreview()
        tabDragSessionWatcher?.invalidate()
        tabDragSessionWatcher = nil

        dropSourceClearTask?.cancel()
        dropSourceClearTask = nil

        let settledTabID = tabID
        let source = sourcePlacement == destinationPlacement
            ? nil
            : sourcePlacement.map { SidebarDroppedTabSource(tabID: tabID, placement: $0) }
        settlingDroppedTabID = settledTabID
        settlingDroppedTabSource = source
        dropSourceClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sidebarDropSettleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard
                    let self,
                    self.settlingDroppedTabID == settledTabID,
                    self.settlingDroppedTabSource == source
                else { return }
                self.settlingDroppedTabID = nil
                self.settlingDroppedTabSource = nil
                self.dropSourceClearTask = nil
            }
        }
    }

    // SwiftUI's onDrag exposes no end-of-session signal, and a drag released
    // over the web view or outside the window never reaches a drop delegate —
    // draggedTabID would stay stale, keeping the source row hidden and letting
    // unrelated text drags trigger ghost reorders. The mouse button is the
    // only reliable signal, so watch it while — and only while — a tab drag
    // is in flight; the watcher tears itself down on release.
    private func startTabDragSessionWatcher(for tabID: UUID) {
        tabDragSessionWatcher?.invalidate()
        let watcher = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard self.draggedTabID == tabID else {
                    self.tabDragSessionWatcher?.invalidate()
                    self.tabDragSessionWatcher = nil
                    return
                }
                guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
                self.tabDragSessionWatcher?.invalidate()
                self.tabDragSessionWatcher = nil
                // System drag sessions can report the mouse as no longer
                // pressed while SwiftUI is still delivering drop target
                // updates. Keep the source row hidden if a sidebar target is
                // still active, otherwise clear truly abandoned drags.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.draggedTabID == tabID else { return }
                        if self.sidebarDropIndicator != nil || self.splitDropPreview != nil {
                            self.startTabDragSessionWatcher(for: tabID)
                            return
                        }
                        self.finishTabDrag()
                    }
                }
            }
        }
        tabDragSessionWatcher = watcher
        // .common keeps the watcher firing inside the drag's event-tracking
        // runloop mode, where default-mode timers stall.
        RunLoop.main.add(watcher, forMode: .common)
    }

    func navigateActiveTab(to rawInput: String) {
        guard let url = navigationService.destinationURL(
            for: rawInput,
            defaultSearchProviderID: defaultSearchProviderID
        ) else { return }
        navigateActiveTab(to: url)
    }

    func navigateActiveTab(to url: URL) {
        // Empty spaces have no active tab; navigating from the address
        // dialog should open one rather than dropping the input.
        guard let activeTab else {
            _ = newTab(url: url)
            return
        }

        // Favorites and pinned tabs are saved destinations. Navigating the
        // address bar to another site should preserve that destination and
        // create a regular tab for the new page, rather than leaving the
        // sidebar with no visible tab for the page the user just opened.
        if shouldOpenNewTab(from: activeTab, to: url) {
            _ = newTab(url: url)
            return
        }

        setURL(url, title: title(for: url), for: activeTab.id)
        webCoordinator.load(url, in: activeTab.id)
    }

    func navigateNewTab(to rawInput: String) {
        guard let url = navigationService.destinationURL(
            for: rawInput,
            defaultSearchProviderID: defaultSearchProviderID
        ) else { return }
        navigateNewTab(to: url)
    }

    func navigateNewTab(to url: URL) {
        // Already sitting on an empty tab: fill it instead of stacking
        // another "New Tab" in the sidebar.
        if let activeTab, activeTab.url == nil {
            navigateActiveTab(to: url)
            return
        }

        newTab(url: url)
    }

    func goBack() {
        guard let activeTabID else { return }
        webCoordinator.goBack(tabID: activeTabID)
    }

    func goForward() {
        guard let activeTabID else { return }
        webCoordinator.goForward(tabID: activeTabID)
    }

    func reloadActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.reload(tabID: activeTabID)
    }

    func stopLoadingActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.stopLoading(tabID: activeTabID)
        setLoading(false, for: activeTabID)
    }

    func updateTabFromWebView(
        tabID: UUID,
        title: String?,
        url: URL?,
        isLoading: Bool,
        loadingProgress: Double,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // The internal home page is loaded via loadHTMLString and WebKit
        // reports it as about:blank; keep the tab URL-less instead of
        // surfacing the placeholder in the tab row and address bar.
        let isInternalHomePage = Self.isInternalBlankPlaceholderURL(url)
        let reportedURL = isInternalHomePage ? nil : url

        if isInternalHomePage {
            tabs[index].title = BrowserDefaults.newTabTitle
        } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabs[index].title = title
        } else if let reportedURL {
            tabs[index].title = self.title(for: reportedURL)
        }

        tabs[index].url = reportedURL
        tabs[index].faviconSymbol = faviconService.placeholderSymbol(for: reportedURL)
        tabs[index].isLoading = isLoading
        tabs[index].loadingProgress = loadingProgress
        updateFavoriteSnapshotIfStillOnSavedURL(at: index)

        if activeTabID == tabID {
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
        }
    }

    func updateFavicon(tabID: UUID, data: Data?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), let data else { return }
        tabs[index].faviconData = data
        if tabs[index].isFavorite && favoriteSnapshotMatchesLiveURL(tabs[index]) {
            tabs[index].favoriteFaviconData = data
        }
    }

    func recordHistoryVisit(tabID: UUID, title: String?, url: URL?) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            let url,
            !Self.isInternalBlankPlaceholderURL(url)
        else {
            return
        }

        tabs[index].lastAccessedAt = Date()
        let tab = tabs[index]

        let resolvedTitle: String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTitle = title
        } else {
            resolvedTitle = self.title(for: url)
        }

        historyRepository.record(
            HistoryVisit(
                id: UUID(),
                title: resolvedTitle,
                url: url,
                tabID: tabID,
                spaceID: tab.spaceID,
                visitedAt: Date()
            )
        )
    }

    func recentHistory(matching query: String = "", limit: Int = 8) -> [HistoryVisit] {
        historyRepository.recentVisits(matching: query, in: activeSpaceID, limit: limit)
    }

    func flushSession() {
        saveSnapshot()
    }

    func setWorkspaceICloudSyncEnabled(_ enabled: Bool) {
        guard iCloudWorkspaceSyncEnabled != enabled else { return }

        if enabled, !CandoaCloudKitEntitlements.hasConfiguredContainer {
            syncRestartMessage = """
            This build is not signed with the CloudKit entitlement yet. Enable the iCloud capability for iCloud.app.candoa.Candoa in Xcode, then build with your Apple Developer team.
            """
            return
        }

        iCloudWorkspaceSyncEnabled = enabled
        CandoaSyncPreferences.syncsWorkspaceWithICloud = enabled

        if !enabled {
            iCloudHistorySyncEnabled = false
        }

        syncRestartMessage = enabled
            ? "Candoa will start syncing Spaces and tabs through your private iCloud database after you relaunch the app."
            : "Candoa will return to local-only Spaces and tabs after you relaunch the app."
    }

    func setHistoryICloudSyncEnabled(_ enabled: Bool) {
        guard iCloudHistorySyncEnabled != enabled else { return }

        if enabled, !CandoaCloudKitEntitlements.hasConfiguredContainer {
            syncRestartMessage = """
            This build is not signed with the CloudKit entitlement yet. Enable the iCloud capability for iCloud.app.candoa.Candoa in Xcode before syncing history.
            """
            return
        }

        if enabled, !iCloudWorkspaceSyncEnabled {
            setWorkspaceICloudSyncEnabled(true)
        }

        iCloudHistorySyncEnabled = enabled
        CandoaSyncPreferences.syncsHistoryWithICloud = enabled
        syncRestartMessage = enabled
            ? "Candoa will sync browsing history through your private iCloud database after you relaunch the app."
            : "Candoa will keep browsing history local-only after you relaunch the app."
    }

    func setLoading(_ isLoading: Bool, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isLoading = isLoading
        updateNavigationState()
    }

    private func setURL(_ url: URL, title: String, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].url = url
        tabs[index].title = title
        tabs[index].faviconSymbol = faviconService.placeholderSymbol(for: url)
        tabs[index].faviconData = nil
        tabs[index].isLoading = true
        tabs[index].loadingProgress = 0.05
        tabs[index].lastAccessedAt = Date()
    }

    private func shouldOpenNewTab(from tab: BrowserTab, to destination: URL) -> Bool {
        guard tab.isFavorite || tab.isPinned, let currentURL = tab.url else {
            return false
        }

        // Keep normal in-site navigation in the saved tab. A different host
        // is a new browsing task and belongs in an ordinary tab.
        return differentHosts(currentURL, destination)
    }

    private func differentHosts(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.host(percentEncoded: false)?.lowercased()
            != rhs.host(percentEncoded: false)?.lowercased()
    }

    private func captureFavoriteSnapshot(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].favoriteTitle = tabs[index].title
        tabs[index].favoriteURL = tabs[index].url
        tabs[index].favoriteFaviconSymbol = tabs[index].faviconSymbol
        tabs[index].favoriteFaviconData = tabs[index].faviconData
    }

    private func clearFavoriteSnapshot(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].favoriteTitle = nil
        tabs[index].favoriteURL = nil
        tabs[index].favoriteFaviconSymbol = nil
        tabs[index].favoriteFaviconData = nil
    }

    private func updateFavoriteSnapshotIfStillOnSavedURL(at index: Int) {
        guard tabs.indices.contains(index), tabs[index].isFavorite else { return }
        if tabs[index].favoriteURL == nil {
            captureFavoriteSnapshot(at: index)
            return
        }

        guard favoriteSnapshotMatchesLiveURL(tabs[index]) else { return }
        tabs[index].favoriteTitle = tabs[index].title
        tabs[index].favoriteFaviconSymbol = tabs[index].faviconSymbol
        if let faviconData = tabs[index].faviconData {
            tabs[index].favoriteFaviconData = faviconData
        }
    }

    private func favoriteSnapshotMatchesLiveURL(_ tab: BrowserTab) -> Bool {
        guard let favoriteURL = tab.favoriteURL else { return true }
        return tab.url == favoriteURL
    }

    private func title(for url: URL?) -> String {
        guard let url else { return BrowserDefaults.newTabTitle }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    private func updateNavigationState() {
        guard let activeTabID else {
            canGoBack = false
            canGoForward = false
            return
        }

        let state = webCoordinator.navigationState(for: activeTabID)
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
    }

    private func configureAutosave() {
        let changes = Publishers.MergeMany(
            $spaces.map { _ in () }.eraseToAnyPublisher(),
            $folders.map { _ in () }.eraseToAnyPublisher(),
            $tabs.map { _ in () }.eraseToAnyPublisher(),
            $activeSpaceID.map { _ in () }.eraseToAnyPublisher(),
            $activeTabID.map { _ in () }.eraseToAnyPublisher(),
            $splitTabIDs.map { _ in () }.eraseToAnyPublisher(),
            $isSplitViewEnabled.map { _ in () }.eraseToAnyPublisher()
        )

        saveCancellable = changes
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSnapshot()
            }
    }

    private func configureRemoteSyncObservation() {
        guard persistenceService.syncsWorkspaceWithICloud else { return }

        remoteChangeCancellable = NotificationCenter.default
            .publisher(for: PersistenceService.remoteStoreDidChange)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyRemoteStateIfNeeded()
                }
            }
    }

    private func saveSnapshot() {
        guard !isInitialSpaceSetupPresented, !isApplyingRemoteState else { return }

        workspaceRepository.saveWorkspace(currentSnapshot())
    }

    private func currentSnapshot() -> BrowserWindowState {
        BrowserWindowState(
            spaces: spaces,
            folders: folders,
            tabs: tabs.map { tab in
                var persistedTab = tab
                persistedTab.isLoading = false
                persistedTab.loadingProgress = 0
                return persistedTab
            },
            activeSpaceID: activeSpaceID,
            activeTabID: activeTabID,
            splitTabIDs: splitTabIDs,
            isSplitViewEnabled: isSplitViewEnabled
        )
    }

    private func applyRemoteStateIfNeeded() {
        guard
            let remoteState = workspaceRepository.loadWorkspace(),
            !remoteState.spaces.isEmpty,
            remoteState != currentSnapshot()
        else {
            return
        }

        let previousTabs = tabs
        let previousSpaceDataStores = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.dataStoreID) })
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = false }

        spaces = remoteState.spaces
        folders = remoteState.folders
        tabs = remoteState.tabs
        activeSpaceID = remoteState.activeSpaceID
        activeTabID = remoteState.activeTabID
        splitTabIDs = remoteState.splitTabIDs
        isSplitViewEnabled = remoteState.isSplitViewEnabled
        repairSessionState()
        isInitialSpaceSetupPresented = needsInitialSpaceSetup()
        if !isInitialSpaceSetupPresented {
            isCreateSpacePresented = false
        }
        if let editingSpaceID, !spaces.contains(where: { $0.id == editingSpaceID }) {
            self.editingSpaceID = nil
        }
        if let editingFolderID, !folders.contains(where: { $0.id == editingFolderID }) {
            self.editingFolderID = nil
        }

        let tabIDs = Set(tabs.map(\.id))
        for previousTab in previousTabs where !tabIDs.contains(previousTab.id) {
            webCoordinator.removeWebView(for: previousTab.id)
        }

        for tab in tabs {
            guard let previousTab = previousTabs.first(where: { $0.id == tab.id }) else { continue }
            let previousDataStoreID = previousSpaceDataStores[previousTab.spaceID] ?? previousTab.spaceID
            if previousTab.spaceID != tab.spaceID || previousDataStoreID != dataStoreID(for: tab.spaceID) {
                webCoordinator.removeWebView(for: tab.id)
            }
        }

        restoreVisibleWebViews()
        updateNavigationState()
    }

    private func switchTab(offset: Int) {
        let visibleTabs = visibleTabsForActiveSpace
        guard !visibleTabs.isEmpty else { return }
        let currentIndex = visibleTabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        let nextIndex = (currentIndex + offset + visibleTabs.count) % visibleTabs.count
        switchTab(to: visibleTabs[nextIndex].id)
    }

    private func switchTabInRecentOrder(offset: Int, keepsPreviewOpen: Bool) {
        // Control-Tab starts from most-recent order, so a quick press toggles
        // between the current tab and the previous tab. The list is frozen
        // while Control stays held so hold-to-cycle doesn't shift underneath
        // the selection; releasing Control ends the interaction even if the
        // overlay is still fading, so the next press re-freezes from the
        // just-committed recency order.
        let isFreshInteraction = !isTabSwitcherCycling || tabSwitcherCandidates.isEmpty
        if isFreshInteraction {
            isTabSwitcherCycling = true
            tabSwitcherCandidates = recentTabsForActiveSpace()
        }

        let recentTabs = tabSwitcherCandidates
        guard !recentTabs.isEmpty else { return }
        guard recentTabs.count > 1 else {
            presentTabSwitcher(
                candidates: recentTabs,
                selectedTabID: activeTabID,
                autoHide: !keepsPreviewOpen
            )
            return
        }

        // A fresh press while the return morph is still landing must cycle
        // from the morph's destination, not the not-yet-switched active tab.
        let currentSelectionID = (isFreshInteraction ? nil : tabSwitcherSelectedTabID)
            ?? pendingMiniPlayerReturnTabID
            ?? activeTabID
        let nextIndex: Int
        if let currentIndex = recentTabs.firstIndex(where: { $0.id == currentSelectionID }) {
            nextIndex = (currentIndex + offset + recentTabs.count) % recentTabs.count
        } else {
            // Active tab sits outside the top tabs: enter the list at the
            // nearest end instead of skipping past it.
            nextIndex = offset > 0 ? 0 : recentTabs.count - 1
        }
        let selectedTabID = recentTabs[nextIndex].id
        // While Control is held only the selection moves; the real switch
        // commits on release (finishTabSwitcherInteraction), so holding to
        // look at the preview never flips the page underneath. Callers
        // without a release event still switch immediately.
        if !keepsPreviewOpen {
            switchTab(to: selectedTabID, updatesAccessTime: false)
        }
        presentTabSwitcher(
            candidates: recentTabs,
            selectedTabID: selectedTabID,
            autoHide: !keepsPreviewOpen
        )
    }

    private func presentTabSwitcher(
        candidates: [BrowserTab]? = nil,
        selectedTabID: UUID? = nil,
        autoHide: Bool = true
    ) {
        let selectedTabID = selectedTabID ?? activeTabID
        let previewTabs = tabSwitcherPreviewTabs(
            from: candidates ?? recentTabsForActiveSpace(),
            selectedTabID: selectedTabID
        )
        guard !previewTabs.isEmpty else {
            hideTabSwitcher()
            return
        }

        tabSwitcherHideWorkItem?.cancel()
        tabSwitcherTabs = previewTabs
        tabSwitcherSelectedTabID = selectedTabID ?? previewTabs.first?.id

        if isTabSwitcherPresented || autoHide {
            tabSwitcherShowWorkItem?.cancel()
            tabSwitcherShowWorkItem = nil
            isTabSwitcherPresented = true
        } else if tabSwitcherShowWorkItem == nil {
            // Hold-to-reveal: defer the overlay so a quick Control-Tab stays a
            // silent switch. Repeated presses keep the original deadline.
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.tabSwitcherShowWorkItem = nil
                    self.isTabSwitcherPresented = true
                }
            }
            tabSwitcherShowWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + TabSwitcherConfiguration.holdRevealDelay,
                execute: workItem
            )
        }

        guard autoHide else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideTabSwitcher()
            }
        }
        tabSwitcherHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: workItem)
    }

    private func hideTabSwitcher() {
        tabSwitcherHideWorkItem?.cancel()
        tabSwitcherHideWorkItem = nil
        tabSwitcherShowWorkItem?.cancel()
        tabSwitcherShowWorkItem = nil
        isTabSwitcherPresented = false
        tabSwitcherCandidates = []
        tabSwitcherSelectedTabID = nil

        // Flows without a Control-release event (auto-hide) end their
        // interaction here: commit the access time the cycling deferred.
        // Control-release flows already stamped the landed tab in
        // finishTabSwitcherInteraction — stamping again here would hit the
        // old tab when the switch is deferred behind the return morph.
        if isTabSwitcherCycling, let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs[index].lastAccessedAt = Date()
        }
        isTabSwitcherCycling = false
    }

    private func recentTabsForActiveSpace() -> [BrowserTab] {
        var candidates = tabs.filter {
            $0.spaceID == activeSpaceID && $0.hasBeenActivated
        }

        if scopesControlTabToCurrentGroup, let activeTab {
            candidates = candidates.filter { tab in
                activeTab.isFavorite ? tab.isFavorite : !tab.isFavorite
            }
        }

        if ignoresPendingTabsWhenCycling {
            candidates = candidates.filter { !isPendingTabForControlTab($0) }
        }

        return candidates
            .sorted {
                if $0.lastAccessedAt == $1.lastAccessedAt {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.lastAccessedAt > $1.lastAccessedAt
            }
    }

    private func markActiveTabAsActivated() {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        tabs[index].hasBeenActivated = true
    }

    private func isPendingTabForControlTab(_ tab: BrowserTab) -> Bool {
        tab.url == nil || tab.isLoading || !webCoordinator.hasLoadedWebView(for: tab.id)
    }

    private func tabSwitcherPreviewTabs(from candidates: [BrowserTab], selectedTabID: UUID?) -> [BrowserTab] {
        var previewTabs = Array(candidates.prefix(TabSwitcherConfiguration.previewLimit))
        guard
            let selectedTabID,
            !previewTabs.contains(where: { $0.id == selectedTabID }),
            let selectedTab = candidates.first(where: { $0.id == selectedTabID })
        else {
            return previewTabs
        }

        if previewTabs.count == TabSwitcherConfiguration.previewLimit {
            previewTabs[previewTabs.count - 1] = selectedTab
        } else {
            previewTabs.append(selectedTab)
        }

        return previewTabs
    }

    private func switchSpace(offset: Int) {
        guard !spaces.isEmpty, let currentIndex = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        let nextIndex = (currentIndex + offset + spaces.count) % spaces.count
        switchSpace(to: spaces[nextIndex].id)
    }

    private func nextSortOrder(
        spaceID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID? = nil
    ) -> Double {
        let resolvedPinned = isPinned && !isFavorite
        let orders = tabs
            .filter {
                $0.spaceID == spaceID &&
                $0.isFavorite == isFavorite &&
                $0.isPinned == resolvedPinned &&
                $0.folderID == (isFavorite ? nil : folderID)
            }
            .map(\.sortOrder)
        return (orders.min() ?? 0) - 1
    }

    private func lastSortOrder(
        spaceID: UUID,
        isFavorite: Bool,
        isPinned: Bool,
        folderID: UUID? = nil
    ) -> Double {
        let resolvedPinned = isPinned && !isFavorite
        let orders = tabs
            .filter {
                $0.spaceID == spaceID &&
                $0.isFavorite == isFavorite &&
                $0.isPinned == resolvedPinned &&
                $0.folderID == (isFavorite ? nil : folderID)
            }
            .map(\.sortOrder)
        return (orders.max() ?? -1) + 1
    }

    private func nextFolderSortOrder(spaceID: UUID, parentFolderID: UUID? = nil) -> Double {
        let orders = folders
            .filter { $0.spaceID == spaceID && $0.parentFolderID == parentFolderID }
            .map(\.sortOrder)
        return (orders.min() ?? 0) - 1
    }

    private func replacementSplitTab(excluding excludedID: UUID?) -> BrowserTab? {
        visibleTabsForActiveSpace.first { $0.id != excludedID }
    }

    private func tab(_ id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id && $0.spaceID == activeSpaceID }
    }

    private func splitGroupTabIDs() -> [UUID] {
        guard isSplitViewEnabled, let activeTabID else { return [] }

        var ids = splitTabIDs
        if !ids.contains(activeTabID) {
            // Older persisted sessions stored only the non-active split tabs.
            // Keep those sessions valid without letting focus reorder panes.
            ids.insert(activeTabID, at: 0)
        }

        var seen = Set<UUID>()
        return ids
            .filter { id in
                guard !seen.contains(id), tab(id) != nil else { return false }
                seen.insert(id)
                return true
            }
            .prefix(Self.splitViewMaxTabs)
            .map { $0 }
    }

    private func applySplitGroup(_ ids: [UUID], activeID: UUID?) {
        var seen = Set<UUID>()
        let validIDs = ids
            .filter { id in
                guard !seen.contains(id), tab(id) != nil else { return false }
                seen.insert(id)
                return true
            }
            .prefix(Self.splitViewMaxTabs)
            .map { $0 }

        guard validIDs.count >= 2 else {
            if let activeID, validIDs.contains(activeID) {
                activeTabID = activeID
            } else if let firstID = validIDs.first {
                activeTabID = firstID
            }
            splitTabIDs = []
            isSplitViewEnabled = false
            return
        }

        let resolvedActiveID = activeID.flatMap { validIDs.contains($0) ? $0 : nil } ?? validIDs[0]
        activeTabID = resolvedActiveID
        splitTabIDs = validIDs
        isSplitViewEnabled = validIDs.count >= 2
    }

    private func newInternalBlankTab(in spaceID: UUID) -> BrowserTab {
        let tab = BrowserTab(
            spaceID: spaceID,
            sortOrder: nextSortOrder(spaceID: spaceID, isFavorite: false, isPinned: false, folderID: nil)
        )

        tabs.insert(tab, at: 0)
        switchTab(to: tab.id)
        return tab
    }

    private func recreateWebViewsIfNeeded(
        in spaceID: UUID,
        previousDataStoreID: UUID,
        nextDataStoreID: UUID
    ) {
        guard previousDataStoreID != nextDataStoreID else { return }

        let affectedTabIDs = tabs
            .filter { $0.spaceID == spaceID }
            .map(\.id)
        affectedTabIDs.forEach { webCoordinator.removeWebView(for: $0) }

        guard activeSpaceID == spaceID else { return }

        if let activeTab {
            webCoordinator.ensureLoaded(activeTab)
        }

        for splitTab in activeSplitTabs {
            webCoordinator.ensureLoaded(splitTab)
        }
    }

    private func repairSessionState() {
        if spaces.isEmpty {
            spaces = [BrowserSpace(name: "", symbolName: "circle.grid.2x2")]
        }

        for index in spaces.indices where !spaces[index].name.isEmpty {
            spaces[index].name = Self.normalizedSpaceName(spaces[index].name)
        }

        let spaceIDs = Set(spaces.map(\.id))
        folders = folders.filter { spaceIDs.contains($0.spaceID) }
        for index in folders.indices {
            folders[index].name = normalizedFolderName(folders[index].name)
            if folders[index].name.isEmpty {
                folders[index].name = "New Folder"
            }
        }

        let folderSpaceByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.spaceID) })
        for index in folders.indices {
            guard let parentID = folders[index].parentFolderID else { continue }
            if folderSpaceByID[parentID] != folders[index].spaceID || folderHasAncestor(parentID, ancestorID: folders[index].id) {
                folders[index].parentFolderID = nil
            }
        }
        tabs = tabs.filter { spaceIDs.contains($0.spaceID) }

        for index in tabs.indices {
            if tabs[index].isFavorite {
                tabs[index].folderID = nil
                tabs[index].isPinned = false
                if tabs[index].favoriteURL == nil {
                    captureFavoriteSnapshot(at: index)
                }
                continue
            }

            guard let folderID = tabs[index].folderID else { continue }
            if folderSpaceByID[folderID] == tabs[index].spaceID {
                tabs[index].isPinned = true
            } else {
                tabs[index].folderID = nil
            }
        }

        if recoverSavedTabNavigations() {
            needsWorkspaceSaveAfterRepair = true
        }

        if !spaceIDs.contains(activeSpaceID) {
            activeSpaceID = spaces[0].id
        }

        normalizeSortOrder()

        if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID && $0.spaceID == activeSpaceID }) {
            activeTabID = visibleTabsForActiveSpace.first?.id
        }

        if isSplitViewEnabled {
            splitTabIDs = Self.validSplitGroupIDs(
                splitTabIDs,
                activeTabID: activeTabID,
                activeSpaceID: activeSpaceID,
                tabs: tabs,
                includesActiveTabID: true
            )
            isSplitViewEnabled = splitTabIDs.count >= 2
        } else {
            splitTabIDs = []
        }
    }

    /// Older builds allowed the sidebar address field to replace a favorite's
    /// live URL while retaining its saved title and icon. Preserve both sites
    /// when opening that state: restore the favorite and make the live page a
    /// regular tab.
    private func recoverSavedTabNavigations() -> Bool {
        let originalTabCount = tabs.count
        var recoveredTabs: [BrowserTab] = []
        var replacementActiveTabID: UUID?

        for index in 0..<originalTabCount {
            let tab = tabs[index]
            guard
                tab.isFavorite,
                let savedURL = tab.favoriteURL,
                let liveURL = tab.url,
                differentHosts(savedURL, liveURL)
            else {
                continue
            }

            let recoveredTab = BrowserTab(
                title: tab.title,
                url: liveURL,
                faviconSymbol: tab.faviconSymbol,
                faviconData: tab.faviconData,
                spaceID: tab.spaceID,
                sortOrder: nextSortOrder(
                    spaceID: tab.spaceID,
                    isFavorite: false,
                    isPinned: false,
                    folderID: nil
                ),
                lastAccessedAt: tab.lastAccessedAt
            )
            recoveredTabs.append(recoveredTab)

            tabs[index].title = tab.favoriteDisplayTitle
            tabs[index].url = savedURL
            tabs[index].faviconSymbol = tab.favoriteDisplayFaviconSymbol
            tabs[index].faviconData = tab.favoriteDisplayFaviconData
            tabs[index].isLoading = false
            tabs[index].loadingProgress = 0

            if activeTabID == tab.id {
                replacementActiveTabID = recoveredTab.id
            }
        }

        guard !recoveredTabs.isEmpty else { return false }
        tabs.append(contentsOf: recoveredTabs)
        activeTabID = replacementActiveTabID ?? activeTabID
        return true
    }

    private static func insertingSplitTab(
        _ draggedID: UUID,
        beside targetID: UUID,
        side: SplitTabDropSide,
        in groupIDs: [UUID]
    ) -> [UUID] {
        var orderedIDs = groupIDs.filter { $0 != draggedID }
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else {
            return groupIDs
        }

        let insertionIndex = side == .leading
            ? targetIndex
            : orderedIDs.index(after: targetIndex)
        orderedIDs.insert(draggedID, at: insertionIndex)
        return orderedIDs
    }

    private static func validSplitGroupIDs(
        _ ids: [UUID],
        activeTabID: UUID?,
        activeSpaceID: UUID,
        tabs: [BrowserTab],
        includesActiveTabID: Bool
    ) -> [UUID] {
        var orderedIDs = ids
        if
            includesActiveTabID,
            let activeTabID,
            !orderedIDs.contains(activeTabID)
        {
            orderedIDs.insert(activeTabID, at: 0)
        }

        var seen = Set<UUID>()
        return orderedIDs
            .filter { id in
                guard !seen.contains(id) else { return false }
                guard tabs.contains(where: { $0.id == id && $0.spaceID == activeSpaceID }) else { return false }
                seen.insert(id)
                return true
            }
            .prefix(Self.splitViewMaxTabs)
            .map { $0 }
    }

    private func needsInitialSpaceSetup() -> Bool {
        spaces.count == 1 && spaces[0].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedFolderName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    }

    private func uniqueFolderName(base: String, in spaceID: UUID) -> String {
        let normalizedBase = normalizedFolderName(base).isEmpty ? "New Folder" : normalizedFolderName(base)
        let existingNames = Set(
            folders
                .filter { $0.spaceID == spaceID }
                .map { $0.name.lowercased() }
        )
        guard existingNames.contains(normalizedBase.lowercased()) else { return normalizedBase }

        for index in 2...99 {
            let candidate = "\(normalizedBase) \(index)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
        }

        return "\(normalizedBase) \(folders.count + 1)"
    }

    private func folderHasAncestor(_ folderID: UUID, ancestorID: UUID) -> Bool {
        var seen = Set<UUID>()
        var currentID: UUID? = folderID

        while let id = currentID {
            if id == ancestorID { return true }
            guard seen.insert(id).inserted else { return true }
            currentID = folders.first { $0.id == id }?.parentFolderID
        }

        return false
    }

    private static func isInternalBlankPlaceholderURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString == "about:blank"
    }

    private func normalizeSortOrder() {
        for spaceID in spaces.map(\.id) {
            normalizeFolderSortOrder(spaceID: spaceID)
            normalizeSortOrder(spaceID: spaceID, isFavorite: true, isPinned: false, folderID: nil)
            normalizeSortOrder(spaceID: spaceID, isFavorite: false, isPinned: true, folderID: nil)
            for folder in folders where folder.spaceID == spaceID {
                normalizeSortOrder(spaceID: spaceID, isFavorite: false, isPinned: true, folderID: folder.id)
            }
            normalizeSortOrder(spaceID: spaceID, isFavorite: false, isPinned: false, folderID: nil)
        }
    }

    private func normalizeFolderSortOrder(spaceID: UUID) {
        let parentIDs = Set(folders.filter { $0.spaceID == spaceID }.map(\.parentFolderID)) as Set<UUID?>

        for parentID in parentIDs {
            let orderedIDs = folders
                .filter { $0.spaceID == spaceID && $0.parentFolderID == parentID }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.id)

            for (offset, id) in orderedIDs.enumerated() {
                guard let index = folders.firstIndex(where: { $0.id == id }) else { continue }
                folders[index].sortOrder = Double(offset)
            }
        }
    }

    private func normalizeSortOrder(spaceID: UUID, isFavorite: Bool, isPinned: Bool, folderID: UUID?) {
        let resolvedPinned = isPinned && !isFavorite
        let orderedIDs = tabs
            .filter {
                $0.spaceID == spaceID &&
                $0.isFavorite == isFavorite &&
                $0.isPinned == resolvedPinned &&
                $0.folderID == (isFavorite ? nil : folderID)
            }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.lastAccessedAt > $1.lastAccessedAt
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map(\.id)

        for (offset, id) in orderedIDs.enumerated() {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            tabs[index].sortOrder = Double(offset)
        }
    }

    private func restoreVisibleWebViews() {
        if let activeTab {
            webCoordinator.ensureLoaded(activeTab)
        }

        for splitTab in activeSplitTabs {
            webCoordinator.ensureLoaded(splitTab)
        }
    }
}

enum CandoaImageTextRecognizer {
    private static let textLimit = 6000

    static func recognizedText(in image: NSImage) -> String? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        return recognizedText(in: cgImage)
    }

    private static func recognizedText(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map {
                $0.replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        return String(text.prefix(textLimit))
    }
}
