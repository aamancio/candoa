import Foundation
import SQLite3

extension BrowserStore {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
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

        return [
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
            "active=\(activeTitle)",
            "url=\(activeURL)",
            "tabs=\(tabTitles)",
            "folders=\(folderNames)",
            "popover=\(uiTestingVisibleFolderPopoverDescription)",
            "query=\(uiTestingCommandPaletteQuery)",
            "command=\(uiTestingLastCommandDescription)",
            "pageScheme=\(uiTestingWebsiteAppearanceDescription)"
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

        if fixture == "ask" {
            return testingBotFixtureState(includesSeedTabs: false)
        }

        if fixture.map({
            ["ask-contextual-purchase", "ask-contextual-followup", "ask-contextual-unsafe-followup"]
                .contains($0)
        }) == true {
            let spaceID = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
            let tabID = UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let isUnsafeFollowUp = fixture == "ask-contextual-unsafe-followup"
            let tab = BrowserTab(
                id: tabID,
                title: isUnsafeFollowUp ? "Buy MacBook Air" : "Apple Education Store",
                url: URL(string: isUnsafeFollowUp
                    ? "https://www.apple.com/us-edu/shop/buy-mac/macbook-air"
                    : "https://www.apple.com/us-edu/store")!,
                faviconSymbol: "apple.logo",
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

        if ["ask-model-selector-context", "ask-live-model-selector-context"].contains(fixture) {
            let spaceID = UUID(uuidString: "CECECECE-CECE-CECE-CECE-CECECECECECE")!
            let tabID = UUID(uuidString: "DFDFDFDF-DFDF-DFDF-DFDF-DFDFDFDFDFDF")!
            let space = BrowserSpace(
                id: spaceID,
                name: "TestingBot",
                symbolName: "sparkles",
                themeAppearance: BrowserSpace.defaultThemeAppearance
            )
            let tab = BrowserTab(
                id: tabID,
                title: "Buy MacBook Air",
                url: URL(string: fixture == "ask-live-model-selector-context"
                    ? "https://www.apple.com/us-edu/shop/buy-mac/macbook-air"
                    : "https://fixture.candoa.test/macbook-air")!,
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

        if fixture == "legacy-saved-tab-navigation" {
            return legacySavedTabNavigationFixtureState()
        }

        if fixture == "legacy-empty-tabs" {
            return legacyEmptyTabsFixtureState()
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

    static func legacySavedTabNavigationFixtureState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let tabID = UUID(uuidString: "45454545-4545-4545-4545-454545454545")!
        let space = BrowserSpace(
            id: spaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeColorHex: BrowserSpace.blueThemeColorHex,
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

    static func legacyEmptyTabsFixtureState() -> BrowserWindowState {
        let spaceID = UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        let emptyTabID = UUID(uuidString: "79797979-7979-7979-7979-797979797979")!
        let youtubeTabID = UUID(uuidString: "80808080-8080-8080-8080-808080808080")!
        let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
        let space = BrowserSpace(
            id: spaceID,
            name: "TestingBot",
            symbolName: "sparkles",
            themeAppearance: BrowserSpace.defaultThemeAppearance
        )
        let tabs = [
            BrowserTab(
                id: emptyTabID,
                title: BrowserDefaults.newTabTitle,
                spaceID: spaceID,
                lastAccessedAt: fixtureDate
            ),
            BrowserTab(
                id: youtubeTabID,
                title: "YouTube",
                url: URL(string: "https://www.youtube.com/")!,
                faviconSymbol: "play.rectangle.fill",
                spaceID: spaceID,
                lastAccessedAt: fixtureDate.addingTimeInterval(-60)
            )
        ]

        return BrowserWindowState(
            spaces: [space],
            folders: [],
            tabs: tabs,
            activeSpaceID: spaceID,
            activeTabID: emptyTabID
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
