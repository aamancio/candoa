import AppKit
import XCTest
@testable import Candoa

/// Unit coverage for Ask's pure request-shaping logic (issue #48): context
/// budgeting, reasoning clamping, catalog validation and hosted-metadata
/// merging, and origin-key normalization. Everything here is side-effect
/// free — persistence and streaming stay covered by the UI test suite —
/// alongside the web pane's own geometry, which is plain view math.
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

    // MARK: - Suggestion catalog (issue #467)

    private func domain(_ string: String) -> EliSuggestionCatalog.Domain {
        EliSuggestionCatalog.domain(for: URL(string: string))
    }

    func testSuggestionDomainDetectsCommonSites() {
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfcdVSCPbQzTwlPqJdKhTvLWb"), .email)
        XCTAssertEqual(domain("https://outlook.office.com/mail/inbox/id/AAMkAGI2NGVhZTVlLTI5Y2E"), .email)
        XCTAssertEqual(domain("https://docs.google.com/spreadsheets/d/abc/edit"), .spreadsheet)
        XCTAssertEqual(domain("https://docs.google.com/document/d/abc/edit"), .document)
        XCTAssertEqual(domain("https://www.notion.so/team/Roadmap-1234"), .document)
        XCTAssertEqual(domain("https://acme.atlassian.net/wiki/spaces/ENG/pages/1"), .document)
        XCTAssertEqual(domain("https://github.com/aamancio/candoa-browser/pull/467"), .codeReview)
        XCTAssertEqual(domain("https://gitlab.com/group/sub/project/-/merge_requests/3"), .codeReview)
        XCTAssertEqual(domain("https://github.com/aamancio/candoa-browser/issues/467"), .issue)
        XCTAssertEqual(domain("https://acme.atlassian.net/browse/ENG-12"), .issue)
        XCTAssertEqual(domain("https://github.com/aamancio/candoa-browser"), .repository)
        XCTAssertEqual(domain("https://github.com/aamancio"), .generic)
        XCTAssertEqual(domain("https://www.youtube.com/watch?v=abc"), .video)
        XCTAssertEqual(domain("https://www.youtube.com/"), .generic)
        XCTAssertEqual(domain("https://youtu.be/abc"), .video)
        XCTAssertEqual(domain("https://app.slack.com/client/T1/C1"), .chat)
        XCTAssertEqual(domain("https://www.amazon.com/dp/B000"), .shopping)
        XCTAssertEqual(domain("https://www.google.com/search?q=swift"), .search)
        XCTAssertEqual(domain("https://duckduckgo.com/?q=swift"), .search)
        XCTAssertEqual(domain("https://duckduckgo.com/"), .generic)
        XCTAssertEqual(domain("https://calendar.google.com/calendar/u/0/r"), .calendar)
        XCTAssertEqual(domain("https://en.wikipedia.org/wiki/Swift"), .reference)
        XCTAssertEqual(domain("https://example.com/report.PDF"), .pdf)
        XCTAssertEqual(domain("https://example.com/article"), .generic)
        XCTAssertEqual(domain("about:blank"), .generic)
        XCTAssertEqual(domain("not a url"), .generic)
        XCTAssertEqual(EliSuggestionCatalog.domain(for: nil), .generic)
    }

    func testMailListViewsGetGenericChips() {
        // Issue #474: the inbox list offered "Draft a reply to this email".
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#inbox"), .generic)
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#starred"), .generic)
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#label/Lancaster%20Bicycle"), .generic)
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#search/lancasterbicycleclubrides"), .generic)
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#advanced-search/from=a%40b.com"), .generic)
        XCTAssertEqual(domain("https://outlook.office.com/mail/inbox"), .generic)
        XCTAssertEqual(domain("https://outlook.live.com/mail/0/"), .generic)
        XCTAssertEqual(domain("https://mail.proton.me/u/0/inbox"), .generic)
        XCTAssertEqual(domain("https://app.hey.com/imbox"), .generic)
        XCTAssertEqual(domain("https://app.fastmail.com/mail/Inbox/?u=abc"), .generic)

        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfcdVSCPbQzTwlPqJdKhTvLWb"), .email)
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#search/ride/FMfcgzQbfcdVSCPbQzTwlPqJdKhTvLWb"), .email)
        XCTAssertEqual(domain("https://mail.google.com/mail/u/0/#label/Club/FMfcgzQbfcdVSCPbQzTwlPqJdKhTvLWb"), .email)
        XCTAssertEqual(domain("https://outlook.live.com/mail/0/inbox/id/AQMkADAwATY3ZmYAZS0xYjE4"), .email)
        XCTAssertEqual(domain("https://mail.proton.me/u/0/inbox/x7Qn3KpL9vT2mR8sW1yB4cD6eF0gH5jK"), .email)
        XCTAssertEqual(domain("https://app.hey.com/topics/1234567890"), .email)
        XCTAssertEqual(domain("https://mail.yahoo.com/d/folders/1/messages/AKx9bQ"), .email)
    }

    func testSuggestionDomainDoesNotMatchLookalikeHosts() {
        XCTAssertEqual(domain("https://github.com.evil.example/pull/1"), .generic)
        XCTAssertEqual(domain("https://notgithub.com/a/b/pull/1"), .generic)
        XCTAssertEqual(domain("https://mail.google.com.attacker.test/"), .generic)
    }

    func testEveryDomainOffersTwoDistinctSuggestions() {
        for domain in EliSuggestionCatalog.Domain.allCases {
            let suggestions = EliSuggestionCatalog.suggestions(for: domain)
            XCTAssertEqual(suggestions.count, 2, "\(domain)")
            XCTAssertEqual(Set(suggestions.map(\.id)).count, 2, "\(domain) repeats a kind")
            XCTAssertFalse(suggestions.contains { $0.kind == .compare }, "\(domain) must leave compare to the view")
            for suggestion in suggestions {
                XCTAssertFalse(suggestion.title.isEmpty)
                XCTAssertFalse(suggestion.isPersonalized)
                if let format = suggestion.personalizedFormat {
                    XCTAssertTrue(format.contains("%@"), "\(domain) \(suggestion.kind) slot is missing")
                }
            }
        }
    }

    func testGenericSuggestionsKeepTheOriginalChips() {
        let titles = EliSuggestionCatalog.suggestions(for: nil).map(\.title)
        XCTAssertEqual(titles, ["Summarize this page", "Explain the key points"])
        // The context chip already names the page, so the generic pair never
        // restates its subject.
        XCTAssertTrue(EliSuggestionCatalog.suggestions(for: .generic).allSatisfy { $0.personalizedFormat == nil })
        XCTAssertTrue(EliSuggestionCatalog.suggestions(for: .pdf).allSatisfy { $0.personalizedFormat == nil })
    }

    func testVideoKeyMomentsChipNeedsChaptersOrTranscript() {
        let video = URL(string: "https://www.youtube.com/watch?v=abc123")
        XCTAssertEqual(EliSuggestionCatalog.suggestions(for: video).map(\.kind), [.summarize, .keyFacts])

        // Sidebar thumbnail durations are not evidence.
        let durationsOnly = "Player 0:00 / 53:16\nRelated\n53:16\nBREAKING\n10:47\nSABOTAGE\n2:39:52\nThriving"
        XCTAssertFalse(EliSuggestionCatalog.videoExposesKeyMoments(pageText: durationsOnly))
        XCTAssertEqual(EliSuggestionCatalog.suggestions(for: video, pageText: durationsOnly).map(\.kind),
                       [.summarize, .keyFacts])

        // The page read collapses a description block onto one line.
        let chapters = "Description 0:00 Intro 2:15 The apartment 14:30 Verdict\n53:16"
        XCTAssertTrue(EliSuggestionCatalog.videoExposesKeyMoments(pageText: chapters))
        XCTAssertEqual(EliSuggestionCatalog.suggestions(for: video, pageText: chapters).map(\.kind),
                       [.summarize, .keyMoments])

        let longChapters = "topics covered: 00:00:00 Introduction 00:02:58 What is JavaScript?"
        XCTAssertTrue(EliSuggestionCatalog.videoExposesKeyMoments(pageText: longChapters))

        let transcript = "Transcript\n0:03 hey everyone\n0:09 today we are\n0:14 in Mactan"
        XCTAssertTrue(EliSuggestionCatalog.videoExposesKeyMoments(pageText: transcript))

        XCTAssertFalse(EliSuggestionCatalog.videoExposesKeyMoments(pageText: nil))
        // The gate never touches other domains.
        XCTAssertEqual(EliSuggestionCatalog.suggestions(for: nil, pageText: chapters).map(\.kind),
                       EliSuggestionCatalog.suggestions(for: nil).map(\.kind))
    }

    func testPersonalizationFillsOnlySlottedChips() {
        let email = EliSuggestionCatalog.suggestions(for: .email)
        let filled = email.map { $0.personalized(with: "the Q3 budget") }
        XCTAssertEqual(filled[0].title, "Summarize the email thread about the Q3 budget")
        XCTAssertEqual(filled[1].title, "Draft a reply about the Q3 budget")
        XCTAssertTrue(filled.allSatisfy(\.isPersonalized))

        let spreadsheet = EliSuggestionCatalog.suggestions(for: .spreadsheet)
        let partiallyFilled = spreadsheet.map { $0.personalized(with: "sales by region") }
        XCTAssertEqual(partiallyFilled[0].title, "Summarize the data about sales by region")
        XCTAssertEqual(partiallyFilled[1], spreadsheet[1])
        XCTAssertFalse(partiallyFilled[1].isPersonalized)
    }

    func testUsableSubjectRejectsNonAnswersAndLongOutput() {
        XCTAssertTrue(EliSuggestionCatalog.isUsableSubject("the Q3 budget"))
        XCTAssertTrue(EliSuggestionCatalog.isUsableSubject("\"Swift 6 migration\"."))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject(""))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("   "))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("This page"))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("Unknown"))
        XCTAssertTrue(EliSuggestionCatalog.isUsableSubject("the mini player floats above the sidebars"))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("one two three four five six seven eight nine"))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("a very long subject line that just keeps going on"))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("line one\nline two"))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("YouTube", host: "www.youtube.com"))
        XCTAssertFalse(EliSuggestionCatalog.isUsableSubject("Git Hub", host: "github.com"))
        XCTAssertTrue(EliSuggestionCatalog.isUsableSubject("YouTube ad revenue", host: "www.youtube.com"))
        XCTAssertTrue(EliSuggestionCatalog.isUsableSubject("the Q3 budget", host: "mail.google.com"))
    }

    func testSuggestionExcerptIsBoundedAndCollapsed() {
        let text = String(repeating: "word ", count: 500) + "\n\n   \n tail"
        let excerpt = EliSuggestionCatalog.excerpt(
            title: "  Q3 Budget  ",
            url: URL(string: "https://mail.google.com/mail/u/0/"),
            pageText: text
        )
        XCTAssertTrue(excerpt.hasPrefix("Title: Q3 Budget\nSite: mail.google.com\nText:\n"))
        XCTAssertLessThanOrEqual(excerpt.count, "Title: Q3 Budget\nSite: mail.google.com\nText:\n".count + 600)
        XCTAssertFalse(excerpt.contains("\n\n"))

        XCTAssertEqual(EliSuggestionCatalog.excerpt(title: nil, url: nil, pageText: nil), "")
        XCTAssertEqual(EliSuggestionCatalog.excerpt(title: "", url: nil, pageText: "  \n "), "")
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

    /// A filled snapshot of an explicit point size, backed by `scale` pixels
    /// per point. Built by hand rather than with `lockFocus`, which adopts the
    /// test machine's display scale and would make these assertions depend on
    /// whether the run happens on a Retina Mac.
    private func solidImage(width: Int, height: Int, scale: Int = 1) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * scale,
            pixelsHigh: height * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
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

    func testThumbnailBitmapFillsTheThumbnailFromARetinaSnapshot() throws {
        // Regression: measuring the source in pixels but drawing from a point
        // space rect left the page in the bottom-left quadrant (issue #347).
        let bitmap = try XCTUnwrap(
            TabSnapshotStore.thumbnailBitmap(from: solidImage(width: 512, height: 320, scale: 2), maxWidth: 320)
        )
        XCTAssertEqual(bitmap.pixelsWide, 320)
        XCTAssertEqual(bitmap.pixelsHigh, 200)
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 318, y: 1), NSPoint(x: 1, y: 198), NSPoint(x: 318, y: 198)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y)))
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "thumbnail corner \(point) is empty")
        }
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

    // MARK: - Split membership survives a reorder

    private func regularTab(folderID: UUID? = nil) -> BrowserTab {
        BrowserTab(
            title: "Tab",
            url: URL(string: "https://example.com")!,
            isFavorite: false,
            isPinned: false,
            folderID: folderID,
            spaceID: UUID()
        )
    }

    /// Dragging a split tab within its own section used to detach it, which
    /// made split tabs impossible to reorder without losing the split.
    func testReorderingWithinTheSameSectionKeepsSplitMembership() {
        let tab = regularTab()
        XCTAssertFalse(
            BrowserStore.splitMemberLeavesItsSection(
                current: tab,
                isFavorite: false,
                isPinned: false,
                folderID: nil
            )
        )
    }

    func testMovingASplitMemberToAnotherSectionDetachesIt() {
        let tab = regularTab()
        let folder = UUID()
        for (favorite, pinned, folderID) in [
            (true, false, nil as UUID?),
            (false, true, nil as UUID?),
            (false, false, folder as UUID?)
        ] {
            XCTAssertTrue(
                BrowserStore.splitMemberLeavesItsSection(
                    current: tab,
                    isFavorite: favorite,
                    isPinned: pinned,
                    folderID: folderID
                ),
                "favorite=\(favorite) pinned=\(pinned) folder=\(String(describing: folderID))"
            )
        }
    }

    func testAFolderMemberReorderedInsideThatFolderStaysSplit() {
        let folder = UUID()
        let tab = regularTab(folderID: folder)
        XCTAssertFalse(
            BrowserStore.splitMemberLeavesItsSection(
                current: tab,
                isFavorite: false,
                isPinned: false,
                folderID: folder
            )
        )
    }

    // MARK: - Dropping onto the split pair's row

    private func tabs(_ n: Int) -> [BrowserTab] {
        (0..<n).map { i in
            BrowserTab(
                title: "Tab \(i)",
                url: URL(string: "https://example.com/\(i)")!,
                spaceID: UUID()
            )
        }
    }

    /// The pair's row anchors on whichever member comes first, so a drop on
    /// its top edge has to land before that member and a drop on its bottom
    /// edge after it. The row carried no delegate at all before, so neither
    /// of these was reachable.
    func testDroppingAboveThePairLandsBeforeItsFirstMember() {
        let list = tabs(5)
        let dragged = list[4]
        XCTAssertEqual(
            insertionBeforeID(
                targetTabID: list[1].id,
                edge: .before,
                tabs: list,
                draggedID: dragged.id
            ),
            list[1].id
        )
    }

    func testDroppingBelowThePairLandsAfterItsFirstMember() {
        let list = tabs(5)
        let dragged = list[4]
        XCTAssertEqual(
            insertionBeforeID(
                targetTabID: list[1].id,
                edge: .after,
                tabs: list,
                draggedID: dragged.id
            ),
            list[2].id
        )
    }

    /// Dropping after the last row appends rather than naming a neighbour.
    func testDroppingAfterTheLastRowAppends() {
        let list = tabs(3)
        let dragged = list[0]
        XCTAssertNil(
            insertionBeforeID(
                targetTabID: list[2].id,
                edge: .after,
                tabs: list,
                draggedID: dragged.id
            )
        )
    }

    /// The dragged tab is not its own neighbour: without filtering it out, a
    /// drop just below it would resolve to itself and no-op.
    func testTheDraggedTabIsExcludedFromNeighbourLookup() {
        let list = tabs(4)
        XCTAssertEqual(
            insertionBeforeID(
                targetTabID: list[0].id,
                edge: .after,
                tabs: list,
                draggedID: list[1].id
            ),
            list[2].id
        )
    }

    // MARK: - A split pair moves as a block

    /// Moving one member used to leave the other behind, and the pair's row
    /// redrew at the member that had not moved — so the drag ran correctly
    /// and the list looked unchanged.
    func testMovingAMemberBringsItsPartner() {
        let ids = (0..<6).map { _ in UUID() }
        let group: Set<UUID> = [ids[0], ids[1]]
        // The pair started at the front; the dragged member landed at index 4.
        let dropped = [ids[1], ids[2], ids[3], ids[4], ids[0], ids[5]]
        XCTAssertEqual(
            BrowserStore.keepingSplitPartnersAdjacent(to: ids[0], in: dropped, splitGroup: group),
            [ids[2], ids[3], ids[4], ids[0], ids[1], ids[5]]
        )
    }

    func testMovingANonMemberChangesNothing() {
        let ids = (0..<4).map { _ in UUID() }
        let order = [ids[0], ids[1], ids[2], ids[3]]
        XCTAssertEqual(
            BrowserStore.keepingSplitPartnersAdjacent(
                to: ids[2],
                in: order,
                splitGroup: [ids[0], ids[1]]
            ),
            order
        )
    }

    func testPartnersKeepTheirRelativeOrder() {
        let ids = (0..<5).map { _ in UUID() }
        let group: Set<UUID> = [ids[0], ids[1], ids[2]]
        let dropped = [ids[1], ids[2], ids[3], ids[0], ids[4]]
        XCTAssertEqual(
            BrowserStore.keepingSplitPartnersAdjacent(to: ids[0], in: dropped, splitGroup: group),
            [ids[3], ids[0], ids[1], ids[2], ids[4]]
        )
    }

    // MARK: - Web pane geometry

    /// The page card an attached inspector is laid out in, and the insets the
    /// page is left with, both come out of the pane host's own geometry.
    @MainActor
    private func makePaneHost(laneLeading: CGFloat, laneTrailing: CGFloat) -> WebPaneHostView {
        let host = WebPaneHostView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        host.layoutHostedSubviews(
            laneInsets: BrowserInterfaceInsets(leading: laneLeading, trailing: laneTrailing)
        )
        return host
    }

    @MainActor
    func testPageAreaInsetsAreTheReservedLanesWithoutAnInspector() {
        let host = makePaneHost(laneLeading: 280, laneTrailing: 60)

        // WebKit reads the stand-in's frame to decide whether it can dock at
        // all, so laying the host out has to size it there and then — waiting
        // for AppKit's next layout pass leaves docking refused.
        XCTAssertEqual(host.inspectorLane.pageArea.frame, host.inspectorLane.bounds)

        let insets = host.pageAreaInsets
        XCTAssertEqual(insets.left, 280, accuracy: 0.5)
        XCTAssertEqual(insets.right, 60, accuracy: 0.5)
        XCTAssertEqual(insets.top, 0, accuracy: 0.5)
        XCTAssertEqual(insets.bottom, 0, accuracy: 0.5)
    }

    /// WebKit shrinks the stand-in to whatever the docked inspector leaves —
    /// that rectangle is what the page's obscured insets have to describe.
    @MainActor
    func testPageAreaInsetsFollowADockedInspector() {
        let host = makePaneHost(laneLeading: 280, laneTrailing: 0)
        let inspectorHeight: CGFloat = 300
        host.inspectorLane.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 920, height: inspectorHeight)))
        host.inspectorLane.pageArea.frame = NSRect(x: 0, y: inspectorHeight, width: 920, height: 500)

        let insets = host.pageAreaInsets
        XCTAssertEqual(insets.left, 280, accuracy: 0.5)
        XCTAssertEqual(insets.bottom, inspectorHeight, accuracy: 0.5)
        XCTAssertEqual(insets.right, 0, accuracy: 0.5)
        XCTAssertEqual(insets.top, 0, accuracy: 0.5)
    }

    /// The lane sits over the page, so it has to be invisible to the pointer
    /// everywhere the inspector is not.
    @MainActor
    func testTheInspectorLanePassesClicksThroughWhileEmpty() {
        let host = makePaneHost(laneLeading: 280, laneTrailing: 0)
        let insideTheCard = NSPoint(x: 600, y: 400)
        XCTAssertNil(host.inspectorLane.hitTest(insideTheCard))
        XCTAssertNil(host.inspectorLane.pageArea.hitTest(insideTheCard))
    }

    /// A hosted web view spans the whole host, lanes included, and stays under
    /// the lane so a docked inspector paints over the page.
    @MainActor
    func testHostedWebViewsSpanTheHostBeneathTheInspectorLane() {
        let host = makePaneHost(laneLeading: 280, laneTrailing: 60)
        let page = NSView(frame: .zero)
        host.hostSubview(page)
        host.layoutHostedSubviews(laneInsets: BrowserInterfaceInsets(leading: 280, trailing: 60))

        XCTAssertEqual(page.frame, host.bounds)
        XCTAssertEqual(host.inspectorLane.frame, NSRect(x: 280, y: 0, width: 860, height: 800))
        XCTAssertLessThan(
            host.subviews.firstIndex(of: page) ?? -1,
            host.subviews.firstIndex(of: host.inspectorLane) ?? -1
        )
    }
}

