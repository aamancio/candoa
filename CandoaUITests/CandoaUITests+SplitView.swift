import AppKit
import XCTest

extension CandoaUITests {
    func testAppLaunchesMainWindow() throws {
        let app = launchApp()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testSplitViewFocusFollowsPaneAndChipClicks() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=one"), currentState(in: app))

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

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitTabs=two|one"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=one"), currentState(in: app))

        let leadingPane = element("split-pane-0", in: app)
        XCTAssertTrue(leadingPane.waitForExistence(timeout: 5), currentState(in: app))
        // Opening a split hands focus to the new pane, so the pane this test
        // samples has to be lit on purpose before the "focused" capture.
        leadingPane.click()
        XCTAssertTrue(waitForState(in: app, containing: "splitActive=two"), currentState(in: app))
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

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
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

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
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

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
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

        // Built by dragging rather than Cmd-\\: this half is about Space
        // switching, and coming back restores the tab the Space remembers.
        // A pane named through the command bar is a tab the Space never knew
        // about, so the group would revive around a non-member and stay
        // suspended -- a different behaviour than the one under test.
        let rowATwo = element("tab-row-a-two", in: spacesApp)
        XCTAssertTrue(rowATwo.waitForExistence(timeout: 5), currentState(in: spacesApp))
        let spacesTarget = spacesApp.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        rowATwo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: spacesTarget)
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

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
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

        // Layout shortcuts switch between stacked rows and side-by-side
        // columns — the only two arrangements.
        app.typeKey("v", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=vertical"), currentState(in: app))

        app.typeKey("h", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))

        // The layout is split state: closing the split resets it.
        app.typeKey("\\", modifierFlags: [.command])
        XCTAssertTrue(waitForState(in: app, containing: "split=false"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "splitLayout=horizontal"), currentState(in: app))
    }

    func testSplitPaneUnsplitButtonReturnsTabToSidebar() throws {
        let app = launchApp(fixture: "split-view")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openFixtureTab(path: "two", in: app)
        openSplitPane(with: "one", in: app)
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
        XCTAssertTrue(waitForState(in: app, containing: "tabs=one|two"), currentState(in: app))
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
        // Scoped to the window: the Window menu holds an identically titled
        // command, and the menu bar materializes in snapshots.
        let favoriteItem = app.windows.firstMatch.menuItems["Add to Favorites"]
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
        let unfavoriteItem = app.windows.firstMatch.menuItems["Remove from Favorites"]
        XCTAssertTrue(unfavoriteItem.waitForExistence(timeout: 5), currentState(in: app))
        unfavoriteItem.click()
        XCTAssertTrue(waitForState(in: app, containing: "favorites=;"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "space=SplitTwo"), currentState(in: app))
        XCTAssertTrue(waitForState(in: app, containing: "active=a-one"), currentState(in: app))
    }
}
