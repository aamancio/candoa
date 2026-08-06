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
            "sidebar=\(sidebarVisible)",
            "space=\(activeSpaceName)",
            "spaceTheme=\(activeSpace.map { $0.themePaletteHexes.joined(separator: "|") } ?? "none")",
            "active=\(activeTitle)",
            "url=\(activeURL)",
            "loading=\(activeTab?.isLoading == true)",
            "tabs=\(tabTitles)",
            "folders=\(folderNames)",
            "favorites=\(favoriteTitles)",
            "split=\(isSplitViewEnabled)",
            "splitDisplayed=\(isSplitViewDisplayed)",
            "splitTabs=\(splitTabTitles)",
            "splitActive=\(splitActiveTitle)",
            "splitRatios=\(splitRatioText)",
            "splitLayout=\(splitLayout.rawValue)",
            "downloads=\(downloadsStore.uiTestingDescription)",
            "downloadsShown=\(isDownloadsPopoverPresented)",
            "popover=\(uiTestingVisibleFolderPopoverDescription)",
            "query=\(uiTestingCommandPaletteQuery)",
            "command=\(uiTestingLastCommandDescription)",
            "pageScheme=\(uiTestingWebsiteAppearanceDescription)",
            "popupDiag=\(uiTestingPopupDiagnostics.joined(separator: "|"))",
            "webAuth=\(uiTestingWebAuthEvents.joined(separator: "|"))"
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