/// Problem reporting's pure logic: the crash-stack parsing that turns a
/// MetricKit call-stack tree into readable frames, the signature that stops one
/// crash being reported twice, and the payload the intake has to accept.
final class ProblemReportTests: XCTestCase {
    // MARK: - Call stack parsing

    /// Shaped like `MXCallStackTree.jsonRepresentation()`: frames nest under
    /// `subFrames`, and only one thread carries `threadAttributed`.
    private func callStackTreeJSON(
        attributedBinary: String = "Candoa",
        includeOtherThread: Bool = true
    ) -> Data {
        var callStacks: [[String: Any]] = []
        if includeOtherThread {
            callStacks.append([
                "threadAttributed": false,
                "callStackRootFrames": [[
                    "binaryName": "libsystem_kernel.dylib",
                    "offsetIntoBinaryTextSegment": 9_000,
                    "subFrames": []
                ]]
            ])
        }
        callStacks.append([
            "threadAttributed": true,
            "callStackRootFrames": [[
                "binaryName": attributedBinary,
                "offsetIntoBinaryTextSegment": 100,
                "subFrames": [[
                    "binaryName": attributedBinary,
                    "offsetIntoBinaryTextSegment": 200,
                    "subFrames": [[
                        "binaryName": "AppKit",
                        "offsetIntoBinaryTextSegment": 300,
                        "subFrames": []
                    ]]
                ]]
            ]]
        ])
        return try! JSONSerialization.data(
            withJSONObject: ["callStacks": callStacks, "callStackPerThread": true]
        )
    }

