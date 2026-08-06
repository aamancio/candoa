import Foundation

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
