import XCTest
@testable import Candoa

/// Unit coverage for Ask's pure request-shaping logic (issue #48): context
/// budgeting, reasoning clamping, catalog validation and hosted-metadata
/// merging, and origin-key normalization. Everything here is side-effect
/// free — persistence and streaming stay covered by the UI test suite.
final class CandoaTests: XCTestCase {
    // MARK: - Context budgeting

    private let smallModel = AIModel(
        id: "test/small",
        provider: .openai,
        displayName: "Small",
        contextWindowTokens: 4_000,
        maxOutputTokens: 1_000,
        supportedEfforts: [.low]
    )

    private func makeContext(text: String) -> AIPageContext {
        AIPageContext(title: "Title", url: "https://example.com", text: text)
    }

    func testBudgetPassesContextThroughWithoutModel() throws {
        let context = makeContext(text: String(repeating: "a", count: 100_000))
        let fitted = try EliContextBudget.fittedContext(
            context, prompt: "q", recentTurns: [], model: nil
        )
        XCTAssertEqual(fitted.text, context.text)
    }

    func testBudgetKeepsFittingContextIntact() throws {
        let context = makeContext(text: "short page text")
        let fitted = try EliContextBudget.fittedContext(
            context, prompt: "q", recentTurns: [], model: smallModel
        )
        XCTAssertEqual(fitted.text, "short page text")
    }

    func testBudgetTruncatesOversizedContextDeterministically() throws {
        let context = makeContext(text: String(repeating: "x", count: 50_000))
        let prompt = "question"

        let first = try EliContextBudget.fittedContext(
            context, prompt: prompt, recentTurns: [], model: smallModel
        )
        let second = try EliContextBudget.fittedContext(
            context, prompt: prompt, recentTurns: [], model: smallModel
        )

        // (4000 - 1000) tokens * 3 chars - 6000 overhead, minus the fixed
        // prompt/title/url characters — the exact budget the type computes.
        let characterBudget = (4_000 - 1_000) * 3 - 6_000
        let fixed = prompt.count + "Title".count + "https://example.com".count
        let expected = characterBudget - fixed

        XCTAssertEqual(first.text?.count, expected)
        XCTAssertEqual(first.text, second.text, "truncation must be deterministic")
        XCTAssertEqual(first.title, context.title)
        XCTAssertEqual(first.url, context.url)
    }

    func testBudgetThrowsWhenFixedInputCannotFit() {
        let context = makeContext(text: "page")
        let hugePrompt = String(repeating: "p", count: 10_000)

        XCTAssertThrowsError(
            try EliContextBudget.fittedContext(
                context, prompt: hugePrompt, recentTurns: [], model: smallModel
            )
        ) { error in
            XCTAssertTrue(error is EliContextBudgetError)
        }
    }

    func testBudgetCountsOnlyTheSixNewestTurns() throws {
        // Seven turns that would each overflow the small model alone; only
        // the newest six may count, and they are sized to fit exactly.
        let oldOverflowingTurn = AIConversationTurn(
            role: .user, text: String(repeating: "o", count: 100_000)
        )
        let recentTurns = [oldOverflowingTurn] + (0..<6).map { index in
            AIConversationTurn(role: .user, text: "turn \(index)")
        }

        XCTAssertNoThrow(
            try EliContextBudget.fittedContext(
                makeContext(text: "page"), prompt: "q",
                recentTurns: recentTurns, model: smallModel
            )
        )
    }

    // MARK: - Reasoning clamping

    func testClampedEffortKeepsSupportedValues() {
        let model = AIModel(
            id: "test/m", provider: .openai, displayName: "M",
            contextWindowTokens: 1, maxOutputTokens: 1,
            supportedEfforts: [.low, .medium, .high]
        )
        XCTAssertEqual(model.clampedEffort(.high), .high)
        XCTAssertEqual(model.clampedEffort(.low), .low)
    }