    func testCrashParserReadsTheThreadThatActuallyCrashed() {
        let frames = CrashCallStackParser.frames(fromCallStackTreeJSON: callStackTreeJSON())
        XCTAssertEqual(frames, ["Candoa +100", "Candoa +200", "AppKit +300"])
    }

    func testCrashParserFallsBackToTheFirstThreadWhenNoneIsAttributed() {
        let json = try! JSONSerialization.data(withJSONObject: [
            "callStacks": [[
                "callStackRootFrames": [[
                    "binaryName": "Candoa",
                    "offsetIntoBinaryTextSegment": 42,
                    "subFrames": []
                ]]
            ]]
        ])
        XCTAssertEqual(
            CrashCallStackParser.frames(fromCallStackTreeJSON: json),
            ["Candoa +42"]
        )
    }

    func testCrashParserSurvivesAnUnexpectedShape() {
        XCTAssertEqual(CrashCallStackParser.frames(fromCallStackTreeJSON: Data()), [])
        XCTAssertEqual(
            CrashCallStackParser.frames(
                fromCallStackTreeJSON: Data("{\"callStacks\":\"unexpected\"}".utf8)
            ),
            []
        )
    }

    // MARK: - Not reporting the same crash twice

    func testSameCrashProducesTheSameSignature() {
        let frames = ["Candoa +100", "Candoa +200", "AppKit +300"]
        XCTAssertEqual(
            CrashReportBuilder.signature(name: "SIGSEGV", frames: frames, appVersion: "0.78.4"),
            CrashReportBuilder.signature(name: "SIGSEGV", frames: frames, appVersion: "0.78.4")
        )
    }

