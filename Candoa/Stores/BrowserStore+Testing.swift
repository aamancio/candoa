import Combine
import Foundation
import SQLite3

extension BrowserStore {
    static var isUITesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
#else
        false
#endif
    }

    /// Test-runner signal that stands in for a CloudKit import finishing:
    /// real remote changes come from `NSPersistentCloudKitContainer`, which
    /// UI tests can't drive, so the runner posts this distributed
    /// notification and the app injects a fixture workspace instead.
    static let uiTestingRemoteRestoreNotification =
        Notification.Name("app.candoa.uitesting.remote-restore")

    static var uiTestingSimulatesRemoteRestore: Bool {
        isUITesting
            && ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_REMOTE_RESTORE_FIXTURE"] == "1"
    }

    func configureUITestingRemoteRestoreTrigger() {
        guard Self.uiTestingSimulatesRemoteRestore else { return }

        uiTestingRemoteRestoreCancellable = DistributedNotificationCenter.default()
            .publisher(for: Self.uiTestingRemoteRestoreNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.workspaceRepository.saveWorkspace(Self.uiTestingRemoteRestoreState())
                    // One runloop beat so the background save's merge reaches
                    // the view context before the restore is read back.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self.applyRemoteStateIfNeeded()
                }
            }
    }

    static func uiTestingRemoteRestoreState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
        let notesTabID = UUID(uuidString: "DEDEDEDE-DEDE-DEDE-DEDE-DEDEDEDEDEDE")!
        let plannerTabID = UUID(uuidString: "EAEAEAEA-EAEA-EAEA-EAEA-EAEAEAEAEAEA")!
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)

        let space = BrowserSpace(
            id: spaceID,
            name: "Synced",
            symbolName: "icloud",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let tabs = [
            BrowserTab(
                id: notesTabID,
                title: "Synced Notes",
                url: URL(string: "https://fixture.candoa.test/synced-notes")!,
                spaceID: spaceID,
                sortOrder: 0,
                lastAccessedAt: fixtureDate,
                hasBeenActivated: true
            ),
            BrowserTab(
                id: plannerTabID,
                title: "Synced Planner",
                url: URL(string: "https://fixture.candoa.test/synced-planner")!,
                spaceID: spaceID,
                sortOrder: 1,
                lastAccessedAt: fixtureDate.addingTimeInterval(-60),
                hasBeenActivated: true
            )
        ]

        return BrowserWindowState(
            spaces: [space],
            folders: [],
            tabs: tabs,
            activeSpaceID: spaceID,
            activeTabID: notesTabID
        )
    }

    /// Mirrors hosted web-authentication outcomes into the state string:
    /// the host service lives on the app delegate, far from any store, so it
    /// broadcasts events in-process and every window's store republishes
    /// them through its own `ui-testing-state` element.
    func configureUITestingWebAuthObservation() {
        guard Self.isUITesting else { return }

        uiTestingWebAuthEventCancellable = NotificationCenter.default
            .publisher(for: WebAuthenticationSessionHostService.uiTestingWebAuthEventNotification)
            .sink { [weak self] notification in
                guard let event = notification.object as? String else { return }
                Task { @MainActor [weak self] in
                    self?.uiTestingWebAuthEvents.append(event)
                }
            }
    }

    /// Test-runner seam for download rows: real WKDownloads need a server
    /// the harness doesn't have, so tests drive the same item states the
    /// delegate callbacks would produce. Spec: "filename|phase|fraction".
    static let uiTestingDownloadFixtureNotification =
        Notification.Name("app.candoa.uitesting.download-fixture")

    func configureUITestingDownloadFixtureTrigger() {
        // Fixtures describe the ordinary windows' shared list; a private
        // window's ephemeral list must stay empty unless it downloads.
        guard Self.isUITesting, !isPrivate else { return }

        uiTestingDownloadFixtureCancellable = DistributedNotificationCenter.default()
            .publisher(for: Self.uiTestingDownloadFixtureNotification)
            .sink { [weak self] notification in
                guard let spec = notification.object as? String else { return }
                Task { @MainActor [weak self] in
                    self?.downloadsStore.applyUITestingFixture(spec)
                }
            }
    }

    /// Test-runner seam for the Ctrl-Tab switcher: neither XCTest's
    /// perform(withKeyModifiers:) nor runner-posted CGEvents can hold
    /// Control across several presses and assertions on CI (typeKey resets
    /// modifier state per key; raw event posting needs an Accessibility
    /// grant the runner doesn't have). The actions map 1:1 onto the store
    /// entry points ContentView's KeyboardShortcutMonitor callbacks invoke.
    static let uiTestingTabSwitcherNotification =
        Notification.Name("app.candoa.uitesting.tab-switcher")

    func configureUITestingTabSwitcherTrigger() {
        guard Self.isUITesting, !isPrivate else { return }

        uiTestingTabSwitcherCancellable = DistributedNotificationCenter.default()
            .publisher(for: Self.uiTestingTabSwitcherNotification)
            .sink { [weak self] notification in
                guard let action = notification.object as? String else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch action {
                    case "next": self.switchToNextRecentTab(keepsPreviewOpen: true)
                    case "previous": self.switchToPreviousRecentTab(keepsPreviewOpen: true)
                    case "release": self.finishTabSwitcherInteraction()
                    case "close": self.closeHighlightedTabInTabSwitcher()
                    case "cancel": self.cancelTabSwitcherInteraction()
                    default: break
                    }
                }
            }
    }

    /// Drives the active window from a fixture runner without synthetic
    /// input: `navigate:<url>` loads a page in the active tab, `tab:new:<url>`
    /// opens one in a new tab (which backgrounds the page that was playing,
    /// the way into the floating mini player), and `eli:toggle` opens or
    /// closes the Eli sidebar. Same rationale as the tab-switcher seam —
    /// keyboard-free, so it works while the machine is in use.
    static let uiTestingWindowCommandNotification =
        Notification.Name("app.candoa.uitesting.window-command")

    func configureUITestingWindowCommandTrigger() {
        guard Self.isUITesting, !isPrivate else { return }

        uiTestingWindowCommandCancellable = DistributedNotificationCenter.default()
            .publisher(for: Self.uiTestingWindowCommandNotification)
            .sink { [weak self] notification in
                guard let command = notification.object as? String else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if command.hasPrefix("navigate:") {
                        self.navigateActiveTab(to: String(command.dropFirst("navigate:".count)))
                    } else if command.hasPrefix("tab:new:") {
                        self.navigateNewTab(to: String(command.dropFirst("tab:new:".count)))
                    } else if command == "eli:toggle" {
                        self.aiSidebarToggleRequestID = UUID()
                    }
                }
            }
    }

    /// The floating player's controls only appear under the pointer, and a
    /// fixture runner has none: this pins them on so their layout — which
    /// goes compact in a portrait player — can be measured on screen.
    static var uiTestingForcesMiniPlayerControls: Bool {
        isUITesting
            && ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_MINI_PLAYER_CONTROLS"] == "1"
    }

    static var uiTestingOnboardingStep: InitialOnboardingStep? {
        guard isUITesting else { return nil }
        return ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_ONBOARDING_STEP"]
            .flatMap(InitialOnboardingStep.init(rawValue:))
    }

    static func uiTestingBrowserImportService() -> BrowserImportService? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CANDOA_UI_TESTING"] == "1",
              let fixtureName = environment["CANDOA_UI_TESTING_BROWSER_IMPORT_FIXTURE"]
        else { return nil }

        if fixtureName == "unreadable-safari" {
            let inaccessibleURL = FileManager.default.temporaryDirectory
                .appending(path: "MissingCandoaUITestSafariProfile", directoryHint: .isDirectory)
            let bookmarksURL = inaccessibleURL.appending(
                path: "Bookmarks.plist",
                directoryHint: .notDirectory
            )
            do {
                try FileManager.default.createDirectory(
                    at: inaccessibleURL,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: bookmarksURL.path) {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: bookmarksURL.path
                    )
                }
                try Data("unreadable Safari fixture".utf8).write(to: bookmarksURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o000],
                    ofItemAtPath: bookmarksURL.path
                )
            } catch {
                assertionFailure("Could not create unreadable browser-import UI test fixture: \(error)")
                return nil
            }
            return BrowserImportService(
                profileFolderURLProvider: { source in
                    source == .safari ? inaccessibleURL : source.suggestedProfileFolderURL
                },
                persistsProfileAccess: false
            )
        }

        if fixtureName == BrowserImportSource.chrome.rawValue {
            let profileURL = FileManager.default.temporaryDirectory
                .appending(path: "CandoaUITestChromeProfile", directoryHint: .isDirectory)
            let defaultProfileURL = profileURL.appending(path: "Default", directoryHint: .isDirectory)
            let bookmarksURL = defaultProfileURL.appending(path: "Bookmarks", directoryHint: .notDirectory)
            let fixture: [String: Any] = [
                "roots": [
                    "bookmark_bar": [
                        "type": "folder",
                        "name": "Bookmarks Bar",
                        "children": [[
                            "type": "url",
                            "name": "Chrome Import Fixture",
                            "url": "https://fixture.candoa.test/chrome-import"
                        ]]
                    ]
                ]
            ]

            do {
                try FileManager.default.createDirectory(
                    at: defaultProfileURL,
                    withIntermediateDirectories: true
                )
                let data = try JSONSerialization.data(withJSONObject: fixture)
                try data.write(to: bookmarksURL, options: .atomic)
            } catch {
                assertionFailure("Could not create Chrome import UI test fixture: \(error)")
                return nil
            }
            return uiTestingBrowserImportService(source: .chrome, profileURL: profileURL)
        }

        if fixtureName == BrowserImportSource.arc.rawValue {
            let profileURL = FileManager.default.temporaryDirectory
                .appending(path: "CandoaUITestArcProfile", directoryHint: .isDirectory)
            let sidebarURL = profileURL.appending(
                path: "StorableSidebar.json",
                directoryHint: .notDirectory
            )
            let fixture: [String: Any] = [
                "sidebarSyncState": [
                    "items": [
                        "fixture-item": [
                            "value": [
                                "id": "fixture-item",
                                "parentID": "fixture-space-container",
                                "title": "Arc Import Fixture",
                                "data": [
                                    "tab": [
                                        "savedURL": "https://fixture.candoa.test/arc-import",
                                        "savedTitle": "Arc Import Fixture"
                                    ]
                                ]
                            ]
                        ]
                    ],
                    "spaceModels": [
                        "fixture-space": [
                            "value": [
                                "title": "E2E Space",
                                "containerIDs": ["fixture-space-container"]
                            ]
                        ]
                    ]
                ]
            ]

            do {
                try FileManager.default.createDirectory(
                    at: profileURL,
                    withIntermediateDirectories: true
                )
                let data = try JSONSerialization.data(withJSONObject: fixture)
                try data.write(to: sidebarURL, options: .atomic)
            } catch {
                assertionFailure("Could not create Arc import UI test fixture: \(error)")
                return nil
            }
            return uiTestingBrowserImportService(source: .arc, profileURL: profileURL)
        }

        if fixtureName == BrowserImportSource.firefox.rawValue {
            let profileURL = FileManager.default.temporaryDirectory
                .appending(path: "CandoaUITestFirefoxProfile", directoryHint: .isDirectory)
            let databaseURL = profileURL.appending(path: "places.sqlite", directoryHint: .notDirectory)
            do {
                try FileManager.default.createDirectory(
                    at: profileURL,
                    withIntermediateDirectories: true
                )
                try createFirefoxImportFixture(at: databaseURL)
            } catch {
                assertionFailure("Could not create Firefox import UI test fixture: \(error)")
                return nil
            }
            return uiTestingBrowserImportService(source: .firefox, profileURL: profileURL)
        }

        guard fixtureName == BrowserImportSource.safari.rawValue else { return nil }

        let profileURL = FileManager.default.temporaryDirectory
            .appending(path: "CandoaUITestSafariProfile", directoryHint: .isDirectory)
        let bookmarksURL = profileURL.appending(path: "Bookmarks.plist", directoryHint: .notDirectory)
        let fixture: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": "E2E Favorites",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://fixture.candoa.test/safari-import",
                            "URIDictionary": ["title": "Safari Import Fixture"]
                        ]
                    ]
                ]
            ]
        ]

        do {
            try FileManager.default.createDirectory(
                at: profileURL,
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: fixture,
                format: .binary,
                options: 0
            )
            try data.write(to: bookmarksURL, options: .atomic)
        } catch {
            assertionFailure("Could not create browser-import UI test fixture: \(error)")
            return nil
        }

        return BrowserImportService(
            profileFolderURLProvider: { source in
                source == .safari ? profileURL : source.suggestedProfileFolderURL
            },
            persistsProfileAccess: false
        )
    }

    private static func uiTestingBrowserImportService(
        source: BrowserImportSource,
        profileURL: URL
    ) -> BrowserImportService {
        BrowserImportService(
            profileFolderURLProvider: { requestedSource in
                requestedSource == source ? profileURL : requestedSource.suggestedProfileFolderURL
            },
            persistsProfileAccess: false
        )
    }

    private static func createFirefoxImportFixture(at databaseURL: URL) throws {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }

        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }

        let sql = """
            CREATE TABLE moz_bookmarks_roots (folder_id INTEGER, root_name TEXT);
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE moz_bookmarks (
                id INTEGER PRIMARY KEY,
                type INTEGER,
                fk INTEGER,
                parent INTEGER,
                position INTEGER,
                title TEXT
            );
            INSERT INTO moz_bookmarks_roots VALUES (1, 'placesRoot');
            INSERT INTO moz_bookmarks_roots VALUES (2, 'toolbar');
            INSERT INTO moz_places VALUES (1, 'https://fixture.candoa.test/firefox-import');
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, 'root');
            INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'toolbar');
            INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 2, 0, 'E2E Firefox');
            INSERT INTO moz_bookmarks VALUES (4, 1, 1, 3, 0, 'Firefox Import Fixture');
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    var activeSpace: BrowserSpace? {
        spaces.first { $0.id == activeSpaceID }
    }

    func uiTestingStateDescription(sidebarVisible: Bool) -> String {
        guard Self.isUITesting else { return "" }

        let activeTitle = activeTab?.title ?? "none"
        let activeURL = activeTab?.url?.absoluteString ?? "none"
        let tabTitles = visibleTabsForActiveSpace.map(\.title).joined(separator: "|")
        let pinnedTitles = pinnedTabs(in: activeSpaceID).map(\.title).joined(separator: "|")
        let folderNames = folders
            .filter { $0.spaceID == activeSpaceID }
            .map(\.name)
            .joined(separator: "|")
        let activeSpaceName = activeSpace?.name ?? "none"

        let favoriteTitles = favoriteTabs.map(\.favoriteDisplayTitle).joined(separator: "|")
        let splitTabTitles = activeSplitGroupTabs.map(\.title).joined(separator: "|")
        let splitActiveTitle = activeTabID.flatMap { id in
            activeSplitGroupTabs.first(where: { $0.id == id })?.title
        } ?? "none"
        let splitRatioText = splitPaneRatios
            .map { String(format: "%.2f", $0) }
            .joined(separator: "|")

        return [
            "private=\(isPrivate)",
            "setup=\(isInitialSpaceSetupPresented)",
            "accountSetup=\(isInitialAccountSetupPresented)",
            "onboarding=\(initialOnboardingStep?.rawValue ?? "none")",
            "tourTip=\(initialTourTip?.rawValue.description ?? "none")",
            "preparingTourTip=\(preparingInitialTourTip?.rawValue.description ?? "none")",
            "palette=\(isCommandPalettePresented)",
            "newTabPalette=\(isNewTabPaletteActive)",
            "find=\(isFindBarPresented)",
            "webFocus=\(webCoordinator.activeWebViewHasKeyboardFocus)",
            "sidebar=\(sidebarVisible)",
            "space=\(activeSpaceName)",
            "spaceTheme=\(activeSpace.map { $0.themePaletteHexes.joined(separator: "|") } ?? "none")",
            "active=\(activeTitle)",
            "url=\(activeURL)",
            "loading=\(activeTab?.isLoading == true)",
            "tabs=\(tabTitles)",
            "pinned=\(pinnedTitles)",
            "folders=\(folderNames)",
            "favorites=\(favoriteTitles)",
            "switcher=\(isTabSwitcherPresented):\(tabSwitcherSelectedTitle)",
            "switcherPreviews=\(tabSwitcherPreviewTitles)",
            "switcherCards=\(tabSwitcherTabs.map(\.title).joined(separator: "|")):\(tabSwitcherTabCount)",
            "addressBar=\(AddressBarPlacement.current.rawValue)",
            "split=\(isSplitViewEnabled)",
            "splitDisplayed=\(isSplitViewDisplayed)",
            "splitTabs=\(splitTabTitles)",
            "splitActive=\(splitActiveTitle)",
            "splitRatios=\(splitRatioText)",
            "splitLayout=\(splitLayout.rawValue)",
            "splitZoom=\(zoomedSplitTabID.flatMap { id in activeSplitGroupTabs.first(where: { $0.id == id })?.title } ?? "none")",
            "downloads=\(downloadsStore.uiTestingDescription)",
            "downloadsShown=\(isDownloadsPopoverPresented)",
            "siteInfoShown=\(isSiteInfoPopoverPresented)",
            "privacyReportShown=\(isPrivacyReportPresented)",
            "inspector=\(uiTestingInspectorDescription)",
            "reader=\(uiTestingReaderDescription)",
            "nav=\(uiTestingNavigationDescription)",
            "popover=\(uiTestingVisibleFolderPopoverDescription)",
            "query=\(uiTestingCommandPaletteQuery)",
            "command=\(uiTestingLastCommandDescription)",
            "pageScheme=\(uiTestingWebsiteAppearanceDescription)",
            "popupDiag=\(uiTestingPopupDiagnostics.joined(separator: "|"))",
            "webAuth=\(uiTestingWebAuthEvents.joined(separator: "|"))"
        ].joined(separator: ";")
    }

    private var uiTestingNavigationDescription: String {
        guard let activeTabID else { return "none" }
        let state = webCoordinator.navigationState(for: activeTabID)
        return "\(state.canGoBack ? "back" : "noback"):\(state.canGoForward ? "fwd" : "nofwd")"
    }

    private var uiTestingInspectorDescription: String {
        guard let activeTabID else { return "none" }
        return webCoordinator.uiTestingAttachedInspectorDescription(for: activeTabID)
    }

    private var uiTestingReaderDescription: String {
        guard let activeTabID else { return "none" }
        let availability = readerAvailableTabIDs.contains(activeTabID) ? "available" : "unavailable"
        return "\(availability):\(readerActiveTabIDs.contains(activeTabID) ? "active" : "inactive")"
    }

    /// Titles of tabs whose switcher card has a real page image, in tab
    /// order — how a test tells a rendered thumbnail from the favicon fallback.
    private var tabSwitcherPreviewTitles: String {
        tabs.filter { tabSwitcherSnapshots[$0.id] != nil }
            .map(\.title)
            .joined(separator: "|")
    }

    private var tabSwitcherSelectedTitle: String {
        tabSwitcherSelectedTabID
            .flatMap { id in tabs.first(where: { $0.id == id })?.title }
            ?? "none"
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

    static let uiTestingPersonalMemorySpaceID = UUID(uuidString: "1A1A1A1A-1A1A-1A1A-1A1A-1A1A1A1A1A1A")!
    static let uiTestingWorkMemorySpaceID = UUID(uuidString: "2A2A2A2A-2A2A-2A2A-2A2A-2A2A2A2A2A2A")!

    /// Canned extractor output for the memory fixture: UI tests set this to
    /// a JSON array of fact strings and the app persists it through the real
    /// sanitize/merge path instead of calling a model.
    static func uiTestingMemoryExtractionFacts() -> [String]? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_MEMORY_EXTRACTION_FACTS"],
              let data = raw.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Seeds saved facts for the space-memory fixture's two Spaces so tests
    /// can assert per-Space isolation without a model round trip.
    func seedUITestingSpaceMemoryIfNeeded() {
        guard Self.isUITesting, !isPrivate,
              ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "space-memory"
        else {
            return
        }

        // Distinct createdAt values keep the row order (and the index-based
        // delete identifiers) deterministic.
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
        persistenceService.replaceSpaceMemoryFacts(
            with: [
                SpaceMemoryFact(
                    spaceID: Self.uiTestingPersonalMemorySpaceID,
                    content: "The user's name is Alex Fixture.",
                    createdAt: fixtureDate
                ),
                SpaceMemoryFact(
                    spaceID: Self.uiTestingPersonalMemorySpaceID,
                    content: "The user is applying for engineering jobs.",
                    createdAt: fixtureDate.addingTimeInterval(60)
                )
            ],
            in: Self.uiTestingPersonalMemorySpaceID
        )
        persistenceService.replaceSpaceMemoryFacts(
            with: [
                SpaceMemoryFact(
                    spaceID: Self.uiTestingWorkMemorySpaceID,
                    content: "The user prepares quarterly budget reports."
                )
            ],
            in: Self.uiTestingWorkMemorySpaceID
        )
    }

    static func uiTestingFixtureState() -> BrowserWindowState? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CANDOA_UI_TESTING"] == "1" else { return nil }
        let fixture = environment["CANDOA_UI_TESTING_FIXTURE"]

        // Relaunch coverage: fall through to the persisted Core Data
        // workspace instead of seeding fixture state.
        if fixture == "persisted-workspace" {
            return nil
        }

        if fixture == "ask" {
            return testingBotFixtureState(includesSeedTabs: false)
        }

        if fixture == "space-memory" {
            let personalSpace = BrowserSpace(
                id: uiTestingPersonalMemorySpaceID,
                name: "Personal",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let workSpace = BrowserSpace(
                id: uiTestingWorkMemorySpaceID,
                name: "Work",
                symbolName: "briefcase",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let personalTabID = UUID(uuidString: "1B1B1B1B-1B1B-1B1B-1B1B-1B1B1B1B1B1B")!
            let tabs = [
                BrowserTab(
                    id: personalTabID,
                    title: "Personal Home",
                    url: URL(string: "https://fixture.candoa.test/personal")!,
                    spaceID: personalSpace.id,
                    hasBeenActivated: true
                ),
                BrowserTab(
                    id: UUID(uuidString: "2B2B2B2B-2B2B-2B2B-2B2B-2B2B2B2B2B2B")!,
                    title: "Work Home",
                    url: URL(string: "https://fixture.candoa.test/work")!,
                    spaceID: workSpace.id,
                    hasBeenActivated: true
                )
            ]
            return BrowserWindowState(
                spaces: [personalSpace, workSpace],
                folders: [],
                tabs: tabs,
                activeSpaceID: personalSpace.id,
                activeTabID: personalTabID
            )
        }

        if fixture == "ask-agent-navigation" {
            let spaceID = UUID(uuidString: "AEAEAEAE-AEAE-AEAE-AEAE-AEAEAEAEAEAE")!
            let tabID = UUID(uuidString: "BFBFBFBF-BFBF-BFBF-BFBF-BFBFBFBFBFBF")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let tab = BrowserTab(
                id: tabID,
                title: "Membership Home",
                url: URL(string: "https://fixture.candoa.test/home")!,
                faviconSymbol: "person.crop.circle",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [tab],
                activeSpaceID: spaceID,
                activeTabID: tabID
            )
        }

        if fixture == "ask-agent-form-fill" {
            let spaceID = UUID(uuidString: "ADADADAD-ADAD-ADAD-ADAD-ADADADADADAD")!
            let tabID = UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let tab = BrowserTab(
                id: tabID,
                title: "Job Application",
                url: URL(string: "https://fixture.candoa.test/apply")!,
                faviconSymbol: "doc.text",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [tab],
                activeSpaceID: spaceID,
                activeTabID: tabID
            )
        }

        if fixture == "ask-agent-waiting" {
            let spaceID = UUID(uuidString: "AFAFAFAF-AFAF-AFAF-AFAF-AFAFAFAFAFAF")!
            let tabID = UUID(uuidString: "CECECECE-CECE-CECE-CECE-CECECECECECE")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let tab = BrowserTab(
                id: tabID,
                title: "Membership Home",
                url: URL(string: "https://fixture.candoa.test/home")!,
                faviconSymbol: "person.crop.circle",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [tab],
                activeSpaceID: spaceID,
                activeTabID: tabID
            )
        }

        if fixture == "ask-agent-normalized-navigation" {
            let spaceID = UUID(uuidString: "ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC")!
            let tabID = UUID(uuidString: "BDBDBDBD-BDBD-BDBD-BDBD-BDBDBDBDBDBD")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let tab = BrowserTab(
                id: tabID,
                title: "MacBook Air",
                url: URL(string: "https://fixture.candoa.test/air")!,
                faviconSymbol: "laptopcomputer",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [tab],
                activeSpaceID: spaceID,
                activeTabID: tabID
            )
        }

        if fixture == "ask-agent-selection" {
            let spaceID = UUID(uuidString: "EFEFEFEF-EFEF-EFEF-EFEF-EFEFEFEFEFEF")!
            let tabID = UUID(uuidString: "FAFAFAFA-FAFA-FAFA-FAFA-FAFAFAFAFAFA")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let tab = BrowserTab(
                id: tabID,
                title: "Configure MacBook Air",
                url: URL(string: "https://fixture.candoa.test/configure")!,
                faviconSymbol: "laptopcomputer",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [tab],
                activeSpaceID: spaceID,
                activeTabID: tabID
            )
        }

        if fixture == "ask-agent-mentioned-tab" {
            let spaceID = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
            let readingTabID = UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
            let membershipTabID = UUID(uuidString: "DEDEDEDE-DEDE-DEDE-DEDE-DEDEDEDEDEDE")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let readingTab = BrowserTab(
                id: readingTabID,
                title: "Reading List",
                url: URL(string: "https://fixture.candoa.test/reading")!,
                faviconSymbol: "book",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            let membershipTab = BrowserTab(
                id: membershipTabID,
                title: "Membership Home",
                url: URL(string: "https://fixture.candoa.test/home")!,
                faviconSymbol: "person.crop.circle",
                spaceID: spaceID,
                hasBeenActivated: true
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [readingTab, membershipTab],
                activeSpaceID: spaceID,
                activeTabID: readingTabID
            )
        }

        if fixture == "cross-space-duplicate-url" {
            return crossSpaceDuplicateURLFixtureState()
        }

        if fixture == "split-view" || fixture == "split-view-pixels" {
            // An empty Space: split tests open exactly the fixture tabs they
            // need, so the seed tabs can't shift replacement-pane selection.
            // The pixels variant loads solid-color fixture pages so pixel
            // sampling has a known web-content baseline.
            return testingBotFixtureState(includesSeedTabs: false)
        }

        if fixture == "split-view-spaces" {
            return splitViewSpacesFixtureState()
        }

        if fixture == "inactive-favorites" {
            return inactiveFavoritesFixtureState()
        }

        if fixture == "long-tab-list" {
            return longTabListFixtureState()
        }

        if fixture == "tab-switcher-previews" {
            return tabSwitcherPreviewsFixtureState()
        }

        if fixture == "website-appearance" {
            let spaceID = UUID(uuidString: "ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC")!
            let dataStoreID = UUID(uuidString: "ADADADAD-ADAD-ADAD-ADAD-ADADADADADAD")!
            let space = BrowserSpace(
                id: spaceID,
                name: "Appearance",
                symbolName: "circle.lefthalf.filled",
                dataStoreID: dataStoreID
            )
            return BrowserWindowState(
                spaces: [space],
                folders: [],
                tabs: [],
                activeSpaceID: spaceID,
                activeTabID: nil
            )
        }

        return testingBotFixtureState(includesSeedTabs: true)
    }

    static func crossSpaceDuplicateURLFixtureState() -> BrowserWindowState {
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
            themeColorHex: BrowserSpace.blueThemeColorHex,
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

    static func splitViewSpacesFixtureState() -> BrowserWindowState {
        let firstSpaceID = UUID(uuidString: "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1")!
        let secondSpaceID = UUID(uuidString: "B2B2B2B2-B2B2-B2B2-B2B2-B2B2B2B2B2B2")!
        let firstTabID = UUID(uuidString: "C3C3C3C3-C3C3-C3C3-C3C3-C3C3C3C3C3C3")!
        let secondTabID = UUID(uuidString: "D4D4D4D4-D4D4-D4D4-D4D4-D4D4D4D4D4D4")!
        let otherSpaceTabID = UUID(uuidString: "E5E5E5E5-E5E5-E5E5-E5E5-E5E5E5E5E5E5")!
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)

        let firstSpace = BrowserSpace(
            id: firstSpaceID,
            name: "SplitOne",
            symbolName: "sparkles",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let secondSpace = BrowserSpace(
            id: secondSpaceID,
            name: "SplitTwo",
            symbolName: "bolt",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let tabs = [
            BrowserTab(
                id: firstTabID,
                title: "a-one",
                url: URL(string: "https://fixture.candoa.test/a-one")!,
                spaceID: firstSpaceID,
                sortOrder: 0,
                lastAccessedAt: fixtureDate,
                hasBeenActivated: true
            ),
            BrowserTab(
                id: secondTabID,
                title: "a-two",
                url: URL(string: "https://fixture.candoa.test/a-two")!,
                spaceID: firstSpaceID,
                sortOrder: 1,
                lastAccessedAt: fixtureDate.addingTimeInterval(-60),
                hasBeenActivated: true
            ),
            BrowserTab(
                id: otherSpaceTabID,
                title: "b-one",
                url: URL(string: "https://fixture.candoa.test/b-one")!,
                spaceID: secondSpaceID,
                sortOrder: 0,
                lastAccessedAt: fixtureDate.addingTimeInterval(-120),
                hasBeenActivated: true
            )
        ]

        return BrowserWindowState(
            spaces: [firstSpace, secondSpace],
            folders: [],
            tabs: tabs,
            activeSpaceID: firstSpaceID,
            activeTabID: firstTabID
        )
    }

    /// More tabs than the sidebar can show at once: drag behaviour that only
    /// appears in an overflowing list — edge auto-scrolling, a drop far from
    /// where the drag began — has something to happen in.
    static func longTabListFixtureState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "5A5A5A5A-5A5A-5A5A-5A5A-5A5A5A5A5A5A")!
        let firstTabID = UUID(uuidString: "6A6A6A6A-6A6A-6A6A-6A6A-6A6A6A6A6A6A")!
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
        let space = BrowserSpace(
            id: spaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let tabs = [
            BrowserTab(
                id: firstTabID,
                title: "Row 01",
                url: URL(string: "https://fixture.candoa.test/row-01")!,
                spaceID: spaceID,
                sortOrder: 0,
                lastAccessedAt: fixtureDate,
                hasBeenActivated: true
            )
        ] + (2...30).map { (index: Int) -> BrowserTab in
            BrowserTab(
                title: String(format: "Row %02d", index),
                url: URL(string: "https://fixture.candoa.test/row-\(index)")!,
                spaceID: spaceID,
                sortOrder: Double(index - 1),
                lastAccessedAt: fixtureDate.addingTimeInterval(-60 * Double(index)),
                hasBeenActivated: true
            )
        }

        return BrowserWindowState(
            spaces: [space],
            folders: [],
            tabs: tabs,
            activeSpaceID: spaceID,
            activeTabID: firstTabID
        )
    }

    /// Two previously-visited tabs on fixture pages; only "Current" gets a
    /// web view at launch, so "Dormant" is exactly the switcher-card gap the
    /// off-screen preview warm-up exists to fill (issue #340).
    static func tabSwitcherPreviewsFixtureState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "58585858-5858-5858-5858-585858585858")!
        let currentTabID = UUID(uuidString: "69696969-6969-6969-6969-696969696969")!
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
                url: URL(string: "https://fixture.candoa.test/current")!,
                spaceID: spaceID,
                lastAccessedAt: fixtureDate,
                hasBeenActivated: true
            ),
        ] + (1...4).map { index in
            // Four dormant tabs — more than the warm-up runs at once — so the
            // switcher test covers slot refill, not just a single load.
            BrowserTab(
                title: "Dormant \(index)",
                url: URL(string: "https://fixture.candoa.test/dormant-\(index)")!,
                spaceID: spaceID,
                lastAccessedAt: fixtureDate.addingTimeInterval(-60 * Double(index)),
                hasBeenActivated: true
            )
        }

        return BrowserWindowState(
            spaces: [space],
            folders: [],
            tabs: tabs,
            activeSpaceID: spaceID,
            activeTabID: currentTabID
        )
    }

    static func inactiveFavoritesFixtureState() -> BrowserWindowState {
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

    static func testingBotFixtureState(includesSeedTabs: Bool) -> BrowserWindowState {
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
            themeColorHex: BrowserSpace.blueThemeColorHex,
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
}

// MARK: - Drop-preview fixture

extension BrowserStore {
    /// Holds a sidebar row in its armed split state at launch so the preview
    /// can be looked at in the running app.
    ///
    /// The state only exists mid-drag, a drag can only be driven with
    /// synthetic mouse events, and those are not something to fire at
    /// somebody's machine while they are using it — so for four rounds this
    /// was "verified" against a scratch reimplementation of the view instead,
    /// which drew a row fill the real list does not always have and hid a
    /// defect that shipped. This is the seam that makes it checkable:
    ///
    ///     CANDOA_FIXTURE_SPLIT_PREVIEW=<row index>:<leading|trailing>
    ///
    /// Debug only, and deliberately not gated on `CANDOA_UI_TESTING` — that
    /// swaps in a fixture workspace, and the point is to see the preview
    /// against real rows with their real titles, favicons and fills.
    /// Puts two real rows into an actual split at launch:
    ///
    ///     CANDOA_FIXTURE_SPLIT=<row index>,<row index>
    func applySplitFixtureIfNeeded() {
#if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["CANDOA_FIXTURE_SPLIT"] else { return }
        let idx = spec.split(separator: ",").compactMap { Int($0) }
        let rows = regularTabsForActiveSpace
        guard idx.count == 2, idx.allSatisfy(rows.indices.contains) else { return }
        splitTab(rows[idx[0]].id, onto: rows[idx[1]].id, side: .trailing)
#endif
    }

    func applySplitPreviewFixtureIfNeeded() {
#if DEBUG
        guard
            let spec = ProcessInfo.processInfo.environment["CANDOA_FIXTURE_SPLIT_PREVIEW"]
        else { return }

        let parts = spec.split(separator: ":").map(String.init)
        let index = parts.first.flatMap(Int.init) ?? 0
        let what = parts.count > 1 ? parts[1] : "trailing"
        let side: SplitTabDropSide = what == "leading" ? .leading : .trailing
        let edge: SidebarTabDropEdge = ["before": .before, "after": .after][what] ?? .split

        let rows = regularTabsForActiveSpace
        guard rows.indices.contains(index) else { return }

        // A real armed row is mid-drag, so the fixture has to look mid-drag:
        // `activeSidebarDropIndicator` returns nil without a dragged tab, and
        // rows suppress their hover treatment off the same flag.
        draggedTabID = rows.first(where: { $0.id != rows[index].id })?.id ?? rows[index].id
        sidebarDropIndicator = SidebarTabDropIndicator(
            placement: .regular,
            targetTabID: rows[index].id,
            edge: edge,
            splitSide: edge == .split ? side : nil
        )
#endif
    }
}
