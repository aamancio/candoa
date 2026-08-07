import Foundation

/// Shows the sidebar's post-update "See What's New" pill on the first launch
/// after the app's version changes, until the person opens or dismisses it.
@MainActor
final class WhatsNewService: ObservableObject {
    static let shared = WhatsNewService()

    /// Hosted release-notes page on Candoa Cloud; the release workflow
    /// appends an entry there for every published version.
    static let pageURL = URL(string: "https://candoa.app/whats-new")!
    private static let lastSeenVersionKey = "whatsNewLastSeenVersion"

    @Published private(set) var isPromptVisible: Bool

    private let defaults = UserDefaults.standard
    private let currentVersion: String?
    private let isUITestingFixture: Bool

    private init() {
        let environment = ProcessInfo.processInfo.environment
        isUITestingFixture = environment["CANDOA_UI_TESTING"] == "1"
        currentVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        if isUITestingFixture {
            // Hermetic fixture, mirroring the update banner: tests opt in
            // explicitly and nothing is persisted.
            isPromptVisible = environment["CANDOA_UI_TESTING_WHATS_NEW"] == "1"
            return
        }

#if DEBUG
        // Development builds restamp the version on every commit and share
        // the release app's defaults container, so staying inert keeps the
        // pill from nagging after rebuilds and from skewing the release
        // anchor. The fixture above still exercises the UI.
        isPromptVisible = false
#else
        guard let currentVersion else {
            isPromptVisible = false
            return
        }

        if let lastSeenVersion = defaults.string(forKey: Self.lastSeenVersionKey) {
            // The stored version only advances in acknowledge(), so the pill
            // survives relaunches until it is opened or dismissed.
            isPromptVisible = lastSeenVersion != currentVersion
        } else {
            // First launch after install (or after this feature shipped):
            // nothing to announce, just anchor the comparison.
            defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
            isPromptVisible = false
        }
#endif
    }

    /// Marks the running version as seen and hides the pill.
    func acknowledge() {
        isPromptVisible = false
#if !DEBUG
        guard !isUITestingFixture, let currentVersion else { return }
        defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
#endif
    }
}
