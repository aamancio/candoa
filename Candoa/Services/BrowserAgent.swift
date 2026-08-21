import Foundation

enum PageActionKind: String, Codable, Sendable {
    case navigate
    case click
    case select
    case fill
    case scroll
    /// A key press in a focused control — Enter to submit a search or a
    /// form the way a person would, Escape to dismiss what a click opened.
    case press

    /// Keys `press` may send. Anything else is rejected at grounding.
    static let pressableKeys: Set<String> = [
        "Enter", "Escape", "Tab", "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight", "Backspace", "Space",
    ]
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
    /// The ARIA role the snapshot printed for this control (`link`,
    /// `combobox`, `clickable`…); finer than `kind`, informational only.
    let role: String?

    init(
        ref: String,
        kind: Kind,
        label: String,
        url: String?,
        disabled: Bool,
        selected: Bool = false,
        sensitive: Bool = false,
        options: [String] = [],
        role: String? = nil
    ) {
        self.ref = ref
        self.kind = kind
        self.label = label
        self.url = url
        self.disabled = disabled
        self.selected = selected
        self.sensitive = sensitive
        self.options = options
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case ref, kind, label, url, disabled, selected, sensitive, options, role
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
        role = try container.decodeIfPresent(String.self, forKey: .role)
    }
}

/// Where the viewport sits on the page at snapshot time, so the model can
/// tell a short page from one it has only seen the top of.
struct BrowserAgentViewport: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
    let scrollTop: Int
    let scrollHeight: Int
    let linesAbove: Int
    let linesBelow: Int
    let modal: Bool
}

struct BrowserAgentPage: Codable, Sendable {
    let snapshotID: UUID
    let title: String?
    let url: String
    let text: String
    let controls: [BrowserAgentControl]
    /// The accessibility-tree snapshot (Resources/BrowserAgent/snapshot.js):
    /// what the model actually reads. `controls` is the same walk flattened
    /// for grounding, and `text` is the readable-text fallback older servers
    /// render.
    let tree: String?
    let viewport: BrowserAgentViewport?

    init(
        snapshotID: UUID,
        title: String?,
        url: String,
        text: String,
        controls: [BrowserAgentControl],
        tree: String? = nil,
        viewport: BrowserAgentViewport? = nil
    ) {
        self.snapshotID = snapshotID
        self.title = title
        self.url = url
        self.text = text
        self.controls = controls
        self.tree = tree
        self.viewport = viewport
    }
}

struct BrowserAgentSnapshot: Sendable {
    let id: UUID
    let tree: String
    let controls: [BrowserAgentControl]
    let viewport: BrowserAgentViewport
}

/// What changed between the page an action was chosen on and the page it
/// left behind. Appended to the outcome the model reads, so "Clicked
/// Continue" comes with "the URL changed" or "nothing visible changed" —
/// the verification the model would otherwise have to infer from a second
/// snapshot, or skip.
enum BrowserAgentPageDiff {
    static let maximumListedControls = 4

