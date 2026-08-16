import AppKit
import XCTest

extension CandoaUITests {
    func testInitialTourStartsOnLocalWelcomePage() throws {
        let app = launchApp(onboardingStep: "tour")

        XCTAssertTrue(element("welcome-to-candoa-page", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("initial-tour-command-bar", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start Quick Tour"].exists)
        XCTAssertFalse(app.buttons["Explore on My Own"].exists)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=candoa://welcome", timeout: 5),
            currentState(in: app)
        )
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testInitialTourMovesThroughNativeControlPopovers() throws {
        let app = launchApp(onboardingStep: "tour")
        XCTAssertTrue(element("initial-tour-command-bar", in: app).waitForExistence(timeout: 5))
        app.buttons["Next"].click()

        XCTAssertTrue(element("initial-tour-spaces", in: app).waitForExistence(timeout: 5))
        app.buttons["Next"].click()

        XCTAssertTrue(
            app.staticTexts["Understand any page"].waitForExistence(timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "aiVisible=true;aiMounted=true", timeout: 5),
            currentState(in: app)
        )
        XCTAssertFalse(element("agent-subscription-gate", in: app).exists)
        app.buttons["Done"].click()

        let askTip = element("initial-tour-ask", in: app)
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: askTip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(element("welcome-to-candoa-page", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForState(in: app, containing: "url=candoa://welcome", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(waitForState(in: app, containing: "Welcome to Candoa", timeout: 5))
        XCTAssertFalse(currentState(in: app).contains("New Tab"), currentState(in: app))
        XCTAssertTrue(element("sidebar-new-tab-button", in: app).exists)

        app.typeKey("t", modifierFlags: .command)
        submitCommandPaletteText("https://example.com", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/", timeout: 10),
            currentState(in: app)
        )
        XCTAssertFalse(currentState(in: app).contains("Welcome to Candoa"), currentState(in: app))
        XCTAssertFalse(element("welcome-to-candoa-page", in: app).exists)
    }

    func testTestingBotNewTabFindAndSidebarShortcuts() throws {
        let app = launchApp()

        XCTAssertTrue(waitForState(in: app, containing: "setup=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot"), currentState(in: app))

        let newTabButton = element("sidebar-new-tab-button", in: app)
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        let realURL = "https://example.com"
        submitCommandPaletteText(realURL, in: app)

        XCTAssertTrue(waitForState(in: app, containing: "url=\(realURL)"), currentState(in: app))
        XCTAssertTrue(element("sidebar-address-button", in: app).waitForExistence(timeout: 5))
        let webViewHost = element("active-webview-host", in: app)
        XCTAssertTrue(webViewHost.waitForExistence(timeout: 5))
        let expandedSidebarHostFrame = webViewHost.frame
        XCTAssertFalse(expandedSidebarHostFrame.isEmpty)

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "find=true"), currentState(in: app))
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "sidebar=false"), currentState(in: app))
        assertEqualFrame(webViewHost.frame, expandedSidebarHostFrame)

        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "sidebar=true"), currentState(in: app))
        assertEqualFrame(webViewHost.frame, expandedSidebarHostFrame)
    }

    func testFreshTabGivesThePageKeyboardFocusWithoutAClick() throws {
        let app = launchApp()

        XCTAssertTrue(waitForState(in: app, containing: "setup=false"), currentState(in: app))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        let realURL = "https://example.com"
        submitCommandPaletteText(realURL, in: app)
        XCTAssertTrue(waitForState(in: app, containing: "url=\(realURL)"), currentState(in: app))

        let webViewHost = element("active-webview-host", in: app)
        XCTAssertTrue(webViewHost.waitForExistence(timeout: 5))

        // Nothing clicks into the content area: the page has to claim keyboard
        // focus on its own, or scrolling and every Edit command stay dead until
        // the person clicks.
        XCTAssertTrue(waitForState(in: app, containing: "webFocus=true"), currentState(in: app))
    }

