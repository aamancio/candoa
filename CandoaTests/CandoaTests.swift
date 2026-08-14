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
}