    func testClampedEffortFallsBackToFirstSupported() {
        let lowOnly = AIModel(
            id: "test/m", provider: .google, displayName: "M",
            contextWindowTokens: 1, maxOutputTokens: 1,
            supportedEfforts: [.low]
        )
        XCTAssertEqual(lowOnly.clampedEffort(.high), .low)

        let none = AIModel(
            id: "test/m", provider: .google, displayName: "M",
            contextWindowTokens: 1, maxOutputTokens: 1,
            supportedEfforts: []
        )
        XCTAssertEqual(none.clampedEffort(.medium), .low)
    }

    // MARK: - Catalog validation and hosted-metadata merging

    func testHostedModelUnknownIDGetsConservativeDefaults() {
        let model = AIModelCatalog.hostedModel(
            id: "openai/brand-new-model", providerID: "openai", displayName: "New"
        )
        XCTAssertEqual(model.contextWindowTokens, 128_000)
        XCTAssertEqual(model.maxOutputTokens, 16_000)
        XCTAssertEqual(model.supportedEfforts, [.low, .medium, .high])
        XCTAssertNil(model.creditCost)
    }

    func testHostedModelBackfillsCuratedMetadata() {
        let model = AIModelCatalog.hostedModel(
            id: "anthropic/claude-haiku-4-5", providerID: "", displayName: "Haiku"
        )
        XCTAssertEqual(model.provider, .anthropic, "curated provider wins over an empty provider ID")
        XCTAssertEqual(model.contextWindowTokens, 200_000)
        XCTAssertEqual(model.maxOutputTokens, 64_000)
        XCTAssertEqual(model.supportedEfforts, [.low])
    }

    func testHostedModelServerMetadataWinsOverCurated() {
        let model = AIModelCatalog.hostedModel(
            id: "anthropic/claude-haiku-4-5", providerID: "anthropic",
            displayName: "Haiku", contextWindowTokens: 300_000,
            maxOutputTokens: 32_000, supportedEfforts: [.low, .medium],
            creditCost: 2
        )
        XCTAssertEqual(model.contextWindowTokens, 300_000)
        XCTAssertEqual(model.maxOutputTokens, 32_000)
        XCTAssertEqual(model.supportedEfforts, [.low, .medium])
        XCTAssertEqual(model.creditCost, 2)
    }

    func testCuratedCatalogInvariants() {
        for provider in AIProvider.allCases {
            XCTAssertFalse(
                AIModelCatalog.directModels(for: provider).isEmpty,
                "\(provider) must offer at least one BYOK model"
            )
            let defaultModel = AIModelCatalog.directDefaultModel(for: provider)
            XCTAssertEqual(defaultModel.provider, provider)
        }
        for model in AIModelCatalog.directModels {
            XCTAssertEqual(AIModelCatalog.model(forID: model.id)?.id, model.id)
            XCTAssertTrue(model.id.hasPrefix("\(model.provider.rawValue)/"))
            XCTAssertFalse(model.bareModelID.contains("/"))
            XCTAssertGreaterThan(model.contextWindowTokens, model.maxOutputTokens)
            XCTAssertFalse(model.supportedEfforts.isEmpty)
        }
    }

    // MARK: - Site permission origin keys (pure normalization)

    func testOriginKeyFoldsDefaultPorts() {
        XCTAssertEqual(
            SitePermissionConfiguration.originKey(for: URL(string: "https://Example.com/page")!),
            "https://example.com:443"
        )
        XCTAssertEqual(
            SitePermissionConfiguration.originKey(for: URL(string: "http://example.com")!),
            "http://example.com:80"
        )
        XCTAssertEqual(
            SitePermissionConfiguration.originKey(for: URL(string: "https://example.com:8443")!),
            "https://example.com:8443"
        )
        XCTAssertNil(SitePermissionConfiguration.originKey(for: URL(string: "file:///tmp/x")!))
        // WKSecurityOrigin reports the default port as 0.
        XCTAssertEqual(
            SitePermissionConfiguration.originKey(scheme: "HTTPS", host: "Example.com", port: 0),
            "https://example.com:443"
        )
    }

