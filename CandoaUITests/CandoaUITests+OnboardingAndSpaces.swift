import AppKit
import XCTest

extension CandoaUITests {
    func testCreateSpaceButtonAdvancesToAccountChoice() throws {
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
        // The address-bar placement question sits between the Space and the
        // account gate; its default keeps the sidebar pill.
        XCTAssertTrue(
            element("initial-onboarding-addressBar", in: app).waitForExistence(timeout: 5),
            "Creating the initial Space should ask where the address lives."
        )
        XCTAssertTrue(app.staticTexts["3 of 4"].exists)
        app.buttons["Continue"].click()

        XCTAssertTrue(
            element("account-onboarding", in: app).waitForExistence(timeout: 5),
            "The address-bar step should offer Sign in with Apple before starting the tour."
        )
        XCTAssertTrue(app.staticTexts["4 of 4"].exists)
        XCTAssertFalse(element("initial-tour-command-bar", in: app).exists)
        XCTAssertTrue(waitForState(in: app, containing: "addressBar=sidebar"), currentState(in: app))
    }

    func testAddressBarOnboardingChoosingTopMovesTheAddressAboveThePage() throws {
        let app = launchApp(onboardingStep: "addressBar")
        XCTAssertTrue(element("initial-onboarding-addressBar", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3 of 4"].exists)

        element("onboarding-address-bar-top", in: app).click()
        app.buttons["Continue"].click()

        XCTAssertTrue(waitForState(in: app, containing: "addressBar=top"), currentState(in: app))
        // Back from the account gate returns to the question with the choice kept.
        XCTAssertTrue(element("account-onboarding", in: app).waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(element("initial-onboarding-addressBar", in: app).waitForExistence(timeout: 5))
        let topCard = element("onboarding-address-bar-top", in: app)
        XCTAssertTrue(topCard.waitForExistence(timeout: 5))
        XCTAssertTrue(topCard.isSelected, "The previously chosen placement should stay selected")
    }

    func testTopAddressBarPlacementReplacesTheSidebarPill() throws {
        let app = launchApp(
            fixture: "split-view",
            extraLaunchArguments: ["-Candoa.Settings.ZenOption.AddressBarPlacement", "top"]
        )
        openFixtureTab(path: "one", in: app)

        let topAddress = element("top-address-button", in: app)
        XCTAssertTrue(topAddress.waitForExistence(timeout: 10), currentState(in: app))
        XCTAssertFalse(element("sidebar-address-button", in: app).exists)
        XCTAssertTrue(element("top-site-info-button", in: app).exists)
        XCTAssertTrue(waitForState(in: app, containing: "addressBar=top"), currentState(in: app))

        // The whole toolbar moves, not just the address: navigation rides the
        // strip and Eli gets the trailing slot, the way Dia lays its bar out.
        XCTAssertTrue(element("navigation-back-button", in: app).exists, currentState(in: app))
        XCTAssertTrue(element("navigation-reload-button", in: app).exists, currentState(in: app))
        XCTAssertTrue(element("top-chat-button", in: app).exists, currentState(in: app))
        // The toggle rides the strip too, and stays there with the sidebar
        // open — Dia keeps it in one place rather than moving it into the
        // sidebar it just opened.
        XCTAssertTrue(element("top-sidebar-toggle-button", in: app).exists, currentState(in: app))
        XCTAssertFalse(element("sidebar-toggle-button", in: app).exists, currentState(in: app))
        // Exactly one copy of each: the sidebar header gave its cluster up.
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "navigation-back-button").count, 1)

        // The strip's address is the same command bar the sidebar pill opens.
        topAddress.click()
        XCTAssertTrue(waitForState(in: app, containing: "palette=true"), currentState(in: app))
    }

    func testDefaultAddressBarPlacementKeepsTheSidebarPillOnly() throws {
        let app = launchApp(fixture: "split-view")
        openFixtureTab(path: "one", in: app)

        XCTAssertTrue(element("sidebar-address-button", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("top-address-button", in: app).exists)
        XCTAssertFalse(element("top-chat-button", in: app).exists)
        XCTAssertFalse(element("top-sidebar-toggle-button", in: app).exists)
        // Navigation and the toggle stay in the sidebar header here.
        XCTAssertTrue(element("navigation-back-button", in: app).exists, currentState(in: app))
        XCTAssertTrue(element("sidebar-toggle-button", in: app).exists, currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "addressBar=sidebar"), currentState(in: app))
    }

    func testFirstRunSpaceSetupSeedsStarterFavorites() throws {
        let app = launchApp(onboardingStep: "space")
        let createSpaceButton = app.buttons["Create Space"]
        XCTAssertTrue(createSpaceButton.waitForExistence(timeout: 10))

        createSpaceButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

        // The onboarding surface's own identifier cascades over plain
        // descendants, so the step's buttons are addressed by title.
        let addressBarContinue = app.buttons["Continue"]
        XCTAssertTrue(addressBarContinue.waitForExistence(timeout: 10))
        addressBarContinue.click()

        let notNowButton = app.buttons["Not Now"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 10))
        notNowButton.click()

        XCTAssertTrue(
            waitForState(
                in: app,
                containing: "favorites=YouTube|Wikipedia|Gmail|Google Maps|GitHub",
                timeout: 10
            ),
            currentState(in: app)
        )
        let starterTile = element("favorite-tile-youtube", in: app)
        XCTAssertTrue(starterTile.waitForExistence(timeout: 5), currentState(in: app))
    }