    func testUpdateBannerOneClickInstallShowsInstallingState() throws {
        let app = launchApp(updateVersion: "9.9.9")

        XCTAssertTrue(waitForState(in: app, containing: "setup=false"), currentState(in: app))

        let banner = element("sidebar-update-banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        banner.click()

        // One click must move straight into the install flow — no
        // intermediate Sparkle dialog — and the pill reports progress.
        let installingBanner = element("sidebar-update-banner-installing", in: app)
        XCTAssertTrue(installingBanner.waitForExistence(timeout: 5))
        XCTAssertFalse(installingBanner.isEnabled)
        XCTAssertEqual(app.sheets.count, 0)
    }

    func testWhatsNewBannerOpensHostedPageAndDismisses() throws {
        let app = launchApp(whatsNewFixture: true)

        XCTAssertTrue(waitForState(in: app, containing: "setup=false"), currentState(in: app))

        let banner = element("sidebar-whats-new-banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        banner.click()

        // One click opens the hosted release-notes page in a new tab and
        // retires the pill. The site may redirect to a locale path
        // (candoa.app/whats-new -> www.candoa.app/en/whats-new), so match
        // the stable path segment rather than the exact URL.
        XCTAssertTrue(
            waitForState(in: app, containing: "/whats-new"),
            currentState(in: app)
        )
        XCTAssertFalse(banner.exists)
    }

    func testViewMenuOffersStopAndReloadCommands() throws {
        let app = launchApp()

        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot"), currentState(in: app))

        app.typeKey("t", modifierFlags: .command)
        submitCommandPaletteText("https://example.com", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 10), currentState(in: app))

        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()

        let stopItem = app.menuItems["Stop"]
        let reloadItem = app.menuItems["Reload Page"]
        XCTAssertTrue(stopItem.waitForExistence(timeout: 3))
        XCTAssertTrue(reloadItem.exists)

        // With an idle page the reload command is enabled and Stop is not.
        XCTAssertFalse(stopItem.isEnabled)
        XCTAssertTrue(reloadItem.isEnabled)

        // Reload From Origin is Reload Page's Option-held alternate, the way
        // Safari hides it: it stays in the menu — accessibility still reports
        // it — but draws no row of its own until Option goes down, so it is
        // not hittable.
        XCTAssertFalse(app.menuItems["Reload Page From Origin"].isHittable)

        app.typeKey(.escape, modifierFlags: [])

        // It still performs a real reload that settles back on the same page
        // with the tab intact.
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 10), currentState(in: app))
    }

    func testReboundBackShortcutDrivesBackAndRetiresTheBrackets() throws {
        // Back is rebindable in Settings ▸ Shortcuts, so the menu bar must
        // follow the person's binding instead of pinning a literal ⌘[ that
        // stays live alongside the new key (#219). Seeded through the
        // argument domain, which is what @AppStorage reads first.
        let app = launchApp(extraLaunchArguments: ["-CandoaShortcut.goBack", "Control-Command-B"])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot"), currentState(in: app))

        // Three visits in one tab, so a wrongly-live ⌘[ plus the real
        // binding would land two pages back instead of one.
        app.typeKey("t", modifierFlags: .command)
        submitCommandPaletteText("https://example.com", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "url=https://example.com/", timeout: 10), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 10), currentState(in: app))

        app.typeKey("l", modifierFlags: .command)
        submitCommandPaletteText("https://example.com/?second", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "url=https://example.com/?second", timeout: 10), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 10), currentState(in: app))

        app.typeKey("l", modifierFlags: .command)
        submitCommandPaletteText("https://example.com/?third", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "url=https://example.com/?third", timeout: 10), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 10), currentState(in: app))

        // The retired default must do nothing: still on the third page
        // after a settle beat.
        app.typeKey("[", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(
            currentState(in: app).contains("url=https://example.com/?third"),
            currentState(in: app)
        )

        // The person's binding goes back exactly one page — and stays there.
        app.typeKey("b", modifierFlags: [.control, .command])
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/?second", timeout: 10),
            currentState(in: app)
        )
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(
            currentState(in: app).contains("url=https://example.com/?second"),
            currentState(in: app)
        )
    }

    func testTestingBotFixtureCoversAddressAndCommandPaletteTabCreation() throws {
        let app = launchApp()

        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "folders=Work|Second"), currentState(in: app))
        XCTAssertTrue(
            waitForState(in: app, containing: "tabs=amazon.com|Granola|WebKit Documentation|Home / X|Apple"),
            currentState(in: app)
        )

        let addressButton = element("sidebar-address-button", in: app)
        XCTAssertTrue(addressButton.waitForExistence(timeout: 5))
        addressButton.click()

        XCTAssertTrue(waitForState(in: app, containing: "palette=true"), currentState(in: app))
        let addressURL = "https://developer.apple.com/documentation/webkit"
        submitCommandPaletteText(addressURL, in: app)

        XCTAssertTrue(waitForState(in: app, containing: "url=\(addressURL)"), currentState(in: app))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        let newTabURL = "https://www.iana.org/domains/reserved"
        submitCommandPaletteText(newTabURL, in: app)

        XCTAssertTrue(waitForState(in: app, containing: "url=\(newTabURL)"), currentState(in: app))

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "find=true"), currentState(in: app))
    }

    func testAddressEntryFromPinnedTabCreatesRegularTab() throws {
        let app = launchApp()

        let pinnedTab = element("tab-row-amazon-com", in: app)
        XCTAssertTrue(pinnedTab.waitForExistence(timeout: 5), currentState(in: app))
        pinnedTab.click()

        let addressButton = element("sidebar-address-button", in: app)
        XCTAssertTrue(addressButton.waitForExistence(timeout: 5), currentState(in: app))
        addressButton.click()
        submitCommandPaletteText("google.com", in: app)

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://www.google.com/", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "|Google|Apple"),
            currentState(in: app)
        )
    }

    func testControlTabSkipsFavoritesThatHaveNotBeenActivated() throws {
        let app = launchApp(fixture: "inactive-favorites")

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/current"),
            currentState(in: app)
        )
        app.typeKey(.tab, modifierFlags: .control)

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/current"),
            currentState(in: app)
        )
    }

    func testControlTabHoldCyclesPreviewWithoutSwitchingUntilRelease() throws {
        let app = launchApp(fixture: "split-view")

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)
        openFixtureTab(path: "three", in: app)

        // While Control stays held, each Tab press only moves the switcher
        // selection through the frozen recency order (three, two, one) —
        // the page itself must stay on "three" until Control is released.
        // The hold is driven through the app's UI-testing seam: neither
        // typeKey (resets modifier state per key) nor runner-posted
        // CGEvents (need an Accessibility grant CI lacks) can keep Control
        // down across several presses and assertions.
        postTabSwitcherAction("next")
        XCTAssertTrue(
            waitForState(in: app, containing: "switcher=true:two"),
            currentState(in: app)
        )
        XCTAssertTrue(currentState(in: app).contains("active=three"), currentState(in: app))

        postTabSwitcherAction("next")
        XCTAssertTrue(
            waitForState(in: app, containing: "switcher=true:one"),
            currentState(in: app)
        )
        XCTAssertTrue(currentState(in: app).contains("active=three"), currentState(in: app))

        // Releasing Control commits the highlighted tab and drops the overlay.
        postTabSwitcherAction("release")
        XCTAssertTrue(waitForState(in: app, containing: "active=one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "switcher=false"), currentState(in: app))
    }

    func testControlTabHoldDeleteClosesHighlightedCardAndEscapeCancels() throws {
        let app = launchApp(fixture: "split-view")

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)
        openFixtureTab(path: "three", in: app)

        // Strip order is recency: three (active), two, one. Highlight "two"
        // and press Delete while Control is held: the card goes, the
        // highlight moves on to "one", and the page stays on "three".
        postTabSwitcherAction("next")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:two"), currentState(in: app))

        postTabSwitcherAction("close")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:one"), currentState(in: app))
        var openTitles = openTabTitles(in: app)
        XCTAssertFalse(openTitles.contains("two"), currentState(in: app))
        XCTAssertTrue(openTitles.contains("one") && openTitles.contains("three"), currentState(in: app))
        XCTAssertTrue(currentState(in: app).contains("active=three"), currentState(in: app))

        // Closing the last-in-row card steps the highlight backwards.
        postTabSwitcherAction("close")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:three"), currentState(in: app))
        openTitles = openTabTitles(in: app)
        XCTAssertFalse(openTitles.contains("one"), currentState(in: app))
        XCTAssertTrue(openTitles.contains("three"), currentState(in: app))

        // A lone card cannot be closed from the strip; release keeps it.
        postTabSwitcherAction("close")
        postTabSwitcherAction("release")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=false"), currentState(in: app))
        XCTAssertTrue(openTabTitles(in: app).contains("three"), currentState(in: app))
        XCTAssertTrue(currentState(in: app).contains("active=three"), currentState(in: app))

        // Escape mid-cycle abandons the strip without switching.
        openFixtureTab(path: "four", in: app)
        postTabSwitcherAction("next")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:three"), currentState(in: app))
        postTabSwitcherAction("cancel")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=false"), currentState(in: app))
        postTabSwitcherAction("release")
        XCTAssertTrue(currentState(in: app).contains("active=four"), currentState(in: app))
        XCTAssertTrue(openTabTitles(in: app).contains("three"), currentState(in: app))
    }

    func testControlTabHoldDeleteBackfillsTheStripFromTheRecencyList() throws {
        let app = launchApp(fixture: "split-view")
        for path in ["a", "b", "c", "d", "e", "f", "g"] {
            openFixtureTab(path: path, in: app)
        }

        // Seven tabs, six cards: the strip shows the six most recent (g…b)
        // and its caption counts all seven.
        postTabSwitcherAction("next")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:f"), currentState(in: app))
        XCTAssertTrue(currentState(in: app).contains("switcherCards=g|f|e|d|c|b:7"), currentState(in: app))

        // Delete "f": "a" backfills at the tail, the highlight holds its
        // slot (now "e"), and the count ticks down.
        postTabSwitcherAction("close")
        XCTAssertTrue(waitForState(in: app, containing: "switcherCards=g|e|d|c|b|a:6"), currentState(in: app))
        XCTAssertTrue(currentState(in: app).contains("switcher=true:e"), currentState(in: app))

        // Keep deleting: the strip shrinks only once the list runs dry, and
        // the very last tab is refused.
        for expected in ["g|d|c|b|a:5", "g|c|b|a:4", "g|b|a:3", "g|a:2"] {
            postTabSwitcherAction("close")
            XCTAssertTrue(waitForState(in: app, containing: "switcherCards=\(expected)"), currentState(in: app))
        }
        XCTAssertTrue(currentState(in: app).contains("switcher=true:a"), currentState(in: app))
        postTabSwitcherAction("close")
        XCTAssertTrue(waitForState(in: app, containing: "switcherCards=g:1"), currentState(in: app))
        postTabSwitcherAction("close")
        XCTAssertTrue(currentState(in: app).contains("switcherCards=g:1"), currentState(in: app))

        postTabSwitcherAction("release")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=false"), currentState(in: app))
        XCTAssertTrue(currentState(in: app).contains("active=g"), currentState(in: app))
    }

    func testControlTabHoldCyclesOnlyTheVisibleCards() throws {
        let app = launchApp(fixture: "split-view")
        for path in ["a", "b", "c", "d", "e", "f", "g"] {
            openFixtureTab(path: path, in: app)
        }

        // Seven tabs, six cards (g…b): stepping through the strip wraps from
        // its last card back to its first — "a" has no card and is skipped.
        for expected in ["f", "e", "d", "c", "b", "g", "f"] {
            postTabSwitcherAction("next")
            XCTAssertTrue(waitForState(in: app, containing: "switcher=true:\(expected)"), currentState(in: app))
        }
        for expected in ["g", "b"] {
            postTabSwitcherAction("previous")
            XCTAssertTrue(waitForState(in: app, containing: "switcher=true:\(expected)"), currentState(in: app))
        }
        XCTAssertTrue(currentState(in: app).contains("switcherCards=g|f|e|d|c|b:7"), currentState(in: app))

        postTabSwitcherAction("release")
        XCTAssertTrue(waitForState(in: app, containing: "active=b"), currentState(in: app))
    }

    func testControlTabHoldPointerHighlightsAndClickCommitsCards() throws {
        let app = launchApp(fixture: "split-view")

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)
        openFixtureTab(path: "three", in: app)

        postTabSwitcherAction("next")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:two"), currentState(in: app))

        // Arc-style: moving the pointer over a card highlights it without
        // switching; the page stays on "three" until something commits.
        let oneCard = element("tab-switcher-card-one", in: app)
        XCTAssertTrue(oneCard.waitForExistence(timeout: 5), currentState(in: app))
        element("tab-switcher-card-three", in: app).hover()
        oneCard.hover()
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:one"), currentState(in: app))
        XCTAssertTrue(currentState(in: app).contains("active=three"), currentState(in: app))

        // Clicking a card commits it right away — no need to lift Control.
        element("tab-switcher-card-two", in: app).hover()
        XCTAssertTrue(waitForState(in: app, containing: "switcher=true:two"), currentState(in: app))
        element("tab-switcher-card-two", in: app).click()
        XCTAssertTrue(waitForState(in: app, containing: "switcher=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "active=two"), currentState(in: app))

        // The eventual Control release finds nothing left to do.
        postTabSwitcherAction("release")
        XCTAssertTrue(currentState(in: app).contains("active=two"), currentState(in: app))
    }

    /// The `tabs=` segment of the state string, split into titles.
    private func openTabTitles(in app: XCUIApplication) -> [String] {
        currentState(in: app)
            .split(separator: ";")
            .first { $0.hasPrefix("tabs=") }
            .map { $0.dropFirst("tabs=".count).split(separator: "|").map(String.init) } ?? []
    }

    func testControlTabWarmsUpPreviewsForTabsNeverDisplayedThisRun() throws {
        // The "Dormant" tabs were visited in a previous session but have no
        // web view this run, no wake snapshot, and (UI runs disable the disk
        // cache) no persisted thumbnail — the favicon-placeholder card of
        // #340. The off-screen warm-up loads each once, a few at a time, and
        // every card gets a real image.
        let app = launchApp(
            fixture: "tab-switcher-previews",
            extraLaunchEnvironment: ["CANDOA_UI_TESTING_PREVIEW_WARMUP": "1"]
        )
        // The fixture page retitles the active tab from its path ("current");
        // the dormant tab keeps its stored title because the throwaway
        // warm-up view never touches tab state.
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/current"),
            currentState(in: app)
        )

        postTabSwitcherAction("next")
        XCTAssertTrue(
            waitForState(in: app, containing: "switcher=true:Dormant 1"),
            currentState(in: app)
        )
        // The active tab's card is a live capture; the dormant ones arrive
        // as their throwaway loads finish and settle.
        XCTAssertTrue(
            waitForState(
                in: app,
                containing: "switcherPreviews=current|Dormant 1|Dormant 2|Dormant 3|Dormant 4",
                timeout: 20
            ),
            currentState(in: app)
        )
        postTabSwitcherAction("release")
        XCTAssertTrue(waitForState(in: app, containing: "switcher=false"), currentState(in: app))
    }

    /// Drives the Ctrl-Tab switcher through the app's distributed-
    /// notification seam; the actions invoke the same store entry points
    /// as the real key monitor's press/release callbacks.
    private func postTabSwitcherAction(_ action: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.candoa.uitesting.tab-switcher"),
            object: action,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func testCommandPaletteDoesNotSwitchToMatchingTabInAnotherSpace() throws {
        let app = launchApp(fixture: "cross-space-duplicate-url")

        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "tabs=Apple"), currentState(in: app))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        submitCommandPaletteText("google.com", in: app)

        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot", timeout: 10), currentState(in: app))
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://www.google.com/", timeout: 10),
            currentState(in: app)
        )
    }
}
