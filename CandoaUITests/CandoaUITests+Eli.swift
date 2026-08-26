import AppKit
import XCTest

extension CandoaUITests {
    func testEliSettingsEditTheFormFillProfile() throws {
        let app = launchApp(fixture: "ask")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        XCTAssertTrue(app.staticTexts["Your Details"].waitForExistence(timeout: 5), app.debugDescription)
        // Subscript lookup caps at 128 characters, so this explainer needs a
        // predicate rather than a literal identifier.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "Eli learns these from your conversations")
            ).firstMatch.exists,
            app.debugDescription
        )

        // The pane starts from an empty profile under UI testing, so it
        // reads as what Eli knows — nothing yet — rather than a form.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "hasn't learned any details yet")
            ).firstMatch.exists,
            app.debugDescription
        )
        XCTAssertFalse(app.textFields["Given name"].exists, "empty fields stay out of sight")

        // Payment and identity fields are deliberately absent, not merely
        // unused: the profile must not become a place to keep them.
        for absent in ["Card number", "Date of birth", "Social Security number", "Password"] {
            XCTAssertFalse(app.staticTexts[absent].exists, "\(absent) must not be a profile field")
        }

        // Adding a detail by hand is still possible; the row appears only
        // once asked for. SwiftUI's Menu surfaces as a pop-up button.
        let addDetail = app.popUpButtons["Add Detail"].firstMatch.exists
            ? app.popUpButtons["Add Detail"].firstMatch
            : app.menuButtons["Add Detail"].firstMatch
        XCTAssertTrue(addDetail.waitForExistence(timeout: 5), app.debugDescription)
        addDetail.click()
        let givenNameItem = app.menuItems["Given name"].firstMatch
        XCTAssertTrue(givenNameItem.waitForExistence(timeout: 5), app.debugDescription)
        givenNameItem.click()

        let givenName = app.textFields["Given name"].firstMatch
        XCTAssertTrue(givenName.waitForExistence(timeout: 5), app.debugDescription)
        givenName.click()
        givenName.typeText("Alex")
        XCTAssertEqual(givenName.value as? String, "Alex")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Eli form-fill profile settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEliFillsAFormAfterOnePageApprovalAndStillConfirmsSubmit() throws {
        // Three personal fields and a submit button, all structurally
        // sensitive. Without page-scoped consent this run would raise four
        // separate confirmations.
        let app = launchApp(fixture: "ask-agent-form-fill")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))
        submitAskText("fill out this application for me", in: app)

        // The first personal field asks, and offers to cover the page.
        XCTAssertTrue(app.staticTexts["Confirm this action?"].waitForExistence(timeout: 8), app.debugDescription)
        let fillPage = element("agent-fill-page", in: app)
        XCTAssertTrue(fillPage.waitForExistence(timeout: 5), app.debugDescription)

        let approvalAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        approvalAttachment.name = "Eli page-scoped fill approval"
        approvalAttachment.lifetime = .keepAlways
        add(approvalAttachment)

        fillPage.click()

        // The remaining fields fill without another dialog, and the page's own
        // status line is the proof they landed.
        XCTAssertTrue(
            app.staticTexts["filled=3 name-ok email-ok phone-ok"].waitForExistence(timeout: 15),
            app.debugDescription
        )

        // Sending the form is a separate decision and still asks.
        XCTAssertTrue(app.staticTexts["Confirm this action?"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(
            app.staticTexts[
                "Eli is ready to activate \"Submit Application\". This may make a consequential change to your account."
            ].exists,
            app.debugDescription
        )
        XCTAssertFalse(
            element("agent-fill-page", in: app).exists,
            "the page-scoped option must never appear on a submit confirmation"
        )

        let continueButton = app.sheets.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.exists, app.debugDescription)
        continueButton.click()

        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastAssistant=[Your application is submitted.]", timeout: 15),
            askState(in: app)
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

    func testEliSettingsOfferAppleSignInAfterSessionExpiry() throws {
        let app = launchApp(fixture: "account-session-expired")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        openEliSettings(in: app)

        // An expired session is not retryable: the stored token is gone, so
        // settings must explain what happened and offer Apple sign-in
        // instead of a doomed Try Again.
        XCTAssertTrue(
            app.staticTexts[
                "Your Candoa session has expired. Sign in with Apple to restore your account."
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Sign In with Apple"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("account-refresh-retry-button", in: app).exists)
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

    func testEliMentionPickerSkipsAttachedTabsAndAddsAllOpenTabs() throws {
        // Seeded TestingBot workspace: five tabs, "Apple" active. The active
        // tab is attached as the current-page chip, so the mention picker
        // must never offer it again.
        let app = launchApp()

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))
        XCTAssertTrue(waitForAskState(in: app, containing: "Apple|www.apple.com"), askState(in: app))

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()

        // "apple" matches the Apple tab and developer.apple.com. With the
        // active Apple tab excluded, the first row is WebKit Documentation.
        field.typeText("@apple")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForAskState(in: app, containing: "WebKit Documentation|developer.apple.com"),
            askState(in: app)
        )

        // Both "apple" tabs are attached now, so the same query offers no tab
        // rows and the first row becomes "All open tabs", which attaches the
        // remaining three tabs at once.
        field.typeText("@apple")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForAskState(in: app, containing: "amazon.com"), askState(in: app))
        XCTAssertTrue(waitForAskState(in: app, containing: "Granola"), askState(in: app))
        XCTAssertTrue(waitForAskState(in: app, containing: "Home / X"), askState(in: app))

        // The attached-tab exclusion means no tab is ever attached twice.
        let state = askState(in: app)
        let appleChipCount = state.components(separatedBy: "Apple|www.apple.com").count - 1
        XCTAssertEqual(appleChipCount, 1, state)
    }

    func testEliAgentWaitsForUserThenContinues() throws {
        let app = launchApp(fixture: "ask-agent-waiting")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeText("play the video for me")
        field.typeKey(.return, modifierFlags: [])

        // The run pauses on a wait-for-user handoff instead of dying.
        let card = element("agent-waiting-card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 8), askState(in: app))
        XCTAssertTrue(app.staticTexts["Waiting for you"].exists, app.debugDescription)
        XCTAssertTrue(
            app.staticTexts["An ad is playing. Skip it or let it finish, then continue."].exists,
            app.debugDescription
        )

        let waitingAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        waitingAttachment.name = "Eli waiting-for-you card"
        waitingAttachment.lifetime = .keepAlways
        add(waitingAttachment)

        element("agent-waiting-continue", in: app).click()
        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastAssistant=[The video is playing.]", timeout: 8),
            askState(in: app)
        )
        XCTAssertFalse(element("agent-waiting-card", in: app).exists, app.debugDescription)
    }

    func testEliAgentWaitingStopFinalizesTheCard() throws {
        let app = launchApp(fixture: "ask-agent-waiting")

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeText("play the video for me")
        field.typeKey(.return, modifierFlags: [])

        let card = element("agent-waiting-card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 8), askState(in: app))

        element("agent-waiting-stop", in: app).click()
        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastAssistant=[Okay, I stopped there.]", timeout: 8),
            askState(in: app)
        )
        XCTAssertFalse(element("agent-waiting-card", in: app).exists, app.debugDescription)

        // The lifecycle state must not be stranded: a new submission works.
        field.click()
        field.typeText("play the video for me")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(card.waitForExistence(timeout: 8), askState(in: app))
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

        // The request itself is consent for reversible browsing: the agent
        // starts without a per-task permission dialog.
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

        // Reversible navigation runs immediately — no per-task permission
        // dialog and no per-action confirmation.
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
        XCTAssertFalse(app.sheets.firstMatch.exists, app.debugDescription)
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
        // The reversible add-to-cart task starts without a permission dialog.
        XCTAssertTrue(
            waitForAskState(in: app, containing: "lastAssistant=[The MacBook Air is in your cart.]", timeout: 20),
            askState(in: app)
        )
        XCTAssertTrue(app.staticTexts["MacBook Air is in your cart."].waitForExistence(timeout: 5))

        // The consequential removal is still confirmed per action; dismissing
        // the confirmation counts as a deny and ends the run cleanly.
        submitAskText("remove teh computer from the cart", in: app)
        XCTAssertTrue(app.staticTexts["Confirm this action?"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[I stopped before making that change.]",
                timeout: 8
            ),
            askState(in: app)
        )
        XCTAssertTrue(app.staticTexts["MacBook Air is in your cart."].exists, app.debugDescription)

        // A denied run must not wedge the sidebar: the same request works
        // again and the confirmation presents again.
        submitAskText("remove teh computer from the cart", in: app)
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

    func testEliAgentRunsInMentionedTabFromAttachedContext() throws {
        // Two-tab fixture: "Reading List" is active and "Membership Home" is
        // attached only via an @-mention. The fixture's browser-control event
        // carries the mentioned tab's URL as targetTabURL, so the run must
        // activate that tab and act there instead of the current page.
        let app = launchApp(fixture: "ask-agent-mentioned-tab")
        let exactPrompt = "open the account page in my membership tab"

        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(element("agent-sidebar", in: app).waitForExistence(timeout: 5), currentState(in: app))
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/reading"),
            currentState(in: app)
        )

        let field = app.textFields["agent-sidebar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), currentState(in: app))
        field.click()
        field.typeText("@member")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForAskState(in: app, containing: "Membership Home|fixture.candoa.test"),
            askState(in: app)
        )

        field.typeText(exactPrompt)
        field.typeKey(.return, modifierFlags: [])

        // The run switches to the mentioned tab (waking its hibernated web
        // view) and clicks through to the account page there; the reading tab
        // is never acted on.
        XCTAssertTrue(
            waitForState(in: app, containing: "url=https://fixture.candoa.test/home#account", timeout: 15),
            currentState(in: app)
        )
        XCTAssertTrue(
            waitForAskState(
                in: app,
                containing: "lastAssistant=[Your account page is open in the membership tab.]",
                timeout: 8
            ),
            askState(in: app)
        )
        XCTAssertTrue(app.staticTexts["Account Page"].waitForExistence(timeout: 5), currentState(in: app))
    }
}
