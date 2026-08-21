import Foundation
import WebKit

/// Runs Eli's page scripts (Resources/BrowserAgent) inside a tab's web view.
///
/// Every script is handed to WebKit with `shared.js` prepended, so the
/// snapshot that assigns a ref and the action that consumes it use the same
/// accessible-name and visibility code. The scripts run in Candoa's isolated
/// content world: the page cannot see the ref registry, and the registry
/// cannot be confused by page globals.
@MainActor
struct BrowserAgentDriver {
    private enum Script: String {
        case shared
        case snapshot
        case scroll
        case performReferencedAction
        case waitForSettle
    }

    enum DriverError: Error {
        case missingScript(String)
        case invalidStringResult
        case actionNotGrounded
    }

    /// Characters of accessibility tree sent per step. Playwright MCP and
    /// Claude in Chrome land in the same range; the model reads the viewport
    /// in full and the rest of the page as budget allows.
    static let treeBudget = 24_000

    private let bundle: Bundle
    private let contentWorld: WKContentWorld

    init(
        bundle: Bundle = .main,
        contentWorld: WKContentWorld
    ) {
        self.bundle = bundle
        self.contentWorld = contentWorld
    }

    func snapshot(
        in webView: WKWebView,
        id snapshotID: UUID
    ) async throws -> BrowserAgentSnapshot {
        let value = try await execute(
            .snapshot,
            arguments: [
                "snapshotID": snapshotID.uuidString.lowercased(),
                "budget": Self.treeBudget,
            ],
            in: webView
        )
        let payload = try JSONDecoder().decode(
            SnapshotPayload.self,
            from: Data(stringResult(from: value).utf8)
        )
        return BrowserAgentSnapshot(
            id: snapshotID,
            tree: payload.tree,
            controls: payload.controls,
            viewport: payload.viewport
        )
    }

    func performAction(
        _ action: PageActionProposal,
        in webView: WKWebView
    ) async throws -> PageActionResult {
        if action.kind == .scroll {
            guard let snapshotID = action.browserAgentSnapshotID else {
                throw DriverError.actionNotGrounded
            }
            let value = try await execute(
                .scroll,
                arguments: [
                    "snapshotID": snapshotID.uuidString.lowercased(),
                    // "up", "down", or a control ref to bring into view.
                    "direction": action.browserAgentReference ?? action.target,
                ],
                in: webView
            )
            return try actionResult(from: value)
        }

        guard let reference = action.browserAgentReference,
              let snapshotID = action.browserAgentSnapshotID,
              let controlKind = action.browserAgentControlKind else {
            throw DriverError.actionNotGrounded
        }

        let value = try await execute(
            .performReferencedAction,
            arguments: [
                "snapshotID": snapshotID.uuidString.lowercased(),
                "ref": reference,
                "expectedLabel": action.target,
                "expectedKind": controlKind.rawValue,
                "kind": action.kind.rawValue,
                "value": action.value ?? "",
            ],
            in: webView
        )
        return try actionResult(from: value)
    }

    /// Waits for the page to stop changing after an action: no structural
    /// DOM mutation for `quiet`, or `timeout` at most. Returns how many
    /// mutations were seen, which is itself a signal of whether the action
    /// did anything.
    @discardableResult
    func waitForSettle(
        in webView: WKWebView,
        quiet: Duration = .milliseconds(400),
        timeout: Duration = .seconds(3)
    ) async -> SettleReport? {
        let value = try? await execute(
            .waitForSettle,
            prependingShared: false,
            arguments: [
                "quietMilliseconds": Int(quiet.components.seconds * 1000) + Int(quiet.components.attoseconds / 1_000_000_000_000_000),
                "timeoutMilliseconds": Int(timeout.components.seconds * 1000) + Int(timeout.components.attoseconds / 1_000_000_000_000_000),
            ],
            in: webView
        )
        guard let json = value as? String else { return nil }
        return try? JSONDecoder().decode(SettleReport.self, from: Data(json.utf8))
    }

    struct SettleReport: Decodable, Sendable {
        let mutations: Int
        let settled: Bool
        let elapsed: Int
    }

    private struct SnapshotPayload: Decodable {
        let tree: String
        let controls: [BrowserAgentControl]
        let viewport: BrowserAgentViewport
    }

    private func execute(
        _ script: Script,
        prependingShared: Bool = true,
        arguments: [String: Any],
        in webView: WKWebView
    ) async throws -> Any? {
        let body = prependingShared
            ? try source(for: .shared) + "\n" + source(for: script)
            : try source(for: script)
        return try await webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: contentWorld
        )
    }

    private func source(for script: Script) throws -> String {
        guard let url = bundle.url(
            forResource: script.rawValue,
            withExtension: "js",
            subdirectory: "BrowserAgent"
        ) else {
            throw DriverError.missingScript(script.rawValue)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func stringResult(from value: Any?) throws -> String {
        guard let value = value as? String else {
            throw DriverError.invalidStringResult
        }
        return value
    }

    /// The action scripts report `{ ok, message }` so the outcome status is
    /// explicit instead of inferred from the message wording.
    private struct ActionResultPayload: Decodable {
        let ok: Bool
        let message: String
    }

    private func actionResult(from value: Any?) throws -> PageActionResult {
        let payload = try JSONDecoder().decode(
            ActionResultPayload.self,
            from: Data(stringResult(from: value).utf8)
        )
        return payload.ok ? .executed(payload.message) : .failed(payload.message)
    }
}