    func testPermissionDecisionsParseFromStoredOverrides() {
        let stored = #"{"https://example.com:443":{"popup-windows":"deny","camera":"allow"}}"#
        let url = URL(string: "https://example.com/")!

        XCTAssertEqual(
            SitePermissionConfiguration.decision(for: .popupWindows, url: url, storedOverrides: stored),
            .deny
        )
        XCTAssertEqual(
            SitePermissionConfiguration.decision(for: .camera, url: url, storedOverrides: stored),
            .allow
        )
        // Unstored permissions and garbage payloads fall back to defaults.
        XCTAssertEqual(
            SitePermissionConfiguration.decision(for: .microphone, url: url, storedOverrides: stored),
            .ask
        )
        XCTAssertEqual(
            SitePermissionConfiguration.decision(for: .popupWindows, url: url, storedOverrides: "not json"),
            .allow
        )
    }
}

/// Unit coverage for Eli's per-Space memory (issue #292): the sanitization
/// gate, extractor reply parsing, merge semantics, and context injection.
/// All pure logic — persistence and the popover stay with the UI tests.
final class SpaceMemoryTests: XCTestCase {
    private let spaceID = UUID()

    // MARK: - Sanitization gate

    func testSanitizationKeepsOrdinaryFacts() {
        let facts = SpaceMemoryPolicy.sanitizedFactContents([
            "The user's name is Alex.",
            "The user is applying for engineering jobs.",
            "  The user prefers dark mode.  ",
        ])
        XCTAssertEqual(facts, [
            "The user's name is Alex.",
            "The user is applying for engineering jobs.",
            "The user prefers dark mode.",
        ])
    }

    func testSanitizationDropsSecretsAndIdentificationNumbers() {
        let facts = SpaceMemoryPolicy.sanitizedFactContents([
            "The user's password is hunter2.",
            "The user's card number is 4111 1111 1111 1111.",
            "The user's SSN is 123-45-6789.",
            "The user's API key is sk-abcdefghijklmnop1234.",
            "The user's token is dGhpc2lzYXZlcnlsb25nb3BhcXVldG9rZW52YWx1ZQ.",
            "The user lives in Lisbon.",
        ])
        XCTAssertEqual(facts, ["The user lives in Lisbon."])
    }

    func testSanitizationDeduplicatesCapsAndDropsOversizedFacts() {
        let oversized = String(repeating: "a", count: SpaceMemoryPolicy.maximumFactLength + 1)
        let many = (0..<40).map { "The user likes hobby number \($0)." }
        let facts = SpaceMemoryPolicy.sanitizedFactContents(
            [oversized, "The user hikes.", "the user hikes.", ""] + many
        )
        XCTAssertEqual(facts.count, SpaceMemoryPolicy.maximumFactCount)
        XCTAssertEqual(facts.filter { $0.lowercased() == "the user hikes." }.count, 1)
        XCTAssertFalse(facts.contains(oversized))
    }

    // MARK: - Extractor reply parsing

    func testParsingAcceptsBareFencedAndProseWrappedArrays() {
        let bare = #"["The user hikes."]"#
        let fenced = "```json\n[\"The user hikes.\"]\n```"
        let prose = #"Here is the updated list: ["The user hikes."] Let me know!"#
        for response in [bare, fenced, prose] {
            XCTAssertEqual(
                SpaceMemoryExtractor.parseFactContents(from: response),
                ["The user hikes."],
                response
            )
        }
        XCTAssertEqual(SpaceMemoryExtractor.parseFactContents(from: "[]"), [])
    }

