import Foundation

protocol HistoryRepository: Sendable {
    func record(_ visit: HistoryVisit)
    func recentVisits(matching query: String, in spaceID: UUID?, limit: Int) -> [HistoryVisit]
}

struct CoreDataHistoryRepository: HistoryRepository {
    let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    func record(_ visit: HistoryVisit) {
        persistence.recordVisit(
            title: visit.title,
            url: visit.url,
            tabID: visit.tabID,
            spaceID: visit.spaceID,
            visitedAt: visit.visitedAt
        )
    }

    func recentVisits(matching query: String, in spaceID: UUID?, limit: Int) -> [HistoryVisit] {
        persistence.recentHistory(matching: query, in: spaceID, limit: limit)
    }
}
