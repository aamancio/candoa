import AppKit
import XCTest

extension CandoaUITests {
    func launchApp(
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
    func postRemoteRestore() {
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
    func openNewTabPalette(in app: XCUIApplication) {
        for _ in 0..<3 {
            app.typeKey("t", modifierFlags: .command)
            if waitForState(in: app, containing: "newTabPalette=true", timeout: 2) { return }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("New-tab palette did not open: \(currentState(in: app))")
    }

    /// Opens a new tab through the command palette and waits until the
    /// fixture page has loaded and retitled itself to its path.
    /// Cmd-\\ opens the new pane blank with the command bar focused, so a
    /// test that wants two real panes names the second one itself.
    func openSplitPane(with path: String, in app: XCUIApplication) {
        app.typeKey("\\", modifierFlags: [.command])
        submitCommandPaletteText("https://fixture.candoa.test/\(path)", in: app)
        XCTAssertTrue(waitForState(in: app, containing: "splitDisplayed=true"), currentState(in: app))
    }

    func openFixtureTab(path: String, in app: XCUIApplication) {
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
    func windowPixelColors(
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
    func isSolidGreen(_ color: [Int]) -> Bool {
        color.count == 3 && color[0] <= 100 && color[1] >= 180 && color[2] <= 100
    }

    /// Reads one key's value out of the semicolon-separated testing state.
    func stateValue(_ key: String, in app: XCUIApplication) -> String? {
        currentState(in: app)
            .split(separator: ";")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    func assertBrowserMigration(
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

    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Window-scoped variant for multi-window tests: with two windows open,
    /// app-wide identifier queries match one state element per window and
    /// become ambiguous.
    @nonobjc func element(_ identifier: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)[identifier]
    }

    /// Opens the new-tab palette in the given window, retrying if the
    /// shortcut landed in another window: right after a window opens,
    /// synthesized key events can race its key status.
    func openNewTabPalette(in window: XCUIElement, of app: XCUIApplication) {
        for _ in 0..<3 {
            app.typeKey("t", modifierFlags: .command)
            if waitForState(in: window, containing: "newTabPalette=true", timeout: 2) { return }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("New-tab palette did not open in the expected window: \(currentState(in: window))")
    }

    @nonobjc func waitForState(
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

    @nonobjc func currentState(in window: XCUIElement) -> String {
        let stateElement = element("ui-testing-state", in: window)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    @nonobjc func submitCommandPaletteText(_ text: String, in window: XCUIElement) {
        let field = element("command-palette-field", in: window)
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: window))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    func assertEqualFrame(
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

    func submitCommandPaletteText(_ text: String, in app: XCUIApplication) {
        let field = element("command-palette-field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    func submitAskText(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        pasteText(text, into: field)
        field.typeKey(.return, modifierFlags: [])
    }

    func waitForState(in app: XCUIApplication, containing expectedText: String, timeout: TimeInterval = 5) -> Bool {
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

    func currentState(in app: XCUIApplication) -> String {
        let stateElement = element("ui-testing-state", in: app)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    func waitForAskState(in app: XCUIApplication, containing expectedText: String, timeout: TimeInterval = 5) -> Bool {
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

    func askState(in app: XCUIApplication) -> String {
        let stateElement = element("agent-ui-testing-state", in: app)
        if let value = stateElement.value as? String, !value.isEmpty {
            return value
        }
        if !stateElement.label.isEmpty {
            return stateElement.label
        }
        return stateElement.debugDescription
    }

    func pasteText(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
    }
}