    func testADifferentCrashProducesADifferentSignature() {
        let signature = CrashReportBuilder.signature(
            name: "SIGSEGV", frames: ["Candoa +100"], appVersion: "0.78.4"
        )
        XCTAssertNotEqual(
            signature,
            CrashReportBuilder.signature(
                name: "SIGABRT", frames: ["Candoa +100"], appVersion: "0.78.4"
            )
        )
        XCTAssertNotEqual(
            signature,
            CrashReportBuilder.signature(
                name: "SIGSEGV", frames: ["Candoa +999"], appVersion: "0.78.4"
            )
        )
    }

    /// A fix ships as a new version. The same crash there is news again, not a
    /// duplicate of what was already reported.
    func testANewVersionReportsTheCrashAgain() {
        XCTAssertNotEqual(
            CrashReportBuilder.signature(
                name: "SIGSEGV", frames: ["Candoa +100"], appVersion: "0.78.4"
            ),
            CrashReportBuilder.signature(
                name: "SIGSEGV", frames: ["Candoa +100"], appVersion: "0.79.0"
            )
        )
    }

    // MARK: - The payload

    private func encoded(_ report: ProblemReport) throws -> [String: Any] {
        let data = try JSONEncoder().encode(report)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testWrittenReportCarriesTheWordsAndNothingAboutBrowsing() throws {
        let report = ProblemReport.written(description: "  The sidebar forgets my Spaces.  ")
        let json = try encoded(report)

        XCTAssertEqual(json["source"] as? String, "browser")
        XCTAssertEqual(json["kind"] as? String, "report")
        XCTAssertEqual(json["userDescription"] as? String, "The sidebar forgets my Spaces.")
        // No page, no tab, no history — the report names the app and nothing else.
        XCTAssertEqual(try XCTUnwrap(json["context"] as? [String: String]), [:])
        XCTAssertEqual(try XCTUnwrap(json["stack"] as? [String]), [])
    }

    func testCrashReportCarriesItsStackAndNoProse() throws {
        let report = CrashReportBuilder.report(
            name: "SIGSEGV",
            message: "",
            frames: ["Candoa +100"],
            appVersion: "0.78.4",
            platform: "macOS 15.5",
            context: ["signal": "11"]
        )
        let json = try encoded(report)

        XCTAssertEqual(json["kind"] as? String, "crash")
        XCTAssertEqual(try XCTUnwrap(json["stack"] as? [String]), ["Candoa +100"])
        XCTAssertEqual(json["userDescription"] as? String, "")
        XCTAssertEqual(try XCTUnwrap(json["context"] as? [String: String])["signal"], "11")
    }

    func testEmptyWrittenReportIsRefusedBeforeItIsSent() async {
        do {
            try await ProblemReportSubmitter.shared.submitWritten(description: "   \n  ")
            XCTFail("An empty report should never reach the network.")
        } catch let error as ProblemReportError {
            XCTAssertEqual(error, .emptyDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// The Chrome Web Store's item pages are the only input to Candoa's install
/// path, and its download endpoint the only output — both are pure string
/// work, so both are checked here.
final class ChromeWebStoreTests: XCTestCase {
    func testStoreItemIDIsReadFromEveryDetailPageShape() {
        let expected = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        let urls = [
            "https://chromewebstore.google.com/detail/ublock-origin-lite/\(expected)",
            "https://chromewebstore.google.com/detail/\(expected)",
            "https://chromewebstore.google.com/detail/ublock-origin-lite/\(expected)/reviews",
            "https://chromewebstore.google.com/detail/ublock-origin-lite/\(expected)?hl=fr",
            "https://chrome.google.com/webstore/detail/ublock-origin-lite/\(expected)"
        ]
        for string in urls {
            let url = URL(string: string) ?? URL(fileURLWithPath: "/")
            XCTAssertEqual(ChromeWebStore.itemID(from: url), expected, string)
        }
    }

    func testPagesWithoutAnItemAreNotInstallable() {
        let urls = [
            "https://chromewebstore.google.com/category/extensions",
            "https://chromewebstore.google.com/search/ublock",
            "https://example.com/detail/ublock/ddkjiahejlhfcafbddmgiahcphecmpfh",
            "https://chromewebstore.google.com/detail/ublock-origin-lite/short"
        ]
        for string in urls {
            let url = URL(string: string) ?? URL(fileURLWithPath: "/")
            XCTAssertNil(ChromeWebStore.itemID(from: url), string)
        }
    }

    func testDownloadURLCarriesTheItemAndAVersionTheStoreAccepts() throws {
        let itemID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        let url = try XCTUnwrap(ChromeWebStore.downloadURL(forItemID: itemID))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)

        XCTAssertEqual(components.host, "clients2.google.com")
        XCTAssertEqual(queryItems.first { $0.name == "x" }?.value, "id=\(itemID)&installsource=ondemand&uc")
        XCTAssertEqual(queryItems.first { $0.name == "acceptformat" }?.value, "crx2,crx3")
        XCTAssertNotNil(queryItems.first { $0.name == "prodversion" }?.value)
    }
}

/// Themes are the one thing the extension install path turns away: Chrome and
/// Firefox both ship them as extensions, and Candoa dresses its windows from
/// its own Spaces.
final class WebExtensionInstallerTests: XCTestCase {
    private func stagedResult(manifest: String) throws -> Result<URL, Error> {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            // Read the staged tree before the defer above clears it.
            let root = try WebExtensionInstaller.stage(source, to: destination)
            return .success(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
                    ? root : URL(fileURLWithPath: "/nonexistent")
            )
        } catch {
            return .failure(error)
        }
    }

    func testChromeAndFirefoxThemesAreRefused() throws {
        let manifests = [
            #"{"manifest_version": 3, "name": "Deep Dark", "version": "1", "theme": {"colors": {"frame": [0, 0, 0]}}}"#,
            #"{"manifest_version": 2, "name": "Firefox Look", "version": "1", "theme": {"images": {"theme_frame": "f.png"}}}"#
        ]
        for manifest in manifests {
            switch try stagedResult(manifest: manifest) {
            case .success:
                XCTFail("A browser theme should never stage as an extension.")
            case .failure(let error):
                XCTAssertEqual(error as? WebExtensionInstaller.InstallError, .browserTheme)
            }
        }
    }

    func testOrdinaryExtensionsStillStage() throws {
        let manifest = #"{"manifest_version": 3, "name": "Blocker", "version": "1", "permissions": ["storage"]}"#
        switch try stagedResult(manifest: manifest) {
        case .success(let root):
            XCTAssertNotEqual(root.path, "/nonexistent", "The staged tree should hold the manifest.")
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// The words the install prompt puts in front of someone: no API names, host
/// access first, and silence for the permissions that tell nobody anything.
final class WebExtensionPermissionCopyTests: XCTestCase {
    func testHostAccessReadsLikeChromesDialog() {
        XCTAssertEqual(
            WebExtensionPermissionCopy.websiteWarning(
                allHosts: false,
                hosts: ["*.youtube.com", "sponsor.ajay.app", "www.youtube-nocookie.com"]
            ),
            "Read and change your data on all youtube.com sites, sponsor.ajay.app, and www.youtube-nocookie.com"
        )
        XCTAssertEqual(
            WebExtensionPermissionCopy.websiteWarning(allHosts: true, hosts: ["example.com"]),
            "Read and change all your data on all websites"
        )
        XCTAssertNil(WebExtensionPermissionCopy.websiteWarning(allHosts: false, hosts: []))
    }

    func testLongHostListsEndInACount() {
        let hosts = (1...8).map { "site\($0).com" }
        let warning = try? XCTUnwrap(
            WebExtensionPermissionCopy.websiteWarning(allHosts: false, hosts: hosts)
        )
        XCTAssertEqual(warning?.contains("3 more sites"), true)
        XCTAssertEqual(warning?.contains("site6.com"), false)
    }

    func testUninformativePermissionsAreLeftUnsaid() {
        let warnings = WebExtensionPermissionCopy.warnings(
            permissions: ["storage", "alarms", "contextMenus", "activeTab", "scripting", "unlimitedStorage"],
            allHosts: false,
            hosts: []
        )
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(
            WebExtensionPermissionCopy.informativeText(for: warnings),
            "It doesn't ask for access to your data."
        )
    }

    func testWebsiteAccessLeadsAndDuplicatesCollapse() {
        let warnings = WebExtensionPermissionCopy.warnings(
            permissions: ["tabs", "webNavigation", "downloads", "storage"],
            allHosts: true,
            hosts: []
        )
        XCTAssertEqual(warnings, [
            "Read and change all your data on all websites",
            "Manage your downloads",
            "Read your browsing history"
        ])
        XCTAssertTrue(WebExtensionPermissionCopy.informativeText(for: warnings).hasPrefix("It can:"))
    }
}

/// Command bar learning ("typed this, opened that"): the ranking and
/// retention rules behind the address bar reordering suggestions around the
/// row a person actually picks.
final class CommandBarSelectionMemoryTests: XCTestCase {

    private func selection(
        typed: String,
        url: String,
        count: Int = 1,
        secondsAgo: TimeInterval = 0
    ) -> CommandBarSelection {
        CommandBarSelection(
            typedText: typed,
            title: url,
            urlString: url,
            count: count,
            lastSelectedAt: Date(timeIntervalSince1970: 1_700_000_000 - secondsAgo)
        )
    }

    func testTheChosenRowLeadsTheNextTimeTheSameTextIsTyped() {
        let selections = CommandBarSelectionRanking.recording(
            [],
            typedText: "sls",
            title: "SwingLifeStyle.com",
            urlString: "https://www.swinglifestyle.com",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let matches = CommandBarSelectionRanking.matches(selections, for: "sls")
        XCTAssertEqual(matches.map(\.urlString), ["https://www.swinglifestyle.com"])
    }

    func testRepeatedPicksOutrankASingleStrayOne() {
        let selections = [
            selection(typed: "news", url: "https://stray.example.com", count: 1, secondsAgo: 0),
            selection(typed: "news", url: "https://daily.example.com", count: 4, secondsAgo: 600)
        ]
        XCTAssertEqual(
            CommandBarSelectionRanking.matches(selections, for: "news").map(\.urlString),
            ["https://daily.example.com", "https://stray.example.com"]
        )
    }

    func testTheMostRecentPickWinsATie() {
        let selections = [
            selection(typed: "sls", url: "https://www.google.com/search?q=sls", secondsAgo: 600),
            selection(typed: "sls", url: "https://www.swinglifestyle.com", secondsAgo: 0)
        ]
        XCTAssertEqual(
            CommandBarSelectionRanking.matches(selections, for: "sls").first?.urlString,
            "https://www.swinglifestyle.com"
        )
    }

    func testATypedPrefixRecallsTheLongerPhraseButNotTheOtherWayAround() {
        let selections = [selection(typed: "swing", url: "https://www.swinglifestyle.com")]
        XCTAssertEqual(CommandBarSelectionRanking.matches(selections, for: "sw").count, 1)
        XCTAssertEqual(CommandBarSelectionRanking.matches(selections, for: "SWING").count, 1)
        XCTAssertEqual(CommandBarSelectionRanking.matches(selections, for: "swings").count, 0)
        XCTAssertEqual(CommandBarSelectionRanking.matches(selections, for: " ").count, 0)
    }

    func testPickingTheSamePageAgainReinforcesOneEntry() {
        var selections: [CommandBarSelection] = []
        for offset in 0..<3 {
            selections = CommandBarSelectionRanking.recording(
                selections,
                typedText: "  SLS ",
                title: "SwingLifeStyle",
                urlString: "https://www.swinglifestyle.com/",
                at: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(offset))
            )
        }
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.count, 3)
        XCTAssertEqual(selections.first?.typedText, "sls")
    }

    func testTheListStaysCappedAndDropsTheLeastUsedPairing() {
        var selections = (0..<CommandBarSelectionRanking.maximumSelections).map {
            selection(typed: "q\($0)", url: "https://site\($0).example.com", count: 5)
        }
        selections[0].count = 1
        selections = CommandBarSelectionRanking.recording(
            selections,
            typedText: "fresh",
            title: "Fresh",
            urlString: "https://fresh.example.com",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(selections.count, CommandBarSelectionRanking.maximumSelections)
        XCTAssertEqual(CommandBarSelectionRanking.matches(selections, for: "q0"), [])
        XCTAssertEqual(CommandBarSelectionRanking.matches(selections, for: "fresh").count, 1)
    }

    func testClearingHistoryTakesThePicksLearnedFromIt() {
        let selections = [
            selection(typed: "sls", url: "https://www.swinglifestyle.com", secondsAgo: 0),
            selection(typed: "old", url: "https://old.example.com", secondsAgo: 10_000)
        ]
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000 - 5_000)
        XCTAssertEqual(
            CommandBarSelectionRanking.forgetting(selections, selectedAfter: cutoff).map(\.urlString),
            ["https://old.example.com"]
        )
        XCTAssertEqual(CommandBarSelectionRanking.forgetting(selections, selectedAfter: nil), [])
        XCTAssertEqual(
            CommandBarSelectionRanking.forgetting(
                selections,
                urls: ["https://www.swinglifestyle.com/"]
            ).map(\.urlString),
            ["https://old.example.com"]
        )
    }

    func testPicksAgeOutWithTheRetentionWindow() {
        let selections = [
            selection(typed: "sls", url: "https://www.swinglifestyle.com", secondsAgo: 0),
            selection(typed: "sls", url: "https://stale.example.com", secondsAgo: 100_000)
        ]
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000 - 50_000)
        XCTAssertEqual(
            CommandBarSelectionRanking.pruned(selections, before: cutoff).map(\.urlString),
            ["https://www.swinglifestyle.com"]
        )
        XCTAssertEqual(CommandBarSelectionRanking.pruned(selections, before: nil).count, 2)
    }

    @MainActor
    func testPrivateWindowsLearnNothingAndRecallNothing() throws {
        let memory = CommandBarSelectionMemory.makeEphemeral()
        memory.record(
            typedText: "sls",
            title: "SwingLifeStyle",
            url: try XCTUnwrap(URL(string: "https://www.swinglifestyle.com"))
        )
        XCTAssertEqual(memory.selections(matching: "sls"), [])
    }

    @MainActor
    func testLearnedPicksSurviveAReadBackFromDefaults() throws {
        let suiteName = "CommandBarSelectionMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let memory = CommandBarSelectionMemory(defaults: defaults)
        memory.record(
            typedText: "sls",
            title: "SwingLifeStyle",
            url: try XCTUnwrap(URL(string: "https://www.swinglifestyle.com"))
        )
        XCTAssertEqual(
            CommandBarSelectionMemory(defaults: defaults).selections(matching: "sl").first?.title,
            "SwingLifeStyle"
        )

        memory.removeAll()
        XCTAssertEqual(CommandBarSelectionMemory(defaults: defaults).selections(matching: "sl"), [])
    }
}

/// The before/after summary a step's outcome carries, and the grounding of
/// the press and scroll-to-control actions.
final class BrowserAgentPerceptionTests: XCTestCase {
    private let snapshotID = UUID()

    private func page(
        url: String = "https://example.com/account",
        title: String = "Account",
        controls: [BrowserAgentControl],
        modal: Bool = false
    ) -> BrowserAgentPage {
        BrowserAgentPage(
            snapshotID: snapshotID,
            title: title,
            url: url,
            text: "",
            controls: controls,
            tree: "- main",
            viewport: BrowserAgentViewport(width: 1280, height: 800, scrollTop: 0, scrollHeight: 800, linesAbove: 0, linesBelow: 0, modal: modal)
        )
    }

    private func control(_ ref: String, _ label: String, kind: BrowserAgentControl.Kind = .button) -> BrowserAgentControl {
        BrowserAgentControl(ref: ref, kind: kind, label: label, url: nil, disabled: false)
    }

    func testDiffReportsNavigationAndNewControls() {
        let before = page(controls: [control("e0", "Manage membership")])
        let after = page(url: "https://example.com/membership", title: "Membership", controls: [control("e0", "Cancel membership"), control("e1", "Change plan")])
        let summary = BrowserAgentPageDiff.summary(before: before, after: after, mutations: 12)
        XCTAssertTrue(summary.contains("URL changed to https://example.com/membership"), summary)
        XCTAssertTrue(summary.contains("title is now \"Membership\""), summary)
        XCTAssertTrue(summary.contains("New controls: \"Cancel membership\", \"Change plan\""), summary)
        XCTAssertTrue(summary.contains("Gone: \"Manage membership\""), summary)
    }

    func testDiffSaysWhenNothingChanged() {
        let before = page(controls: [control("e0", "Next")])
        XCTAssertEqual(BrowserAgentPageDiff.summary(before: before, after: before, mutations: 0), "Nothing visible changed.")
        XCTAssertEqual(
            BrowserAgentPageDiff.summary(before: before, after: before, mutations: 3),
            "The page updated but its controls did not change."
        )
    }

    func testDiffNoticesDialogsAndCapsTheList() {
        let before = page(controls: [])
        let opened = page(controls: (0..<7).map { control("e\($0)", "Option \($0)") }, modal: true)
        let summary = BrowserAgentPageDiff.summary(before: before, after: opened, mutations: nil)
        XCTAssertTrue(summary.hasPrefix("A dialog opened."), summary)
        XCTAssertTrue(summary.contains("and 3 more"), summary)
    }

    func testPressIsGroundedOnAListedControlWithAnAllowedKey() {
        let current = page(controls: [control("e0", "Search", kind: .field)])
        let press = { (value: String) in
            BrowserAgentAction(snapshotID: self.snapshotID, kind: .press, target: "e0", value: value, label: "Search", url: nil, requiresApproval: false, message: "")
        }
        let proposal = press("Enter").validatedAction(on: current)
        XCTAssertEqual(proposal?.kind, .press)
        XCTAssertEqual(proposal?.value, "Enter")
        XCTAssertEqual(proposal?.browserAgentReference, "e0")
        XCTAssertNil(press("F5").validatedAction(on: current), "only the listed keys are pressable")
    }

    func testScrollAcceptsADirectionOrAControlToReveal() {
        let current = page(controls: [control("e0", "Reviews", kind: .link)])
        let scroll = { (target: String, label: String) in
            BrowserAgentAction(snapshotID: self.snapshotID, kind: .scroll, target: target, value: "", label: label, url: nil, requiresApproval: false, message: "")
        }
        XCTAssertEqual(scroll("down", "Scroll down").validatedAction(on: current)?.target, "down")
        let toControl = scroll("e0", "Reviews").validatedAction(on: current)
        XCTAssertEqual(toControl?.browserAgentReference, "e0")
        XCTAssertEqual(toControl?.target, "Reviews")
        XCTAssertNil(scroll("e0", "Other").validatedAction(on: current), "the label has to match the snapshot")
        XCTAssertNil(scroll("sideways", "Scroll sideways").validatedAction(on: current))
    }

    func testPressOnASensitiveControlStillNeedsApproval() {
        let current = page(controls: [BrowserAgentControl(ref: "e0", kind: .field, label: "Email", url: nil, disabled: false, sensitive: true)])
        let action = BrowserAgentAction(snapshotID: snapshotID, kind: .press, target: "e0", value: "Enter", label: "Email", url: nil, requiresApproval: false, message: "")
        XCTAssertTrue(BrowserAgentPolicy.requiresNativeApproval(for: action, on: current))
    }
}

/// The floating mini player's shape and size math: portrait shorts, the
/// long-edge size it carries across a change of clip, and the resize drag.
final class MiniPlayerLayoutTests: XCTestCase {
    private let window = CGSize(width: 1440, height: 900)

    func testPlayerTakesTheVideoShapeForPortraitClips() {
        let short = MiniPlayerLayout.clampedSize(longEdge: 430, aspectRatio: 9.0 / 16.0, in: window)
        XCTAssertEqual(short.height, 430, accuracy: 0.5, "the long edge is the height for a portrait clip")
        XCTAssertEqual(short.width, 430 * 9 / 16, accuracy: 0.5)

        let wide = MiniPlayerLayout.clampedSize(longEdge: 430, aspectRatio: 16.0 / 9.0, in: window)
        XCTAssertEqual(wide.width, 430, accuracy: 0.5)
        XCTAssertEqual(wide.height, 430 * 9 / 16, accuracy: 0.5)
    }

    func testPlayerFallsBackToWidescreenWithoutAReportedShape() {
        XCTAssertEqual(MiniPlayerLayout.normalizedAspectRatio(nil), 16.0 / 9.0)
        XCTAssertEqual(MiniPlayerLayout.normalizedAspectRatio(0), 16.0 / 9.0)
        XCTAssertEqual(MiniPlayerLayout.normalizedAspectRatio(.nan), 16.0 / 9.0)
    }

    func testPlayerShapeStaysWithinItsLimits() {
        let sliver = MiniPlayerLayout.normalizedAspectRatio(40)
        XCTAssertEqual(sliver, MiniPlayerLayout.aspectRatioLimits.upperBound)
        let tower = MiniPlayerLayout.normalizedAspectRatio(0.05)
        XCTAssertEqual(tower, MiniPlayerLayout.aspectRatioLimits.lowerBound)
    }

    func testPortraitPlayerFitsAShortWindow() {
        let shortWindow = CGSize(width: 1440, height: 420)
        let size = MiniPlayerLayout.clampedSize(longEdge: 430, aspectRatio: 9.0 / 16.0, in: shortWindow)
        XCTAssertLessThanOrEqual(size.height, shortWindow.height - MiniPlayerLayout.margin * 2)
        XCTAssertEqual(size.width / size.height, 9.0 / 16.0, accuracy: 0.01, "clamping keeps the video's shape")
    }

    func testResizeDragFollowsTheShapeItIsGiven() {
        let drag = CGSize(width: 0, height: 80)
        let wide = MiniPlayerResizeEdge.bottom.widthDelta(for: drag, aspectRatio: 16.0 / 9.0)
        XCTAssertEqual(wide, 80 * 16 / 9, accuracy: 0.5)
        let tall = MiniPlayerResizeEdge.bottom.widthDelta(for: drag, aspectRatio: 9.0 / 16.0)
        XCTAssertEqual(tall, 80 * 9 / 16, accuracy: 0.5, "a portrait player widens by less than it grows")
    }

    func testLongEdgeSurvivesAShapeChange() {
        let wide = MiniPlayerLayout.clampedSize(longEdge: 520, aspectRatio: 16.0 / 9.0, in: window)
        let carried = MiniPlayerLayout.longEdge(of: wide)
        let tall = MiniPlayerLayout.clampedSize(longEdge: carried, aspectRatio: 9.0 / 16.0, in: window)
        XCTAssertEqual(tall.height, 520, accuracy: 0.5, "the player keeps its stature across a swipe to a short")
    }
}