    static func summary(before: BrowserAgentPage, after: BrowserAgentPage, mutations: Int?) -> String {
        var parts: [String] = []
        if before.url != after.url {
            parts.append("The URL changed to \(after.url).")
        }
        if let beforeTitle = before.title, let afterTitle = after.title, beforeTitle != afterTitle, !afterTitle.isEmpty {
            parts.append("The title is now \"\(afterTitle)\".")
        }
        if before.viewport?.modal == false, after.viewport?.modal == true {
            parts.append("A dialog opened.")
        } else if before.viewport?.modal == true, after.viewport?.modal == false {
            parts.append("The dialog closed.")
        }

        let beforeLabels = Set(before.controls.map(\.label))
        let afterLabels = Set(after.controls.map(\.label))
        let appeared = after.controls.map(\.label).filter { !beforeLabels.contains($0) }.uniqued()
        let disappeared = before.controls.map(\.label).filter { !afterLabels.contains($0) }.uniqued()
        if !appeared.isEmpty {
            parts.append("New controls: \(list(appeared)).")
        }
        if !disappeared.isEmpty {
            parts.append("Gone: \(list(disappeared)).")
        }

        if parts.isEmpty {
            if let mutations, mutations > 0 {
                parts.append("The page updated but its controls did not change.")
            } else if before.url == after.url {
                parts.append("Nothing visible changed.")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func list(_ labels: [String]) -> String {
        let shown = labels.prefix(maximumListedControls).map { "\"\($0.count > 60 ? String($0.prefix(59)) + "…" : $0)\"" }
        let remainder = labels.count - shown.count
        return shown.joined(separator: ", ") + (remainder > 0 ? " and \(remainder) more" : "")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

struct BrowserAgentActionOutcome: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case executed
        case failed
        case rejected
        /// The user cleared a wait-for-user handoff and asked Eli to continue.
        /// Requires a fresh page snapshot, like `executed`.
        case resumed
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
        /// The run is paused on something only the user can clear (an ad, a
        /// sign-in, a CAPTCHA). The workflow stays alive; resume with a
        /// `.resumed` outcome or end it with `.rejected`.
        case waiting

        // A status this client doesn't know must not abort the run loop —
        // it decodes as `blocked` so the server's message still surfaces.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .blocked
        }
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
            if let control = page.controls.first(where: { $0.ref == target }) {
                // Scroll a control into view; the label check keeps it to
                // the control the snapshot showed.
                guard control.label == label else { return nil }
                return PageActionProposal(
                    kind: .scroll,
                    target: control.label,
                    value: nil,
                    browserAgentReference: control.ref,
                    browserAgentSnapshotID: snapshotID,
                    browserAgentPageURL: page.url,
                    browserAgentControlKind: control.kind
                )
            }
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
        case .press:
            guard PageActionKind.pressableKeys.contains(value) else { return nil }
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

/// Permission to type into the personal fields of one page, granted once so a
/// long form is not one modal per field. Scoped to the run, the tab, and the
/// exact URL that was on screen when it was granted: a new page, a new run, or
/// a different tab has to ask again.
struct BrowserAgentFillConsent: Equatable, Sendable {
    let runID: UUID
    let tabID: UUID
    let url: String

    func covers(runID: UUID, tabID: UUID, url: String) -> Bool {
        self.runID == runID && self.tabID == tabID && self.url == url
    }
}

enum BrowserAgentPolicy {
    /// The model's `requiresApproval` judgment is a floor, never a ceiling: an action
    /// that targets a structurally sensitive control (per the snapshot's DOM semantics)
    /// must be confirmed natively even when the server marked it routine.
    ///
    /// `fillConsent` is the one thing that can lower the bar, and only for
    /// typing into a field on the page it was granted for. Buttons are never
    /// covered: agreeing to have a form filled is not agreeing to send it.
    static func requiresNativeApproval(
        for action: BrowserAgentAction,
        on page: BrowserAgentPage,
        fillConsent: BrowserAgentFillConsent? = nil,
        runID: UUID? = nil,
        tabID: UUID? = nil
    ) -> Bool {
        if action.requiresApproval { return true }
        guard action.kind != .scroll else { return false }
        // Direct URL navigation (an empty or non-ref target) matches no
        // control here and is intentionally not sensitive on its own: it loads
        // natively in the tab and is reversible with Back. The model's
        // `requiresApproval` judgment above still gates it.
        guard let control = page.controls.first(where: { $0.ref == action.target }),
              control.sensitive else {
            return false
        }
        if isCoveredByFillConsent(action, control: control, page: page, fillConsent: fillConsent, runID: runID, tabID: tabID) {
            return false
        }
        return true
    }

    /// Whether a page-scoped consent already covers this action. Deliberately
    /// narrow: a fill, into a field, on the page the consent names.
    static func isCoveredByFillConsent(
        _ action: BrowserAgentAction,
        control: BrowserAgentControl,
        page: BrowserAgentPage,
        fillConsent: BrowserAgentFillConsent?,
        runID: UUID?,
        tabID: UUID?
    ) -> Bool {
        guard action.kind == .fill, control.kind == .field,
              let fillConsent, let runID, let tabID else {
            return false
        }
        return fillConsent.covers(runID: runID, tabID: tabID, url: page.url)
    }

    /// Whether this confirmation should offer to cover the rest of the page's
    /// fields. Only a fill into a field qualifies — the offer would be
    /// meaningless on a click, and dangerous on a submit.
    static func allowsPageScopedFillConsent(for action: PageActionProposal) -> Bool {
        action.kind == .fill && action.browserAgentControlKind == .field
    }

    static func sensitiveConfirmationMessage(for action: PageActionProposal) -> String {
        switch action.kind {
        case .click:
            return String(localized: "Eli is ready to activate \"\(action.target)\". This may make a consequential change to your account.")
        case .select:
            return String(localized: "Eli is ready to select \"\(action.value ?? action.target)\". Review this choice before continuing.")
        case .fill:
            guard allowsPageScopedFillConsent(for: action) else {
                return String(localized: "Eli is ready to enter information in \"\(action.target)\". Review it before continuing.")
            }
            return String(localized: "Eli is ready to enter information in \"\(action.target)\". Fill This Page lets Eli complete the other fields here without asking again; sending the form still needs your approval.")
        case .navigate:
            return String(localized: "Eli is ready to open \"\(action.target)\". Review the destination before continuing.")
        case .press:
            return String(localized: "Eli is ready to press \(action.value ?? "Enter") in \"\(action.target)\". This may send the form.")
        case .scroll:
            return String(localized: "Eli is ready to continue this task.")
        }
    }
}

enum BrowserAgentRemoteService {
    static func start(
        runID: UUID,
        goal: String,
        page: BrowserAgentPage,
        attachedContext: String?
    ) async throws -> BrowserAgentRunResponse {
        try await advance(RunRequest(
            runID: runID,
            start: .init(goal: goal, page: page, attachedContext: attachedContext),
            outcome: nil
        ))
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
            let serverMessage = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            // A 400 means Candoa Cloud rejected the request shape — a protocol
            // bug, not something the user can act on. Its raw validation text
            // goes to the log; the chat gets a plain-language stop. Other
            // statuses keep the server's message, which is written for users
            // (credit and subscription copy relies on this).
            if response.statusCode == 400 {
                NSLog("Candoa Cloud rejected a browser-agent request: \(serverMessage ?? "no detail")")
                throw RemoteEliError.server(
                    String(localized: "Eli hit a problem reading this page and stopped. Please try again.")
                )
            }
            throw RemoteEliError.server(
                serverMessage ?? String(localized: "Eli could not continue the browser task.")
            )
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
        /// The user's attached tab and file sections, sent only on start (the
        /// server carries it for the rest of the run). Nil when nothing was
        /// attached; synthesized encoding omits the key entirely then.
        let attachedContext: String?
    }

    private struct ServerError: Decodable {
        let error: String?
    }
}