    func testCloudKitRestoreDuringWelcomeShowsWelcomeBackInsteadOfSetup() throws {
        let app = launchApp(onboardingStep: "welcome", remoteRestoreFixture: true)
        XCTAssertTrue(element("initial-onboarding-welcome", in: app).waitForExistence(timeout: 10))

        postRemoteRestore()

        let restoredStep = element("initial-onboarding-restoredWorkspace", in: app)
        XCTAssertTrue(
            restoredStep.waitForExistence(timeout: 10),
            "A CloudKit restore landing mid-onboarding should swap the wizard for the welcome-back card"
        )
        XCTAssertFalse(element("initial-onboarding-welcome", in: app).exists)
        XCTAssertFalse(element("initial-onboarding-space", in: app).exists)

        app.buttons["Start Browsing"].click()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: restoredStep
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(
            waitForState(in: app, containing: "onboarding=none", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "space=Synced", timeout: 5),
            "Start Browsing should land in the restored workspace: \(currentState(in: app))"
        )
        // The active tab retitles itself once its web view starts loading,
        // so the background tab is the one that proves the synced tabs came
        // through intact.
        XCTAssertTrue(
            waitForState(in: app, containing: "Synced Planner", timeout: 5),
            currentState(in: app)
        )
        XCTAssertFalse(
            element("initial-tour-command-bar", in: app).exists,
            "A returning user should not be walked through the new-user tour"
        )
    }

    func testCloudKitRestoreDuringSpaceSetupSkipsCreatingASpace() throws {
        let app = launchApp(onboardingStep: "space", remoteRestoreFixture: true)
        XCTAssertTrue(element("initial-onboarding-space", in: app).waitForExistence(timeout: 10))

        postRemoteRestore()

        let restoredStep = element("initial-onboarding-restoredWorkspace", in: app)
        XCTAssertTrue(
            restoredStep.waitForExistence(timeout: 10),
            "The space-setup step should give way to the welcome-back card once iCloud restores existing Spaces"
        )
        XCTAssertFalse(element("initial-onboarding-space", in: app).exists)
        XCTAssertFalse(element("account-onboarding", in: app).exists)

        app.buttons["Start Browsing"].click()
        XCTAssertTrue(
            waitForState(in: app, containing: "space=Synced", timeout: 5),
            currentState(in: app)
        )
    }

    func testSpaceThemePaletteSavesRestoresAndSurvivesRelaunch() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openSpaceEditor(forSpaceNamed: "TestingBot", in: app)

        let editThemeButton = app.buttons["Edit Theme"]
        XCTAssertTrue(editThemeButton.waitForExistence(timeout: 10))
        editThemeButton.click()

