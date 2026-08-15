import AppKit
import XCTest

extension CandoaUITests {
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
        clickPopUpButton(withValue: "Low", in: app)
        XCTAssertTrue(app.menuItems["Low"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["High"].exists)
        app.typeKey(.escape, modifierFlags: [])

        // Switching back to the hosted connection swaps in the plan catalog.
        clickPopUpButton(withValue: "Personal API key", in: app)
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
        clickPopUpButton(withValue: "GPT-5.6 Luna", in: app)
        let novaItem = app.menuItems["GPT-6 Nova"]
        XCTAssertTrue(novaItem.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["GPT-6 Mini"].exists)
        novaItem.click()
        XCTAssertTrue(popUpButton(withValue: "GPT-6 Nova", in: app).waitForExistence(timeout: 5))

        // Reasoning follows the listed model's declared support.
        clickPopUpButton(withValue: "Low", in: app)
        XCTAssertTrue(app.menuItems["High"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        clickPopUpButton(withValue: "GPT-6 Nova", in: app)
        let miniItem = app.menuItems["GPT-6 Mini"]
        XCTAssertTrue(miniItem.waitForExistence(timeout: 5))
        miniItem.click()
        XCTAssertTrue(popUpButton(withValue: "GPT-6 Mini", in: app).waitForExistence(timeout: 5))
        clickPopUpButton(withValue: "Low", in: app)
        XCTAssertTrue(app.menuItems["Low"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["High"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func openEliSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let eliButton = app.buttons["Eli"].firstMatch
        XCTAssertTrue(eliButton.waitForExistence(timeout: 5))
        eliButton.click()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 5))
    }

    func popUpButton(withValue value: String, in app: XCUIApplication) -> XCUIElement {
        app.popUpButtons.matching(
            NSPredicate(format: "value == %@", value)
        ).firstMatch
    }

    /// Clicks a settings popup that loaded CI runners occasionally report
    /// non-hittable right after a previous picker menu dismisses: polls for
    /// hittability, then falls back to a coordinate click, which skips the
    /// hit test entirely.
    private func clickPopUpButton(withValue value: String, in app: XCUIApplication) {
        let button = popUpButton(withValue: value, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "popup with value '\(value)' missing")
        let deadline = Date().addingTimeInterval(5)
        while !button.isHittable, Date() < deadline {
            usleep(200_000)
        }
        if button.isHittable {
            button.click()
        } else {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
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
}
