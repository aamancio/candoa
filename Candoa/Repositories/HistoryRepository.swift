import Foundation

protocol HistoryRepository: Sendable {
    func record(_ visit: HistoryVisit)
    func recentVisits(matching query: String, in spaceID: UUID?, limit: Int) -> [HistoryVisit]
    func visits(matching query: String, in spaceID: UUID?, limit: Int, offset: Int) -> [HistoryVisit]
    func deleteVisits(withIDs ids: Set<UUID>) throws
    func deleteVisits(visitedAfter startDate: Date?) throws
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

    func visits(matching query: String, in spaceID: UUID?, limit: Int, offset: Int) -> [HistoryVisit] {
        persistence.history(matching: query, in: spaceID, limit: limit, offset: offset)
    }

    func deleteVisits(withIDs ids: Set<UUID>) throws {
        try persistence.deleteHistory(withIDs: ids)
    }

    func deleteVisits(visitedAfter startDate: Date?) throws {
        try persistence.deleteHistory(visitedAfter: startDate)
    }
}
