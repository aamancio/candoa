import AppKit
import XCTest

extension CandoaUITests {
    func testLocalhostDeveloperBarWearsTheChromeTreatment() throws {
        // No server anywhere (neither the app nor the runner carries the
        // network-server entitlement): the coordinator's UI-testing fixture
        // intercept serves this HTML for local-development URLs, so the
        // localhost navigation is fully self-contained on CI.
        let host = "localhost:8080"
        let app = launchApp(extraLaunchEnvironment: [
            "CANDOA_UI_TESTING_PAGE_HTML":
                "<!doctype html><html><body style=\"background:#ffffff\"><h1>Candoa dev bar fixture</h1></body></html>"
        ])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openNewTabPalette(in: app)
        submitCommandPaletteText(host, in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=http://\(host)/", timeout: 15),
            currentState(in: app)
        )

        let window = app.windows.firstMatch
        let urlField = window.textFields
            .matching(NSPredicate(format: "value CONTAINS %@", host)).firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "developer bar URL field missing")

        // Let the page settle so the bar is in its resting visual state.
        sleep(2)

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Localhost developer bar"
        attachment.lifetime = .keepAlways
        add(attachment)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
        let windowFrame = window.frame
        let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height

        func color(atX xPt: CGFloat, y yPt: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(
                x: min(Int(xPt * scaleX), bitmap.pixelsWide - 1),
                y: min(Int(yPt * scaleY), bitmap.pixelsHigh - 1)
            )?.usingColorSpace(.sRGB))
        }

        // The bar shares the chrome's material, so there is no palette to
        // scan for: locate it by the URL field itself and check the run of
        // rows around it. The field's Y is only a starting point — the
        // AX-frame-to-bitmap mapping does not hold exactly across machines
        // (the CI runner's window layout shifted it onto the page below).
        let fieldCenterY = urlField.frame.midY - windowFrame.minY
        let barRows = stride(
            from: max(4, fieldCenterY - 20),
            through: fieldCenterY + 20,
            by: 2
        )

        // The URL text renders legibly against the chrome: light pixels
        // exist in the field's leading run (X mapping is reliable).
        var sawTextPixel = false
        let fieldLeading = urlField.frame.minX - windowFrame.minX
        textScan: for yPt in barRows {
            for xPt in stride(from: fieldLeading, to: fieldLeading + 220, by: 2) {
                let sample = try color(atX: xPt, y: yPt)
                if sample.brightnessComponent > 0.7 {
                    sawTextPixel = true
                    break textScan
                }
            }
        }
        XCTAssertTrue(sawTextPixel, "URL text is not legible on the developer bar")

        // Control icons share the bar's neutral foreground — none renders
        // in the saturated accent (the borderless menu button regression).
        let controlsMenu = window.menuButtons.firstMatch
        if controlsMenu.exists {
            let menuFrame = controlsMenu.frame
            for xPt in stride(from: menuFrame.minX - windowFrame.minX, to: menuFrame.maxX - windowFrame.minX, by: 1) {
                for yPt in barRows {
                    let sample = try color(atX: xPt, y: yPt)
                    XCTAssertLessThan(
                        sample.blueComponent - sample.redComponent, 0.5,
                        "a developer bar control renders accent-tinted instead of the bar foreground"
                    )
                }
            }
        }

        // The URL field accepts input: click, retype, and navigate.
        urlField.click()
        window.typeKey("a", modifierFlags: .command)
        window.typeText("\(host)/dashboard\r")
        XCTAssertTrue(
            waitForState(in: app, containing: "url=http://\(host)/dashboard", timeout: 15),
            currentState(in: app)
        )
    }

    func testWebsiteAppearanceRendersYouTubeInDarkMode() throws {
        let app = launchApp(fixture: "website-appearance", websiteAppearance: "dark")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openNewTabPalette(in: app)
        submitCommandPaletteText("youtube.com", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://www.youtube.com/", timeout: 15),
            currentState(in: app)
        )

        let pageLoaded = app.staticTexts["Try searching to get started"]
        XCTAssertTrue(pageLoaded.waitForExistence(timeout: 15))
        XCTAssertTrue(
            waitForState(in: app, containing: "websiteAppearance=dark", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "pageScheme=initial-dark-media-dark-html-dark", timeout: 5),
            currentState(in: app)
        )

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "YouTube with Website appearance set to Dark"
        attachment.lifetime = .keepAlways
        add(attachment)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
        let pageBackground = try XCTUnwrap(
            bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        )
        let luminance = 0.2126 * pageBackground.redComponent
            + 0.7152 * pageBackground.greenComponent
            + 0.0722 * pageBackground.blueComponent
        XCTAssertLessThan(luminance, 0.25, "Expected YouTube's page surface to render dark")
    }

    func testExternalHTTPSURLIsOpenedDirectlyInANewTab() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let url = try XCTUnwrap(URL(string: "https://example.com/candoa-external-url-test?source=macos"))
        // Another Candoa instance (an installed copy or a leftover Xcode
        // debug session) may share the bundle identifier; the app under
        // test is always the most recently launched instance.
        let appURL = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "app.candoa.browser")
                .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
                .bundleURL
        )
        let opened = expectation(description: "macOS delivered the external URL to Candoa")
        var openError: Error?

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            openError = error
            opened.fulfill()
        }

        wait(for: [opened], timeout: 10)
        XCTAssertNil(openError)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=\(url.absoluteString)", timeout: 10),
            currentState(in: app)
        )
    }

    func testHistoryCanBeSearchedDeletedAndReopened() throws {
        let app = launchApp(fixture: "history")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        submitCommandPaletteText("https://fixture.candoa.test/history", in: app)
        XCTAssertTrue(app.staticTexts["Candoa History Fixture"].waitForExistence(timeout: 10))

        app.typeKey("y", modifierFlags: .command)
        let historyView = element("history-view", in: app)
        XCTAssertTrue(historyView.waitForExistence(timeout: 5))

        let historyRow = app.staticTexts["https://fixture.candoa.test/history"].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(historyView.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Candoa History Fixture"].waitForExistence(timeout: 5))

        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(historyView.waitForExistence(timeout: 5))

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Searchable History"
        attachment.lifetime = .keepAlways
        add(attachment)

        let searchField = app.searchFields["Search History"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        pasteText("fixture.candoa.test", into: searchField)
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))

        historyRow.click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(historyRow.waitForExistence(timeout: 5))

        app.typeKey("y", modifierFlags: .command)
        XCTAssertFalse(historyView.waitForExistence(timeout: 5))
        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(element("history-view", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["https://fixture.candoa.test/history"].exists)
    }

    func testClearHistoryMenuClearsHistoryAndIsDisabledInPrivateWindows() throws {
        let app = launchApp(fixture: "history")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        submitCommandPaletteText("https://fixture.candoa.test/history", in: app)
        XCTAssertTrue(app.staticTexts["Candoa History Fixture"].waitForExistence(timeout: 10))

        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(element("history-view", in: app).waitForExistence(timeout: 5))
        let historyRow = app.staticTexts["https://fixture.candoa.test/history"].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))

        // Private windows have nothing persistent to clear, so the menu
        // command must be disabled while one is key.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let privateWindow = app.windows["Private Browsing"]
        XCTAssertTrue(privateWindow.waitForExistence(timeout: 10))
        element("private-browsing-label", in: privateWindow).click()
        let historyMenu = app.menuBars.menuBarItems["History"]
        historyMenu.click()
        let clearHistoryItem = app.menuBars.menuItems["Clear History…"]
        XCTAssertTrue(clearHistoryItem.waitForExistence(timeout: 5))
        XCTAssertFalse(
            clearHistoryItem.isEnabled,
            "Clear History… must be disabled while a private window is key"
        )
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        let privateWindowClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: privateWindow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [privateWindowClosed], timeout: 10), .completed)

        // Back in the ordinary window the command opens the confirmation
        // sheet; the default scope (This Space, Last Hour) covers the visit.
        // Focus needs a beat to land back on the ordinary window after the
        // private one closes — opening the menu mid-transition leaves its
        // items without frames.
        app.activate()
        XCTAssertTrue(element("history-view", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        historyMenu.click()
        let enabledClearItem = app.menuBars.menuItems["Clear History…"]
        XCTAssertTrue(enabledClearItem.waitForExistence(timeout: 5))
        XCTAssertTrue(enabledClearItem.isEnabled)
        XCTAssertTrue(enabledClearItem.isHittable)
        enabledClearItem.click()

        // The confirming button carries Safari's wording, "Clear History".
        let confirmButton = app.sheets.buttons["Clear History"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.click()

        let historyRowGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: historyRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [historyRowGone], timeout: 10), .completed)
        XCTAssertTrue(
            app.staticTexts["No History"].waitForExistence(timeout: 5),
            "Clearing everything in range should leave the empty history state"
        )
    }

    func testPrivateWindowOpensIsolatedAndRecordsNoHistory() throws {
        let app = launchApp(fixture: "history")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitForState(in: app, containing: "private=false"), currentState(in: app))

        // Give shared history one ordinary visit to compare against.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        submitCommandPaletteText("https://fixture.candoa.test/history", in: app)
        XCTAssertTrue(app.staticTexts["Candoa History Fixture"].firstMatch.waitForExistence(timeout: 10))

        // Positive control for the private-window absence check below: the
        // same query must find the empty-favorites hint in an ordinary window.
        XCTAssertTrue(
            element("favorites-drop-zone", in: app).waitForExistence(timeout: 5),
            "An ordinary window with no favorites should show the drop-zone hint"
        )

        app.typeKey("n", modifierFlags: [.command, .shift])
        let privateWindow = app.windows["Private Browsing"]
        XCTAssertTrue(privateWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            element("private-browsing-label", in: privateWindow).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            waitForState(in: privateWindow, containing: "private=true"),
            currentState(in: privateWindow)
        )
        XCTAssertTrue(
            element("private-browsing-explainer", in: privateWindow).waitForExistence(timeout: 5),
            "An empty private window should present the Private Browsing explainer"
        )
        XCTAssertFalse(
            element("favorites-drop-zone", in: privateWindow).exists,
            "Private windows must not advertise workspace favorites"
        )

        // Force key status onto the private window before typing: window
        // existence in the accessibility tree can precede key status.
        element("private-browsing-label", in: privateWindow).click()
        openNewTabPalette(in: privateWindow, of: app)
        submitCommandPaletteText("https://fixture.candoa.test/private-visit", in: privateWindow)
        XCTAssertTrue(
            waitForState(
                in: privateWindow,
                containing: "url=https://fixture.candoa.test/private-visit",
                timeout: 15
            ),
            currentState(in: privateWindow)
        )
        XCTAssertTrue(
            privateWindow.staticTexts["Candoa History Fixture"].firstMatch.waitForExistence(timeout: 10)
        )

        let screenshot = privateWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Private window with page loaded"
        attachment.lifetime = .keepAlways
        add(attachment)

        // A private window with one tab closes outright on Command-W.
        app.typeKey("w", modifierFlags: .command)
        let privateWindowClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: privateWindow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [privateWindowClosed], timeout: 10), .completed)

        // Back in the ordinary window: its own visit is in history, the
        // private one never was.
        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(element("history-view", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["https://fixture.candoa.test/history"]
                .firstMatch.waitForExistence(timeout: 5),
            "The ordinary visit should appear in history"
        )
        XCTAssertFalse(
            app.staticTexts["https://fixture.candoa.test/private-visit"].exists,
            "A private visit must not appear in history"
        )
    }

    func testOrdinaryNewWindowShortcutIsUnchangedByPrivateBrowsing() throws {
        let app = launchApp(fixture: "history")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .command)
        let secondWindowExists = NSPredicate(format: "count == 2")
        let windowCount = XCTNSPredicateExpectation(
            predicate: secondWindowExists,
            object: app.windows
        )
        XCTAssertEqual(XCTWaiter.wait(for: [windowCount], timeout: 10), .completed)
        XCTAssertFalse(
            app.windows["Private Browsing"].exists,
            "Command-N must keep opening ordinary windows"
        )
    }

    func testPrivateBrowsingLeavesNoPersistedStateAfterRelaunch() throws {
        let app = launchApp(fixture: "history")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // One ordinary visit, so relaunch can prove ordinary persistence
        // still works while private browsing left nothing behind.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
        submitCommandPaletteText("https://fixture.candoa.test/history", in: app)
        XCTAssertTrue(app.staticTexts["Candoa History Fixture"].firstMatch.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: [.command, .shift])
        let privateWindow = app.windows["Private Browsing"]
        XCTAssertTrue(privateWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            element("private-browsing-label", in: privateWindow).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            waitForState(in: privateWindow, containing: "private=true"),
            currentState(in: privateWindow)
        )

        // Force key status onto the private window before typing: window
        // existence in the accessibility tree can precede key status.
        element("private-browsing-label", in: privateWindow).click()
        openNewTabPalette(in: privateWindow, of: app)
        submitCommandPaletteText("https://fixture.candoa.test/private-leak", in: privateWindow)
        XCTAssertTrue(
            waitForState(
                in: privateWindow,
                containing: "url=https://fixture.candoa.test/private-leak",
                timeout: 15
            ),
            currentState(in: privateWindow)
        )

        // A private window with one tab closes outright on Command-W.
        app.typeKey("w", modifierFlags: .command)
        let privateWindowClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: privateWindow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [privateWindowClosed], timeout: 10), .completed)

        app.terminate()

        let relaunchedApp = launchApp(fixture: "persisted-workspace", preservesStore: true)
        XCTAssertTrue(relaunchedApp.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(
            relaunchedApp.windows["Private Browsing"].exists,
            "Private windows must not be restored across launches"
        )

        // The ordinary workspace round-tripped intact — the private
        // session neither replaced it nor rode along inside it.
        XCTAssertTrue(
            waitForState(in: relaunchedApp, containing: "space=TestingBot", timeout: 10),
            currentState(in: relaunchedApp)
        )
        XCTAssertTrue(
            waitForState(in: relaunchedApp, containing: "url=https://fixture.candoa.test/history", timeout: 10),
            currentState(in: relaunchedApp)
        )
        XCTAssertFalse(currentState(in: relaunchedApp).contains("private-leak"))

        relaunchedApp.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(element("history-view", in: relaunchedApp).waitForExistence(timeout: 5))
        XCTAssertTrue(
            relaunchedApp.staticTexts["https://fixture.candoa.test/history"]
                .firstMatch.waitForExistence(timeout: 5),
            "Ordinary history must survive the relaunch"
        )
        XCTAssertFalse(
            relaunchedApp.staticTexts["https://fixture.candoa.test/private-leak"].exists,
            "Private browsing must leave no history behind"
        )
    }

    func testBrowserMigrationImportsSafariFixtureThroughRealParser() throws {
        let app = launchApp(
            onboardingStep: "importData",
            browserImportFixture: "safari"
        )

        let browserSources = ["Safari", "Chrome", "Arc", "Firefox"].map { app.radioButtons[$0] }
        let firefoxSource = app.radioButtons["Firefox"]
        XCTAssertTrue(firefoxSource.waitForExistence(timeout: 10))

        for source in browserSources {
            XCTAssertTrue(source.exists)
            XCTAssertEqual(source.frame.midY, firefoxSource.frame.midY, accuracy: 2)
        }
        for (leadingSource, trailingSource) in zip(browserSources, browserSources.dropFirst()) {
            XCTAssertLessThan(leadingSource.frame.midX, trailingSource.frame.midX)
        }

        let importButton = app.buttons["Import from Safari…"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Import an HTML File…"].exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)

        importButton.click()
        let importStep = element("initial-onboarding-importData", in: app)
        let importFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: importStep
        )
        XCTAssertEqual(XCTWaiter.wait(for: [importFinished], timeout: 5), .completed)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@",
            "Imported 1 bookmark"
        )).firstMatch.exists)
        XCTAssertTrue(
            waitForState(in: app, containing: "Imported from Safari", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "Safari Import Fixture", timeout: 5),
            currentState(in: app)
        )
    }

    func testSkippingBrowserMigrationAdvancesToSpaceSetup() throws {
        let app = launchApp(onboardingStep: "importData")
        let importStep = element("initial-onboarding-importData", in: app)
        XCTAssertTrue(importStep.waitForExistence(timeout: 10))

        app.buttons["Skip"].click()

        let spaceStep = element("initial-onboarding-space", in: app)
        XCTAssertTrue(spaceStep.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 of 4"].exists)
        XCTAssertFalse(element("account-onboarding", in: app).exists)
    }
}
