import SwiftUI

struct BrowserCommandActions {
    var newTab: () -> Void
    var focusAddressBar: () -> Void
    var openCommandPalette: () -> Void
    var toggleSidebar: () -> Void
    var isSidebarVisible: Bool
    var toggleAISidebar: () -> Void
    var isAISidebarVisible: Bool
    var showHistory: () -> Void
    var isHistoryVisible: Bool
    var clearBrowsingData: () -> Void
    var canClearBrowsingData: Bool
    var showDownloads: () -> Void
    var isDownloadsVisible: Bool
    var showSiteInfo: () -> Void
    var canShowSiteInfo: Bool
    var showPrivacyReport: () -> Void
    var toggleReader: () -> Void
    var canToggleReader: Bool
    var isReaderActive: Bool
    var showQuickTour: () -> Void
    var openExtensionGallery: () -> Void
    var reloadTab: () -> Void
    var reloadTabFromOrigin: () -> Void
    var printPage: () -> Void
    var canPrintActiveTab: Bool
    var openLocalFile: () -> Void
    var saveActiveTabAs: () -> Void
    var sharePage: () -> Void
    var canSharePage: Bool
    var exportActiveTabAsPDF: () -> Void
    var canSaveActiveTab: Bool
    var stopLoading: () -> Void
    var isActiveTabLoading: Bool
    var canReloadActiveTab: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    var goHome: () -> Void
    var returnToSearchResults: () -> Void
    var canReturnToSearchResults: Bool
    var closeCurrentTab: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var nextSpace: () -> Void
    var previousSpace: () -> Void
    var reopenClosedTab: () -> Void
    var pinOrUnpinTab: () -> Void
    var isActiveTabPinned: Bool
    var isActiveTabFavorite: Bool
    var createSpace: () -> Void
    var editActiveSpace: () -> Void
    var spaces: [BrowserSpace]
    var activeSpaceID: UUID
    var selectSpace: (UUID) -> Void
    var canToggleFavorite: Bool
    var toggleFavoriteForActiveTab: () -> Void
    var duplicateTab: () -> Void
    var clearUnpinnedTabs: () -> Void
    var copyURL: () -> Void
    var copyURLAsMarkdown: () -> Void
    var findInPage: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var resetZoom: () -> Void
    var toggleSplitView: () -> Void
    var setSplitLayout: (SplitViewLayout) -> Void
    var isSplitDisplayed: Bool
    var toggleSplitPaneZoom: () -> Void
    var isSplitPaneZoomed: Bool
    var focusSplitPane: (Int) -> Void
    var unsplitPane: () -> Void
    var splitWithTab: () -> Void
    var installedBrowsers: [ExternalBrowserService.Browser]
    var openPageWith: (ExternalBrowserService.Browser) -> Void
    var canUseDevelopTools: Bool
    /// nil while a custom (Other…) user agent is active.
    var activeUserAgentPreset: UserAgentPreset?
    var setUserAgentPreset: (UserAgentPreset) -> Void
    var isCustomUserAgentActive: Bool
    var promptForCustomUserAgent: () -> Void
    var inspectablePages: [BrowserStore.InspectablePage]
    var inspectPage: (UUID) -> Void
    var isWebInspectorVisible: Bool
    var toggleWebInspector: () -> Void
    var connectWebInspector: () -> Void
    var showJavaScriptConsole: () -> Void
    var showPageSource: () -> Void
    var showPageResources: () -> Void
    var isRecordingTimeline: Bool
    var toggleTimelineRecording: () -> Void
    var isSelectingElement: Bool
    var toggleElementSelection: () -> Void
    var emptyCaches: () -> Void
    var arrangeTabsByTitle: () -> Void
    var arrangeTabsByWebsite: () -> Void
    var canArrangeTabs: Bool
    var canMuteActiveTab: Bool
    var isActiveTabMuted: Bool
    var toggleActiveTabMute: () -> Void
    var canMuteOtherTabs: Bool
    var muteOtherTabs: () -> Void
}

private struct BrowserCommandActionsKey: FocusedValueKey {
    typealias Value = BrowserCommandActions
}

extension FocusedValues {
    var browserCommandActions: BrowserCommandActions? {
        get { self[BrowserCommandActionsKey.self] }
        set { self[BrowserCommandActionsKey.self] = newValue }
    }
}