    func testParsingRejectsRepliesWithoutAValidStringArray() {
        XCTAssertNil(SpaceMemoryExtractor.parseFactContents(from: "I could not update the list."))
        XCTAssertNil(SpaceMemoryExtractor.parseFactContents(from: #"[1, 2, 3]"#))
        XCTAssertNil(SpaceMemoryExtractor.parseFactContents(from: #"["unterminated"#))
    }

    // MARK: - Merge semantics

    func testMergePreservesIdentityOfUnchangedFactsAndMintsNewOnes() {
        let kept = SpaceMemoryFact(spaceID: spaceID, content: "The user hikes.")
        let dropped = SpaceMemoryFact(spaceID: spaceID, content: "The user is job hunting.")
        let merged = SpaceMemoryExtractor.mergedFacts(
            contents: ["The user hikes.", "The user found a job."],
            existing: [kept, dropped],
            spaceID: spaceID
        )
        XCTAssertEqual(merged.map(\.content), ["The user hikes.", "The user found a job."])
        XCTAssertEqual(merged[0].id, kept.id)
        XCTAssertEqual(merged[0].createdAt, kept.createdAt)
        XCTAssertNotEqual(merged[1].id, dropped.id)
        XCTAssertTrue(merged.allSatisfy { $0.spaceID == spaceID })
    }

    // MARK: - Mid-conversation extraction gate

    func testGateFiresOnDurableDetailsAcrossShippingLocales() {
        let openings = [
            "My name is Alex and I need help here",
            "i work at a small design studio",
            "I live in Lisbon now",
            "I prefer dark mode everywhere",
            "Remember that I use metric units",
            "I'm learning Swift concurrency",
            "Mein Name ist Alex",
            "Me llamo Alex y trabajo en Madrid",
            "Je m'appelle Alex",
            "Meu nome é Alex",
            "私の名前はアレックスです",
            "我叫亚历克斯",
        ]
        for opening in openings {
            XCTAssertTrue(
                SpaceMemoryPolicy.suggestsDurableFact(in: opening),
                "expected a durable-fact signal in: \(opening)"
            )
        }
    }

    func testGateIgnoresOrdinaryBrowsingQuestions() {
        let ordinary = [
            "Summarize this page",
            "What is this article about?",
            "Translate the third paragraph",
            "Find the pricing table and explain it",
            "Open the docs in a new tab",
            "",
            "   ",
        ]
        for prompt in ordinary {
            XCTAssertFalse(
                SpaceMemoryPolicy.suggestsDurableFact(in: prompt),
                "expected no extraction request for: \(prompt)"
            )
        }
    }

    // MARK: - Context injection

    func testMemorySectionListsFactsAndIsNilWhenEmpty() {
        XCTAssertNil(SpaceMemoryPolicy.memoryContextSection(for: []))
        let section = SpaceMemoryPolicy.memoryContextSection(for: [
            SpaceMemoryFact(spaceID: spaceID, content: "The user hikes."),
        ])
        XCTAssertNotNil(section)
        XCTAssertTrue(section?.contains("- The user hikes.") == true)
        XCTAssertTrue(section?.contains("not page content") == true)
    }

    func testInjectionPrependsMemoryAndPreservesTitleAndURL() {
        let context = AIPageContext(title: "Title", url: "https://example.com", text: "Page text")
        let injected = SpaceMemoryPolicy.contextByPrependingMemory("Memory block", to: context)
        XCTAssertEqual(injected.title, "Title")
        XCTAssertEqual(injected.url, "https://example.com")
        XCTAssertEqual(injected.text, "Memory block\n\nPage text")
        XCTAssertTrue(injected.text?.hasPrefix("Memory block") == true, "memory must lead so prefix truncation keeps it")

        let noMemory = SpaceMemoryPolicy.contextByPrependingMemory(nil, to: context)
        XCTAssertEqual(noMemory.text, "Page text")

        let noPage = AIPageContext(title: nil, url: nil, text: nil)
        XCTAssertEqual(SpaceMemoryPolicy.contextByPrependingMemory("Memory block", to: noPage).text, "Memory block")
    }

    func testAgentContextInjectionJoinsAndCaps() {
        XCTAssertNil(SpaceMemoryPolicy.agentContextByPrependingMemory(nil, to: nil))
        XCTAssertEqual(
            SpaceMemoryPolicy.agentContextByPrependingMemory("Memory", to: "Agent context"),
            "Memory\n\nAgent context"
        )
        XCTAssertEqual(
            SpaceMemoryPolicy.agentContextByPrependingMemory("Memory", to: nil),
            "Memory"
        )
        let capped = SpaceMemoryPolicy.agentContextByPrependingMemory(
            "Memory",
            to: String(repeating: "x", count: 30_000)
        )
        XCTAssertEqual(capped?.count, 20_000)
        XCTAssertTrue(capped?.hasPrefix("Memory") == true)
    }

    // MARK: - Extraction prompt

    func testExtractionPromptCarriesFactsTranscriptAndSafetyRules() {
        let prompt = SpaceMemoryExtractor.extractionPrompt(
            existingFacts: ["The user hikes."],
            transcript: [
                AIConversationTurn(role: .user, text: "I'm applying for jobs."),
                AIConversationTurn(role: .assistant, text: "Good luck!"),
            ]
        )
        XCTAssertTrue(prompt.contains("- The user hikes."))
        XCTAssertTrue(prompt.contains("User: I'm applying for jobs."))
        XCTAssertTrue(prompt.contains("Eli: Good luck!"))
        XCTAssertTrue(prompt.contains("NEVER include passwords"))
        XCTAssertTrue(prompt.contains("JSON array of strings"))
    }

}

/// The form-fill profile: user-entered, carried only where it is needed.
final class UserProfileTests: XCTestCase {
    private let snapshotID = UUID()

    private func page(sensitiveField: Bool) -> BrowserAgentPage {
        BrowserAgentPage(
            snapshotID: snapshotID,
            title: "Page",
            url: "https://example.com",
            text: "",
            controls: [
                BrowserAgentControl(
                    ref: "e0",
                    kind: sensitiveField ? .field : .button,
                    label: "Email",
                    url: nil,
                    disabled: false,
                    sensitive: sensitiveField
                )
            ]
        )
    }

    private var profile: UserProfile {
        var profile = UserProfile()
        profile.givenName = "Alex"
        profile.familyName = "Fixture"
        profile.email = "alex@example.com"
        return profile
    }

    func testProfileTravelsOnlyWhenThePageAsksForPersonalDetails() {
        XCTAssertNil(UserProfilePolicy.profileSection(for: profile, page: page(sensitiveField: false)))
        XCTAssertNotNil(UserProfilePolicy.profileSection(for: profile, page: page(sensitiveField: true)))
    }

    func testEmptyProfileAddsNothing() {
        XCTAssertNil(UserProfilePolicy.profileSection(for: UserProfile(), page: page(sensitiveField: true)))
        XCTAssertEqual(
            UserProfilePolicy.agentContext("Goal context", byAppendingProfile: UserProfile(), for: page(sensitiveField: true)),
            "Goal context"
        )
    }

    func testSectionListsFilledValuesAndForbidsInvention() {
        let section = UserProfilePolicy.profileSection(for: profile, page: page(sensitiveField: true))
        XCTAssertTrue(section?.contains("- Email: alex@example.com") == true)
        XCTAssertTrue(section?.contains("- Full name: Alex Fixture") == true, "derived from the two name fields")
        XCTAssertFalse(section?.contains("Phone") == true, "a blank field is not offered to the model")
        XCTAssertTrue(section?.contains("never invent") == true)
    }

    func testValuesAreLengthCapped() {
        var profile = UserProfile()
        profile.organization = String(repeating: "a", count: UserProfilePolicy.maximumValueLength + 50)
        let value = profile.labeledValues.first { $0.label == "Organization" }?.value
        XCTAssertEqual(value?.count, UserProfilePolicy.maximumValueLength)
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "candoa.tests.profile"))
        defaults.removePersistentDomain(forName: "candoa.tests.profile")
        XCTAssertTrue(UserProfileStore.load(from: defaults).isEmpty)
        UserProfileStore.save(profile, to: defaults)
        XCTAssertEqual(UserProfileStore.load(from: defaults), profile)
        defaults.removePersistentDomain(forName: "candoa.tests.profile")
    }
}

/// Page-scoped fill consent: one approval covers a form's remaining fields,
/// and covers nothing else.
final class BrowserAgentFillConsentTests: XCTestCase {
    private let runID = UUID()
    private let tabID = UUID()
    private let snapshotID = UUID()
    private let pageURL = "https://jobs.example.com/apply"

    private func page(url: String? = nil) -> BrowserAgentPage {
        BrowserAgentPage(
            snapshotID: snapshotID,
            title: "Apply",
            url: url ?? pageURL,
            text: "",
            controls: [
                BrowserAgentControl(ref: "e0", kind: .field, label: "Email", url: nil, disabled: false, sensitive: true),
                BrowserAgentControl(ref: "e1", kind: .button, label: "Submit", url: nil, disabled: false, sensitive: true),
                BrowserAgentControl(ref: "e2", kind: .field, label: "Search", url: nil, disabled: false, sensitive: false),
            ]
        )
    }

    private func action(
        _ kind: PageActionKind,
        target: String,
        requiresApproval: Bool = false
    ) -> BrowserAgentAction {
        BrowserAgentAction(
            snapshotID: snapshotID,
            kind: kind,
            target: target,
            value: "alex@example.com",
            label: "Email",
            url: nil,
            requiresApproval: requiresApproval,
            message: ""
        )
    }

    private var consent: BrowserAgentFillConsent {
        BrowserAgentFillConsent(runID: runID, tabID: tabID, url: pageURL)
    }

    private func requiresApproval(
        _ action: BrowserAgentAction,
        on page: BrowserAgentPage,
        consent: BrowserAgentFillConsent?
    ) -> Bool {
        BrowserAgentPolicy.requiresNativeApproval(
            for: action,
            on: page,
            fillConsent: consent,
            runID: runID,
            tabID: tabID
        )
    }

    func testWithoutConsentEveryPersonalFillIsConfirmed() {
        XCTAssertTrue(requiresApproval(action(.fill, target: "e0"), on: page(), consent: nil))
    }

    func testConsentCoversFurtherFillsOnTheSamePage() {
        XCTAssertFalse(requiresApproval(action(.fill, target: "e0"), on: page(), consent: consent))
    }

    func testConsentNeverCoversTheSubmitButton() {
        XCTAssertTrue(
            requiresApproval(action(.click, target: "e1"), on: page(), consent: consent),
            "agreeing to have a form filled is not agreeing to send it"
        )
    }

    func testConsentDoesNotSurviveNavigationOrAnotherRun() {
        XCTAssertTrue(
            requiresApproval(action(.fill, target: "e0"), on: page(url: "https://jobs.example.com/apply/step-2"), consent: consent),
            "a new page must ask again"
        )
        let otherRun = BrowserAgentFillConsent(runID: UUID(), tabID: tabID, url: pageURL)
        XCTAssertTrue(requiresApproval(action(.fill, target: "e0"), on: page(), consent: otherRun))
        let otherTab = BrowserAgentFillConsent(runID: runID, tabID: UUID(), url: pageURL)
        XCTAssertTrue(requiresApproval(action(.fill, target: "e0"), on: page(), consent: otherTab))
    }

    func testModelApprovalFlagOutranksConsent() {
        XCTAssertTrue(
            requiresApproval(action(.fill, target: "e0", requiresApproval: true), on: page(), consent: consent),
            "the model's judgment is a floor the consent cannot lower"
        )
    }

    func testNonSensitiveFieldsNeverNeededApprovalAnyway() {
        XCTAssertFalse(requiresApproval(action(.fill, target: "e2"), on: page(), consent: nil))
    }

    func testOnlyFieldFillsOfferThePageScopedOption() {
        XCTAssertTrue(
            BrowserAgentPolicy.allowsPageScopedFillConsent(
                for: PageActionProposal(kind: .fill, target: "Email", value: "a@b.c", browserAgentControlKind: .field)
            )
        )
        XCTAssertFalse(
            BrowserAgentPolicy.allowsPageScopedFillConsent(
                for: PageActionProposal(kind: .click, target: "Submit", value: nil, browserAgentControlKind: .button)
            )
        )
    }
}

/// Address-bar scheme selection: bare hosts default to HTTPS, except
/// localhost and loopback hosts, which Safari defaults to plain HTTP.
final class NavigationSchemeTests: XCTestCase {
    private let service = NavigationService()

    private func destination(_ input: String) -> String? {
        service.destinationURL(for: input)?.absoluteString
    }

    func testBareHostsDefaultToHTTPS() {
        XCTAssertEqual(destination("example.com"), "https://example.com")
        XCTAssertEqual(destination("example.com/path"), "https://example.com/path")
    }

    func testLocalhostDefaultsToHTTP() {
        XCTAssertEqual(destination("localhost"), "http://localhost")
        XCTAssertEqual(destination("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(destination("localhost:8080/admin"), "http://localhost:8080/admin")
        XCTAssertEqual(destination("app.localhost:3000"), "http://app.localhost:3000")
    }

    func testLoopbackAddressesDefaultToHTTP() {
        XCTAssertEqual(destination("127.0.0.1"), "http://127.0.0.1")
        XCTAssertEqual(destination("127.0.0.1:3000"), "http://127.0.0.1:3000")
        XCTAssertEqual(destination("0.0.0.0:8080"), "http://0.0.0.0:8080")
    }

    func testExplicitSchemeIsPreserved() {
        XCTAssertEqual(destination("https://localhost:8443"), "https://localhost:8443")
        XCTAssertEqual(destination("http://example.com"), "http://example.com")
    }

    func testNonLoopbackAddressesStayHTTPS() {
        XCTAssertEqual(destination("192.168.1.10:8080"), "https://192.168.1.10:8080")
        XCTAssertEqual(destination("localhost.example.com"), "https://localhost.example.com")
    }

    // MARK: - Tab switcher thumbnails (issue #340)

    private func solidImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    func testThumbnailBitmapDownscalesWideSnapshotsPreservingAspect() throws {
        // Wake snapshots are captured up to 1024pt wide; the disk cache keeps
        // them at switcher width so the launch-time load stays cheap.
        let bitmap = try XCTUnwrap(
            TabSnapshotStore.thumbnailBitmap(from: solidImage(width: 1024, height: 640), maxWidth: 320)
        )
        XCTAssertEqual(bitmap.pixelsWide, 320)
        XCTAssertEqual(bitmap.pixelsHigh, 200)
    }

    func testThumbnailBitmapLeavesNarrowSnapshotsAlone() throws {
        let bitmap = try XCTUnwrap(
            TabSnapshotStore.thumbnailBitmap(from: solidImage(width: 300, height: 180), maxWidth: 320)
        )
        XCTAssertEqual(bitmap.pixelsWide, 300)
        XCTAssertEqual(bitmap.pixelsHigh, 180)
    }

    func testPreviewWarmupOnlyLoadsWebPages() {
        XCTAssertTrue(WebViewCoordinator.isWarmable(URL(string: "https://example.com/a")!))
        XCTAssertTrue(WebViewCoordinator.isWarmable(URL(string: "HTTP://example.com")!))
        XCTAssertFalse(WebViewCoordinator.isWarmable(URL(string: "mailto:someone@example.com")!))
        XCTAssertFalse(WebViewCoordinator.isWarmable(URL(string: "file:///tmp/page.html")!))
        XCTAssertFalse(WebViewCoordinator.isWarmable(URL(string: "candoa://welcome")!))
    }

    // MARK: - Address display text

    func testDisplayDomainKeepsHostAndPortOnly() {
        // Zen's urlbarTrim under zen.urlbar.show-domain-only-in-sidebar, and
        // what Arc's sidebar field shows.
        XCTAssertEqual(
            URL(string: "https://www.youtube.com/watch?v=abc")!.displayDomainText,
            "youtube.com"
        )
        XCTAssertEqual(
            URL(string: "http://localhost:8080/financial")!.displayDomainText,
            "localhost:8080"
        )
        XCTAssertEqual(
            URL(string: "https://docs.google.com/document/d/1")!.displayDomainText,
            "docs.google.com"
        )
    }

    func testDisplayDomainStripsWWWOnlyAsALeadingLabel() {
        XCTAssertEqual(URL(string: "https://wwwx.example.com/")!.displayDomainText, "wwwx.example.com")
        XCTAssertEqual(URL(string: "https://cdn.www.example.com/")!.displayDomainText, "cdn.www.example.com")
        XCTAssertEqual(URL(string: "https://www.example.com/")!.displayDomainText, "example.com")
    }

    func testDisplayDomainFallsBackForHostlessURLs() {
        XCTAssertEqual(
            URL(string: "file:///tmp/page.html")!.displayDomainText,
            "file:///tmp/page.html"
        )
    }
}

/// The command palette teaches shortcuts by mapping each row's action back to
/// its rebindable `ShortcutDefinition` (issue #370). Pure logic: no palette
/// UI or persistence involved.
final class PaletteShortcutTests: XCTestCase {
    func testBaseActionsMapToTheirShortcutDefinitions() {
        XCTAssertEqual(PaletteAction.newTab.shortcutDefinition, .newTab)
        XCTAssertEqual(PaletteAction.closeCurrentTab.shortcutDefinition, .closeCurrentTab)
        XCTAssertEqual(PaletteAction.reloadTab.shortcutDefinition, .reloadTab)
        XCTAssertEqual(PaletteAction.focusAddressBar.shortcutDefinition, .focusAddressBar)
        XCTAssertEqual(PaletteAction.toggleSplitView.shortcutDefinition, .toggleSplitView)
        XCTAssertEqual(PaletteAction.toggleSplitPaneZoom.shortcutDefinition, .zoomSplitPane)
        XCTAssertEqual(PaletteAction.focusSplitPane(1).shortcutDefinition, .focusNextSplitPane)
        XCTAssertEqual(PaletteAction.focusSplitPane(-1).shortcutDefinition, .focusPreviousSplitPane)
        XCTAssertEqual(PaletteAction.unsplitPane.shortcutDefinition, .unsplitPane)
        XCTAssertEqual(PaletteAction.togglePinTab.shortcutDefinition, .pinOrUnpinTab)
    }

    func testPaletteOnlyActionsHaveNoShortcut() {
        XCTAssertNil(PaletteAction.duplicateCurrentTab.shortcutDefinition)
        XCTAssertNil(PaletteAction.createSpace.shortcutDefinition)
        XCTAssertNil(PaletteAction.setDeveloperMode(true).shortcutDefinition)
        XCTAssertNil(PaletteAction.navigate("https://example.com").shortcutDefinition)
        XCTAssertNil(PaletteAction.switchTab(UUID()).shortcutDefinition)
        XCTAssertNil(PaletteAction.switchSpace(UUID()).shortcutDefinition)
    }

    func testCommandKeysFollowTheStoredRebind() {
        let key = ShortcutDefinition.reloadTab.storageKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let command = PaletteCommand(title: "Reload", symbolName: "arrow.clockwise", action: .reloadTab)

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(command.shortcutKeys, ["⌘", "R"])

        UserDefaults.standard.set("Shift-Command-R", forKey: key)
        XCTAssertEqual(command.shortcutKeys, ["⇧", "⌘", "R"])

        UserDefaults.standard.set(ShortcutDefinition.removedValue, forKey: key)
        XCTAssertEqual(command.shortcutKeys, [])
    }
}
