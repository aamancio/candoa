import Foundation
import WebKit

@MainActor
struct BrowserAgentDriver {
    private enum Script: String {
        case snapshot
        case scroll
        case performReferencedAction
    }

    enum DriverError: Error {
        case missingScript(String)
        case invalidStringResult
        case actionNotGrounded
    }

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
            arguments: ["snapshotID": snapshotID.uuidString.lowercased()],
            in: webView,
            contentWorld: contentWorld
        )
        let json = try stringResult(from: value)
        let controls = try JSONDecoder().decode(
            [BrowserAgentControl].self,
            from: Data(json.utf8)
        )
        return BrowserAgentSnapshot(id: snapshotID, controls: controls)
    }

    func performAction(
        _ action: PageActionProposal,
        in webView: WKWebView
    ) async throws -> String {
        if action.kind == .scroll {
            guard let snapshotID = action.browserAgentSnapshotID else {
                throw DriverError.actionNotGrounded
            }
            let value = try await execute(
                .scroll,
                arguments: [
                    "snapshotID": snapshotID.uuidString.lowercased(),
                    "direction": action.target,
                ],
                in: webView,
                contentWorld: contentWorld
            )
            return try stringResult(from: value)
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
            in: webView,
            contentWorld: contentWorld
        )
        return try stringResult(from: value)
    }

    private func execute(
        _ script: Script,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            try source(for: script),
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
}
