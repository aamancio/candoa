import Foundation

/// Fetches the current chat-capable model list from a provider's own API
/// using the personal (or Debug environment) key, so the BYOK model picker
/// tracks what the key can actually reach instead of a frozen catalog.
///
/// Fetches happen only on demand from the Ask settings surface — never from
/// timers or launch paths — and results live in view state, so an offline Mac
/// simply keeps the curated catalog. Keys stay in request headers; they are
/// never placed in URLs or persisted here.
enum ProviderModelDirectory {
    enum DirectoryError: LocalizedError {
        case requestFailed

        var errorDescription: String? {
            "Candoa couldn’t load the provider’s model list. Showing the built-in catalog instead."
        }
    }

    static func models(for provider: AIProvider, apiKey: String) async throws -> [AIModel] {
        if let fixture = uiTestingFixtureModels(for: provider) {
            return fixture
        }
        switch provider {
        case .openai: return try await openAIModels(apiKey: apiKey)
        case .anthropic: return try await anthropicModels(apiKey: apiKey)
        case .google: return try await googleModels(apiKey: apiKey)
        }
    }

    // MARK: - OpenAI

    /// OpenAI's list mixes chat models with audio, image, embedding, and
    /// moderation endpoints and carries no capability metadata, so chat
    /// models are selected by family prefix.
    private static let openAIChatPrefixes = ["gpt-4", "gpt-5", "o1", "o3", "o4", "chatgpt-"]
    private static let openAIExcludedFragments = [
        "audio", "realtime", "transcribe", "tts", "image", "moderation",
        "embedding", "whisper", "dall-e", "search", "instruct",
    ]

    private static func openAIModels(apiKey: String) async throws -> [AIModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String
                let created: Int?
            }
            let data: [Entry]
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response: Response = try await fetch(request)

        return response.data
            .filter { entry in
                let id = entry.id.lowercased()
                return openAIChatPrefixes.contains(where: id.hasPrefix)
                    && !openAIExcludedFragments.contains(where: id.contains)
            }
            .sorted { ($0.created ?? 0) > ($1.created ?? 0) }
            .map { entry in
                resolvedModel(
                    provider: .openai,
                    bareID: entry.id,
                    displayName: nil,
                    contextWindowTokens: nil,
                    maxOutputTokens: nil
                )
            }
    }

    // MARK: - Anthropic

    private static func anthropicModels(apiKey: String) async throws -> [AIModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String
                let displayName: String?

                private enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                }
            }
            let data: [Entry]
        }

        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        )
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let response: Response = try await fetch(request)

        // The API returns newest-first dated snapshots; keep its order.
        return response.data.map { entry in
            resolvedModel(
                provider: .anthropic,
                bareID: entry.id,
                displayName: entry.displayName,
                contextWindowTokens: nil,
                maxOutputTokens: nil
            )
        }
    }

    // MARK: - Google

    private static func googleModels(apiKey: String) async throws -> [AIModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let name: String
                let displayName: String?
                let inputTokenLimit: Int?
                let outputTokenLimit: Int?
                let supportedGenerationMethods: [String]?
            }
            let models: [Entry]?
        }

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!
        )
        // The key travels in a header, never in the URL.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let response: Response = try await fetch(request)

        let excludedFragments = ["embedding", "aqa", "imagen", "tts", "image-generation", "live"]
        return (response.models ?? [])
            .filter { entry in
                let name = entry.name.lowercased()
                return entry.supportedGenerationMethods?.contains("generateContent") == true
                    && !excludedFragments.contains(where: name.contains)
            }
            .map { entry in
                let bareID = entry.name.hasPrefix("models/")
                    ? String(entry.name.dropFirst("models/".count))
                    : entry.name
                return resolvedModel(
                    provider: .google,
                    bareID: bareID,
                    displayName: entry.displayName,
                    contextWindowTokens: entry.inputTokenLimit,
                    maxOutputTokens: entry.outputTokenLimit
                )
            }
    }

    // MARK: - Shared

    /// Merges a listed model with curated metadata when this build knows the
    /// model (matching dated snapshots like `-20250929` to their undated
    /// catalog entry), and falls back to conservative defaults otherwise so
    /// context budgeting and reasoning clamping never overreach.
    private static func resolvedModel(
        provider: AIProvider,
        bareID: String,
        displayName: String?,
        contextWindowTokens: Int?,
        maxOutputTokens: Int?
    ) -> AIModel {
        let id = "\(provider.rawValue)/\(bareID)"
        let undatedBareID = bareID.replacingOccurrences(
            of: #"-\d{8}$"#,
            with: "",
            options: .regularExpression
        )
        let known = AIModelCatalog.model(forID: id)
            ?? AIModelCatalog.model(forID: "\(provider.rawValue)/\(undatedBareID)")

        return AIModel(
            id: id,
            provider: provider,
            displayName: displayName ?? known?.displayName ?? bareID,
            contextWindowTokens: contextWindowTokens
                ?? known?.contextWindowTokens
                ?? 128_000,
            maxOutputTokens: maxOutputTokens
                ?? known?.maxOutputTokens
                ?? 16_000,
            supportedEfforts: known?.supportedEfforts
                ?? defaultEfforts(provider: provider, bareID: undatedBareID)
        )
    }

    /// Reasoning support for models the curated catalog does not know.
    /// OpenAI reasoning families accept effort directly; other unknown models
    /// stay clamped to low rather than inventing unsupported API values.
    private static func defaultEfforts(
        provider: AIProvider,
        bareID: String
    ) -> [AIReasoningEffort] {
        switch provider {
        case .openai:
            let id = bareID.lowercased()
            let reasoningPrefixes = ["gpt-5", "o1", "o3", "o4"]
            return reasoningPrefixes.contains(where: id.hasPrefix)
                ? [.low, .medium, .high]
                : [.low]
        case .anthropic, .google:
            return [.low]
        }
    }

    private static func fetch<Response: Decodable>(
        _ request: URLRequest
    ) async throws -> Response {
        var request = request
        request.timeoutInterval = 15
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw DirectoryError.requestFailed
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// UI tests inject a deterministic list instead of reaching provider APIs.
    private static func uiTestingFixtureModels(for provider: AIProvider) -> [AIModel]? {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["CANDOA_UI_TESTING"] == "1",
              let json = environment["CANDOA_UI_TESTING_DIRECT_MODELS"],
              let data = json.data(using: .utf8),
              let models = try? JSONDecoder().decode([AIModel].self, from: data) else {
            return nil
        }
        return models.filter { $0.provider == provider }
#else
        return nil
#endif
    }
}
