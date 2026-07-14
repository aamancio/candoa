import Foundation

struct HistoryVisit: Identifiable, Hashable {
    let id: UUID
    let title: String
    let url: URL
    let tabID: UUID
    let spaceID: UUID
    let visitedAt: Date
}
