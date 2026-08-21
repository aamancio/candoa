import Foundation

extension BrowserStore {
    // MARK: - Space memory

    func activeSpaceMemoryFacts() -> [SpaceMemoryFact] {
        guard !isPrivate else { return [] }
        return persistenceService.spaceMemoryFacts(in: activeSpaceID)
    }

    /// The labeled block Ask and the browser agent carry, or nil when
    /// nothing is saved. Memory is always on outside private browsing —
    /// deliberately no per-Space opt-out, matching sync. Reads only the
    /// active Space, which is what keeps one Space's facts out of another's
    /// requests.
    func activeSpaceMemorySection() -> String? {
        SpaceMemoryPolicy.memoryContextSection(for: activeSpaceMemoryFacts())
    }

    func deleteSpaceMemoryFact(_ id: UUID) {
        persistenceService.deleteSpaceMemoryFact(withID: id)
        objectWillChange.send()
    }

    func deleteActiveSpaceMemory() {
        guard !isPrivate else { return }
        persistenceService.deleteSpaceMemoryFacts(in: activeSpaceID)
        objectWillChange.send()
    }

    /// Runs the memory extraction pass over an Ask conversation. Fire-and-forget:
    /// a failed or malformed extraction leaves existing memory untouched.
    ///
    /// `spaceID` is explicit because the conversation outlives the Space
    /// selection: switching Spaces mid-conversation must distill what was said
    /// before the switch into the Space it was said in, not into the new one.
    func updateSpaceMemory(fromConversation transcript: [AIConversationTurn], in spaceID: UUID? = nil) {
        guard !isPrivate else { return }
        guard transcript.contains(where: { $0.role == .user }) else { return }
        let spaceID = spaceID ?? activeSpaceID
        guard transcript.count > (eliMemoryLastExtractedTurnCounts[spaceID] ?? 0) else { return }

        let existing = persistenceService.spaceMemoryFacts(in: spaceID)

        // UI tests never reach the network: the fixture's canned facts stand
        // in for the extractor's reply, exercising the same sanitize, merge,
        // and persist path.
        if Self.isUITesting {
            guard let fixtureContents = Self.uiTestingMemoryExtractionFacts() else { return }
            eliMemoryLastExtractedTurnCounts[spaceID] = transcript.count
            persistSpaceMemoryUpdate(contents: fixtureContents, existing: existing, spaceID: spaceID)
            return
        }

        guard eliMemoryExtractionTasks[spaceID] == nil else { return }
        eliMemoryLastExtractedTurnCounts[spaceID] = transcript.count
        eliMemoryExtractionTasks[spaceID] = Task { [weak self] in
            let contents = try? await SpaceMemoryExtractor.updatedFactContents(
                existingFacts: existing.map(\.content),
                transcript: transcript
            )
            if let contents {
                self?.persistSpaceMemoryUpdate(contents: contents, existing: existing, spaceID: spaceID)
            }
            self?.eliMemoryExtractionTasks[spaceID] = nil
        }
    }

    /// The mid-conversation pass. Extraction costs a request, so it runs only
    /// when a user turn the extractor has not seen yet actually reads like a
    /// durable personal detail — the everyday "summarize this page"
    /// conversation never triggers it.
    ///
    /// This is what keeps memory from depending on a clean exit: a quit takes
    /// the app down before any extraction request could finish, so anything
    /// that waited for teardown would simply be lost.
    func updateSpaceMemoryIfConversationRevealedFacts(
        _ transcript: [AIConversationTurn],
        in spaceID: UUID? = nil
    ) {
        guard !isPrivate else { return }
        let spaceID = spaceID ?? activeSpaceID
        let alreadySeen = eliMemoryLastExtractedTurnCounts[spaceID] ?? 0
        let fresh = transcript.dropFirst(alreadySeen).filter { $0.role == .user }
        guard fresh.contains(where: { SpaceMemoryPolicy.suggestsDurableFact(in: $0.text) }) else { return }
        updateSpaceMemory(fromConversation: transcript, in: spaceID)
    }

    /// Starts a fresh extraction window for a Space. The turn counts that
    /// guard re-extraction are indexes into the transcript being sent, so a
    /// new conversation — or a conversation that just moved to this Space —
    /// has to reset them or its early turns look already-extracted.
    func resetSpaceMemoryExtractionWindow(for spaceID: UUID) {
        eliMemoryLastExtractedTurnCounts[spaceID] = 0
    }

