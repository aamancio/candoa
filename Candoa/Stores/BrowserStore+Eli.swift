import Foundation

extension BrowserStore {
    func browserAgentPage(for tabID: UUID?) async -> CandoaBrowserAgentPage? {
        guard let tabID else { return nil }
        var resolvedTab = tabs.first(where: { $0.id == tabID && $0.url != nil })
        if resolvedTab == nil {
            // Dismissing a native confirmation can coincide with WebKit publishing
            // a transient nil URL during its first load. Wait only for this
            // user-initiated capture; no observer or recurring work is retained.
            for _ in 0..<20 {
                guard !Task.isCancelled else { return nil }
                try? await Task.sleep(for: .milliseconds(100))
                resolvedTab = tabs.first(where: { $0.id == tabID && $0.url != nil })
                if resolvedTab != nil { break }
            }
        }
        guard let tab = resolvedTab, let url = tab.url else { return nil }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-navigation" {
            let labels: [String]
            switch url.path {
            case "/home":
                labels = ["Account"]
            case "/account":
                labels = ["Manage Membership"]
            case "/membership":
                labels = ["Cancel Membership"]
            default:
                labels = []
            }
            let snapshotID = UUID()
            return CandoaBrowserAgentPage(
                snapshotID: snapshotID,
                title: tab.title,
                url: url.absoluteString,
                text: labels.joined(separator: "\n"),
                controls: labels.enumerated().map {
                    CandoaBrowserAgentControl(ref: "e\($0.offset)", kind: .button, label: $0.element, url: nil, disabled: false)
                }
            )
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-normalized-navigation" {
            let controls: [CandoaBrowserAgentControl] = URL(string: url.absoluteString)?.path == "/air"
                ? [CandoaBrowserAgentControl(
                    ref: "e0",
                    kind: .link,
                    label: "Buy MacBook Air",
                    url: "https://fixture.candoa.test/buy",
                    disabled: false
                )]
                : []
            return CandoaBrowserAgentPage(
                snapshotID: UUID(),
                title: tab.title,
                url: url.absoluteString,
                text: controls.map(\.label).joined(separator: "\n"),
                controls: controls
            )
        }

