import Foundation

enum CandoaPageActionKind: String, Codable, Sendable {
    case navigate
    case click
    case select
    case fill
    case scroll
}

struct CandoaBrowserAgentControl: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case link
        case button
        case choice
        case field
    }

    let ref: String
    let kind: Kind
    let label: String
    let url: String?
    let disabled: Bool
    let selected: Bool
    let sensitive: Bool
    let options: [String]

    init(
        ref: String,
        kind: Kind,
        label: String,
        url: String?,
        disabled: Bool,
        selected: Bool = false,
        sensitive: Bool = false,
        options: [String] = []
    ) {
        self.ref = ref
        self.kind = kind
        self.label = label
        self.url = url
        self.disabled = disabled
        self.selected = selected
        self.sensitive = sensitive
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case ref, kind, label, url, disabled, selected, sensitive, options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        kind = try container.decode(Kind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        disabled = try container.decode(Bool.self, forKey: .disabled)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        sensitive = try container.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}

struct CandoaBrowserAgentPage: Codable, Sendable {
    let snapshotID: UUID
    let title: String?
    let url: String
    let text: String
    let controls: [CandoaBrowserAgentControl]
}

struct CandoaBrowserAgentSnapshot: Sendable {
    let id: UUID
    let controls: [CandoaBrowserAgentControl]
}

struct CandoaBrowserAgentActionOutcome: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case executed
        case failed
        case rejected
    }

    let status: Status
    let result: String
    let page: CandoaBrowserAgentPage?
}

struct CandoaBrowserAgentRunResponse: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case action
        case complete
        case blocked
    }

    let runID: UUID
    let status: Status
    let message: String
    let action: CandoaBrowserAgentAction?
}

struct CandoaBrowserAgentAction: Codable, Sendable {
    let snapshotID: UUID
    let kind: CandoaPageActionKind
    let target: String
    let value: String
    let label: String
    let url: String?
    let requiresApproval: Bool
    let message: String

    func validatedAction(on page: CandoaBrowserAgentPage) -> CandoaPageActionProposal? {
        guard page.snapshotID == snapshotID else { return nil }
        if kind == .scroll {
            guard ["up", "down"].contains(target) else { return nil }
            return CandoaPageActionProposal(
                kind: .scroll,
                target: target,
                value: nil,
                browserAgentSnapshotID: snapshotID,
                browserAgentPageURL: page.url
            )
        }

        guard let control = page.controls.first(where: { $0.ref == target }),
              !control.disabled,
              control.label == label else { return nil }

        switch kind {
        case .click:
            guard [.link, .button, .choice].contains(control.kind) else { return nil }
        case .select:
            guard control.kind == .choice else { return nil }
            if !value.isEmpty,
               !control.options.contains(where: { labelsMatch($0, value) }) {
                return nil
            }
        case .fill:
            guard control.kind == .field, !value.isEmpty else { return nil }
        case .navigate:
            guard control.kind == .link,
                  let controlURL = control.url,
                  controlURL == url,
                  let destination = URL(string: controlURL),
                  let current = URL(string: page.url),
                  isSameSite(destination, current) else { return nil }
        case .scroll:
            break
        }

        return CandoaPageActionProposal(
            kind: kind,
            target: kind == .navigate ? (control.url ?? control.label) : control.label,
            value: value.isEmpty ? nil : value,
            browserAgentReference: control.ref,
            browserAgentSnapshotID: snapshotID,
            browserAgentPageURL: page.url,
            browserAgentControlKind: control.kind
        )
    }

    private func labelsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func isSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedHost(lhs) == normalizedHost(rhs)
    }

    private func normalizedHost(_ url: URL) -> String {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

enum CandoaBrowserAgentPolicy {
    /// The model's `requiresApproval` judgment is a floor, never a ceiling: an action
    /// that targets a structurally sensitive control (per the snapshot's DOM semantics)
    /// must be confirmed natively even when the server marked it routine.
    static func requiresNativeApproval(
        for action: CandoaBrowserAgentAction,
        on page: CandoaBrowserAgentPage
    ) -> Bool {
        if action.requiresApproval { return true }
        guard action.kind != .scroll else { return false }
        return page.controls.first(where: { $0.ref == action.target })?.sensitive == true
    }

    static func sensitiveConfirmationMessage(for action: CandoaPageActionProposal) -> String {
        switch action.kind {
        case .click:
            return "Eli is ready to activate \"\(action.target)\". This may make a consequential change to your account."
        case .select:
            return "Eli is ready to select \"\(action.value ?? action.target)\". Review this choice before continuing."
        case .fill:
            return "Eli is ready to enter information in \"\(action.target)\". Review it before continuing."
        case .navigate:
            return "Eli is ready to open \"\(action.target)\". Review the destination before continuing."
        case .scroll:
            return "Eli is ready to continue this task."
        }
    }
}

enum CandoaBrowserAgentRemoteService {
    static func start(
        runID: UUID,
        goal: String,
        page: CandoaBrowserAgentPage
    ) async throws -> CandoaBrowserAgentRunResponse {
        try await advance(RunRequest(runID: runID, start: .init(goal: goal, page: page), outcome: nil))
    }

    static func resume(
        runID: UUID,
        outcome: CandoaBrowserAgentActionOutcome
    ) async throws -> CandoaBrowserAgentRunResponse {
        try await advance(RunRequest(runID: runID, start: nil, outcome: outcome))
    }

    private static func advance(_ payload: RunRequest) async throws -> CandoaBrowserAgentRunResponse {
        guard let accessToken = CandoaAccountKeychain.accessToken else {
            throw CandoaRemoteEliError.missingAccountSession
        }
        var request = URLRequest(url: CandoaCloudAPI.aiAgentRunURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(CandoaBrowserAgentRunResponse.self, from: data)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw CandoaRemoteEliError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
                ?? "Eli could not continue the browser task."
            throw CandoaRemoteEliError.server(message)
        }
    }

    private struct RunRequest: Encodable {
        let runID: UUID
        let start: Start?
        let outcome: CandoaBrowserAgentActionOutcome?
    }

    private struct Start: Encodable {
        let goal: String
        let page: CandoaBrowserAgentPage
    }

    private struct ServerError: Decodable {
        let error: String?
    }
}
