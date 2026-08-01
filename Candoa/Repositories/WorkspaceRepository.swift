protocol WorkspaceRepository: Sendable {
    func loadWorkspace() -> BrowserWindowState?
    func saveWorkspace(_ state: BrowserWindowState)
}

/// Workspace repository for private windows: loads nothing and saves
/// nothing. Private stores must never reach the Core Data session row —
/// a saved snapshot there would not only leak private tabs, it would
/// delete every persisted space and tab absent from that snapshot.
struct EphemeralWorkspaceRepository: WorkspaceRepository {
    func loadWorkspace() -> BrowserWindowState? { nil }
    func saveWorkspace(_ state: BrowserWindowState) {}
}

struct CoreDataWorkspaceRepository: WorkspaceRepository {
    let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    func loadWorkspace() -> BrowserWindowState? {
        persistence.loadState()
    }

    func saveWorkspace(_ state: BrowserWindowState) {
        persistence.saveState(state)
    }
}
