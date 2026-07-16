import Foundation

extension BrowserStore {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
    }

    static var uiTestingOnboardingStep: InitialOnboardingStep? {
        guard isUITesting else { return nil }
        return ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_ONBOARDING_STEP"]
            .flatMap(InitialOnboardingStep.init(rawValue:))
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

    static func uiTestingFixtureState() -> BrowserWindowState? {
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
            themeColorHex: BrowserSpace.defaultThemeColorHex,
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
            themeColorHex: BrowserSpace.defaultThemeColorHex,
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
            themeColorHex: BrowserSpace.defaultThemeColorHex,
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
