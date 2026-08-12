import Foundation

enum PageActionKind: String, Codable, Sendable {
    case navigate
    case click
    case select
    case fill
    case scroll
}

struct BrowserAgentControl: Codable, Sendable {
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

struct BrowserAgentPage: Codable, Sendable {
    let snapshotID: UUID
    let title: String?
    let url: String
    let text: String
    let controls: [BrowserAgentControl]
}

struct BrowserAgentSnapshot: Sendable {
    let id: UUID
    let controls: [BrowserAgentControl]
}

struct BrowserAgentActionOutcome: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case executed
        case failed
        case rejected
    }

    let status: Status
    let result: String
    let page: BrowserAgentPage?
}

struct BrowserAgentRunResponse: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case action
        case complete
        case blocked
    }

    let runID: UUID
    let status: Status
    let message: String
    let action: BrowserAgentAction?
}

struct BrowserAgentAction: Codable, Sendable {
    let snapshotID: UUID
    let kind: PageActionKind
    /// A snapshot control ref, a scroll direction, or — for direct URL
    /// navigation — empty/omitted on the wire.
    let target: String
    let value: String
    let label: String
    let url: String?
    let requiresApproval: Bool
    let message: String

    func validatedAction(on page: BrowserAgentPage) -> PageActionProposal? {
        guard page.snapshotID == snapshotID else { return nil }
        if kind == .scroll {
            guard ["up", "down"].contains(target) else { return nil }
            return PageActionProposal(
                kind: .scroll,
                target: target,
                value: nil,
                browserAgentSnapshotID: snapshotID,
                browserAgentPageURL: page.url
            )
        }
        if kind == .navigate {
            return validatedNavigation(on: page)
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
        case .navigate, .scroll:
            break
        }

        return PageActionProposal(
            kind: kind,
            target: control.label,
            value: value.isEmpty ? nil : value,
            browserAgentReference: control.ref,
            browserAgentSnapshotID: snapshotID,
            browserAgentPageURL: page.url,
            browserAgentControlKind: control.kind
        )
    }

    /// A navigate is valid if EITHER the target is a snapshot link ref (which
    /// stays same-site) OR `url` is a direct absolute http/https destination
    /// (`target` may then be empty). Direct URL navigation loads natively in
    /// the tab — reversible with Back — so cross-site is allowed there.
    private func validatedNavigation(on page: BrowserAgentPage) -> PageActionProposal? {
        if let control = page.controls.first(where: { $0.ref == target }),
           !control.disabled,
           control.label == label,
           control.kind == .link,
           let controlURL = control.url,
           controlURL == url,
           let destination = URL(string: controlURL),
           let current = URL(string: page.url),
           isSameSite(destination, current) {
            return PageActionProposal(
                kind: .navigate,
                target: controlURL,
                value: nil,
                browserAgentReference: control.ref,
                browserAgentSnapshotID: snapshotID,
                browserAgentPageURL: page.url,
                browserAgentControlKind: control.kind
            )
        }

        guard let destination = validatedDirectNavigationURL else { return nil }
        return PageActionProposal(
            kind: .navigate,
            target: destination.absoluteString,
            value: nil,
            browserAgentSnapshotID: snapshotID,
            browserAgentPageURL: page.url
        )
    }

    /// Accepts only an absolute http/https URL without userinfo and within a
    /// bounded length; anything else is rejected rather than repaired.
    private var validatedDirectNavigationURL: URL? {
        guard let url,
              url.count <= 2048,
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let destination = components.url else { return nil }
        return destination
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case snapshotID, kind, target, value, label, url, requiresApproval, message
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

extension BrowserAgentAction {
    // Custom decoding lives in an extension so the struct keeps its memberwise
    // initializer (the UI-test fixtures use it): `target`, `value`, and
    // `label` may be omitted on the wire for direct URL navigation.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotID = try container.decode(UUID.self, forKey: .snapshotID)
        kind = try container.decode(PageActionKind.self, forKey: .kind)
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url)
        requiresApproval = try container.decode(Bool.self, forKey: .requiresApproval)
        message = try container.decode(String.self, forKey: .message)
    }
}

enum BrowserAgentPolicy {
    /// The model's `requiresApproval` judgment is a floor, never a ceiling: an action
    /// that targets a structurally sensitive control (per the snapshot's DOM semantics)
    /// must be confirmed natively even when the server marked it routine.
    static func requiresNativeApproval(
        for action: BrowserAgentAction,
        on page: BrowserAgentPage
    ) -> Bool {
        if action.requiresApproval { return true }
        guard action.kind != .scroll else { return false }
        // Direct URL navigation (an empty or non-ref target) matches no
        // control here and is intentionally not sensitive on its own: it loads
        // natively in the tab and is reversible with Back. The model's
        // `requiresApproval` judgment above still gates it.
        return page.controls.first(where: { $0.ref == action.target })?.sensitive == true
    }

    static func sensitiveConfirmationMessage(for action: PageActionProposal) -> String {
        switch action.kind {
        case .click:
            return String(localized: "Eli is ready to activate \"\(action.target)\". This may make a consequential change to your account.")
        case .select:
            return String(localized: "Eli is ready to select \"\(action.value ?? action.target)\". Review this choice before continuing.")
        case .fill:
            return String(localized: "Eli is ready to enter information in \"\(action.target)\". Review it before continuing.")
        case .navigate:
            return String(localized: "Eli is ready to open \"\(action.target)\". Review the destination before continuing.")
        case .scroll:
            return String(localized: "Eli is ready to continue this task.")
        }
    }
}

enum BrowserAgentRemoteService {
    static func start(
        runID: UUID,
        goal: String,
        page: BrowserAgentPage
    ) async throws -> BrowserAgentRunResponse {
        try await advance(RunRequest(runID: runID, start: .init(goal: goal, page: page), outcome: nil))
    }

    static func resume(
        runID: UUID,
        outcome: BrowserAgentActionOutcome
    ) async throws -> BrowserAgentRunResponse {
        try await advance(RunRequest(runID: runID, start: nil, outcome: outcome))
    }

    private static func advance(_ payload: RunRequest) async throws -> BrowserAgentRunResponse {
        guard let accessToken = AccountKeychain.accessToken else {
            throw RemoteEliError.missingAccountSession
        }
        var request = URLRequest(url: CloudAPI.aiAgentRunURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BrowserAgentRunResponse.self, from: data)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw RemoteEliError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 {
                NotificationCenter.default.post(name: .cloudSessionUnauthorized, object: nil)
                throw RemoteEliError.sessionExpired
            }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
                ?? String(localized: "Eli could not continue the browser task.")
            throw RemoteEliError.server(message)
        }
    }

    private struct RunRequest: Encodable {
        let runID: UUID
        let start: Start?
        let outcome: BrowserAgentActionOutcome?
    }

    private struct Start: Encodable {
        let goal: String
        let page: BrowserAgentPage
    }

    private struct ServerError: Decodable {
        let error: String?
    }
}
