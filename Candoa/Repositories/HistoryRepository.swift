import Foundation

protocol HistoryRepository: Sendable {
    func record(_ visit: HistoryVisit)
    func recentVisits(matching query: String, in spaceID: UUID?, limit: Int) -> [HistoryVisit]
    func visits(matching query: String, in spaceID: UUID?, limit: Int, offset: Int) -> [HistoryVisit]
    func deleteVisits(withIDs ids: Set<UUID>) throws
    func deleteVisits(visitedAfter startDate: Date?, in spaceID: UUID?) throws
}

/// History repository for private windows. Visits are dropped — private
/// browsing records no history and therefore syncs none. Reads and
/// per-space deletes pass through to the persistent store; since all
/// consumers scope queries to the active space and a private window's
/// space is ephemeral, a private window surfaces no history in practice.
/// A space-less delete would wipe every ordinary Space's history, so it
/// is refused here even though no private surface currently offers one.
struct PrivateBrowsingHistoryRepository: HistoryRepository {
    let base: CoreDataHistoryRepository

    func record(_ visit: HistoryVisit) {}

    func recentVisits(matching query: String, in spaceID: UUID?, limit: Int) -> [HistoryVisit] {
        base.recentVisits(matching: query, in: spaceID, limit: limit)
    }

    func visits(matching query: String, in spaceID: UUID?, limit: Int, offset: Int) -> [HistoryVisit] {
        base.visits(matching: query, in: spaceID, limit: limit, offset: offset)
    }

    func deleteVisits(withIDs ids: Set<UUID>) throws {
        try base.deleteVisits(withIDs: ids)
    }

    func deleteVisits(visitedAfter startDate: Date?, in spaceID: UUID?) throws {
        guard spaceID != nil else { return }
        try base.deleteVisits(visitedAfter: startDate, in: spaceID)
    }
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

    func deleteVisits(visitedAfter startDate: Date?, in spaceID: UUID?) throws {
        try persistence.deleteHistory(visitedAfter: startDate, in: spaceID)
    }
}
