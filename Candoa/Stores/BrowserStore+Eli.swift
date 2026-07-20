import Foundation

extension BrowserStore {
    func browserAgentPage(for tabID: UUID?) async -> CandoaBrowserAgentPage? {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }), let url = tab.url else {
            return nil
        }

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
            return CandoaBrowserAgentPage(
                title: tab.title,
                url: url.absoluteString,
                text: labels.joined(separator: "\n"),
                controls: labels.map {
                    CandoaBrowserAgentControl(kind: .button, label: $0, url: nil, disabled: false)
                }
            )
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-normalized-navigation" {
            let controls: [CandoaBrowserAgentControl] = URL(string: url.absoluteString)?.path == "/air"
                ? [CandoaBrowserAgentControl(
                    kind: .link,
                    label: "Buy MacBook Air",
                    url: "https://fixture.candoa.test/buy",
                    disabled: false
                )]
                : []
            return CandoaBrowserAgentPage(
                title: tab.title,
                url: url.absoluteString,
                text: controls.map(\.label).joined(separator: "\n"),
                controls: controls
            )
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-selection" {
            let controls: [CandoaBrowserAgentControl] = switch url.path {
            case "/configure": [
                CandoaBrowserAgentControl(kind: .choice, label: "Sky Blue", url: nil, disabled: false)
            ]
            case "/configured": [
                CandoaBrowserAgentControl(kind: .button, label: "Add to Cart", url: nil, disabled: false)
            ]
            case "/cart": [
                CandoaBrowserAgentControl(kind: .button, label: "Remove", url: nil, disabled: false)
            ]
            default: []
            }
            return CandoaBrowserAgentPage(
                title: tab.title,
                url: url.absoluteString,
                text: url.path == "/cart" ? "MacBook Air is in your cart." : controls.map(\.label).joined(separator: "\n"),
                controls: controls
            )
        }

        let pageText = await webCoordinator.readablePageText(for: tabID) ?? ""
        let controls = await webCoordinator.browserAgentControls(for: tabID)
        return CandoaBrowserAgentPage(
            title: tab.title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.absoluteString,
            text: String(pageText.prefix(16_000)),
            controls: controls
        )
    }

    func nextBrowserAgentStep(
        goal: String,
        page: CandoaBrowserAgentPage,
        history: [CandoaBrowserAgentHistoryItem]
    ) async throws -> CandoaBrowserAgentDecision {
        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-navigation" {
            switch URL(string: page.url)?.path {
            case "/home":
                return .init(status: .act, kind: .click, target: "Account", value: "", message: "")
            case "/account":
                return .init(status: .act, kind: .click, target: "Manage Membership", value: "", message: "")
            case "/membership":
                return .init(status: .act, kind: .click, target: "Cancel Membership", value: "", message: "")
            default:
                return .init(
                    status: .complete,
                    kind: .none,
                    target: "",
                    value: "",
                    message: "Your membership has been cancelled."
                )
            }
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-normalized-navigation" {
            if URL(string: page.url)?.path == "/air" {
                return .init(
                    status: .act,
                    kind: .navigate,
                    target: "Buy MacBook Air",
                    value: "https://fixture.candoa.test/buy",
                    message: "Opening the MacBook Air buying page."
                )
            }
            if history.last?.kind == .navigate {
                return .init(
                    status: .act,
                    kind: .scroll,
                    target: "page",
                    value: "",
                    message: "Scroll to reveal the remaining laptop configuration options."
                )
            }
            return .init(
                status: .complete,
                kind: .none,
                target: "",
                value: "",
                message: "The MacBook Air buying page is open."
            )
        }


        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-selection" {
            switch URL(string: page.url)?.path {
            case "/configure":
                return .init(status: .act, kind: .click, target: "Sky Blue", value: "", message: "")
            case "/configured":
                return .init(status: .act, kind: .click, target: "Add to Cart", value: "", message: "")
            case "/cart" where CandoaEliPromptPolicy.normalizedText(goal).contains("remove"):
                return .init(status: .act, kind: .click, target: "Remove", value: "", message: "")
            default:
                return .init(
                    status: .complete,
                    kind: .none,
                    target: "",
                    value: "",
                    message: URL(string: page.url)?.path == "/removed"
                        ? "The MacBook Air was removed from your cart."
                        : "The MacBook Air is in your cart."
                )
            }
        }

        return try await CandoaBrowserAgentRemoteService.nextStep(
            goal: goal,
            page: page,
            history: history
        )
    }

    func waitForBrowserAgentPageSettled(in tabID: UUID, previousURL: String) async {
        if Self.isUITesting,
           ["ask-agent-navigation", "ask-agent-normalized-navigation", "ask-agent-selection"].contains(
               ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"]
           ) {
            return
        }
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
                return "Activated \"\(action.target)\"."
            }
        }

        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] == "ask-agent-selection" {
            let destination: (path: String, title: String)? = switch (action.kind, action.target) {
            case (.select, "Sky Blue"): ("/configured", "Configured MacBook Air")
            case (.click, "Sky Blue"): ("/configured", "Configured MacBook Air")
            case (.click, "Add to Cart"): ("/cart", "Shopping Cart")
            case (.click, "Remove"): ("/removed", "Empty Shopping Cart")
            default: nil
            }
            if let destination,
               let url = URL(string: "https://fixture.candoa.test\(destination.path)") {
                setURL(url, title: destination.title, for: tabID)
                return action.kind == .select
                    ? "Selected \"\(action.target)\"."
                    : "Clicked \"\(action.target)\"."
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
