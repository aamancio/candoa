import AppKit
import XCTest

extension CandoaUITests {
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
}
