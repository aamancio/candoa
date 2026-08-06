import Foundation

enum CandoaAIProvider: String, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic
    case google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        }
    }

    var keychainAccount: String { "\(rawValue)-api-key" }

    var keyPlaceholder: String {
        switch self {
        case .openai: return "sk-..."
        case .anthropic: return "sk-ant-..."
        case .google: return "AIza..."
        }
    }

    /// Debug/development-only credential source. Process environment variables
    /// are never a storage mechanism for public-release users.
    var environmentVariable: String {
        switch self {
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .google: return "GOOGLE_GENERATIVE_AI_API_KEY"
        }
    }
}

enum CandoaAIReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// A provider-qualified model identity plus the request-time metadata Ask
/// needs: context budgeting inputs and which reasoning efforts the adapter
/// can express without inventing unsupported API values.
struct CandoaAIModel: Identifiable, Equatable, Sendable {
    /// Provider-qualified identity, e.g. `openai/gpt-5.6-luna`.
    let id: String
    let provider: CandoaAIProvider
    let displayName: String
    let contextWindowTokens: Int
    let maxOutputTokens: Int
    let supportedEfforts: [CandoaAIReasoningEffort]

    var bareModelID: String {
        guard let separator = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: separator)...])
    }

    func clampedEffort(_ effort: CandoaAIReasoningEffort) -> CandoaAIReasoningEffort {
        supportedEfforts.contains(effort) ? effort : (supportedEfforts.first ?? .low)
    }
}

enum CandoaEliConnection: String, CaseIterable, Identifiable {
    case candoaCloud
    case personalKey
    case environment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .candoaCloud: return "Candoa Cloud"
        case .personalKey: return "Personal API key"
        case .environment: return "Environment (Debug)"
        }
    }
}

enum CandoaAIModelCatalog {
    /// Curated, updateable client catalog for BYOK. Hosted models remain
    /// server-authoritative; entries here also enrich hosted IDs with the
    /// metadata the server catalog does not carry yet.
    static let directModels: [CandoaAIModel] = [
        CandoaAIModel(
            id: "openai/gpt-5.6-luna",
            provider: .openai,
            displayName: "GPT-5.6 Luna",
            contextWindowTokens: 400_000,
            maxOutputTokens: 128_000,
            supportedEfforts: [.low, .medium, .high]
        ),
        CandoaAIModel(
            id: "openai/gpt-5",
            provider: .openai,
            displayName: "GPT-5",
            contextWindowTokens: 400_000,
            maxOutputTokens: 128_000,
            supportedEfforts: [.low, .medium, .high]
        ),
        CandoaAIModel(
            id: "anthropic/claude-opus-5",
            provider: .anthropic,
            displayName: "Claude Opus 5",
            contextWindowTokens: 1_000_000,
            maxOutputTokens: 128_000,
            supportedEfforts: [.low, .medium, .high]
        ),
        CandoaAIModel(
            id: "anthropic/claude-sonnet-5",
            provider: .anthropic,
            displayName: "Claude Sonnet 5",
            contextWindowTokens: 1_000_000,
            maxOutputTokens: 128_000,
            supportedEfforts: [.low, .medium, .high]
        ),
        CandoaAIModel(
            id: "anthropic/claude-haiku-4-5",
            provider: .anthropic,
            displayName: "Claude Haiku 4.5",
            contextWindowTokens: 200_000,
            maxOutputTokens: 64_000,
            supportedEfforts: [.low]
        ),
        CandoaAIModel(
            id: "google/gemini-3.5-flash",
            provider: .google,
            displayName: "Gemini 3.5 Flash",
            contextWindowTokens: 1_000_000,
            maxOutputTokens: 64_000,
            supportedEfforts: [.low]
        ),
    ]

    static func directModels(for provider: CandoaAIProvider) -> [CandoaAIModel] {
        directModels.filter { $0.provider == provider }
    }

    static func directDefaultModel(for provider: CandoaAIProvider) -> CandoaAIModel {
        directModels(for: provider)[0]
    }

    static func model(forID id: String) -> CandoaAIModel? {
        directModels.first { $0.id == id }
    }

    /// Hosted plan availability comes from the server; only display metadata
    /// and budgeting numbers are resolved client-side, with conservative
    /// defaults for hosted models this build does not know.
    static func hostedModel(id: String, providerID: String, displayName: String) -> CandoaAIModel {
        if let known = model(forID: id) {
            return known
        }
        return CandoaAIModel(
            id: id,
            provider: CandoaAIProvider(rawValue: providerID) ?? .openai,
            displayName: displayName,
            contextWindowTokens: 128_000,
            maxOutputTokens: 16_000,
            supportedEfforts: [.low, .medium, .high]
        )
    }
}

enum CandoaEliContextBudgetError: LocalizedError {
    case requestTooLarge

    var errorDescription: String? {
        "This conversation and page context are too large for the selected model. Remove some attached context or start a new conversation."
    }
}

/// Request-time input budgeting: fit the newest turns and attached page
/// context inside the selected model's advertised context window. Uses a
/// conservative characters-per-token estimate; no background work.
enum CandoaEliContextBudget {
    private static let charactersPerToken = 3
    private static let fixedOverheadCharacters = 6_000

    static func fittedContext(
        _ context: CandoaAIPageContext,
        prompt: String,
        recentTurns: [CandoaAIConversationTurn],
        model: CandoaAIModel?
    ) throws -> CandoaAIPageContext {
        guard let model else { return context }

        let inputTokenBudget = model.contextWindowTokens - model.maxOutputTokens
        let characterBudget = inputTokenBudget * charactersPerToken - fixedOverheadCharacters
        let turnCharacters = recentTurns.suffix(6).reduce(0) { $0 + $1.text.count }
        let fixedCharacters = prompt.count + turnCharacters
            + (context.title?.count ?? 0) + (context.url?.count ?? 0)

        guard fixedCharacters < characterBudget else {
            throw CandoaEliContextBudgetError.requestTooLarge
        }

        let contextBudget = characterBudget - fixedCharacters
        guard let text = context.text, text.count > contextBudget else {
            return context
        }
        return CandoaAIPageContext(
            title: context.title,
            url: context.url,
            text: String(text.prefix(contextBudget))
        )
    }
}
