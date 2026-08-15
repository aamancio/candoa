import AppKit
import XCTest

@MainActor
final class EliLiveUITests: XCTestCase {
    private let liveE2EMarkerPath = "/tmp/candoa-live-e2e-enabled"

    override func setUpWithError() throws {
        continueAfterFailure = false

        guard FileManager.default.fileExists(atPath: liveE2EMarkerPath) else {
            throw XCTSkip("Run Scripts/e2e-ask-test.sh to enable live Eli website smoke tests.")
        }
    }

    /// Same as CandoaUITests: never strand the app under test on screen.
    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
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
