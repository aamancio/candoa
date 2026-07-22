import Combine
import Foundation

enum HistoryClearRange: String, CaseIterable, Identifiable {
    case lastHour
    case today
    case todayAndYesterday
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        }
    }

    func startDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour:
            return now.addingTimeInterval(-60 * 60)
        case .today:
            return calendar.startOfDay(for: now)
        case .todayAndYesterday:
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all:
            return nil
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    private static let pageSize = 200

    @Published private(set) var visits: [HistoryVisit] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleReload()
        }
    }
    @Published var selectedSpaceID: UUID? {
        didSet {
            guard selectedSpaceID != oldValue else { return }
            reload()
        }
    }
    @Published var selection: Set<UUID> = []
    @Published var errorMessage: String?

    private let repository: any HistoryRepository
    private var loadTask: Task<Void, Never>?

    init(repository: any HistoryRepository) {
        self.repository = repository
    }

    deinit {
        loadTask?.cancel()
    }

    func load() {
        reload()
    }

    func reload() {
        selection.removeAll()
        requestPage(offset: 0, replacing: true, debounceNanoseconds: 0)
    }

    func loadMore() {
        guard canLoadMore, !isLoading else { return }
        requestPage(offset: visits.count, replacing: false, debounceNanoseconds: 0)
    }

    func deleteSelection() {
        deleteVisits(withIDs: selection)
    }

    func delete(_ visit: HistoryVisit) {
        deleteVisits(withIDs: [visit.id])
    }

    func clear(_ range: HistoryClearRange) {
        let repository = repository
        let startDate = range.startDate()
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repository.deleteVisits(visitedAfter: startDate)
                }.value
                reload()
            } catch is CancellationError {
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteVisits(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let repository = repository
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repository.deleteVisits(withIDs: ids)
                }.value
                reload()
            } catch is CancellationError {
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleReload() {
        selection.removeAll()
        requestPage(offset: 0, replacing: true, debounceNanoseconds: 150_000_000)
    }

    private func requestPage(offset: Int, replacing: Bool, debounceNanoseconds: UInt64) {
        loadTask?.cancel()
        isLoading = true

        let repository = repository
        let query = searchText
        let spaceID = selectedSpaceID
        let pageSize = Self.pageSize
        loadTask = Task {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
            }

            let page = await Task.detached(priority: .userInitiated) {
                repository.visits(
                    matching: query,
                    in: spaceID,
                    limit: pageSize,
                    offset: offset
                )
            }.value
            guard !Task.isCancelled else { return }

            if replacing {
                visits = page
            } else {
                visits.append(contentsOf: page)
            }
            canLoadMore = page.count == pageSize
            isLoading = false
        }
    }
}
