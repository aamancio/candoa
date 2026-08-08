import Foundation

/// Outcome of performing a proposed page action. Callers branch on `status`;
/// `message` is the English description forwarded verbatim to the cloud agent
/// run (`BrowserAgentActionOutcome.result`) and is never shown in the UI.
struct PageActionResult: Sendable {
    enum Status: Sendable {
        case executed
        case failed
    }

    let status: Status
    let message: String

    static func executed(_ message: String) -> PageActionResult {
        PageActionResult(status: .executed, message: message)
    }

    static func failed(_ message: String) -> PageActionResult {
        PageActionResult(status: .failed, message: message)
    }
}

struct PageActionProposal: Identifiable, Sendable {
    let id = UUID()
    let kind: PageActionKind
    let target: String
    let value: String?
    let browserAgentReference: String?
    let browserAgentSnapshotID: UUID?
    let browserAgentPageURL: String?
    let browserAgentControlKind: BrowserAgentControl.Kind?

    init(
        kind: PageActionKind,
        target: String,
        value: String?,
        browserAgentReference: String? = nil,
        browserAgentSnapshotID: UUID? = nil,
        browserAgentPageURL: String? = nil,
        browserAgentControlKind: BrowserAgentControl.Kind? = nil
    ) {
        self.kind = kind
        self.target = target
        self.value = value
        self.browserAgentReference = browserAgentReference
        self.browserAgentSnapshotID = browserAgentSnapshotID
        self.browserAgentPageURL = browserAgentPageURL
        self.browserAgentControlKind = browserAgentControlKind
    }
}
