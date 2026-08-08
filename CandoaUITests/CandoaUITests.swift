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

    func testSplitViewFocusFollowsPaneAndChipClicks() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=two"), currentState(in: app))

        // The sidebar pill focuses one pane per chip, not the whole group.
        let chipOne = element("split-chip-one", in: app)
        XCTAssertTrue(chipOne.waitForExistence(timeout: 5), currentState(in: app))
        chipOne.click()
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=one"), currentState(in: app))

        // Clicking inside a pane's web content commits that tab as active.
        let leadingPane = element("split-pane-0", in: app)
        XCTAssertTrue(leadingPane.waitForExistence(timeout: 5), currentState(in: app))
        leadingPane.click()
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=two"), currentState(in: app))

        let trailingPane = element("split-pane-1", in: app)
        XCTAssertTrue(trailingPane.waitForExistence(timeout: 5), currentState(in: app))
        trailingPane.click()
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=one"), currentState(in: app))
    }

    /// Two real bugs shipped past the whole suite because chrome existed in
    /// the view hierarchy but composited *behind* the AppKit-hosted
    /// WKWebViews (the pane-reorder ghost and target ring, PR #84): XCUITest
    /// asserts state and AX presence, not what's on screen. This samples the
    /// window's real pixels over a solid-green fixture page: the split focus
    /// ring must visibly appear on the focused pane's edge and vanish when
    /// focus moves to the other pane.
    func testSplitFocusRingCompositesAboveWebContent() throws {
        let app = launchApp(fixture: "split-view-pixels")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=two"), currentState(in: app))

        let leadingPane = element("split-pane-0", in: app)
        XCTAssertTrue(leadingPane.waitForExistence(timeout: 5), currentState(in: app))
        let paneFrame = leadingPane.frame

        // The ring is a 1pt strokeBorder on the visible card's edge; a short
        // horizontal run across the trailing edge at mid-height (clear of the
        // rounded corners and of the hover-revealed pill) hedges sub-point
        // frame alignment. The pane center must show the fixture page's
        // solid green — proving the web content rendered and the capture
        // isn't blank, so an "unchanged edge" can only mean a layering bug.
        let edgePoints = (0..<4).map { offset in
            CGPoint(x: paneFrame.maxX - 0.5 - CGFloat(offset), y: paneFrame.midY)
        }
        let centerPoint = CGPoint(x: paneFrame.midX, y: paneFrame.midY)

        // Let the ring's fade-in and the freshly split layout settle.
        Thread.sleep(forTimeInterval: 0.4)
        let focusedColors = try windowPixelColors(at: edgePoints + [centerPoint], in: app)
        XCTAssertTrue(
            isSolidGreen(focusedColors[edgePoints.count]),
            "Pane center should show the green fixture page, got \(focusedColors[edgePoints.count])"
        )

        // Move focus to the trailing pane and resample the same points.
        let trailingPane = element("split-pane-1", in: app)
        XCTAssertTrue(trailingPane.waitForExistence(timeout: 5), currentState(in: app))
        trailingPane.click()
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=one"), currentState(in: app))
        Thread.sleep(forTimeInterval: 0.4)

        let unfocusedColors = try windowPixelColors(at: edgePoints + [centerPoint], in: app)
        XCTAssertTrue(
            isSolidGreen(unfocusedColors[edgePoints.count]),
            "Pane center should show the green fixture page, got \(unfocusedColors[edgePoints.count])"
        )

        let edgeDelta = zip(focusedColors, unfocusedColors)
            .prefix(edgePoints.count)
            .map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }
            .max() ?? 0
        XCTAssertGreaterThan(
            edgeDelta,
            24,
            "Focus ring never composited over the pane edge: "
                + "focused=\(focusedColors) unfocused=\(unfocusedColors)"
        )
    }

    func testSplitPaneGripEdgeDropStacksVertically() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))

        // Dropping a grip-dragged pane on another pane's bottom band stacks
        // the row into a column, with the dragged pane below the target.
        let grip = element("split-pane-grip-0", in: app)
        XCTAssertTrue(grip.waitForExistence(timeout: 5), currentState(in: app))
        let trailingPane = element("split-pane-1", in: app)
        XCTAssertTrue(trailingPane.waitForExistence(timeout: 5), currentState(in: app))
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.2,
            thenDragTo: trailingPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        )
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=vertical"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=one|two"), currentState(in: app))
    }

    func testDraggingSidebarTabOntoBottomEdgeStacksVertically() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        // Releasing over the page's bottom-edge quarter creates a fresh
        // split stacked as a column, the dragged page below the current one.
        let row = element("tab-row-one", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), currentState(in: app))
        let target = app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.93))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: target)

        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=vertical"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
    }

    func testDraggingSidebarTabOntoPageEdgeCreatesSplit() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        // Dragging a sidebar row starts the native dragging session (whose
        // drag image is the ghost page card); releasing over the page's
        // right-edge quarter drops into the trailing split zone.
        let row = element("tab-row-one", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), currentState(in: app))
        let target = app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: target)

        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))
    }

    func testSplitViewPaneResizePersistsAndResets() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitRatios=0.50|0.50"), currentState(in: app))

        let divider = element("split-divider-0", in: app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5), currentState(in: app))
        let dragStart = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.2, thenDragTo: dragStart.withOffset(CGVector(dx: 180, dy: 0)))

        let deadline = Date().addingTimeInterval(5)
        var draggedRatios = stateValue("splitRatios", in: app)
        while Date() < deadline, draggedRatios == nil || draggedRatios == "0.50|0.50" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            draggedRatios = stateValue("splitRatios", in: app)
        }
        let resizedRatios = try XCTUnwrap(draggedRatios, currentState(in: app))
        XCTAssertNotEqual(resizedRatios, "0.50|0.50", currentState(in: app))

        // Let the 300ms autosave debounce flush before relaunching.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.terminate()

        let relaunchedApp = launchApp(fixture: "persisted-workspace", preservesStore: true)
        XCTAssertTrue(relaunchedApp.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(
            waitForState(in: relaunchedApp, containing: "splitDisplayed=true", timeout: 10),
            currentState(in: relaunchedApp)
        )
        XCTAssertTrue(
            waitForState(in: relaunchedApp, containing: "splitRatios=\(resizedRatios)", timeout: 10),
            currentState(in: relaunchedApp)
        )

        // Double-clicking a divider resets the split to equal widths.
        let relaunchedDivider = element("split-divider-0", in: relaunchedApp)
        XCTAssertTrue(relaunchedDivider.waitForExistence(timeout: 5), currentState(in: relaunchedApp))
        relaunchedDivider.doubleClick()
        XCTAssertTrue(
            waitForState(in: relaunchedApp, containing: "splitRatios=0.50|0.50"),
            currentState(in: relaunchedApp)
        )
    }

    func testSplitViewSurvivesNonMemberTabAndSpaceSwitches() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))

        // Switching to a non-member tab suspends the split instead of
        // destroying it; the group stays in the sidebar.
        openFixtureTab(path: "three", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "split=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))

        // Focusing a member from the sidebar pill brings the panes back.
        let chipOne = element("split-chip-one", in: app)
        XCTAssertTrue(chipOne.waitForExistence(timeout: 5), currentState(in: app))
        chipOne.click()
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=one"), currentState(in: app))
        app.terminate()

        // Space switches suspend and revive the Space's split group.
        let spacesApp = launchApp(fixture: "split-view-spaces")
        XCTAssertTrue(spacesApp.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitForState(in: spacesApp, containing: "space=SplitOne"), currentState(in: spacesApp))

        spacesApp.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(
            waitForState(in: spacesApp, containing: "splitTabs=a-one|a-two"),
            currentState(in: spacesApp)
        )
        XCTAssertTrue(
            waitForState(in: spacesApp, containing: "splitDisplayed=true"),
            currentState(in: spacesApp)
        )

        spacesApp.typeKey(.rightArrow, modifierFlags: [.option, .command])
        XCTAssertTrue(waitForState(in: spacesApp, containing: "space=SplitTwo"), currentState(in: spacesApp))
        XCTAssertTrue(waitForState(in: spacesApp, containing: "split=false"), currentState(in: spacesApp))

        spacesApp.typeKey(.leftArrow, modifierFlags: [.option, .command])
        XCTAssertTrue(waitForState(in: spacesApp, containing: "space=SplitOne"), currentState(in: spacesApp))
        XCTAssertTrue(
            waitForState(in: spacesApp, containing: "splitDisplayed=true"),
            currentState(in: spacesApp)
        )
        XCTAssertTrue(
            waitForState(in: spacesApp, containing: "splitTabs=a-one|a-two"),
            currentState(in: spacesApp)
        )
    }

    func testSplitViewLayoutsAndPaneReorder() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))

        // Dragging a pane's grab handle onto the other pane reorders them.
        let grip = element("split-pane-grip-0", in: app)
        XCTAssertTrue(grip.waitForExistence(timeout: 5), currentState(in: app))
        let trailingPane = element("split-pane-1", in: app)
        XCTAssertTrue(trailingPane.waitForExistence(timeout: 5), currentState(in: app))
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.2,
            thenDragTo: trailingPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        )
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=one|two"), currentState(in: app))

        // Dropping the grip on a pane's bottom quarter re-stacks the group
        // into a column with the dragged pane below its target (Zen-style
        // edge drop) instead of swapping the two slots.
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.2,
            thenDragTo: trailingPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        )
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=vertical"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))

        // Zen-style layout shortcuts switch between rows, grid, and columns.
        app.typeKey("v", modifierFlags: [.control, .option])
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=vertical"), currentState(in: app))

        app.typeKey("g", modifierFlags: [.control, .option])
        if !waitForState(in: app, containing: "splitLayout=grid") {
            // Window managers can claim Control-Option-G as a system-wide
            // hotkey (Rectangle's recommended scheme binds it to "Last
            // Third"), consuming the event before the app's local monitor
            // sees it. Only tolerate the miss when such an app is running,
            // and still exercise the grid layout via the menu command.
            XCTAssertFalse(
                runningGlobalHotkeyApps().isEmpty,
                "Control-Option-G did not switch to the grid layout and no known global-hotkey app is running: \(currentState(in: app))"
            )
            let viewMenu = app.menuBarItems["View"]
            XCTAssertTrue(viewMenu.waitForExistence(timeout: 5), currentState(in: app))
            viewMenu.click()
            let gridItem = app.menuItems["Grid Split Layout"]
            XCTAssertTrue(gridItem.waitForExistence(timeout: 3), currentState(in: app))
            gridItem.click()
            XCTAssertTrue(waitForState(in: app, containing: "splitLayout=grid"), currentState(in: app))
        }

        app.typeKey("h", modifierFlags: [.control, .option])
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))

        // The layout is split state: closing the split resets it.
        app.typeKey("-", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "split=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))
    }

    func testSplitPaneCloseButtonClosesTabAndDissolvesSplit() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))

        // The pane pill's close button closes that pane's tab; with one
        // member left the split dissolves.
        let closeButton = element("split-pane-close-1", in: app)
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), currentState(in: app))
        closeButton.click()
        XCTAssertTrue(waitForState(in: app, containing: "split=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "active=two"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "tabs=two"), currentState(in: app))
    }

    func testSplitPaneUnsplitButtonReturnsTabToSidebar() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "one", in: app)
        openFixtureTab(path: "two", in: app)

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))

        // The pane pill's unsplit button takes that pane out of the group
        // without closing its tab: the tab returns to its ordinary sidebar
        // row, and with one member left the split dissolves. The clicked
        // pane's page keeps the surface — unsplitting pane "one" while
        // "two" is focused must show "one", not the surviving partner.
        let unsplitButton = element("split-pane-unsplit-1", in: app)
        XCTAssertTrue(unsplitButton.waitForExistence(timeout: 5), currentState(in: app))
        unsplitButton.click()
        XCTAssertTrue(waitForState(in: app, containing: "split=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "active=one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "tabs=two|one"), currentState(in: app))
        XCTAssertTrue(element("tab-row-one", in: app).waitForExistence(timeout: 5), currentState(in: app))
        XCTAssertTrue(element("tab-row-two", in: app).waitForExistence(timeout: 5), currentState(in: app))
    }

    func testFavoritesStayGlobalAcrossSpaces() throws {
        let app = launchApp(fixture: "split-view-spaces")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitForState(in: app, containing: "space=SplitOne"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "active=a-one", timeout: 10), currentState(in: app))

        // Favorite the active tab from its sidebar row.
        let row = element("tab-row-a-one", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), currentState(in: app))
        row.rightClick()
        let favoriteItem = app.menuItems["Add to Favorites"]
        XCTAssertTrue(favoriteItem.waitForExistence(timeout: 5), currentState(in: app))
        favoriteItem.click()
        XCTAssertTrue(waitForState(in: app, containing: "favorites=a-one"), currentState(in: app))

        // The shared grid stays put when switching Spaces.
        app.typeKey(.rightArrow, modifierFlags: [.option, .command])
        XCTAssertTrue(waitForState(in: app, containing: "space=SplitTwo"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "favorites=a-one"), currentState(in: app))

        // Activating the favorite opens it here — no Space switch.
        let tile = element("favorite-tile-a-one", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 5), currentState(in: app))
        tile.click()
        XCTAssertTrue(waitForState(in: app, containing: "active=a-one", timeout: 10), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "space=SplitTwo"), currentState(in: app))

        // Un-favoriting from here returns the tab to the Space on screen.
        tile.rightClick()
        let unfavoriteItem = app.menuItems["Remove from Favorites"]
        XCTAssertTrue(unfavoriteItem.waitForExistence(timeout: 5), currentState(in: app))
        unfavoriteItem.click()
        XCTAssertTrue(waitForState(in: app, containing: "favorites=;"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "space=SplitTwo"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "active=a-one"), currentState(in: app))
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

        let confirmButton = app.sheets.buttons["Clear"].firstMatch
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
        XCTAssertTrue(app.staticTexts["2 of 3"].exists)
        XCTAssertFalse(element("account-onboarding", in: app).exists)
    }

    func testShowDownloadsCommandTracksDownloadLifecycle() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitForState(in: app, containing: "downloads=none"), currentState(in: app))

        // View > Show Downloads (Option-Command-L) opens the popover.
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(element("downloads-popover", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForState(in: app, containing: "downloadsShown=true", timeout: 5),
            currentState(in: app)
        )

        // An active download surfaces with its progress.
        postDownloadFixture("report.pdf|active|0.42")
        XCTAssertTrue(
            waitForState(in: app, containing: "downloads=report.pdf:active:0.42", timeout: 5),
            currentState(in: app)
        )

        // Cancelling keeps the row, marked cancelled.
        let cancelButton = app.buttons["Cancel Download"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.click()
        XCTAssertTrue(
            waitForState(in: app, containing: "downloads=report.pdf:cancelled", timeout: 5),
            currentState(in: app)
        )

        // Failures stay visible with their reason; completions land too.
        postDownloadFixture("big.iso|failed|Network connection lost")
        XCTAssertTrue(
            waitForState(in: app, containing: "big.iso:failed", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(
            app.staticTexts["Failed — Network connection lost"].waitForExistence(timeout: 5)
        )
        postDownloadFixture("notes.txt|completed")
        XCTAssertTrue(
            waitForState(in: app, containing: "notes.txt:completed", timeout: 5),
            currentState(in: app)
        )

        // Clear empties the visible list (files on disk are untouched —
        // fixture rows have no files, so this asserts the list semantics).
        let clearButton = app.buttons["Clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))
        clearButton.click()
        XCTAssertTrue(
            waitForState(in: app, containing: "downloads=none", timeout: 5),
            currentState(in: app)
        )

        // The same command closes the surface again.
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForState(in: app, containing: "downloadsShown=false", timeout: 5),
            currentState(in: app)
        )
    }

    func testPrivateWindowDownloadsStayIsolated() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        postDownloadFixture("report.pdf|completed")
        XCTAssertTrue(
            waitForState(in: app, containing: "downloads=report.pdf:completed", timeout: 5),
            currentState(in: app)
        )

        // The ordinary window's list must not leak into a private window.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let privateWindow = app.windows["Private Browsing"]
        XCTAssertTrue(privateWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForState(in: privateWindow, containing: "private=true"),
            currentState(in: privateWindow)
        )
        XCTAssertTrue(
            waitForState(in: privateWindow, containing: "downloads=none", timeout: 5),
            currentState(in: privateWindow)
        )
    }

    private func postDownloadFixture(_ spec: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.candoa.uitesting.download-fixture"),
            object: spec,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Exercises the real WKDownload path end to end: a data-URL anchor
    /// with a download attribute becomes an actual WKDownload that must
    /// land in ~/Downloads and surface as completed in the list.
    func testRealDownloadLandsOnDiskAndSurfacesAsCompleted() throws {
        let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        )[0]
        removeE2EDownloadArtifacts(in: downloadsDirectory)
        defer { removeE2EDownloadArtifacts(in: downloadsDirectory) }

        let app = launchApp(fixture: "download-page")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        submitCommandPaletteText("https://fixture.candoa.test/download-page", in: app)
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10))
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(
            waitForState(
                in: app,
                containing: "downloads=candoa-e2e-download.bin:completed",
                timeout: 10
            ),
            currentState(in: app)
        )
        let landedFile = downloadsDirectory.appendingPathComponent("candoa-e2e-download.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: landedFile.path),
            "The downloaded file must land in ~/Downloads"
        )

        // A fresh download surfaces the popover on its own — silent saves
        // read as a dead button.
        XCTAssertTrue(
            waitForState(in: app, containing: "downloadsShown=true", timeout: 5),
            currentState(in: app)
        )
        XCTAssertTrue(element("downloads-popover", in: app).waitForExistence(timeout: 5))
    }

    private func removeE2EDownloadArtifacts(in directory: URL) {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("candoa-e2e-download") } ?? []
        for name in leftovers {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
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
        XCTAssertTrue(
            element("account-onboarding", in: app).waitForExistence(timeout: 5),
            "Creating the initial Space should offer Sign in with Apple before starting the tour."
        )
        XCTAssertTrue(app.staticTexts["3 of 3"].exists)
        XCTAssertFalse(element("initial-tour-command-bar", in: app).exists)
    }

    func testFirstRunSpaceSetupSeedsStarterFavorites() throws {
        let app = launchApp(onboardingStep: "space")
        let createSpaceButton = app.buttons["Create Space"]
        XCTAssertTrue(createSpaceButton.waitForExistence(timeout: 10))

        createSpaceButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

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

    func testAccountOnboardingOffersAppleOrLocalUse() throws {
        let app = launchApp(onboardingStep: "account")
        let accountOnboarding = element("account-onboarding", in: app).firstMatch

        XCTAssertTrue(accountOnboarding.waitForExistence(timeout: 10))
        XCTAssertEqual(accountOnboarding.value as? String, "idle")
        XCTAssertTrue(app.buttons["Continue with Apple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Not Now"].exists)
        // The description Text's identifier is not exposed on every
        // macOS/Xcode combination — CI runners have never surfaced the
        // identified element even though the copy renders. The requirement is
        // the sentence being shown, so accept it via the identifier or via
        // any static text carrying the words, normalizing whitespace because
        // wrapped-text labels can embed layout-dependent line breaks.
        let expectedDescription = "Sign in with Apple to restore your subscription"

        func normalized(_ label: String) -> String {
            label
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        let identified = element("account-onboarding-description", in: app)
        let identifiedShowsDescription = identified.waitForExistence(timeout: 3)
            && normalized(identified.label).contains(expectedDescription)
        if !identifiedShowsDescription {
            let staticTexts = app.staticTexts.allElementsBoundByIndex.prefix(40)
            XCTAssertTrue(
                staticTexts.contains { normalized($0.label).contains(expectedDescription) },
                """
                Account-onboarding description not found by identifier or content.
                staticTexts: \(staticTexts.map { "id='\($0.identifier)' label='\($0.label)'" }
                    .joined(separator: " | "))
                state: \(currentState(in: app))
                """
            )
        }
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "passkey"))
                .count,
            0
        )
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testSyncSettingsExplainICloudWorkspaceOwnership() throws {
        let app = launchApp(cloudKitEntitlement: true)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        let syncButton = app.buttons["Sync"]
        XCTAssertTrue(syncButton.waitForExistence(timeout: 5))
        syncButton.click()

        XCTAssertTrue(app.staticTexts["Workspace recovery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Uses this Mac’s Apple Account"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Candoa subscription sign-in does not control or delete your browser workspace."
            ].exists
        )
    }

    func testEliSettingsDefaultToHostedConnectionWithAutomaticModel() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        XCTAssertTrue(popUpButton(withValue: "Candoa Cloud", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(popUpButton(withValue: "Automatic", in: app).exists)
        XCTAssertTrue(popUpButton(withValue: "Low", in: app).exists)
        XCTAssertFalse(popUpButton(withValue: "OpenAI", in: app).exists)
    }

    func testEliSettingsShowHostedModelCreditCosts() throws {
        let hostedModels = """
        [{"id":"openai/gpt-5.6-sol","provider":"openai","displayName":"GPT-5.6 Sol",\
        "contextWindowTokens":1050000,"maxOutputTokens":128000,\
        "supportedEfforts":["low","medium","high"],"creditCost":5},\
        {"id":"openai/gpt-5.6-luna","provider":"openai","displayName":"GPT-5.6 Luna",\
        "contextWindowTokens":1050000,"maxOutputTokens":128000,\
        "supportedEfforts":["low","medium","high"],"creditCost":1}]
        """
        let app = launchApp(
            extraLaunchArguments: [
                // The pane's initial state reads the real defaults domain, so
                // neutralize any hosted selection made on this Mac.
                "-Candoa.Settings.ZenOption.AskConnection", "candoaCloud",
                "-Candoa.Settings.ZenOption.AskHostedModel", "",
            ],
            extraLaunchEnvironment: ["CANDOA_UI_TESTING_HOSTED_MODELS": hostedModels]
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        // Each hosted option names its server-priced credit cost.
        let picker = popUpButton(withValue: "Automatic", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        XCTAssertTrue(app.menuItems["GPT-5.6 Sol (5 credits)"].waitForExistence(timeout: 5))
        let lunaItem = app.menuItems["GPT-5.6 Luna (1 credit)"]
        XCTAssertTrue(lunaItem.exists)
        lunaItem.click()
        XCTAssertTrue(
            popUpButton(withValue: "GPT-5.6 Luna (1 credit)", in: app).waitForExistence(timeout: 5)
        )
    }

    func testEliSettingsScopeModelsByProviderAndClampReasoning() throws {
        let app = launchApp(extraLaunchArguments: [
            "-Candoa.Settings.ZenOption.AskConnection", "personalKey",
            "-Candoa.Settings.ZenOption.AskDirectModel", "openai/gpt-5.6-luna",
        ])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        XCTAssertTrue(
            popUpButton(withValue: "Personal API key", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(popUpButton(withValue: "OpenAI", in: app).exists)
        XCTAssertTrue(popUpButton(withValue: "GPT-5.6 Luna", in: app).exists)

        // Switching provider rescopes the model picker to that provider.
        popUpButton(withValue: "OpenAI", in: app).click()
        let anthropicItem = app.menuItems["Anthropic"]
        XCTAssertTrue(anthropicItem.waitForExistence(timeout: 5))
        anthropicItem.click()
        XCTAssertTrue(popUpButton(withValue: "Anthropic", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(popUpButton(withValue: "Claude Opus 5", in: app).waitForExistence(timeout: 5))

        // A model that only supports low reasoning collapses the effort picker.
        popUpButton(withValue: "Claude Opus 5", in: app).click()
        let haikuItem = app.menuItems["Claude Haiku 4.5"]
        XCTAssertTrue(haikuItem.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Claude Fable 5"].exists)
        haikuItem.click()
        XCTAssertTrue(popUpButton(withValue: "Claude Haiku 4.5", in: app).waitForExistence(timeout: 5))
        let reasoning = popUpButton(withValue: "Low", in: app)
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
        reasoning.click()
        XCTAssertTrue(app.menuItems["Low"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["High"].exists)
        app.typeKey(.escape, modifierFlags: [])

        // Switching back to the hosted connection swaps in the plan catalog.
        popUpButton(withValue: "Personal API key", in: app).click()
        let hostedItem = app.menuItems["Candoa Cloud"]
        XCTAssertTrue(hostedItem.waitForExistence(timeout: 5))
        hostedItem.click()
        XCTAssertTrue(popUpButton(withValue: "Automatic", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(popUpButton(withValue: "Anthropic", in: app).exists)
    }

    func testEliSettingsListDirectModelsDynamicallyFromProviderAPI() throws {
        let fixtureModels = """
        [{"id":"openai/gpt-6-nova","provider":"openai","displayName":"GPT-6 Nova",\
        "contextWindowTokens":500000,"maxOutputTokens":128000,\
        "supportedEfforts":["low","medium","high"]},\
        {"id":"openai/gpt-6-mini","provider":"openai","displayName":"GPT-6 Mini",\
        "contextWindowTokens":200000,"maxOutputTokens":64000,\
        "supportedEfforts":["low"]}]
        """.replacingOccurrences(of: "\n", with: "")
        let app = launchApp(
            extraLaunchArguments: [
                "-Candoa.Settings.ZenOption.AskConnection", "personalKey",
            ],
            extraLaunchEnvironment: [
                "CANDOA_UI_TESTING_DIRECT_MODELS": fixtureModels,
            ]
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        // The dynamically listed models replace the curated picker contents.
        XCTAssertTrue(
            app.staticTexts["Current OpenAI models available to your key."]
                .waitForExistence(timeout: 5)
        )
        let modelPicker = popUpButton(withValue: "GPT-5.6 Luna", in: app)
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
        modelPicker.click()
        let novaItem = app.menuItems["GPT-6 Nova"]
        XCTAssertTrue(novaItem.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["GPT-6 Mini"].exists)
        novaItem.click()
        XCTAssertTrue(popUpButton(withValue: "GPT-6 Nova", in: app).waitForExistence(timeout: 5))

        // Reasoning follows the listed model's declared support.
        let reasoning = popUpButton(withValue: "Low", in: app)
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
        reasoning.click()
        XCTAssertTrue(app.menuItems["High"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        popUpButton(withValue: "GPT-6 Nova", in: app).click()
        let miniItem = app.menuItems["GPT-6 Mini"]
        XCTAssertTrue(miniItem.waitForExistence(timeout: 5))
        miniItem.click()
        XCTAssertTrue(popUpButton(withValue: "GPT-6 Mini", in: app).waitForExistence(timeout: 5))
        let clampedReasoning = popUpButton(withValue: "Low", in: app)
        XCTAssertTrue(clampedReasoning.waitForExistence(timeout: 5))
        clampedReasoning.click()
        XCTAssertTrue(app.menuItems["Low"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["High"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    private func openEliSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let eliButton = app.buttons["Eli"].firstMatch
        XCTAssertTrue(eliButton.waitForExistence(timeout: 5))
        eliButton.click()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 5))
    }

    private func popUpButton(withValue value: String, in app: XCUIApplication) -> XCUIElement {
        app.popUpButtons.matching(
            NSPredicate(format: "value == %@", value)
        ).firstMatch
    }

    func testNotNowCompletesAccountSetup() throws {
        let app = launchApp(onboardingStep: "account")
        let accountOnboarding = element("account-onboarding", in: app).firstMatch
        XCTAssertTrue(accountOnboarding.waitForExistence(timeout: 10))

        let continueButton = app.buttons["Not Now"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.click()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: accountOnboarding
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    func testSigningInWithAppleCompletesAccountSetup() throws {
        let app = launchApp(onboardingStep: "account", appleSuccess: true)
        let accountOnboarding = element("account-onboarding", in: app).firstMatch
        XCTAssertTrue(accountOnboarding.waitForExistence(timeout: 10))

        app.buttons["Continue with Apple"].click()

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
        let reloadFromOriginItem = app.menuItems["Reload Page From Origin"]
        XCTAssertTrue(stopItem.waitForExistence(timeout: 3))
        XCTAssertTrue(reloadItem.exists)
        XCTAssertTrue(reloadFromOriginItem.exists)

        // With an idle page the reload commands are enabled and Stop is not.
        XCTAssertFalse(stopItem.isEnabled)
        XCTAssertTrue(reloadItem.isEnabled)
        XCTAssertTrue(reloadFromOriginItem.isEnabled)

        // Reload From Origin performs a real reload that settles back on the
        // same page with the tab intact.
        reloadFromOriginItem.click()
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://example.com/", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(waitForState(in: app, containing: "loading=false", timeout: 10), currentState(in: app))
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

    func testEliUserMessageBubbleUsesAccentPrimaryColor() throws {
        try assertEliUserMessageBubbleTracksAccent(appearanceName: "system")
        try assertEliUserMessageBubbleTracksAccent(appearanceName: "light", forcesLightAppearance: true)
    }

    private func assertEliUserMessageBubbleTracksAccent(
        appearanceName: String,
        forcesLightAppearance: Bool = false
    ) throws {
        let app = launchApp(
            fixture: "ask",
            checkoutFailure: true,
            appleSuccess: true,
            forcesLightAppearance: forcesLightAppearance
        )

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        submitAskText("Accent bubble check", in: app)

        let bubble = element("user-message-bubble", in: app)
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), askState(in: app))

        let windowAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        windowAttachment.name = "Eli user message bubble (\(appearanceName))"
        windowAttachment.lifetime = .keepAlways
        add(windowAttachment)

        // The bubble is mostly fill with some text glyphs, so the per-channel
        // median over a sampling grid recovers the fill color regardless of
        // where the glyphs land. Compare it against the runner's own dynamic
        // accent so the assertion holds for whatever accent this Mac uses.
        let shot = bubble.screenshot().image
        guard
            let tiff = shot.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return XCTFail("Could not decode the bubble screenshot")
        }

        var reds: [CGFloat] = []
        var greens: [CGFloat] = []
        var blues: [CGFloat] = []
        for row in 1..<20 {
            for column in 1..<20 {
                let x = rep.pixelsWide * column / 20
                let y = rep.pixelsHigh * row / 20
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                reds.append(color.redComponent)
                greens.append(color.greenComponent)
                blues.append(color.blueComponent)
            }
        }

        guard !reds.isEmpty, let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return XCTFail("Could not resolve the sampled or accent colors")
        }

        // Screenshots come back in the display's color space, so exact
        // channel values drift; hue and saturation survive that. Skip the
        // color check entirely for achromatic accents (Graphite) where hue
        // is meaningless.
        guard accent.saturationComponent > 0.2 else {
            throw XCTSkip("Achromatic accent color; hue comparison is meaningless")
        }

        func median(_ values: [CGFloat]) -> CGFloat {
            values.sorted()[values.count / 2]
        }

        let fill = NSColor(srgbRed: median(reds), green: median(greens), blue: median(blues), alpha: 1)
        XCTAssertEqual(
            fill.hueComponent,
            accent.hueComponent,
            accuracy: 0.06,
            "bubble fill hue should track the accent, got \(fill) vs \(accent)"
        )
        XCTAssertGreaterThan(
            fill.saturationComponent,
            0.3,
            "bubble fill should be saturated like the accent, not neutral gray, got \(fill)"
        )
    }

    func testEliProPromptRendersSubscriptionGateAndCheckoutFailure() throws {
        let app = launchApp(
            fixture: "ask",
            checkoutFailure: true,
            appleSuccess: true
        )

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        submitAskText("What is this page about?", in: app)

        let subscriptionGate = element("agent-subscription-gate", in: app)
        XCTAssertTrue(subscriptionGate.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(app.staticTexts["Sign in to use Eli"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Sign in with Apple to restore your Candoa subscription on this Mac."
            ].exists
        )
        XCTAssertFalse(element("agent-feedback-up", in: app).exists)
        XCTAssertFalse(element("agent-copy-text", in: app).exists)

        let signInButton = element("agent-sign-in-button", in: app)
        XCTAssertTrue(signInButton.exists)
        XCTAssertEqual(signInButton.label, "Sign In with Apple")
        XCTAssertFalse(element("agent-subscribe-button", in: app).exists)

        let signedOutAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        signedOutAttachment.name = "Eli signed-out account gate"
        signedOutAttachment.lifetime = .keepAlways
        add(signedOutAttachment)

        signInButton.click()

        let subscribeButton = element("agent-subscribe-button", in: app)
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(app.staticTexts["Eli with Candoa Pro"].exists)
        XCTAssertTrue(subscribeButton.isEnabled)
        XCTAssertEqual(subscribeButton.label, "Subscribe")
        XCTAssertEqual(subscribeButton.value as? String, "idle")
        XCTAssertFalse(element("agent-subscribe-error", in: app).exists)
        subscribeButton.click()
        let subscribeError = element("agent-subscribe-error", in: app)
        XCTAssertTrue(subscribeError.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(
            app.staticTexts["Candoa checkout is temporarily unavailable."].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(subscribeButton.isEnabled)
        XCTAssertEqual(subscribeButton.label, "Subscribe")
        XCTAssertEqual(subscribeButton.value as? String, "idle")

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Eli Pro subscription gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEliCloudFailureRendersSignInGate() throws {
        let app = launchApp(fixture: "ask-cloud-unavailable")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5))
        submitAskText("Summarize this page", in: app)

        let subscriptionGate = element("agent-subscription-gate", in: app)
        XCTAssertTrue(subscriptionGate.waitForExistence(timeout: 5), askState(in: app))
        XCTAssertTrue(app.staticTexts["Sign in to use Eli"].exists)
        XCTAssertTrue(element("agent-sign-in-button", in: app).exists)
        XCTAssertTrue(
            app.staticTexts["Could not connect to the local Candoa Cloud."]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.staticTexts[
                "I couldn’t verify your Candoa subscription. Check the Cloud connection and try again."
            ].exists
        )

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Eli local Cloud sign-in gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEliCloudFailureOffersRetryInSettings() throws {
        let app = launchApp(fixture: "ask-cloud-unavailable")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5))
        submitAskText("Summarize this page", in: app)
        XCTAssertTrue(
            element("agent-subscription-gate", in: app).waitForExistence(timeout: 5),
            askState(in: app)
        )

        openEliSettings(in: app)
        XCTAssertTrue(
            app.staticTexts["Could not connect to the local Candoa Cloud."]
                .waitForExistence(timeout: 5)
        )
        let retryButton = element("account-refresh-retry-button", in: app)
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(retryButton.isEnabled)
        retryButton.click()

        // The fixture keeps Cloud unavailable, so a retry lands back on the
        // same recoverable error instead of losing the session state.
        XCTAssertTrue(
            app.staticTexts["Could not connect to the local Candoa Cloud."]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(retryButton.exists)
    }

    func testEliSettingsShowSubscriptionUsageAndBillingDetails() throws {
        let app = launchApp(fixture: "subscription-usage")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        XCTAssertTrue(app.staticTexts["Candoa Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["4,100 of 6,000 Candoa credits used"].waitForExistence(timeout: 5)
        )
        let usageDetail = element("subscription-usage-detail", in: app)
        XCTAssertTrue(usageDetail.exists)
        let usageDetailText = usageDetail.value as? String ?? usageDetail.label
        XCTAssertTrue(
            usageDetailText.contains("provider-neutral Candoa credits"),
            usageDetailText
        )

        let billingRow = element("subscription-billing-row", in: app)
        XCTAssertTrue(billingRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'Next billing date:' OR value BEGINSWITH 'Next billing date:'")
            ).firstMatch.exists
        )

        // A refresh keeps the honest freshness stamp visible.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'Updated' OR value BEGINSWITH 'Updated'")
            ).firstMatch.exists
        )
        let refreshButton = element("subscription-refresh-button", in: app)
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 5))
        XCTAssertTrue(refreshButton.isEnabled)
        refreshButton.click()
        XCTAssertTrue(
            app.staticTexts["4,100 of 6,000 Candoa credits used"].waitForExistence(timeout: 5)
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Eli subscription usage settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEliSettingsFlagPastDueAndExhaustedSubscription() throws {
        let app = launchApp(fixture: "subscription-attention")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        XCTAssertTrue(
            app.staticTexts["6,000 of 6,000 Candoa credits used"].waitForExistence(timeout: 5)
        )
        let usageDetail = element("subscription-usage-detail", in: app)
        XCTAssertTrue(usageDetail.exists)
        let usageDetailText = usageDetail.value as? String ?? usageDetail.label
        XCTAssertTrue(
            usageDetailText.contains("used all of this period’s credits"),
            usageDetailText
        )
        XCTAssertTrue(app.staticTexts["Payment is past due"].exists)
    }

    func testEliSubscriptionGateShowsConfirmationAndDisappearsAfterCheckout() throws {
        let app = launchApp(
            fixture: "ask-streaming",
            checkoutSuccess: true,
            appleSuccess: true
        )

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5))
        submitAskText("Summarize this page", in: app)

        let subscriptionGate = element("agent-subscription-gate", in: app)
        XCTAssertTrue(subscriptionGate.waitForExistence(timeout: 5), askState(in: app))
        element("agent-sign-in-button", in: app).click()
        XCTAssertTrue(
            element("agent-subscribe-button", in: app).waitForExistence(timeout: 5),
            askState(in: app)
        )
        element("agent-subscribe-button", in: app).click()

        let confirming = element("agent-subscription-confirming", in: app)
        XCTAssertTrue(confirming.waitForExistence(timeout: 2), askState(in: app))
        XCTAssertEqual(confirming.label, "Confirming subscription…")

        let confirmingAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        confirmingAttachment.name = "Eli subscription confirming"
        confirmingAttachment.lifetime = .keepAlways
        add(confirmingAttachment)

        let gateRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: subscriptionGate
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gateRemoved], timeout: 5), .completed)
        XCTAssertFalse(element("agent-subscribe-button", in: app).exists)
        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[Streaming response started.]",
                timeout: 5
            ),
            askState(in: app)
        )
        XCTAssertTrue(askState(in: app).contains("messages=[0:user:"), askState(in: app))
        XCTAssertTrue(askState(in: app).contains("||1:assistant:"), askState(in: app))
        XCTAssertFalse(askState(in: app).contains("||2:user:"), askState(in: app))
    }

    func testSignOutKeepsBrowsingAndResetsHostedEli() throws {
        let app = launchApp(
            fixture: "ask-streaming",
            checkoutSuccess: true,
            appleSuccess: true
        )

        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://www.apple.com/"),
            currentState(in: app)
        )
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5))
        submitAskText("Summarize this page", in: app)

        let subscriptionGate = element("agent-subscription-gate", in: app)
        XCTAssertTrue(subscriptionGate.waitForExistence(timeout: 5), askState(in: app))
        element("agent-sign-in-button", in: app).click()
        XCTAssertTrue(
            element("agent-subscribe-button", in: app).waitForExistence(timeout: 5),
            askState(in: app)
        )
        element("agent-subscribe-button", in: app).click()

        let gateRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: subscriptionGate
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gateRemoved], timeout: 5), .completed)

        submitAskText("Keep streaming", in: app)
        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[Streaming response started.]",
                timeout: 5
            ),
            askState(in: app)
        )

        app.menuBars.menuBarItems["Candoa"].click()
        let signOutItem = app.menuItems["Sign Out"]
        XCTAssertTrue(signOutItem.waitForExistence(timeout: 5))
        XCTAssertTrue(signOutItem.isEnabled)
        signOutItem.click()

        XCTAssertTrue(element("sign-out-confirmation", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(
            element("agent-subscription-gate", in: app).waitForExistence(timeout: 2),
            askState(in: app)
        )
        XCTAssertTrue(element("agent-sign-in-button", in: app).waitForExistence(timeout: 2))
        XCTAssertFalse(element("agent-subscribe-button", in: app).exists)
        XCTAssertTrue(waitForAskState(in: app, containing: "lastUser=[]"), askState(in: app))
        XCTAssertFalse(askState(in: app).contains("This should never appear after sign-out."))
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://www.apple.com/"),
            currentState(in: app)
        )
        XCTAssertTrue(element("sidebar-address-button", in: app).exists)
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
    }

    // MARK: - Site Info (issue #29)

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

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=false"), currentState(in: app))

        // The page's window.open click must now be refused: the source tab
        // stays put and the delegate records the block.
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), currentState(in: app))
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

    /// View ▸ Site Info presents the same popover from the menu bar.
    func testSiteInfoMenuCommandOpensPopover() {
        let app = launchApp(fixture: "popup-open")

        openFixtureTab(path: "popup", in: app)

        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let siteInfoItem = app.menuItems["Site Info…"]
        XCTAssertTrue(siteInfoItem.waitForExistence(timeout: 5))
        siteInfoItem.click()

        XCTAssertTrue(waitForState(in: app, containing: "siteInfoShown=true"), currentState(in: app))
        XCTAssertTrue(
            element("site-info-popover", in: app).waitForExistence(timeout: 5),
            currentState(in: app)
        )
    }

    // MARK: - Hosted web-authentication sessions (issue #47)

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

    private func launchApp(
        fixture: String? = nil,
        onboardingStep: String? = nil,
        browserImportFixture: String? = nil,
        checkoutFailure: Bool = false,
        checkoutSuccess: Bool = false,
        appleSuccess: Bool = false,
        websiteAppearance: String? = nil,
        cloudKitEntitlement: Bool = false,
        preservesStore: Bool = false,
        forcesLightAppearance: Bool = false,
        remoteRestoreFixture: Bool = false,
        updateVersion: String? = nil,
        whatsNewFixture: Bool = false,
        extraLaunchArguments: [String] = [],
        extraLaunchEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += extraLaunchArguments
        app.launchEnvironment.merge(extraLaunchEnvironment) { _, new in new }
        if forcesLightAppearance {
            app.launchArguments += ["-NSRequiresAquaSystemAppearance", "YES"]
        }
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
        if checkoutFailure {
            app.launchEnvironment["CANDOA_UI_TESTING_CHECKOUT_FAILURE"] = "1"
        }
        if checkoutSuccess {
            app.launchEnvironment["CANDOA_UI_TESTING_CHECKOUT_SUCCESS"] = "1"
        }
        if appleSuccess {
            app.launchEnvironment["CANDOA_UI_TESTING_APPLE_SUCCESS"] = "1"
        }
        if cloudKitEntitlement {
            app.launchEnvironment["CANDOA_UI_TESTING_CLOUDKIT_ENTITLEMENT"] = "1"
        }
        if preservesStore {
            app.launchEnvironment["CANDOA_UI_TESTING_PRESERVES_STORE"] = "1"
        }
        if remoteRestoreFixture {
            app.launchEnvironment["CANDOA_UI_TESTING_REMOTE_RESTORE_FIXTURE"] = "1"
        }
        if let updateVersion {
            app.launchEnvironment["CANDOA_UI_TESTING_UPDATE_VERSION"] = updateVersion
        }
        if whatsNewFixture {
            app.launchEnvironment["CANDOA_UI_TESTING_WHATS_NEW"] = "1"
        }

        app.launch()
        return app
    }

    /// Stands in for a CloudKit import finishing: the app (launched with
    /// `remoteRestoreFixture`) listens for this distributed notification and
    /// injects a synced-workspace fixture through the real remote-apply path.
    private func postRemoteRestore() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.candoa.uitesting.remote-restore"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Opens the new-tab palette, retrying because a synthesized ⌘T right
    /// after launch can race the window's key status (the same hazard the
    /// window-scoped openNewTabPalette documents) — on CI runners the first
    /// press regularly lands before the window is key.
    private func openNewTabPalette(in app: XCUIApplication) {
        for _ in 0..<3 {
            app.typeKey("t", modifierFlags: .command)
            if waitForState(in: app, containing: "newTabPalette=true", timeout: 2) { return }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("New-tab palette did not open: \(currentState(in: app))")
    }

    /// Opens a new tab through the command palette and waits until the
    /// fixture page has loaded and retitled itself to its path.
    private func openFixtureTab(path: String, in app: XCUIApplication) {
        openNewTabPalette(in: app)
        submitCommandPaletteText("https://fixture.candoa.test/\(path)", in: app)
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/\(path)", timeout: 10),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForState(in: app, containing: "active=\(path)", timeout: 10),
            currentState(in: app)
        )
    }

    /// Samples the composited window pixels at the given screen points from a
    /// runner-side screenshot, as [red, green, blue] 0–255 triples.
    /// Screenshots capture the real window-server output — including the
    /// out-of-process WKWebView layers an in-process snapshot can't see — so
    /// these assertions catch chrome that exists in the AX hierarchy but
    /// renders behind the web content. Not usable mid-drag: event synthesis
    /// blocks the test thread, so sample before and after a drag instead.
    private func windowPixelColors(
        at screenPoints: [CGPoint],
        in app: XCUIApplication
    ) throws -> [[Int]] {
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        let image = try XCTUnwrap(
            window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            "Window screenshot produced no bitmap"
        )

        let width = image.width
        let height = image.height
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        try buffer.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(
                CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                "Could not create the pixel-sampling bitmap context"
            )
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // XCUITest frames and the screenshot share a top-left origin, and the
        // bitmap's first row is the top scanline, so only scaling remains.
        let scaleX = CGFloat(width) / windowFrame.width
        let scaleY = CGFloat(height) / windowFrame.height
        return screenPoints.map { point in
            let pixelX = min(max(Int((point.x - windowFrame.minX) * scaleX), 0), width - 1)
            let pixelY = min(max(Int((point.y - windowFrame.minY) * scaleY), 0), height - 1)
            let index = (pixelY * width + pixelX) * 4
            return [Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2])]
        }
    }

    /// Loose match for the pixel fixture pages' #00ff00 background: display
    /// color-profile conversion shifts the captured channels, so this checks
    /// "unmistakably green", not equality.
    private func isSolidGreen(_ color: [Int]) -> Bool {
        color.count == 3 && color[0] <= 100 && color[1] >= 180 && color[2] <= 100
    }

    /// Reads one key's value out of the semicolon-separated testing state.
    private func stateValue(_ key: String, in app: XCUIApplication) -> String? {
        currentState(in: app)
            .split(separator: ";")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    private static let splitFixturePageHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Split Fixture</title>
        <script>document.title = location.pathname.slice(1)</script>
      </head>
      <body><h1>Split pane fixture</h1></body>
    </html>
    """

    /// A solid #00ff00 page so pixel sampling has an unmistakable baseline:
    /// the pane center proves web content rendered, and any chrome drawn
    /// over the page must move a sampled channel away from pure green.
    private static let pixelProbeFixturePageHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <script>document.title = location.pathname.slice(1)</script>
        <style>html, body { margin: 0; height: 100%; background: #00ff00; }</style>
      </head>
      <body></body>
    </html>
    """

    /// Hosted web-authentication fixture: the path picks the provider
    /// behavior — an immediate matching-scheme callback, a non-matching
    /// scheme, or an idle page that waits to be dismissed.
    private static let webAuthFixturePageHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <script>
          addEventListener("load", () => {
            if (location.pathname === "/auth-success") {
              location.href = "candoa-e2e://auth?code=ok";
            } else if (location.pathname === "/auth-wrong") {
              location.href = "wrong-scheme://auth?code=bad";
            }
          });
        </script>
      </head>
      <body><h1>Web auth fixture</h1></body>
    </html>
    """

    private static let pageHTMLFixtures: [String: String] = [
        "split-view": splitFixturePageHTML,
        "split-view-spaces": splitFixturePageHTML,
        "split-view-pixels": pixelProbeFixturePageHTML,
        "web-auth": webAuthFixturePageHTML,
        "download-page": """
        <!doctype html>
        <meta charset="utf-8">
        <title>Download Fixture</title>
        <a href="data:application/octet-stream;base64,Q2FuZG9hIGUyZSBkb3dubG9hZCBmaXh0dXJl"
           download="candoa-e2e-download.bin"
           style="position:fixed;inset:0;font-size:40px">Download</a>
        """,
        "popup-open": """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <script>document.title = location.pathname.slice(1)</script>
          </head>
          <body>
            <script>
              document.addEventListener("click", () => {
                window.open("https://fixture.candoa.test/popup-child");
              });
            </script>
          </body>
        </html>
        """,
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

    /// Window-scoped variant for multi-window tests: with two windows open,
    /// app-wide identifier queries match one state element per window and
    /// become ambiguous.
    private func element(_ identifier: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)[identifier]
    }

    /// Opens the new-tab palette in the given window, retrying if the
    /// shortcut landed in another window: right after a window opens,
    /// synthesized key events can race its key status.
    private func openNewTabPalette(in window: XCUIElement, of app: XCUIApplication) {
        for _ in 0..<3 {
            app.typeKey("t", modifierFlags: .command)
            if waitForState(in: window, containing: "newTabPalette=true", timeout: 2) { return }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("New-tab palette did not open in the expected window: \(currentState(in: window))")
    }

    private func waitForState(
        in window: XCUIElement,
        containing expectedText: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        guard element("ui-testing-state", in: window).waitForExistence(timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentState(in: window).contains(expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTContext.runActivity(named: "Current UI testing state") { activity in
            let attachment = XCTAttachment(string: currentState(in: window))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return false
    }

    private func currentState(in window: XCUIElement) -> String {
        let stateElement = element("ui-testing-state", in: window)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    private func submitCommandPaletteText(_ text: String, in window: XCUIElement) {
        let field = element("command-palette-field", in: window)
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: window))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
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

    /// Window managers and launchers that register Control-Option letter
    /// combos as system-wide hotkeys. A global hotkey consumes the key
    /// event before the app's local NSEvent monitor can see it, so
    /// keystroke-driven assertions are only trustworthy when none of
    /// these are running.
    private func runningGlobalHotkeyApps() -> [String] {
        let knownHotkeyApps: Set<String> = [
            "com.knollsoft.Rectangle",
            "com.knollsoft.Hookshot", // Rectangle Pro
            "com.raycast.macos",
            "com.crowdcafe.windowmagnet", // Magnet
            "com.divisiblebyzero.Spectacle",
            "com.hegenberg.BetterTouchTool",
            "com.lwouis.alt-tab-macos",
        ]
        return NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter(knownHotkeyApps.contains)
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
final class EliLiveUITests: XCTestCase {
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
