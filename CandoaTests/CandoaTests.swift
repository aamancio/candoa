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
