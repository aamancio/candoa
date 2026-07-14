protocol WorkspaceRepository: Sendable {
    func loadWorkspace() -> BrowserWindowState?
    func saveWorkspace(_ state: BrowserWindowState)
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
