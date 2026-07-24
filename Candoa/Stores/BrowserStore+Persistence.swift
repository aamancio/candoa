import Combine
import Foundation

extension BrowserStore {
    func flushSession() {
        saveSnapshot()
    }

    func setWorkspaceICloudSyncEnabled(_ enabled: Bool) {
        guard iCloudWorkspaceSyncEnabled != enabled else { return }

        if enabled, !CandoaCloudKitEntitlements.hasConfiguredContainer {
            syncRestartMessage = """
            This build is not signed with the CloudKit entitlement yet. Enable the iCloud capability for iCloud.app.candoa.browser in Xcode, then build with your Apple Developer team.
            """
            return
        }

        iCloudWorkspaceSyncEnabled = enabled
        CandoaSyncPreferences.syncsWorkspaceWithICloud = enabled

        if !enabled {
            iCloudHistorySyncEnabled = false
        }

        syncRestartMessage = enabled
            ? "Candoa will start syncing Spaces and tabs through your iCloud database after you relaunch the app."
            : "Candoa will return to local-only Spaces and tabs after you relaunch the app."
    }

    func setHistoryICloudSyncEnabled(_ enabled: Bool) {
        guard iCloudHistorySyncEnabled != enabled else { return }

        if enabled, !CandoaCloudKitEntitlements.hasConfiguredContainer {
            syncRestartMessage = """
            This build is not signed with the CloudKit entitlement yet. Enable the iCloud capability for iCloud.app.candoa.browser in Xcode before syncing history.
            """
            return
        }

        if enabled, !iCloudWorkspaceSyncEnabled {
            setWorkspaceICloudSyncEnabled(true)
        }

        iCloudHistorySyncEnabled = enabled
        CandoaSyncPreferences.syncsHistoryWithICloud = enabled
        syncRestartMessage = enabled
            ? "Candoa will sync browsing history through your iCloud database after you relaunch the app."
            : "Candoa will keep browsing history local-only after you relaunch the app."
    }

    func configureAutosave() {
        let changes = Publishers.MergeMany(
            $spaces.map { _ in () }.eraseToAnyPublisher(),
            $folders.map { _ in () }.eraseToAnyPublisher(),
            $tabs.map { _ in () }.eraseToAnyPublisher(),
            $activeSpaceID.map { _ in () }.eraseToAnyPublisher(),
            $activeTabID.map { _ in () }.eraseToAnyPublisher(),
            $splitTabIDs.map { _ in () }.eraseToAnyPublisher(),
            $isSplitViewEnabled.map { _ in () }.eraseToAnyPublisher()
        )

        saveCancellable = changes
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSnapshot()
            }
    }

    func configureRemoteSyncObservation() {
        guard persistenceService.syncsWorkspaceWithICloud else { return }

        remoteChangeCancellable = NotificationCenter.default
            .publisher(for: PersistenceService.remoteStoreDidChange)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyRemoteStateIfNeeded()
                }
            }
    }

    func saveSnapshot() {
        guard !isInitialOnboardingPresented, !isApplyingRemoteState else { return }

        workspaceRepository.saveWorkspace(currentSnapshot())
    }

    func currentSnapshot() -> BrowserWindowState {
        BrowserWindowState(
            spaces: spaces,
            folders: folders,
            tabs: tabs.map { tab in
                var persistedTab = tab
                persistedTab.isLoading = false
                persistedTab.loadingProgress = 0
                return persistedTab
            },
            activeSpaceID: activeSpaceID,
            activeTabID: activeTabID,
            splitTabIDs: splitTabIDs,
            isSplitViewEnabled: isSplitViewEnabled
        )
    }

    func applyRemoteStateIfNeeded() {
        guard
            let remoteState = workspaceRepository.loadWorkspace(),
            !remoteState.spaces.isEmpty,
            remoteState != currentSnapshot()
        else {
            return
        }

        let previousTabs = tabs
        let previousSpaceDataStores = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.dataStoreID) })
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = false }

        spaces = remoteState.spaces
        folders = remoteState.folders
        tabs = remoteState.tabs
        activeSpaceID = remoteState.activeSpaceID
        activeTabID = remoteState.activeTabID
        splitTabIDs = remoteState.splitTabIDs
        isSplitViewEnabled = remoteState.isSplitViewEnabled
        repairSessionState()
        if Self.isUITesting {
            setInitialOnboardingStep(nil, persists: false)
        } else if needsInitialSpaceSetup() {
            setInitialOnboardingStep(.welcome)
        } else if !UserDefaults.standard.bool(forKey: Self.hasCompletedTourKey) {
            setInitialOnboardingStep(.tour)
        } else {
            setInitialOnboardingStep(nil)
        }
        if !isInitialSpaceSetupPresented {
            isCreateSpacePresented = false
        }
        if let editingSpaceID, !spaces.contains(where: { $0.id == editingSpaceID }) {
            self.editingSpaceID = nil
        }
        if let editingFolderID, !folders.contains(where: { $0.id == editingFolderID }) {
            self.editingFolderID = nil
        }

        let tabIDs = Set(tabs.map(\.id))
        for previousTab in previousTabs where !tabIDs.contains(previousTab.id) {
            webCoordinator.removeWebView(for: previousTab.id)
        }

        for tab in tabs {
            guard let previousTab = previousTabs.first(where: { $0.id == tab.id }) else { continue }
            let previousDataStoreID = previousSpaceDataStores[previousTab.spaceID] ?? previousTab.spaceID
            if previousTab.spaceID != tab.spaceID || previousDataStoreID != dataStoreID(for: tab.spaceID) {
                webCoordinator.removeWebView(for: tab.id)
            }
        }

        restoreVisibleWebViews()
        updateNavigationState()
    }

    func recreateWebViewsIfNeeded(
        in spaceID: UUID,
        previousDataStoreID: UUID,
        nextDataStoreID: UUID
    ) {
        guard previousDataStoreID != nextDataStoreID else { return }

        let affectedTabIDs = tabs
            .filter { $0.spaceID == spaceID }
            .map(\.id)
        affectedTabIDs.forEach { webCoordinator.removeWebView(for: $0) }

        guard activeSpaceID == spaceID else { return }

        if let activeTab {
            webCoordinator.ensureLoaded(activeTab)
        }

        for splitTab in activeSplitTabs {
            webCoordinator.ensureLoaded(splitTab)
        }
    }

    func restoreVisibleWebViews() {
        if let activeTab {
            webCoordinator.ensureLoaded(activeTab)
        }

        for splitTab in activeSplitTabs {
            webCoordinator.ensureLoaded(splitTab)
        }
    }
}