        // The fixture Space already uses the primary Blue; each click adds
        // the next palette color as an auxiliary.
        let addColorButton = app.buttons["Add Color"]
        XCTAssertTrue(addColorButton.waitForExistence(timeout: 5))
        addColorButton.click()
        addColorButton.click()
        XCTAssertFalse(addColorButton.isEnabled, "Two auxiliaries should fill the palette")
        app.typeKey(.escape, modifierFlags: [])

        let saveButton = app.buttons["Save Changes"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

        let expectedPalette = "spaceTheme=#007AFF|#74E0AA|#E0A84F"
        XCTAssertTrue(waitForState(in: app, containing: expectedPalette), currentState(in: app))

        app.terminate()

        // Relaunching against the persisted workspace proves the palette
        // round-trips through Core Data, not just the in-memory store.
        let relaunchedApp = launchApp(fixture: "persisted-workspace", preservesStore: true)
        XCTAssertTrue(relaunchedApp.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(
            waitForState(in: relaunchedApp, containing: expectedPalette, timeout: 10),
            currentState(in: relaunchedApp)
        )

        // Reopening the editor restores the saved palette's color controls:
        // with both auxiliary slots occupied, Add Color is disabled.
        openSpaceEditor(forSpaceNamed: "TestingBot", in: relaunchedApp)

        let editThemeAgain = relaunchedApp.buttons["Edit Theme"]
        XCTAssertTrue(editThemeAgain.waitForExistence(timeout: 5))
        editThemeAgain.click()

        let addColorAgain = relaunchedApp.buttons["Add Color"]
        XCTAssertTrue(addColorAgain.waitForExistence(timeout: 5))
        XCTAssertFalse(addColorAgain.isEnabled, "A restored three-color palette should leave no room to add colors")
        XCTAssertTrue(relaunchedApp.buttons["Remove Color"].isEnabled)

        // Capture the blended browsing chrome in both explicit appearances
        // for rendered-app verification.
        relaunchedApp.buttons["Dark"].click()
        relaunchedApp.typeKey(.escape, modifierFlags: [])
        let saveAgain = relaunchedApp.buttons["Save Changes"]
        XCTAssertTrue(saveAgain.waitForExistence(timeout: 5))
        saveAgain
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()
        XCTAssertTrue(waitForState(in: relaunchedApp, containing: expectedPalette), currentState(in: relaunchedApp))
        attachScreenshot(of: relaunchedApp, named: "Blended three-color theme, dark appearance")

        openSpaceEditor(forSpaceNamed: "TestingBot", in: relaunchedApp)
        let editThemeOnceMore = relaunchedApp.buttons["Edit Theme"]
        XCTAssertTrue(editThemeOnceMore.waitForExistence(timeout: 5))
        editThemeOnceMore.click()
        relaunchedApp.buttons["Light"].click()
        relaunchedApp.typeKey(.escape, modifierFlags: [])
        let saveLight = relaunchedApp.buttons["Save Changes"]
        XCTAssertTrue(saveLight.waitForExistence(timeout: 5))
        saveLight
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()
        XCTAssertTrue(waitForState(in: relaunchedApp, containing: expectedPalette), currentState(in: relaunchedApp))
        attachScreenshot(of: relaunchedApp, named: "Blended three-color theme, light appearance")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSpaceThemeHarmonyToggleSnapsAuxiliaryColors() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openSpaceEditor(forSpaceNamed: "TestingBot", in: app)

        let editThemeButton = app.buttons["Edit Theme"]
        XCTAssertTrue(editThemeButton.waitForExistence(timeout: 10))
        editThemeButton.click()

        // One auxiliary color: deterministically the palette color after
        // the fixture's primary Blue.
        let addColorButton = app.buttons["Add Color"]
        XCTAssertTrue(addColorButton.waitForExistence(timeout: 5))
        addColorButton.click()

        // Harmony starts enabled; the first click turns it off (colors stay
        // put), the second re-enables it and snaps the auxiliary hue into a
        // triad around the primary.
        let harmonyButton = app.buttons["Color Harmony"]
        harmonyButton.click()
        harmonyButton.click()
        app.typeKey(.escape, modifierFlags: [])

        let saveButton = app.buttons["Save Changes"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

        XCTAssertTrue(waitForState(in: app, containing: "spaceTheme=#007AFF|#"), currentState(in: app))

        let state = currentState(in: app)
        let palette = state
            .split(separator: ";")
            .first { $0.hasPrefix("spaceTheme=") }
            .map { $0.dropFirst("spaceTheme=".count).split(separator: "|").map(String.init) } ?? []
        XCTAssertEqual(palette.count, 2, state)
        XCTAssertEqual(palette.first, "#007AFF", "Harmony must not move the primary color")
        XCTAssertNotEqual(
            palette.last,
            "#74E0AA",
            "Harmony should snap the auxiliary color into a hue derived from the primary"
        )
    }

    func testNewlyCreatedSpaceButtonsSwitchSpaces() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        createSpace(named: "Personal", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "space=Personal"), currentState(in: app))

        createSpace(named: "Work", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "space=Work"), currentState(in: app))

