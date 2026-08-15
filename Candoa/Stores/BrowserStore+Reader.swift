import Foundation

extension BrowserStore {
    // MARK: - Reader Mode

    /// The menu command is one toggle: it enables when the active page can
    /// enter Reader, or is already in it (so Hide Reader always works).
    var canToggleReaderForActiveTab: Bool {
        guard let activeTabID else { return false }
        return readerAvailableTabIDs.contains(activeTabID)
            || readerActiveTabIDs.contains(activeTabID)
    }

    var isReaderActiveForActiveTab: Bool {
        guard let activeTabID else { return false }
        return readerActiveTabIDs.contains(activeTabID)
    }

    /// Leaves Reader without touching availability, so the tab can re-enter
    /// it. Escape uses this rather than the toggle: it is an exit, never an
    /// entrance.
    func hideReaderForActiveTab() {
        guard let activeTabID, readerActiveTabIDs.contains(activeTabID) else { return }
        webCoordinator.hideReader(for: activeTabID)
    }

    func toggleReaderForActiveTab() {
        guard let activeTabID else { return }
        if readerActiveTabIDs.contains(activeTabID) {
            webCoordinator.hideReader(for: activeTabID)
        } else {
            webCoordinator.showReader(for: activeTabID)
        }
    }

    /// Written only by the coordinator, which owns the actual reader state;
    /// these published mirrors exist so menu items re-evaluate.
    func setReaderAvailable(_ isAvailable: Bool, for tabID: UUID) {
        if isAvailable {
            guard !readerAvailableTabIDs.contains(tabID) else { return }
            readerAvailableTabIDs.insert(tabID)
        } else {
            guard readerAvailableTabIDs.contains(tabID) else { return }
            readerAvailableTabIDs.remove(tabID)
        }
    }

    func setReaderActive(_ isActive: Bool, for tabID: UUID) {
        if isActive {
            guard !readerActiveTabIDs.contains(tabID) else { return }
            readerActiveTabIDs.insert(tabID)
        } else {
            guard readerActiveTabIDs.contains(tabID) else { return }
            readerActiveTabIDs.remove(tabID)
        }
    }
}
