import AppKit
import XCTest

extension CandoaUITests {
    /// Diagnostic: drives the real Google One Tap flow on notion.com and
    /// captures opener linkage inside the popup via the popup-diagnostics
    /// script. Requires network access.
    func testGoogleOneTapPopupDiagnostics() throws {
        let app = launchApp()

        // Prime the data store with Google cookies the way a real profile has
        // them (the bug reproduces with prior google-property visits).
        openNewTabPalette(in: app)
        submitCommandPaletteText("https://www.youtube.com", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 30), currentState(in: app))
        sleep(3)

        openNewTabPalette(in: app)
        submitCommandPaletteText("https://www.notion.com", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://www.notion.com", timeout: 30),
            currentState(in: app)
        )
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 30), currentState(in: app))

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))

        // The One Tap card renders in a delayed cross-origin iframe.
        let continueButton = webView.buttons["Continue"].firstMatch
        guard continueButton.waitForExistence(timeout: 20) else {
            throw XCTSkip("One Tap prompt did not appear: \(webView.debugDescription.suffix(3000))")
        }
        continueButton.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://accounts.google.com", timeout: 15),
            currentState(in: app)
        )
        // Give Google's page time to decide whether to keep the popup alive,
        // and record the timeline so a pass still shows the diagnostics.
        var timeline: [String] = []
        for second in 0..<10 {
            timeline.append("t+\(second)s url=\(stateValue("url", in: app) ?? "?")")
            sleep(1)
        }
        print("POPUP TIMELINE: \(timeline.joined(separator: " ; "))")
        print("POPUP DIAG: \(stateValue("popupDiag", in: app) ?? "none")")
        XCTAssertTrue(
            stateValue("url", in: app)?.hasPrefix("https://accounts.google.com") == true,
            "popup did not stay open — \(currentState(in: app))"
        )
    }

    /// window.open (OAuth sign-in popups, target=_blank) hands Candoa the
    /// source page's configuration; registering the popup web view against it
    /// must not re-add script message handlers, which throws and crashed the
    /// app before the popup could appear.
    func testWindowOpenPopupOpensTabWithoutCrashing() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/popup-child", timeout: 10),
            currentState(in: app)
        )
        XCTAssertEqual(app.state, .runningForeground)

        // The pop-up's own navigation goes to the network — which the fixture
        // host does not answer — so it never commits and the web view keeps
        // reporting no URL. The tab has to hold the destination it was opened
        // with anyway; blanking it here is what made this test fail on CI,
        // where the failure lands before the assertion above is even polled.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(
            stateValue("url", in: app),
            "https://fixture.candoa.test/popup-child",
            currentState(in: app)
        )
    }

    /// The address pill's leading icon opens Site Info: the popover names the
    /// effective origin, and its Pop-up Windows control persists a Block
    /// decision that the create-web-view delegate then enforces.
    func testSiteInfoBlocksPopupsForSite() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let siteInfoButton = element("sidebar-site-info-button", in: app)
        XCTAssertTrue(siteInfoButton.waitForExistence(timeout: 5), currentState(in: app))
        siteInfoButton.click()

        let popover = element("site-info-popover", in: app)
        XCTAssertTrue(popover.waitForExistence(timeout: 5), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=true"), currentState(in: app))
        XCTAssertTrue(
            element("site-info-host", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )

        // Pop-up Windows is the only permission defaulting to Allow, so the
        // value uniquely identifies its picker (SwiftUI menu pickers don't
        // reliably expose accessibility identifiers — see the Ask settings
        // tests).
        let popupPicker = popUpButton(withValue: "Allow", in: app)
        XCTAssertTrue(popupPicker.waitForExistence(timeout: 5), currentState(in: app))
        popupPicker.click()
        let blockItem = app.menuItems["Block"]
        XCTAssertTrue(blockItem.waitForExistence(timeout: 5))
        blockItem.click()
        XCTAssertTrue(
            popUpButton(withValue: "Block", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )

        // A stored decision surfaces the reset affordance.
        XCTAssertTrue(
            element("site-info-reset", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )

        // Dismiss by clicking the page: the transient popover consumes that
        // click, so it deterministically closes without reaching the page
        // (synthesized Escape can lose races when the machine is in use).
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=false"), currentState(in: app))

        // The page's window.open click must now be refused: the source tab
        // stays put and the delegate records the block.
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(
            waitForState(
                in: app,
                containing: "blocked href=https://fixture.candoa.test/popup-child",
                timeout: 10
            ),
            currentState(in: app)
        )
        XCTAssertTrue(
            stateValue("url", in: app)?.hasSuffix("/popup") == true,
            "blocked popup must not navigate or open a tab — \(currentState(in: app))"
        )
    }

    /// The address pill's trailing button opens the system share picker for
    /// the displayed page (its first row is Copy, so copying stays one step
    /// away). The button is hover-revealed but keeps a trace-opacity click
    /// footprint, so the test can address it without winning a hover race.
    func testAddressPillShareButtonOpensSharePicker() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let shareButton = element("sidebar-share-url-button", in: app)
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5), currentState(in: app))
        shareButton.click()

        // The NSSharingServicePicker menu is app-hosted; its Copy item is the
        // stable first entry across macOS versions.
        let copyItem = app.menuItems["Copy"]
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5), currentState(in: app))
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Candoa ▸ Site Info presents the same popover from the menu bar, in the
    /// app-menu slot Safari uses for its per-site entries.
    func testSiteInfoMenuCommandOpensPopover() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let appMenu = app.menuBars.menuBarItems["Candoa"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()
        let siteInfoItem = app.menuItems["Site Info…"]
        XCTAssertTrue(siteInfoItem.waitForExistence(timeout: 5))
        siteInfoItem.click()

        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=true"), currentState(in: app))
        XCTAssertTrue(
            element("site-info-popover", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )
    }

    /// Candoa ▸ Privacy Report presents the report sheet: the status row
    /// reflects the default-on protection, every category of the compiled
    /// blocklist is listed, and the retention statement is present. Done
    /// dismisses it.
    func testPrivacyReportMenuCommandShowsReport() {
        let app = launchApp()

        let appMenu = app.menuBars.menuBarItems["Candoa"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()
        let reportItem = app.menuItems["Privacy Report…"]
        XCTAssertTrue(reportItem.waitForExistence(timeout: 5))
        reportItem.click()

        XCTAssertTrue(waitForState(in: app, containing: "privacyReportShown=true"), currentState(in: app))
        XCTAssertTrue(
            element("privacy-report", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            element("privacy-report-status", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )
        for categoryID in ["ad-delivery", "ad-verification", "analytics", "session-recording"] {
            XCTAssertTrue(
                element("privacy-report-category-\(categoryID)", in: app).waitForExistence(timeout: 5),
                "missing category \(categoryID) — \(currentState(in: app))"
            )
        }
        XCTAssertTrue(
            element("privacy-report-retention", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )

        element("privacy-report-done", in: app).click()
        XCTAssertTrue(waitForState(in: app, containing: "privacyReportShown=false"), currentState(in: app))
    }

    /// Site Info hands off to the Privacy Report: its Tracking Protection
    /// section names the global state, and its button closes the popover
    /// before the sheet appears.
    func testSiteInfoOpensPrivacyReport() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let siteInfoButton = element("sidebar-site-info-button", in: app)
        XCTAssertTrue(siteInfoButton.waitForExistence(timeout: 5), currentState(in: app))
        siteInfoButton.click()

        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=true"), currentState(in: app))
        XCTAssertTrue(
            element("site-info-tracking", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )

        let reportButton = element("site-info-privacy-report", in: app)
        XCTAssertTrue(reportButton.waitForExistence(timeout: 5), currentState(in: app))
        reportButton.click()

        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "privacyReportShown=true"), currentState(in: app))
        XCTAssertTrue(
            element("privacy-report", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )
    }

    func testFileMenuOffersDocumentCommands() {
        let app = launchApp(fixture: "popup-open")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "saved-page", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "loading=false"), currentState(in: app))

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let openFileItem = app.menuBars.menuItems["Open File…"]
        XCTAssertTrue(openFileItem.waitForExistence(timeout: 5))
        XCTAssertTrue(openFileItem.isEnabled)
        let saveAsItem = app.menuBars.menuItems["Save As…"]
        XCTAssertTrue(saveAsItem.exists)
        XCTAssertTrue(saveAsItem.isEnabled)
        let shareItem = app.menuBars.menuItems["Share…"]
        XCTAssertTrue(shareItem.exists)
        XCTAssertTrue(shareItem.isEnabled)
        let exportItem = app.menuBars.menuItems["Export as PDF…"]
        XCTAssertTrue(exportItem.exists)
        XCTAssertTrue(exportItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// File ▸ Share… routes to the sidebar address pill's picker — the same
    /// NSSharingServicePicker the pill's hover button anchors, whose Copy item
    /// is the stable first entry across macOS versions.
    func testFileMenuShareCommandOpensSharePicker() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let shareItem = app.menuBars.menuItems["Share…"]
        XCTAssertTrue(shareItem.waitForExistence(timeout: 5))
        shareItem.click()

        let copyItem = app.menuItems["Copy"]
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5), currentState(in: app))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testOpenLocalFileCommandOpensChosenFile() throws {
        // NSOpenPanel runs out of process, so the app's UI-testing seam
        // writes a fixture file itself and opens it when the command fires.
        let app = launchApp(extraLaunchEnvironment: [
            "CANDOA_UI_TESTING_OPEN_FILE_FIXTURE": "1",
        ])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let openFileItem = app.menuBars.menuItems["Open File…"]
        XCTAssertTrue(openFileItem.waitForExistence(timeout: 5))
        openFileItem.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "url=file://", timeout: 15),
            currentState(in: app)
        )
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))
        XCTAssertTrue(
            webView.staticTexts["Local file content"].waitForExistence(timeout: 10),
            currentState(in: app)
        )
    }

    func testSaveAsAndExportAsPDFWriteDocuments() throws {
        let downloads = try XCTUnwrap(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
        let archiveURL = downloads.appendingPathComponent("saved-page.webarchive")
        let pdfURL = downloads.appendingPathComponent("saved-page.pdf")
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: pdfURL)
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: pdfURL)
        }

        // NSSavePanel runs out of process, so the app's UI-testing seam
        // writes straight into Downloads with the suggested name.
        let app = launchApp(
            fixture: "popup-open",
            extraLaunchEnvironment: ["CANDOA_UI_TESTING_EXPORT_TO_DOWNLOADS": "1"]
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        openFixtureTab(path: "saved-page", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "loading=false"), currentState(in: app))

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let saveAsItem = app.menuBars.menuItems["Save As…"]
        XCTAssertTrue(saveAsItem.waitForExistence(timeout: 5))
        saveAsItem.click()
        XCTAssertTrue(
            waitForFile(at: archiveURL, timeout: 15),
            "Web archive was not written: \(currentState(in: app))"
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "saved-page.webarchive", timeout: 5),
            currentState(in: app)
        )

        fileMenu.click()
        let exportItem = app.menuBars.menuItems["Export as PDF…"]
        XCTAssertTrue(exportItem.waitForExistence(timeout: 5))
        exportItem.click()
        XCTAssertTrue(
            waitForFile(at: pdfURL, timeout: 15),
            "PDF was not written: \(currentState(in: app))"
        )
        let pdfHeader = try XCTUnwrap(FileHandle(forReadingFrom: pdfURL).readData(ofLength: 4))
        XCTAssertEqual(String(data: pdfHeader, encoding: .ascii), "%PDF")
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The Develop menu mirrors Safari's order with Candoa's own items kept:
    /// opening elsewhere, user-agent spoofing, and the device-targets submenu
    /// up top, developer mode, the inspector family, recording tools, caches,
    /// the developer-tools rows, and the copy commands. With a real page
    /// loaded every page-scoped command is enabled.
    func testDevelopMenuOffersSafariParityCommands() throws {
        let app = launchApp(fixture: "popup-open")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "develop", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "loading=false"), currentState(in: app))

        let developMenu = app.menuBarItems["Develop"]
        XCTAssertTrue(developMenu.waitForExistence(timeout: 5))
        developMenu.click()

        let openPageWithItem = app.menuItems["Open Page With"]
        XCTAssertTrue(openPageWithItem.waitForExistence(timeout: 3))
        XCTAssertTrue(openPageWithItem.isEnabled)
        let userAgentItem = app.menuItems["User Agent"]
        XCTAssertTrue(userAgentItem.exists)
        XCTAssertTrue(userAgentItem.isEnabled)

        // After User Agent comes the device-targets submenu. Its title is
        // computed at launch — this Mac's name over its macOS version — and
        // the runner is the same machine, so rebuild both lines here (the
        // patch component is dropped when zero) rather than matching a
        // literal string. Query before any submenu opens: the User Agent
        // presets also carry "macOS" in their labels.
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        var macOSVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        if osVersion.patchVersion > 0 {
            macOSVersion += ".\(osVersion.patchVersion)"
        }
        let deviceItem = app.menuItems.matching(
            NSPredicate(format: "title CONTAINS %@", "macOS ")
        ).firstMatch
        XCTAssertTrue(deviceItem.exists, "missing device-targets submenu")
        XCTAssertTrue(deviceItem.isEnabled)
        if let computerName = Host.current().localizedName {
            XCTAssertTrue(
                deviceItem.title.hasPrefix(computerName),
                "device submenu should lead with this Mac's name: \(deviceItem.title)"
            )
        }
        XCTAssertTrue(
            deviceItem.title.hasSuffix("macOS \(macOSVersion)"),
            "device submenu should close with the OS version: \(deviceItem.title)"
        )

        // Safari has no Developer Mode row, so neither does Candoa's Develop
        // menu; the per-site toggle lives in the palette and the sidebar.
        XCTAssertFalse(app.menuItems["Turn On Developer Mode"].exists)

        for title in [
            "Show Web Inspector",
            "Connect Web Inspector",
            "Show JavaScript Console",
            "Show Page Source",
            "Show Page Resources",
            "Start Timeline Recording",
            "Start Element Selection",
            "Empty Caches",
        ] {
            let item = app.menuItems[title]
            XCTAssertTrue(item.exists, "missing Develop item \(title)")
            XCTAssertTrue(item.isEnabled, "\(title) should be enabled with a page loaded")
        }

        // Developer Settings and Feature Flags sit between the caches and
        // copy groups; neither depends on a page.
        for title in ["Developer Settings…", "Feature Flags…"] {
            let item = app.menuItems[title]
            XCTAssertTrue(item.exists, "missing Develop item \(title)")
            XCTAssertTrue(item.isEnabled, "\(title) should always be enabled")
        }

        XCTAssertTrue(app.menuItems["Copy URL"].exists)
        XCTAssertTrue(app.menuItems["Copy URL as Markdown"].exists)

        // Safari's Service Workers submenu is deliberately absent: its rows
        // open per-worker inspectors WebKit gives no entry point for.
        XCTAssertFalse(app.menuItems["Service Workers"].exists)

        // The User Agent submenu mirrors Safari's layout: the automatic
        // default, the Safari / Edge / Chrome / Firefox groups, and the
        // custom-agent escape hatch.
        userAgentItem.click()
        XCTAssertTrue(app.menuItems["Default (Automatically Chosen)"].waitForExistence(timeout: 3))
        for presetTitle in [
            "Safari — macOS",
            "Safari — iOS",
            "Safari — iPadOS",
            "Microsoft Edge — macOS",
            "Microsoft Edge — Windows",
            "Microsoft Edge — Android",
            "Google Chrome — macOS",
            "Google Chrome — Windows",
            "Google Chrome — Android",
            "Google Chrome — ChromeOS",
            "Firefox — macOS",
            "Firefox — Windows",
            "Firefox — Android",
            "Other…",
        ] {
            XCTAssertTrue(
                app.menuItems[presetTitle].exists,
                "missing User Agent preset \(presetTitle)"
            )
        }

        // Open Page With lists the installed HTTPS handlers; the exact set is
        // machine-dependent, but Safari ships with macOS.
        openPageWithItem.click()
        XCTAssertTrue(app.menuItems["Safari"].waitForExistence(timeout: 3))

        // The device-targets submenu leads with a disabled Candoa header,
        // then one enabled row per inspectable page named host — path.
        // Clicking the parent swaps out the Open Page With submenu.
        deviceItem.click()
        // Scoped to the submenu: the Window menu also carries a "Candoa" row
        // (the main window's title) in the closed-menu accessibility tree.
        let candoaHeaderItem = deviceItem.menuItems["Candoa"]
        XCTAssertTrue(candoaHeaderItem.waitForExistence(timeout: 3))
        XCTAssertFalse(candoaHeaderItem.isEnabled, "the app header row is informational only")
        let inspectablePageItem = deviceItem.menuItems["fixture.candoa.test — develop"]
        XCTAssertTrue(inspectablePageItem.exists)
        XCTAssertTrue(inspectablePageItem.isEnabled, "a loaded page is an inspectable target")

        // One escape per open menu level: submenu, then the Develop menu.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Without a loaded page there is nothing to inspect or hand off, so the
    /// page-scoped Develop commands must be disabled. The split-view fixture
    /// launches an empty Space with no active tab.
    func testDevelopMenuItemsDisabledWithoutPage() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(waitForState(in: app, containing: "url=none"), currentState(in: app))

        let developMenu = app.menuBarItems["Develop"]
        XCTAssertTrue(developMenu.waitForExistence(timeout: 5))
        developMenu.click()

        for title in [
            "Show Web Inspector",
            "Connect Web Inspector",
            "Show JavaScript Console",
            "Show Page Source",
            "Show Page Resources",
            "Empty Caches",
        ] {
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "missing Develop item \(title)")
            XCTAssertFalse(item.isEnabled, "\(title) must be disabled without a page")
        }

        // The device-targets submenu is always present; with nothing loaded
        // it carries the disabled placeholder.
        let deviceItem = app.menuItems.matching(
            NSPredicate(format: "title CONTAINS %@", "macOS ")
        ).firstMatch
        XCTAssertTrue(deviceItem.exists, "missing device-targets submenu")
        deviceItem.click()
        let noInspectablePagesItem = app.menuItems["No Inspectable Pages"]
        XCTAssertTrue(noInspectablePagesItem.waitForExistence(timeout: 3))
        XCTAssertFalse(noInspectablePagesItem.isEnabled, "the placeholder row is informational only")

        // One escape per open menu level: submenu, then the Develop menu.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Develop ▸ Empty Caches clears the Space's caches and confirms through
    /// the same toast surface the copy commands use.
    func testEmptyCachesShowsToast() throws {
        let app = launchApp(fixture: "popup-open")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "develop", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "loading=false"), currentState(in: app))

        let developMenu = app.menuBarItems["Develop"]
        XCTAssertTrue(developMenu.waitForExistence(timeout: 5))
        developMenu.click()

        let emptyCachesItem = app.menuItems["Empty Caches"]
        XCTAssertTrue(emptyCachesItem.waitForExistence(timeout: 3))
        XCTAssertTrue(emptyCachesItem.isEnabled)
        emptyCachesItem.click()

        XCTAssertTrue(
            app.staticTexts["Caches Emptied"].waitForExistence(timeout: 5),
            currentState(in: app)
        )
    }

    /// Develop ▸ Feature Flags… opens its own window; the command needs no
    /// page, so the empty split-view Space is enough.
    func testFeatureFlagsWindowOpensFromDevelopMenu() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(waitForState(in: app, containing: "url=none"), currentState(in: app))

        let developMenu = app.menuBarItems["Develop"]
        XCTAssertTrue(developMenu.waitForExistence(timeout: 5))
        developMenu.click()

        let featureFlagsItem = app.menuItems["Feature Flags…"]
        XCTAssertTrue(featureFlagsItem.waitForExistence(timeout: 3))
        XCTAssertTrue(featureFlagsItem.isEnabled)
        featureFlagsItem.click()

        let featureFlagsWindow = app.windows["Feature Flags"]
        XCTAssertTrue(featureFlagsWindow.waitForExistence(timeout: 5))

        featureFlagsWindow.buttons[XCUIIdentifierCloseWindow].click()
        let featureFlagsWindowClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: featureFlagsWindow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [featureFlagsWindowClosed], timeout: 10), .completed)
    }

    /// Window ▸ Arrange Tabs By ▸ Title re-sorts the active Space's regular
    /// bucket alphabetically. New tabs land at the top of their bucket, so
    /// opening "apricot" before "banana" leaves the sidebar in the reversed
    /// order the command must fix.
    func testArrangeTabsByTitleSortsActiveSpaceTabs() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "apricot", in: app)
        openFixtureTab(path: "banana", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "tabs=banana|apricot"), currentState(in: app))

        let windowMenu = app.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 5))
        windowMenu.click()

        let arrangeItem = app.menuItems["Arrange Tabs By"]
        XCTAssertTrue(arrangeItem.waitForExistence(timeout: 3))
        XCTAssertTrue(arrangeItem.isEnabled, "two regular tabs make the bucket sortable")
        arrangeItem.click()

        let titleItem = app.menuItems["Title"]
        XCTAssertTrue(titleItem.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Website"].exists)
        titleItem.click()

        XCTAssertTrue(waitForState(in: app, containing: "tabs=apricot|banana"), currentState(in: app))
    }

    /// With at most one tab in every bucket there is nothing to sort, so the
    /// Arrange Tabs By submenu greys out instead of offering a no-op.
    func testArrangeTabsDisabledWithSingleTab() throws {
        // The split-view fixture is an empty Space; a single opened tab is
        // the only sortable candidate, which is not enough.
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "solo", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "tabs=solo"), currentState(in: app))

        let windowMenu = app.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 5))
        windowMenu.click()

        // AppKit keeps submenu parents enabled, so the child items carry
        // the disabled state.
        let arrangeItem = app.menuItems["Arrange Tabs By"]
        XCTAssertTrue(arrangeItem.waitForExistence(timeout: 3))
        arrangeItem.click()

        let titleItem = arrangeItem.menuItems["Title"]
        XCTAssertTrue(titleItem.waitForExistence(timeout: 3))
        XCTAssertFalse(titleItem.isEnabled, "a single tab must not be sortable")
        let websiteItem = arrangeItem.menuItems["Website"]
        XCTAssertTrue(websiteItem.exists)
        XCTAssertFalse(websiteItem.isEnabled, "a single tab must not be sortable")

        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A page that never reported media leaves both mute commands with
    /// nothing to act on, so they stay disabled.
    func testMuteMenuItemsDisabledWithoutMedia() throws {
        let app = launchApp(fixture: "popup-open")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "develop", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "loading=false"), currentState(in: app))

        let windowMenu = app.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 5))
        windowMenu.click()

        let muteThisItem = app.menuItems["Mute This Tab"]
        XCTAssertTrue(muteThisItem.waitForExistence(timeout: 3))
        XCTAssertFalse(muteThisItem.isEnabled, "no media on the active tab")

        let muteOthersItem = app.menuItems["Mute Other Tabs"]
        XCTAssertTrue(muteOthersItem.exists)
        XCTAssertFalse(muteOthersItem.isEnabled, "no other tab has unmuted media")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Help ▸ Acknowledgments opens its own small window with the bundled
    /// credits; the window's close button tears it back down.
    func testHelpMenuOpensAcknowledgments() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let helpMenu = app.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 5))
        helpMenu.click()

        let acknowledgmentsItem = app.menuItems["Acknowledgments"]
        XCTAssertTrue(acknowledgmentsItem.waitForExistence(timeout: 3))
        acknowledgmentsItem.click()

        let ackWindow = app.windows["Acknowledgments"]
        XCTAssertTrue(ackWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element("acknowledgments-view", in: ackWindow).waitForExistence(timeout: 5)
        )
        // The bundled Credits.rtf names the open-source software.
        XCTAssertTrue(
            ackWindow.staticTexts.containing(
                NSPredicate(format: "value CONTAINS %@", "Sparkle")
            ).firstMatch.waitForExistence(timeout: 5)
        )

        ackWindow.buttons[XCUIIdentifierCloseWindow].click()
        let windowGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: ackWindow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [windowGone], timeout: 10), .completed)
    }

    /// An article page enables View ▸ Show Reader: entering swaps the same
    /// web view to the reader document (article text kept, page chrome
    /// stripped), and exiting restores the original live page.
    func testReaderEntersAndExitsForArticlePage() {
        let app = launchApp(fixture: "reader-article")

        openFixtureTab(path: "reader-article", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:inactive", timeout: 10),
            currentState(in: app)
        )

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))
        XCTAssertTrue(
            webView.links["Fixture Nav Link"].waitForExistence(timeout: 5),
            currentState(in: app)
        )

        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let showReaderItem = app.menuItems["Show Reader"]
        XCTAssertTrue(showReaderItem.waitForExistence(timeout: 5))
        XCTAssertTrue(showReaderItem.isEnabled, currentState(in: app))
        showReaderItem.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:active", timeout: 10),
            currentState(in: app)
        )
        // The article body survives; the page's navigation chrome does not.
        XCTAssertTrue(
            webView.staticTexts["Reader fixture marker sentence."].waitForExistence(timeout: 10),
            currentState(in: app)
        )
        XCTAssertFalse(webView.links["Fixture Nav Link"].exists, currentState(in: app))

        viewMenu.click()
        let hideReaderItem = app.menuItems["Hide Reader"]
        XCTAssertTrue(hideReaderItem.waitForExistence(timeout: 5))
        hideReaderItem.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:inactive", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(
            webView.links["Fixture Nav Link"].waitForExistence(timeout: 10),
            currentState(in: app)
        )
    }

    /// Escape is the other way out of Reader: it exits to the live page and
    /// leaves the tab free to re-enter, and the find bar still gets the first
    /// press when both are up.
    func testEscapeExitsReaderAndFindBarTakesPrecedence() {
        let app = launchApp(fixture: "reader-article")

        openFixtureTab(path: "reader-article", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:inactive", timeout: 10),
            currentState(in: app)
        )

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))

        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let showReaderItem = app.menuItems["Show Reader"]
        XCTAssertTrue(showReaderItem.waitForExistence(timeout: 5))
        showReaderItem.click()
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:active", timeout: 10),
            currentState(in: app)
        )

        // Find bar first: one Escape closes it and Reader survives.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "find=true", timeout: 5), currentState(in: app))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForState(in: app, containing: "find=false", timeout: 5), currentState(in: app))
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:active", timeout: 5),
            currentState(in: app)
        )

        // The next Escape leaves Reader, and the page comes back intact.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:inactive", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(
            webView.links["Fixture Nav Link"].waitForExistence(timeout: 10),
            currentState(in: app)
        )

        // Reader stays off; a further Escape is the page's, not ours.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=available:inactive", timeout: 5),
            currentState(in: app)
        )
    }

    /// A page without article-grade text keeps the reader command disabled.
    func testReaderStaysUnavailableForNonArticlePage() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "reader=unavailable:inactive", timeout: 10),
            currentState(in: app)
        )

        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let showReaderItem = app.menuItems["Show Reader"]
        XCTAssertTrue(showReaderItem.waitForExistence(timeout: 5))
        XCTAssertFalse(showReaderItem.isEnabled, currentState(in: app))
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A hosted session completes only on the request's own callback match,
    /// and completion tears the dedicated window down without touching tabs.
    /// Ephemeral mode is exercised here so the non-persistent store path
    /// runs end to end.
    func testHostedWebAuthenticationCompletesOnMatchingCallback() throws {
        let app = launchApp(fixture: "web-auth")
        XCTAssertTrue(waitForState(in: app, containing: "active=Apple"), currentState(in: app))
        let tabsBefore = stateValue("tabs", in: app)

        beginWebAuthRequest(id: "t1", path: "auth-success", mode: "ephemeral")

        XCTAssertTrue(
            waitForState(in: app, containing: "t1:began:ephemeral", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(
                in: app,
                containing: "t1:resolved-completed:candoa-e2e://auth?code=ok",
                timeout: 10
            ),
            currentState(in: app)
        )

        // Completion closes the authentication window and leaves the
        // browser's tabs untouched — the session never joins the tab world.
        let authWindow = app.windows["Sign In — fixture.candoa.test"]
        XCTAssertFalse(authWindow.exists, currentState(in: app))
        XCTAssertEqual(stateValue("tabs", in: app), tabsBefore, currentState(in: app))
    }

    /// Closing the authentication window returns the standard canceled-login
    /// error (ASWebAuthenticationSessionError code 1) to the requesting app.
    func testHostedWebAuthenticationWindowCloseCancels() throws {
        let app = launchApp(fixture: "web-auth")
        XCTAssertTrue(waitForState(in: app, containing: "active=Apple"), currentState(in: app))

        beginWebAuthRequest(id: "t2", path: "auth-wait", mode: "shared")
        XCTAssertTrue(
            waitForState(in: app, containing: "t2:began:shared", timeout: 10),
            currentState(in: app)
        )

        let authWindow = app.windows["Sign In — fixture.candoa.test"]
        XCTAssertTrue(authWindow.waitForExistence(timeout: 10), currentState(in: app))
        authWindow.buttons[XCUIIdentifierCloseWindow].click()

        XCTAssertTrue(
            waitForState(in: app, containing: "t2:resolved-canceled:", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(
            (stateValue("webAuth", in: app) ?? "").contains("t2:resolved-canceled:")
                && (stateValue("webAuth", in: app) ?? "").hasSuffix(":1"),
            currentState(in: app)
        )
    }

    /// A navigation to a lookalike scheme the request did not register must
    /// not complete the session — only the exact callback match may.
    func testHostedWebAuthenticationIgnoresNonMatchingCallback() throws {
        let app = launchApp(fixture: "web-auth")
        XCTAssertTrue(waitForState(in: app, containing: "active=Apple"), currentState(in: app))

        beginWebAuthRequest(id: "t3", path: "auth-wrong", mode: "shared")
        XCTAssertTrue(
            waitForState(in: app, containing: "t3:began:shared", timeout: 10),
            currentState(in: app)
        )

        // The wrong-scheme redirect is swallowed; the session stays pending
        // with its window up and no resolution event.
        let authWindow = app.windows["Sign In — fixture.candoa.test"]
        XCTAssertTrue(authWindow.waitForExistence(timeout: 10), currentState(in: app))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(
            (stateValue("webAuth", in: app) ?? "").contains("t3:resolved"),
            currentState(in: app)
        )

        authWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(
            waitForState(in: app, containing: "t3:resolved-canceled:", timeout: 10),
            currentState(in: app)
        )
    }

    /// When the requesting app cancels its session, AuthenticationServices
    /// only expects the browser UI to disappear — no completion, no error.
    func testHostedWebAuthenticationSystemCancelDismissesSilently() throws {
        let app = launchApp(fixture: "web-auth")
        XCTAssertTrue(waitForState(in: app, containing: "active=Apple"), currentState(in: app))

        beginWebAuthRequest(id: "t4", path: "auth-wait", mode: "shared")
        let authWindow = app.windows["Sign In — fixture.candoa.test"]
        XCTAssertTrue(authWindow.waitForExistence(timeout: 10), currentState(in: app))

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.candoa.uitesting.web-auth-cancel"),
            object: "t4",
            userInfo: nil,
            deliverImmediately: true
        )

        XCTAssertTrue(
            waitForState(in: app, containing: "t4:dismissed", timeout: 10),
            currentState(in: app)
        )
        XCTAssertFalse(authWindow.exists, currentState(in: app))
        XCTAssertFalse(
            (stateValue("webAuth", in: app) ?? "").contains("t4:resolved"),
            currentState(in: app)
        )
    }

    /// A docked Web Inspector belongs inside the visible page card. WebKit
    /// lays an attached inspector out against its attachment view's superview,
    /// and the live web view deliberately spans the reserved sidebar lane — so
    /// while the web view was its own attachment view the inspector spanned
    /// that lane too, and an open sidebar covered its toolbar, close button
    /// first.
    func testDockedWebInspectorStaysInsideThePageCard() throws {
        let app = launchApp(
            fixture: "popup-open",
            extraLaunchEnvironment: ["CANDOA_UI_TESTING_DOCK_INSPECTOR": "1"]
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "develop", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "sidebar=true"), currentState(in: app))
        XCTAssertTrue(
            waitForState(in: app, containing: "inspector=attached:", timeout: 15),
            currentState(in: app)
        )

        let docked = try inspectorPlacement(in: app)
        XCTAssertGreaterThan(
            docked.card.minX,
            0,
            "the open sidebar should hold a lane the card starts after: \(currentState(in: app))"
        )
        assertInspectorFillsCard(docked, in: app)

        // Closing the sidebar hands the lane back: the card widens to the
        // window and the inspector has to follow it, not stay short.
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "sidebar=false"), currentState(in: app))
        XCTAssertTrue(
            waitForState(in: app, containing: "inspector=attached:0,", timeout: 5),
            currentState(in: app)
        )
        assertInspectorFillsCard(try inspectorPlacement(in: app), in: app)
    }

    private struct InspectorPlacement {
        var inspector: CGRect
        var card: CGRect
    }

    /// Reads `inspector=attached:x,y,w,h:card:x,y,w,h` out of the UI-testing
    /// state: the docked inspector's frame and the visible page card, both in
    /// the pane host's own coordinates.
    private func inspectorPlacement(in app: XCUIApplication) throws -> InspectorPlacement {
        let value = try XCTUnwrap(stateValue("inspector", in: app), currentState(in: app))
        let fields = value.split(separator: ":")
        XCTAssertEqual(fields.count, 4, "unexpected inspector state \(value)")

        func rect(_ field: Substring) throws -> CGRect {
            let numbers = field.split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(numbers.count, 4, "unexpected inspector rect \(field)")
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }

        return InspectorPlacement(inspector: try rect(fields[1]), card: try rect(fields[3]))
    }

    private func assertInspectorFillsCard(
        _ placement: InspectorPlacement,
        in app: XCUIApplication
    ) {
        XCTAssertEqual(
            placement.inspector.minX,
            placement.card.minX,
            accuracy: 1,
            "docked inspector should start at the card's leading edge: \(currentState(in: app))"
        )
        XCTAssertEqual(
            placement.inspector.width,
            placement.card.width,
            accuracy: 1,
            "docked inspector should span the card, lanes excluded: \(currentState(in: app))"
        )
        XCTAssertGreaterThan(placement.inspector.height, 0, currentState(in: app))
    }

    /// Stands in for AuthenticationServices routing a session request to the
    /// default browser: real requests need default-browser consent no CI
    /// runner can grant, so the app's UI-testing seam mints an equivalent
    /// request behind the same hosting path.
    private func beginWebAuthRequest(id: String, path: String, mode: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.candoa.uitesting.web-auth-begin"),
            object: "\(id)|https://fixture.candoa.test/\(path)|candoa-e2e|\(mode)",
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