        // Clicking a newly created Space's switcher button must activate it.
        app.buttons["Personal"].firstMatch.click()
        XCTAssertTrue(waitForState(in: app, containing: "space=Personal"), currentState(in: app))

        app.buttons["TestingBot"].firstMatch.click()
        XCTAssertTrue(waitForState(in: app, containing: "space=TestingBot"), currentState(in: app))

        app.buttons["Work"].firstMatch.click()
        XCTAssertTrue(waitForState(in: app, containing: "space=Work"), currentState(in: app))

        // A Space click while the edit composer is open must still act:
        // it cancels editing and switches instead of being dropped.
        openSpaceEditor(forSpaceNamed: "Work", in: app)
        XCTAssertTrue(app.buttons["Save Changes"].waitForExistence(timeout: 5))

        app.buttons["Personal"].firstMatch.click()
        XCTAssertTrue(waitForState(in: app, containing: "space=Personal"), currentState(in: app))

        let composerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["Save Changes"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [composerDismissed], timeout: 5), .completed)
    }

    func testEditSpaceOpensWithoutFocusingTheNameField() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        createSpace(named: "Work", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "space=Work"), currentState(in: app))

        openSpaceEditor(forSpaceNamed: "Work", in: app)

        let nameField = element("space-name-field", in: app)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))

        // The old auto-focus landed one runloop turn after onAppear, so give
        // it a moment to (wrongly) arrive before asserting neutrality.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(nameField.value as? String, "Work")
        XCTAssertNotEqual(
            nameField.value(forKey: "hasKeyboardFocus") as? Bool,
            true,
            "Edit Space must open without focusing the Space name field"
        )

        // Clicking the field must still focus it and allow normal editing.
        nameField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Refit")
        XCTAssertEqual(nameField.value as? String, "Refit")
    }

    private func createSpace(named name: String, in app: XCUIApplication, dismissesPalette: Bool = true) {
        let existingSpaceButton = app.buttons["TestingBot"].firstMatch
        XCTAssertTrue(existingSpaceButton.waitForExistence(timeout: 10))
        existingSpaceButton.rightClick()

        let newSpaceItem = app.menuItems["New Space"]
        XCTAssertTrue(newSpaceItem.waitForExistence(timeout: 5))
        newSpaceItem.click()

        let nameField = element("space-name-field", in: app)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText(name)

        let createButton = app.buttons["Create Space"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

        // Creating a Space opens the new-tab palette; dismiss it so the
        // switcher is interactive again.
        guard dismissesPalette else { return }
        if waitForState(in: app, containing: "newTabPalette=true", timeout: 3) {
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitForState(in: app, containing: "newTabPalette=false"), currentState(in: app))
        }
    }

    private func openSpaceEditor(forSpaceNamed name: String, in app: XCUIApplication) {
        // Reclaim foreground focus and retry the right-click: context menus
        // are flaky under XCUITest immediately after animated UI changes.
        app.activate()
        let spaceButton = app.buttons[name].firstMatch
        XCTAssertTrue(spaceButton.waitForExistence(timeout: 10))

        let editSpaceItem = app.menuItems["Edit Space..."]
        for _ in 0..<3 {
            spaceButton.rightClick()
            if editSpaceItem.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(editSpaceItem.waitForExistence(timeout: 2), currentState(in: app))
        editSpaceItem.click()
    }
}