        let pageText = await webCoordinator.readablePageText(for: tabID) ?? ""
        guard let snapshot = await webCoordinator.browserAgentSnapshot(for: tabID) else { return nil }
        return CandoaBrowserAgentPage(
            snapshotID: snapshot.id,
            title: tab.title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.absoluteString,
            text: String(pageText.prefix(16_000)),
            controls: snapshot.controls
        )
    }

    func startBrowserAgentRun(
        runID: UUID,
        goal: String,
        page: CandoaBrowserAgentPage
    ) async throws -> CandoaBrowserAgentRunResponse {
        if let fixture = fixtureBrowserAgentResponse(runID: runID, goal: goal, page: page, outcome: nil) {
            return fixture
        }
        return try await CandoaBrowserAgentRemoteService.start(runID: runID, goal: goal, page: page)
    }

    func resumeBrowserAgentRun(
        runID: UUID,
        goal: String,
        outcome: CandoaBrowserAgentActionOutcome
    ) async throws -> CandoaBrowserAgentRunResponse {
        if let page = outcome.page,
           let fixture = fixtureBrowserAgentResponse(runID: runID, goal: goal, page: page, outcome: outcome) {
            return fixture
        }
        return try await CandoaBrowserAgentRemoteService.resume(runID: runID, outcome: outcome)
    }

    private func fixtureBrowserAgentResponse(
        runID: UUID,
        goal: String,
        page: CandoaBrowserAgentPage,
        outcome: CandoaBrowserAgentActionOutcome?
    ) -> CandoaBrowserAgentRunResponse? {
        guard Self.isUITesting,
              let fixture = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"],
              ["ask-agent-navigation", "ask-agent-normalized-navigation", "ask-agent-selection"]
                .contains(fixture) else { return nil }
        let path = URL(string: page.url)?.path

        if fixture == "ask-agent-normalized-navigation" {
            if path == "/air", let control = page.controls.first {
                return fixtureActionResponse(
                    runID: runID,
                    page: page,
                    control: control,
                    kind: .navigate,
                    message: "Opening the MacBook Air buying page."
                )
            }
            if outcome?.result.hasPrefix("Navigated") == true {
                return CandoaBrowserAgentRunResponse(
                    runID: runID,
                    status: .action,
                    message: "Scroll to reveal the remaining laptop configuration options.",
                    action: CandoaBrowserAgentAction(
                        snapshotID: page.snapshotID,
                        kind: .scroll,
                        target: "down",
                        value: "",
                        label: "Scroll down",
                        url: nil,
                        requiresApproval: false,
                        message: "Scroll to reveal the remaining laptop configuration options."
                    )
                )
            }
            return .init(
                runID: runID,
                status: .complete,
                message: "The MacBook Air buying page is open.",
                action: nil
            )
        }

        if fixture == "ask-agent-selection" {
            let normalizedGoal = CandoaEliPromptPolicy.normalizedText(goal)
            let control = page.controls.first(where: { $0.label == "Add to Cart" })
                ?? page.controls.first(where: { $0.label == "Remove" && normalizedGoal.contains("remove") })
                ?? page.controls.first(where: { $0.label == "Sky Blue" && !$0.selected })
            if let control {
                return fixtureActionResponse(
                    runID: runID,
                    page: page,
                    control: control,
                    kind: .click,
                    requiresApproval: control.label == "Remove"
                )
            }
            let removed = page.text.localizedCaseInsensitiveContains("empty")
            return .init(
                runID: runID,
                status: .complete,
                message: removed
                    ? "The MacBook Air was removed from your cart."
                    : "The MacBook Air is in your cart.",
                action: nil
            )
        }

        let shouldAct = ["/home", "/account", "/membership"].contains(path)
        if shouldAct, let control = page.controls.first {
            return fixtureActionResponse(
                runID: runID,
                page: page,
                control: control,
                kind: .click,
                requiresApproval: control.label.localizedCaseInsensitiveContains("cancel")
                    || control.label.localizedCaseInsensitiveContains("remove")
            )
        }

        return .init(
            runID: runID,
            status: .complete,
            message: "Your membership has been cancelled.",
            action: nil
        )
    }

    private func fixtureActionResponse(
        runID: UUID,
        page: CandoaBrowserAgentPage,
        control: CandoaBrowserAgentControl,
        kind: CandoaPageActionKind,
        message: String = "",
        requiresApproval: Bool = false
    ) -> CandoaBrowserAgentRunResponse {
        CandoaBrowserAgentRunResponse(
            runID: runID,
            status: .action,
            message: message,
            action: CandoaBrowserAgentAction(
                snapshotID: page.snapshotID,
                kind: kind,
                target: control.ref,
                value: "",
                label: control.label,
                url: control.url,
                requiresApproval: requiresApproval,
                message: message
            )
        )
    }

    func waitForBrowserAgentPageSettled(in tabID: UUID, previousURL: String) async {
        await webCoordinator.waitForBrowserAgentPageSettled(for: tabID, previousURL: previousURL)
    }

    func pagePurchaseCandidates(for tabID: UUID?) async -> [CandoaPagePurchaseCandidate] {
        if Self.isUITesting,
           ["ask-contextual-purchase", "ask-contextual-followup"].contains(
               ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"]
           ) {
            return [
                CandoaPagePurchaseCandidate(
                    label: "MacBook Air - Education Savings",
                    url: "https://www.apple.com/us-edu/shop/buy-mac/macbook-air/macbook-air-with-m5-chip",
                    price: 1_199
                ),
                CandoaPagePurchaseCandidate(
                    label: "MacBook Neo - Education Savings",
                    url: "https://www.apple.com/us-edu/shop/buy-mac/macbook-neo",
                    price: 599
                ),
            ]
        }

        guard let tabID else { return [] }
        return await webCoordinator.pagePurchaseCandidates(for: tabID)
    }

    func activeAIPageContext() async -> CandoaAIPageContext {
        await aiPageContext(for: activeTabID)
    }

    func aiPageContext(for tabID: UUID?) async -> CandoaAIPageContext {
        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-contextual-unsafe-followup" {
            return CandoaAIPageContext(
                title: "Buy MacBook Air",
                url: "https://www.apple.com/us-edu/shop/buy-mac/macbook-air",
                text: """
                Full page semantic text:
                MacBook Air configurations with the M5 chip.

                Visible page controls and links:
                - a: Buy Mac or iPad with education savings, get a gift card [visible: top] [url: https://www.apple.com/us-edu/shop/browse/overlay/mac/tradein]
                - a: MacBook Air, 13-inch, M5 Chip, 10-core CPU, 10-core GPU, 16GB memory, 1TB storage [price: 1599] [visible: middle] [url: https://www.apple.com/us-edu/shop/buy-mac/macbook-air/13-inch-m5-16gb-1tb]
                - a: MacBook Air, 15-inch, M5 Chip, 10-core CPU, 10-core GPU, 24GB memory, 1TB storage [price: 1799] [visible: middle] [url: https://www.apple.com/us-edu/shop/buy-mac/macbook-air/15-inch-m5-24gb-1tb]
                """
            )
        }

        if Self.isUITesting,
           ["ask-contextual-purchase", "ask-contextual-followup"].contains(
               ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"]
           ) {
            return CandoaAIPageContext(
                title: "Apple Education Store",
                url: "https://www.apple.com/us-edu/store",
                text: """
                Full page semantic text:
                MacBook Air. From $1,199 with education savings.
                MacBook Pro. From $1,899 with education savings.

                Visible page controls and links:
                - a: MacBook Air [price: 1199] [visible: middle left] [url: https://www.apple.com/us-edu/shop/buy-mac/macbook-air]
                - a: MacBook Pro [price: 1899] [visible: middle center] [url: https://www.apple.com/us-edu/shop/buy-mac/macbook-pro]
                """
            )
        }

        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        let pageText: String?
        let controlsText: String?
        let imageText: String?
        if let tabID = tab?.id {
            await webCoordinator.waitForAIPageContextSettled(for: tabID)
            pageText = await webCoordinator.readablePageText(for: tabID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            controlsText = await webCoordinator.visiblePageControlsText(for: tabID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            imageText = await visiblePageOCRText(for: tabID)
        } else {
            pageText = nil
            controlsText = nil
            imageText = nil
        }
        let pageTextSection = pageText.map { "Full page semantic text:\n\($0)" }
        let imageTextSection = imageText.map { "Visible page image text from OCR:\n\($0)" }
        let combinedText = [pageTextSection, controlsText, imageTextSection]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")

        return CandoaAIPageContext(
            title: tab?.title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: tab?.url?.absoluteString,
            text: combinedText.isEmpty ? nil : combinedText
        )
    }

    func performAIPageAction(_ action: CandoaPageActionProposal, in tabID: UUID?) async -> String {
        guard let tabID, tabs.contains(where: { $0.id == tabID }) else {
            return "That page is no longer open."
        }
        if let expectedURL = action.browserAgentPageURL,
           tabs.first(where: { $0.id == tabID })?.url?.absoluteString != expectedURL {
            return "Candoa stopped because the page changed after it was inspected."
        }

        if action.kind == .navigate {
            guard let url = navigationService.explicitDestinationURL(for: action.target) else {
                return "I could not understand that destination."
            }

            setURL(url, title: title(for: url), for: tabID)
            webCoordinator.load(url, in: tabID)
            return "Navigated to \(url.absoluteString)."
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-navigation",
           action.kind == .click {
            let destination: (path: String, title: String)? = switch action.target {
            case "Account": ("/account", "Account")
            case "Manage Membership": ("/membership", "Membership")
            case "Cancel Membership": ("/cancelled", "Membership Cancelled")
            default: nil
            }
            if let destination,
               let url = URL(string: "https://fixture.candoa.test\(destination.path)") {
                setURL(url, title: destination.title, for: tabID)
                webCoordinator.load(url, in: tabID)
                return "Activated \"\(action.target)\"."
            }
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-contextual-purchase",
           action.kind == .click,
           action.target.localizedCaseInsensitiveContains("MacBook Neo"),
           let url = URL(string: "https://www.apple.com/us-edu/shop/buy-mac/macbook-neo") {
            setURL(url, title: "MacBook Neo", for: tabID)
            return "Clicked \"MacBook Neo - Education Savings\"."
        }

        return await webCoordinator.performAIPageAction(action, for: tabID)
    }

    private func visiblePageOCRText(for tabID: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            webCoordinator.captureVisiblePage(for: tabID) { image in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CandoaImageTextRecognizer.recognizedText(in: image))
            }
        }
    }
}
