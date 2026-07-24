import Foundation

struct CandoaPageActionProposal: Identifiable, Sendable {
    let id = UUID()
    let kind: CandoaPageActionKind
    let target: String
    let value: String?
    let browserAgentReference: String?
    let browserAgentSnapshotID: UUID?
    let browserAgentPageURL: String?
    let browserAgentControlKind: CandoaBrowserAgentControl.Kind?

    init(
        kind: CandoaPageActionKind,
        target: String,
        value: String?,
        browserAgentReference: String? = nil,
        browserAgentSnapshotID: UUID? = nil,
        browserAgentPageURL: String? = nil,
        browserAgentControlKind: CandoaBrowserAgentControl.Kind? = nil
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
