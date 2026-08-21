import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Fills the subject slot of Eli's suggestion chips with Apple's on-device
/// model (issue #467). Zero tokens, nothing leaves the Mac, and when the
/// model is unavailable — Intel, pre-Tahoe, Apple Intelligence off — the
/// chips simply keep their catalog wording. There is deliberately no cloud
/// fallback: credits are never spent on decoration.
@MainActor
final class EliSuggestionPersonalizer {
    static let shared = EliSuggestionPersonalizer()

    private static let log = Logger(subsystem: "com.candoa.browser", category: "EliSuggestions")

    /// Per page result so tab switches and revisits never re-run the model.
    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private init() {}

    /// Whether the on-device model can run right now. Fixture runs report
    /// unavailable so UI tests see the static chips and no model load; a
    /// fixture that wants the live fill opts back in with
    /// `CANDOA_UI_TESTING_ELI_ON_DEVICE_SUGGESTIONS=1`.
    var isAvailable: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CANDOA_UI_TESTING"] == "1",
           environment["CANDOA_UI_TESTING_ELI_ON_DEVICE_SUGGESTIONS"] != "1" {
            return false
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Loads the model ahead of the first fill so opening the panel on a page
    /// does not pay the cold-start latency on the visible chips.
    func prewarm() {
        #if canImport(FoundationModels)
        guard isAvailable else { return }
        if #available(macOS 26, *) {
            Self.makeSession().prewarm()
        }
        #endif
    }

    /// The page's subject in a few words, or `nil` when the model is
    /// unavailable, the answer is unusable, or the call exceeds `timeout`.
    func subject(
        forExcerpt excerpt: String,
        host: String?,
        cacheKey: String,
        timeout: Duration = .seconds(3)
    ) async -> String? {
        guard isAvailable, !excerpt.isEmpty else { return nil }
        if let cached = cache[cacheKey] { return cached }
        if let running = inFlight[cacheKey] { return await running.value }

        let task = Task<String?, Never> { [weak self] in
            let result = await Self.fill(excerpt: excerpt, host: host, timeout: timeout)
            self?.cache[cacheKey] = result
            self?.inFlight[cacheKey] = nil
            return result
        }
        inFlight[cacheKey] = task
        return await task.value
    }

    private static func fill(excerpt: String, host: String?, timeout: Duration) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        let session = makeSession()
        let generation = Task<String?, Never> {
            do {
                let response = try await session.respond(
                    to: excerpt,
                    generating: SubjectFill.self,
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 40)
                )
                let subject = response.content.subject
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'“”‘’"))
                guard EliSuggestionCatalog.isUsableSubject(subject, host: host) else {
                    log.info("Discarded unusable subject (\(subject.count) chars): \(subject, privacy: .private)")
                    return nil
                }
                log.info("Filled subject: \(subject, privacy: .private)")
                return subject
            } catch is CancellationError {
                log.info("Subject fill timed out after \(timeout.components.seconds)s")
                return nil
            } catch {
                log.info("Subject fill failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(for: timeout)
            generation.cancel()
        }
        let result = await generation.value
        timer.cancel()
        return result
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            model: .default,
            instructions: """
            You label web pages for a browser's suggestion chips. Given a page's \
            title, site, and a short excerpt, answer with the page's specific \
            subject as a short noun phrase of at most five words, in the page's \
            language, suitable for the sentence "Summarize the page about <subject>". \
            Name what the content itself is about — the change, the thread's \
            topic, the product, the decision — rather than the project, site, \
            company, or person hosting it. Never "this page", never a full \
            sentence. For a pull request or commit, name the change it makes, \
            dropping prefixes like "fix:" or "feat:" and ticket numbers.
            """
        )
    }

    @available(macOS 26, *)
    @Generable
    struct SubjectFill {
        @Guide(description: "The page's specific subject as a noun phrase of at most five words.")
        var subject: String
    }
    #endif
}
