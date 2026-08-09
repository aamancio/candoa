import Foundation
import WebKit

/// One block of the protection list as the Privacy Report presents it: a
/// plain-language name, what its trackers do, and the exact domains blocked.
struct TrackerProtectionCategory: Identifiable {
    let id: String
    let title: String
    let summary: String
    let domains: [String]
}

/// Compiles and caches the tracker/ad WKContentRuleList. Rules run inside
/// WebKit's network process, so blocked requests cost no JavaScript and no
/// main-thread time — they simply never happen.
@MainActor
final class ContentBlockerService {
    static let shared = ContentBlockerService()

    /// Bump the suffix whenever `blockedTrackerDomains` changes so the
    /// on-disk compiled cache is invalidated.
    private static let ruleListIdentifier = "CandoaTrackerBlockRules-v1"

    private var cachedRuleList: WKContentRuleList?

    func ruleList() async -> WKContentRuleList? {
        if let cachedRuleList {
            return cachedRuleList
        }

        let ruleList = await loadOrCompileRuleList()
        cachedRuleList = ruleList
        return ruleList
    }

    private func loadOrCompileRuleList() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }

        if let compiled = await lookUpCompiledRuleList(in: store) {
            return compiled
        }

        return await compileRuleList(in: store)
    }

    private func lookUpCompiledRuleList(in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: Self.ruleListIdentifier) { ruleList, _ in
                continuation.resume(returning: ruleList)
            }
        }
    }

    private func compileRuleList(in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: Self.ruleListIdentifier,
                encodedContentRuleList: Self.encodedRules()
            ) { ruleList, _ in
                continuation.resume(returning: ruleList)
            }
        }
    }

    /// Third-party ad/tracking hosts only — first-party requests and
    /// login-critical hosts (e.g. connect.facebook.net) are left alone so
    /// sites keep working. Grouped so the Privacy Report and the compiled
    /// rules describe the same list: what the report claims is exactly what
    /// the network process blocks.
    static let protectionCategories: [TrackerProtectionCategory] = [
        TrackerProtectionCategory(
            id: "ad-delivery",
            title: String(localized: "Ad delivery and exchanges"),
            summary: String(
                localized: "Networks that auction and serve ads, and follow what you read to target them."
            ),
            domains: [
                "doubleclick.net",
                "googlesyndication.com",
                "googleadservices.com",
                "googletagservices.com",
                "adservice.google.com",
                "amazon-adsystem.com",
                "adnxs.com",
                "adsrvr.org",
                "criteo.com",
                "criteo.net",
                "rubiconproject.com",
                "pubmatic.com",
                "openx.net",
                "casalemedia.com",
                "smartadserver.com",
                "spotxchange.com",
                "teads.tv",
                "sharethrough.com",
                "yieldmo.com",
                "33across.com",
                "bidswitch.net",
                "taboola.com",
                "outbrain.com"
            ]
        ),
        TrackerProtectionCategory(
            id: "ad-verification",
            title: String(localized: "Ad verification"),
            summary: String(
                localized: "Services that re-check every ad impression with heavy scripts."
            ),
            domains: [
                "moatads.com",
                "doubleverify.com",
                "adsafeprotected.com"
            ]
        ),
        TrackerProtectionCategory(
            id: "analytics",
            title: String(localized: "Analytics and audience tracking"),
            summary: String(
                localized: "Services that measure audiences and build interest profiles across sites."
            ),
            domains: [
                "google-analytics.com",
                "scorecardresearch.com",
                "quantserve.com",
                "demdex.net",
                "omtrdc.net",
                "krxd.net",
                "bluekai.com",
                "mathtag.com",
                "rlcdn.com",
                "agkn.com",
                "simpli.fi",
                "chartbeat.com",
                "mixpanel.com",
                "amplitude.com"
            ]
        ),
        TrackerProtectionCategory(
            id: "session-recording",
            title: String(localized: "Session recording"),
            summary: String(
                localized: "Scripts that capture scrolling, typing, and mouse movement while a page is open."
            ),
            domains: [
                "hotjar.com",
                "fullstory.com",
                "mouseflow.com",
                "clarity.ms"
            ]
        )
    ]

    private static let blockedTrackerDomains = protectionCategories.flatMap(\.domains)

    private static func encodedRules() -> String {
        let rules: [[String: Any]] = blockedTrackerDomains.map { domain in
            let escapedDomain = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://(.*\\.)?\(escapedDomain)[/:]",
                    "load-type": ["third-party"]
                ],
                "action": ["type": "block"]
            ]
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: rules),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }

        return encoded
    }
}