    private func persistSpaceMemoryUpdate(
        contents: [String],
        existing: [SpaceMemoryFact],
        spaceID: UUID
    ) {
        let sanitized = SpaceMemoryPolicy.sanitizedFactContents(contents)
        // A reply that empties the whole list is indistinguishable from a
        // failed extraction; only the user's Forget All clears memory outright.
        guard !sanitized.isEmpty || existing.isEmpty else { return }
        persistenceService.replaceSpaceMemoryFacts(
            with: SpaceMemoryExtractor.mergedFacts(
                contents: sanitized,
                existing: existing,
                spaceID: spaceID
            ),
            in: spaceID
        )
        objectWillChange.send()
    }
    func browserAgentPage(for tabID: UUID?) async -> BrowserAgentPage? {
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

        let pageText = await webCoordinator.readablePageText(for: tabID) ?? ""
        guard let snapshot = await webCoordinator.browserAgentSnapshot(for: tabID) else { return nil }
        return BrowserAgentPage(
            snapshotID: snapshot.id,
            title: tab.title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.absoluteString,
            text: String(pageText.prefix(16_000)),
            controls: snapshot.controls,
            tree: snapshot.tree,
            viewport: snapshot.viewport
        )
    }

    /// Gives a tab the agent just activated a bounded window to be usable:
    /// the mentioned tab may have been hibernated, so its web view can still
    /// be mounting and loading when the run wants its first snapshot.
    func wakeBrowserAgentTab(_ tabID: UUID) async {
        for _ in 0..<20 {
            guard !Task.isCancelled else { return }
            if webCoordinator.hasLoadedWebView(for: tabID) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await webCoordinator.waitForAIPageContextSettled(for: tabID)
    }

    func startBrowserAgentRun(
        runID: UUID,
        goal: String,
        page: BrowserAgentPage,
        attachedContext: String?
    ) async throws -> BrowserAgentRunResponse {
        if let fixture = fixtureBrowserAgentResponse(runID: runID, goal: goal, page: page, outcome: nil) {
            return fixture
        }
        return try await BrowserAgentRemoteService.start(
            runID: runID,
            goal: goal,
            page: page,
            attachedContext: attachedContext
        )
    }

    func resumeBrowserAgentRun(
        runID: UUID,
        goal: String,
        outcome: BrowserAgentActionOutcome
    ) async throws -> BrowserAgentRunResponse {
        if let page = outcome.page,
           let fixture = fixtureBrowserAgentResponse(runID: runID, goal: goal, page: page, outcome: outcome) {
            return fixture
        }
        return try await BrowserAgentRemoteService.resume(runID: runID, outcome: outcome)
    }

    private func fixtureBrowserAgentResponse(
        runID: UUID,
        goal: String,
        page: BrowserAgentPage,
        outcome: BrowserAgentActionOutcome?
    ) -> BrowserAgentRunResponse? {
        guard Self.isUITesting,
              let fixture = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"],
              [
                  "ask-agent-navigation", "ask-agent-normalized-navigation", "ask-agent-selection",
                  "ask-agent-mentioned-tab", "ask-agent-waiting", "ask-agent-form-fill"
              ].contains(fixture) else { return nil }
        let pageURL = URL(string: page.url)
        let path = pageURL?.fragment.map { "/\($0)" } ?? pageURL?.path

        if fixture == "ask-agent-waiting" {
            if outcome == nil {
                return .init(
                    runID: runID,
                    status: .waiting,
                    message: "An ad is playing. Skip it or let it finish, then continue.",
                    action: nil
                )
            }
            if outcome?.status == .resumed {
                return .init(
                    runID: runID,
                    status: .complete,
                    message: "The video is playing.",
                    action: nil
                )
            }
            return .init(
                runID: runID,
                status: .complete,
                message: "I stopped there.",
                action: nil
            )
        }

        if fixture == "ask-agent-mentioned-tab" {
            if path == "/home", let control = page.controls.first {
                return fixtureActionResponse(
                    runID: runID,
                    page: page,
                    control: control,
                    kind: .click,
                    message: "Opening your account page."
                )
            }
            return .init(
                runID: runID,
                status: .complete,
                message: "Your account page is open in the membership tab.",
                action: nil
            )
        }

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
                return BrowserAgentRunResponse(
                    runID: runID,
                    status: .action,
                    message: "Scroll to reveal the remaining laptop configuration options.",
                    action: BrowserAgentAction(
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

        // Fills one personal field per turn, the way a real run does, then
        // submits. The page reports which fields are already filled, so the
        // fixture stays stateless between turns.
        if fixture == "ask-agent-form-fill" {
            let filled = page.text
                .range(of: #"filled=(\d+)"#, options: .regularExpression)
                .map { Int(page.text[$0].dropFirst("filled=".count)) ?? 0 } ?? 0
            let personalFields = page.controls.filter { $0.kind == .field && $0.sensitive }
            if filled < personalFields.count {
                return fixtureActionResponse(
                    runID: runID,
                    page: page,
                    control: personalFields[filled],
                    kind: .fill,
                    value: Self.uiTestingFormFillValues[filled]
                )
            }
            if let submit = page.controls.first(where: { $0.label == "Submit Application" }),
               !page.text.contains("submitted") {
                return fixtureActionResponse(runID: runID, page: page, control: submit, kind: .click)
            }
            return .init(
                runID: runID,
                status: .complete,
                message: "Your application is submitted.",
                action: nil
            )
        }

        if fixture == "ask-agent-selection" {
            let normalizedGoal = EliPromptPolicy.normalizedText(goal)
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

    /// Canned values for the form-fill fixture, in the page's field order.
    static let uiTestingFormFillValues = [
        "Alex Fixture",
        "alex@fixture.test",
        "5550000000",
    ]

    private func fixtureActionResponse(
        runID: UUID,
        page: BrowserAgentPage,
        control: BrowserAgentControl,
        kind: PageActionKind,
        message: String = "",
        value: String = "",
        requiresApproval: Bool = false
    ) -> BrowserAgentRunResponse {
        BrowserAgentRunResponse(
            runID: runID,
            status: .action,
            message: message,
            action: BrowserAgentAction(
                snapshotID: page.snapshotID,
                kind: kind,
                target: control.ref,
                value: value,
                label: control.label,
                url: control.url,
                requiresApproval: requiresApproval,
                message: message
            )
        )
    }

    @discardableResult
    func waitForBrowserAgentPageSettled(in tabID: UUID, previousURL: String) async -> Int? {
        await webCoordinator.waitForBrowserAgentPageSettled(for: tabID, previousURL: previousURL)
    }

    /// The bounded slice of the page Eli's chip personalizer reads (issue
    /// #467): readable text only, no OCR and no controls, cut to a few
    /// hundred characters before it reaches the on-device model.
    func eliSuggestionExcerpt(for tabID: UUID?) async -> String {
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        var pageText: String?
        if let tabID = tab?.id {
            await webCoordinator.waitForAIPageContextSettled(for: tabID)
            pageText = await webCoordinator.readablePageText(for: tabID)
        }
        return EliSuggestionCatalog.excerpt(title: tab?.title, url: tab?.url, pageText: pageText)
    }

    func activeAIPageContext() async -> AIPageContext {
        await aiPageContext(for: activeTabID)
    }

    func aiPageContext(for tabID: UUID?) async -> AIPageContext {
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

        return AIPageContext(
            title: tab?.title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: tab?.url?.absoluteString,
            text: combinedText.isEmpty ? nil : combinedText
        )
    }

    func performAIPageAction(_ action: PageActionProposal, in tabID: UUID?) async -> PageActionResult {
        guard let tabID, tabs.contains(where: { $0.id == tabID }) else {
            return .failed("That page is no longer open.")
        }
        if let expectedURL = action.browserAgentPageURL,
           tabs.first(where: { $0.id == tabID })?.url?.absoluteString != expectedURL {
            return .failed("Candoa stopped because the page changed after it was inspected.")
        }

        if action.kind == .navigate {
            // The target is a snapshot link's URL or a validated absolute
            // http/https destination (direct URL navigation); either way the
            // load happens natively in the tab, like typed navigation.
            guard let url = navigationService.explicitDestinationURL(for: action.target) else {
                return .failed("I could not understand that destination.")
            }

            setURL(url, title: title(for: url), for: tabID)
            webCoordinator.load(url, in: tabID)
            return .executed("Navigated to \(url.absoluteString).")
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

                continuation.resume(returning: ImageTextRecognizer.recognizedText(in: image))
            }
        }
    }
}
