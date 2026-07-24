import AppKit
import XCTest

@MainActor
final class CandoaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesMainWindow() throws {
        let app = launchApp()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testWebsiteAppearanceRendersYouTubeInDarkMode() throws {
        let app = launchApp(fixture: "website-appearance", websiteAppearance: "dark")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true"), currentState(in: app))
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
        let appURL = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "app.candoa.browser")
                .first?.bundleURL
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
        XCTAssertTrue(app.staticTexts["2 of 3"].exists)
        XCTAssertFalse(element("account-onboarding", in: app).exists)
    }

    func testBrowserMigrationImportsChromeFixtureThroughRealParser() throws {
        try assertBrowserMigration(
            source: "Chrome",
            fixtureName: "chrome",
            importedTitle: "Chrome Import Fixture"
        )
    }

    func testBrowserMigrationImportsArcFixtureThroughRealParser() throws {
        try assertBrowserMigration(
            source: "Arc",
            fixtureName: "arc",
            importedTitle: "Arc Import Fixture"
        )
    }

    func testBrowserMigrationImportsFirefoxFixtureThroughRealParser() throws {
        try assertBrowserMigration(
            source: "Firefox",
            fixtureName: "firefox",
            importedTitle: "Firefox Import Fixture"
        )
    }

    func testSafariMigrationReportsPermissionRequirementForUnreadableProfile() throws {
        let app = launchApp(
            onboardingStep: "importData",
            browserImportFixture: "unreadable-safari"
        )

        let importButton = app.buttons["Import from Safari…"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.click()

        let chooseProfileButton = app.buttons["Choose Profile…"]
        XCTAssertTrue(chooseProfileButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Couldn’t Import Bookmarks"].exists)
        XCTAssertTrue(app.staticTexts["macOS requires permission before Candoa can read Safari’s bookmarks."].exists)
        XCTAssertFalse(app.buttons["Continue"].exists)
    }

    func testCreateSpaceButtonAcceptsClicksAcrossItsVisibleWidth() throws {
        let app = launchApp(onboardingStep: "space")
        let createSpaceButton = app.buttons["Create Space"]
        XCTAssertTrue(createSpaceButton.waitForExistence(timeout: 10))

        createSpaceButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

        let spaceOnboarding = element("initial-onboarding-space", in: app)
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: spaceOnboarding
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    func testAppleSignInKeepsProviderButtonDisabledWhileWorking() throws {
        let app = launchApp(onboardingStep: "account", appleSignInWorking: true)
        let accountOnboarding = element("account-onboarding", in: app).firstMatch

        XCTAssertTrue(accountOnboarding.waitForExistence(timeout: 10))
        XCTAssertEqual(accountOnboarding.value as? String, "signing-in")

        let signInButton = element("onboarding-apple-sign-in", in: app).firstMatch
        XCTAssertTrue(signInButton.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(signInButton.frame.height, 42)
        XCTAssertFalse(signInButton.isEnabled)
    }

    func testAccountOnboardingOffersAppleAndLocalUse() throws {
        let app = launchApp(onboardingStep: "account")
        let accountOnboarding = element("account-onboarding", in: app).firstMatch

        XCTAssertTrue(accountOnboarding.waitForExistence(timeout: 10))
        XCTAssertEqual(accountOnboarding.value as? String, "idle")
        XCTAssertTrue(app.buttons["Continue with Apple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Not Now"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertFalse(app.buttons["Skip"].exists)
        XCTAssertFalse(app.buttons["Explore on My Own"].exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testNotNowCompletesAccountSetup() throws {
        let app = launchApp(onboardingStep: "account")
        let accountOnboarding = element("account-onboarding", in: app).firstMatch
        XCTAssertTrue(accountOnboarding.waitForExistence(timeout: 10))

        let notNowButton = app.buttons["Not Now"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 5))
        notNowButton.click()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: accountOnboarding
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

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

    func testEliProPromptRendersSubscriptionGateAndCheckoutFailure() throws {
        let app = launchApp(fixture: "ask", checkoutFailure: true)

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        submitAskText("What is this page about?", in: app)

        let subscriptionGate = element("agent-subscription-gate", in: app)
        XCTAssertTrue(subscriptionGate.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(app.staticTexts["Eli with Candoa Pro"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Summarize pages, ask questions, and turn what you’re viewing into useful next steps."
            ].exists
        )
        XCTAssertFalse(element("agent-feedback-up", in: app).exists)
        XCTAssertFalse(element("agent-copy-text", in: app).exists)

        let subscribeButton = element("agent-subscribe-button", in: app)
        XCTAssertTrue(subscribeButton.exists)
        XCTAssertTrue(subscribeButton.isEnabled)
        XCTAssertFalse(element("agent-subscribe-error", in: app).exists)
        subscribeButton.click()
        let subscribeError = element("agent-subscribe-error", in: app)
        XCTAssertTrue(subscribeError.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertEqual(subscribeError.label, "Candoa checkout is temporarily unavailable.")
        XCTAssertTrue(subscribeButton.isEnabled)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Eli Pro subscription gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEliSubscriptionGateIsNotTreatedAsAssistantContent() throws {
        let app = launchApp(fixture: "ask")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        submitAskText("Summarize this page", in: app)
        XCTAssertTrue(element("agent-subscription-gate", in: app).waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(waitForAskState(in: app, containing: "lastAssistant=[]"), askState(in: app))
        XCTAssertFalse(element("agent-feedback-up", in: app).exists)
        XCTAssertFalse(element("agent-copy-text", in: app).exists)
    }

    func testEliPastesScreenshotIntoComposer() throws {
        let app = launchApp(fixture: "ask")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()

        let screenshot = NSImage(size: NSSize(width: 320, height: 120))
        screenshot.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: screenshot.size).fill()
        NSString(string: "Screenshot text for Eli").draw(
            at: NSPoint(x: 18, y: 48),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22)]
        )
        screenshot.unlockFocus()

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([screenshot]))
        field.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(
            waitForAskState(in: app, containing: "Pasted Image"),
            askState(in: app)
        )

        let previewButton = element("agent-attachment-preview", in: app)
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5), askState(in: app))
        previewButton.click()
        XCTAssertTrue(
            element("agent-image-preview-dialog", in: app).waitForExistence(timeout: 5),
            askState(in: app)
        )

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Eli pasted screenshot preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEliAgentNavigatesMultiplePagesAndConfirmsCancellation() throws {
        let app = launchApp(fixture: "ask-agent-navigation")
        let exactPrompt = "unsubscribe me from this service"

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeText(exactPrompt)
        field.typeKey(.return, modifierFlags: [])

        let allowButton = app.sheets.buttons["Allow This Task"].firstMatch
        XCTAssertTrue(allowButton.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(app.staticTexts["Let Eli take control of this browser tab?"].exists, app.debugDescription)
        allowButton.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/home#membership", timeout: 8),
            currentState(in: app)
        )
        XCTAssertTrue(app.staticTexts["Confirm this action?"].waitForExistence(timeout: 5), app.debugDescription)
        let activityStatus = element("agent-activity-status", in: app)
        XCTAssertTrue(activityStatus.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(activityStatus.label.contains("Using Cancel Membership"), activityStatus.debugDescription)
        XCTAssertTrue(
            app.staticTexts[
                "Eli is ready to activate \"Cancel Membership\". This may make a consequential change to your account."
            ].exists,
            app.debugDescription
        )
        XCTAssertFalse(currentState(in: app).contains("url=https://fixture.candoa.test/home#cancelled"))

        let confirmationAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        confirmationAttachment.name = "Eli consequential action confirmation"
        confirmationAttachment.lifetime = .keepAlways
        add(confirmationAttachment)

        let continueButton = app.sheets.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.exists, app.debugDescription)
        continueButton.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/home#cancelled", timeout: 8),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastAssistant=[Your membership has been cancelled.]", timeout: 8),
            askState(in: app)
        )
    }

    func testEliUsesVerifiedNavigationWithinOneTaskPermission() throws {
        let app = launchApp(fixture: "ask-agent-normalized-navigation")
        let exactPrompt = "take me to buy the MacBook Air"

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))
        submitAskText(exactPrompt, in: app)

        let allowButton = app.sheets.buttons["Allow This Task"].firstMatch
        XCTAssertTrue(allowButton.waitForExistence(timeout: 5), askState(in: app))
        allowButton.click()

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/buy", timeout: 8),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[The MacBook Air buying page is open.]",
                timeout: 8
            ),
            askState(in: app)
        )
        XCTAssertFalse(app.staticTexts["Confirm this action?"].exists, app.debugDescription)
        XCTAssertFalse(app.sheets.buttons["Allow This Task"].firstMatch.exists, app.debugDescription)
    }

    func testEliSelectsAProductOptionThenAddsItToTheCart() throws {
        let app = launchApp(fixture: "ask-agent-selection")
        let exactPrompt = "Bring mich dorthin und lege es in den Warenkorb"

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeText(exactPrompt)
        field.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastUser=[\(exactPrompt)]"),
            askState(in: app)
        )
        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[I can take control of this browser tab to complete your request. Please confirm first.]"
            ),
            askState(in: app)
        )
        let allowButton = app.sheets.buttons["Allow This Task"].firstMatch
        XCTAssertTrue(allowButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Let Eli take control of this browser tab?"].exists, app.debugDescription)
        allowButton.click()

        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastAssistant=[The MacBook Air is in your cart.]", timeout: 20),
            askState(in: app)
        )
        XCTAssertTrue(app.staticTexts["MacBook Air is in your cart."].waitForExistence(timeout: 5))

        submitAskText("remove teh computer from the cart", in: app)
        let removalTaskAllowButton = app.sheets.buttons["Allow This Task"].firstMatch
        XCTAssertTrue(removalTaskAllowButton.waitForExistence(timeout: 5), app.debugDescription)
        removalTaskAllowButton.click()
        XCTAssertTrue(app.staticTexts["Confirm this action?"].waitForExistence(timeout: 5), app.debugDescription)

        let continueButton = app.sheets.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.exists, app.debugDescription)
        continueButton.click()

        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[The MacBook Air was removed from your cart.]",
                timeout: 20
            ),
            askState(in: app)
        )
        XCTAssertTrue(app.staticTexts["Your cart is empty."].waitForExistence(timeout: 5))
    }

    private func launchApp(
        fixture: String? = nil,
        onboardingStep: String? = nil,
        browserImportFixture: String? = nil,
        appleSignInWorking: Bool = false,
        checkoutFailure: Bool = false,
        websiteAppearance: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if let websiteAppearance {
            app.launchArguments += ["-Candoa.Settings.ZenOption.WebsiteAppearance", websiteAppearance]
        }
        app.launchEnvironment["CANDOA_UI_TESTING"] = "1"
        app.launchEnvironment["CANDOA_UI_TESTING_STORE_ID"] = "TestingBot"
        if let fixture {
            app.launchEnvironment["CANDOA_UI_TESTING_FIXTURE"] = fixture
            if let pageHTML = Self.pageHTMLFixtures[fixture] {
                app.launchEnvironment["CANDOA_UI_TESTING_PAGE_HTML"] = pageHTML
            }
        }
        if let onboardingStep {
            app.launchEnvironment["CANDOA_UI_TESTING_ONBOARDING_STEP"] = onboardingStep
        }
        if let browserImportFixture {
            app.launchEnvironment["CANDOA_UI_TESTING_BROWSER_IMPORT_FIXTURE"] = browserImportFixture
        }
        if appleSignInWorking {
            app.launchEnvironment["CANDOA_UI_TESTING_APPLE_SIGN_IN_WORKING"] = "1"
        }
        if checkoutFailure {
            app.launchEnvironment["CANDOA_UI_TESTING_CHECKOUT_FAILURE"] = "1"
        }

        app.launch()
        return app
    }

    private static let pageHTMLFixtures: [String: String] = [
        "history": """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>Candoa History Fixture</title></head>
          <body><h1>Candoa History Fixture</h1><p>Representative browsing history.</p></body>
        </html>
        """,
        "ask-agent-navigation": """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>Membership</title></head>
          <body>
            <main id="content"></main>
            <script>
              const content = document.getElementById("content");
              const render = () => {
                const route = location.hash.slice(1) || "home";
                const next = {
                  home: ["Account", "account"],
                  account: ["Manage Membership", "membership"],
                  membership: ["Cancel Membership", "cancelled"]
                }[route];
                content.replaceChildren();
                if (next) {
                  const button = document.createElement("button");
                  button.textContent = next[0];
                  button.addEventListener("click", () => { location.hash = next[1]; });
                  content.append(button);
                } else {
                  content.textContent = "Membership Cancelled";
                }
              };
              addEventListener("hashchange", render);
              render();
            </script>
          </body>
        </html>
        """,
        "ask-agent-normalized-navigation": """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>MacBook Air</title></head>
          <body><a href="https://fixture.candoa.test/buy">Buy MacBook Air</a></body>
        </html>
        """,
        "ask-agent-selection": """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Configure MacBook Air</title>
          <style>
            body { font: 16px -apple-system; padding: 40px; }
            #color { width: 20px; height: 20px; }
            label[for="color"] { display: inline-block; margin-left: 8px; padding: 12px 18px; border: 1px solid #888; }
            label[for="color"]::before { content: "Sky Blue"; }
            button { padding: 12px 18px; }
          </style>
        </head>
        <body>
          <main id="content">
            <h1>Choose your color</h1>
            <input id="color" type="radio" name="color" aria-label="Sky Blue">
            <label for="color"></label>
            <button id="add" hidden>Add to Cart</button>
            <section id="cart" hidden>
              <h1>Shopping Cart</h1>
              <p id="cart-status">MacBook Air is in your cart.</p>
              <button id="remove">Remove</button>
            </section>
          </main>
          <script>
            const color = document.getElementById("color");
            const add = document.getElementById("add");
            const cart = document.getElementById("cart");
            const remove = document.getElementById("remove");
            color.addEventListener("click", (event) => event.preventDefault());
            document.querySelector('label[for="color"]').addEventListener("click", (event) => {
              event.preventDefault();
              color.checked = true;
              add.hidden = false;
            });
            add.addEventListener("click", () => {
              add.hidden = true;
              cart.hidden = false;
            });
            remove.addEventListener("click", () => {
              remove.hidden = true;
              document.getElementById("cart-status").textContent = "Your cart is empty.";
            });
          </script>
        </body>
        </html>
        """
    ]

    private func assertBrowserMigration(
        source: String,
        fixtureName: String,
        importedTitle: String
    ) throws {
        let app = launchApp(
            onboardingStep: "importData",
            browserImportFixture: fixtureName
        )

        let sourceButton = app.radioButtons[source]
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 10))
        sourceButton.click()

        let importButton = app.buttons["Import from \(source)…"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()

        let importStep = element("initial-onboarding-importData", in: app)
        let importFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: importStep
        )
        XCTAssertEqual(XCTWaiter.wait(for: [importFinished], timeout: 5), .completed)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(
            waitForState(in: app, containing: "Imported from \(source)", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: importedTitle, timeout: 5),
            currentState(in: app)
        )
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertEqualFrame(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func submitCommandPaletteText(_ text: String, in app: XCUIApplication) {
        let field = element("command-palette-field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    private func submitAskText(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    private func waitForState(in app: XCUIApplication, containing expectedText: String, timeout: TimeInterval = 5) -> Bool {
        guard element("ui-testing-state", in: app).waitForExistence(timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentState(in: app).contains(expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTContext.runActivity(named: "Current UI testing state") { activity in
            let attachment = XCTAttachment(string: currentState(in: app))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return false
    }

    private func currentState(in app: XCUIApplication) -> String {
        let stateElement = element("ui-testing-state", in: app)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    private func waitForAskState(in app: XCUIApplication, containing expectedText: String, timeout: TimeInterval = 5) -> Bool {
        guard element("agent-ui-testing-state", in: app).waitForExistence(timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if askState(in: app).contains(expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTContext.runActivity(named: "Current Eli UI testing state") { activity in
            let attachment = XCTAttachment(string: askState(in: app))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return false
    }

    private func askState(in app: XCUIApplication) -> String {
        let stateElement = element("agent-ui-testing-state", in: app)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    private func pasteText(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
    }
}

@MainActor
final class CandoaEliLiveUITests: XCTestCase {
    private let liveE2EMarkerPath = "/tmp/candoa-live-e2e-enabled"

    override func setUpWithError() throws {
        continueAfterFailure = false

        guard FileManager.default.fileExists(atPath: liveE2EMarkerPath) else {
            throw XCTSkip("Run Scripts/e2e-ask-test.sh to enable live Eli website smoke tests.")
        }
    }

    func testAskReadsLiveGoogleAmazonAndEbayPages() throws {
        let app = launchAskApp()
        let sites = [
            LiveSite(name: "Google", url: "https://www.google.com", hostNeedle: "google."),
            LiveSite(name: "Amazon", url: "https://www.amazon.com", hostNeedle: "amazon."),
            LiveSite(name: "eBay", url: "https://www.ebay.com", hostNeedle: "ebay.")
        ]

        for site in sites {
            openURL(site.url, hostNeedle: site.hostNeedle, in: app)
            openAskSidebar(in: app)
            submitAskText("what is this page about", in: app)

            XCTAssertTrue(
                waitForAskAnswer(in: app, timeout: 20) { answer in
                    !answer.localizedCaseInsensitiveContains("I can't see what you're currently looking at")
                        && !answer.localizedCaseInsensitiveContains("I can't answer that yet")
                        && !answer.localizedCaseInsensitiveContains("no page context is attached")
                },
                "\(site.name): \(askState(in: app))"
            )

            resetAskConversation(in: app)
        }
    }

    func testAskChecksLiveEbaySignInControlWithoutHallucinating() throws {
        let app = launchAskApp()

        openURL("https://www.ebay.com", hostNeedle: "ebay.", in: app)
        openAskSidebar(in: app)
        submitAskText("where is the sign in button", in: app)

        XCTAssertTrue(
            waitForAskAnswer(in: app, timeout: 20) { answer in
                let normalizedAnswer = answer.lowercased()
                return normalizedAnswer.contains("i see")
                    || normalizedAnswer.contains("do not see")
                    || normalizedAnswer.contains("visible part of the page")
            },
            askState(in: app)
        )
    }

    func testAskAnswersLiveEbaySectionQuestionsWithoutControlScannerLeak() throws {
        let app = launchAskApp()

        openURL("https://www.ebay.com", hostNeedle: "ebay.", in: app)
        openAskSidebar(in: app)
        submitAskText("where is ebay live", in: app)

        XCTAssertTrue(
            waitForAskAnswer(in: app, timeout: 20) { answer in
                let normalizedAnswer = answer.lowercased()
                return !normalizedAnswer.contains("shop now")
                    && !normalizedAnswer.contains("visible control")
                    && !normalizedAnswer.contains("a:")
                    && !normalizedAnswer.contains("no page context is attached")
                    && !normalizedAnswer.contains("i can't answer that yet")
            },
            askState(in: app)
        )
    }

    private struct LiveSite {
        let name: String
        let url: String
        let hostNeedle: String
    }

    private func launchAskApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CANDOA_UI_TESTING"] = "1"
        app.launchEnvironment["CANDOA_UI_TESTING_STORE_ID"] = "TestingBot"
        app.launchEnvironment["CANDOA_UI_TESTING_FIXTURE"] = "ask"
        app.launch()
        return app
    }

    private func openURL(_ url: String, hostNeedle: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=true", timeout: 5), currentState(in: app))
        submitCommandPaletteText(url, in: app)
        XCTAssertTrue(waitForState(in: app, containing: hostNeedle, timeout: 30), currentState(in: app))
    }

    private func openAskSidebar(in app: XCUIApplication) {
        if !element("agent-sidebar", in: app).exists {
            app.typeKey("e", modifierFlags: .command)
        }
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))
        XCTAssertTrue(element("agent-ui-testing-state", in: app).waitForExistence(timeout: 8), currentState(in: app))
    }

    private func resetAskConversation(in app: XCUIApplication) {
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(waitForState(in: app, containing: "sidebar=true", timeout: 5), currentState(in: app))
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func submitCommandPaletteText(_ text: String, in app: XCUIApplication) {
        let field = element("command-palette-field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    private func submitAskText(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    private func waitForState(in app: XCUIApplication, containing expectedText: String, timeout: TimeInterval = 5) -> Bool {
        guard element("ui-testing-state", in: app).waitForExistence(timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentState(in: app).localizedCaseInsensitiveContains(expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTContext.runActivity(named: "Current UI testing state") { activity in
            let attachment = XCTAttachment(string: currentState(in: app))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return false
    }

    private func currentState(in app: XCUIApplication) -> String {
        let stateElement = element("ui-testing-state", in: app)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    private func waitForAskAnswer(
        in app: XCUIApplication,
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) -> Bool {
        guard element("agent-ui-testing-state", in: app).waitForExistence(timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let answer = lastAssistantAnswer(in: app)
            if !answer.isEmpty, predicate(answer) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTContext.runActivity(named: "Current Eli UI testing state") { activity in
            let attachment = XCTAttachment(string: askState(in: app))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return false
    }

    private func lastAssistantAnswer(in app: XCUIApplication) -> String {
        let state = askState(in: app)
        guard let startRange = state.range(of: "lastAssistant=[") else { return "" }
        let answerStart = startRange.upperBound
        guard let endRange = state[answerStart...].range(of: "];messages=") else {
            return String(state[answerStart...])
        }
        return String(state[answerStart..<endRange.lowerBound])
    }

    private func askState(in app: XCUIApplication) -> String {
        let stateElement = element("agent-ui-testing-state", in: app)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    private func pasteText(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
    }
}
