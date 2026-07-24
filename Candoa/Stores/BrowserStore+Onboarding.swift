import Foundation

extension BrowserStore {
    var isSpaceSetupPresented: Bool {
        isCreateSpacePresented || isInitialSpaceSetupPresented || editingSpaceID != nil
    }

    var isInitialSpaceSetupPresented: Bool {
        initialOnboardingStep == .space
    }

    var isInitialAccountSetupPresented: Bool {
        initialOnboardingStep == .account
    }

    var isInitialOnboardingPresented: Bool {
        initialOnboardingStep != nil
    }

    var isInitialOnboardingBlockingBrowsing: Bool {
        switch initialOnboardingStep {
        case .welcome, .account, .importData, .space:
            return true
        case .tour, .none:
            return false
        }
    }

    var editingSpace: BrowserSpace? {
        guard let editingSpaceID else { return nil }
        return spaces.first { $0.id == editingSpaceID }
    }

    private var nextAccountOrTourStep: InitialOnboardingStep {
        .account
    }

    func completeInitialSpaceSetup(
        name: String,
        symbolName: String,
        themeColorHex: String?,
        themeAppearance: SpaceThemeAppearance = .automatic,
        themeOpacity: Double = 0.5,
        themeTexture: Double = 0,
        dataStoreID: UUID? = nil
    ) {
        let normalizedName = Self.normalizedSpaceName(name)
        guard !normalizedName.isEmpty else { return }

        if spaces.isEmpty {
            let defaultSpace = BrowserSpace(
                name: normalizedName,
                symbolName: symbolName,
                themeColorHex: themeColorHex,
                themeAppearance: themeAppearance,
                themeOpacity: themeOpacity,
                themeTexture: themeTexture,
                dataStoreID: dataStoreID
            )
            spaces = [defaultSpace]
            activeSpaceID = defaultSpace.id
        }

        let targetSpaceID = spaces.contains(where: { $0.id == activeSpaceID })
            ? activeSpaceID
            : spaces[0].id

        guard let index = spaces.firstIndex(where: { $0.id == targetSpaceID }) else { return }
        let previousDataStoreID = spaces[index].dataStoreID

        spaces[index].name = normalizedName
        spaces[index].symbolName = symbolName
        spaces[index].themeColorHex = themeColorHex
        spaces[index].themeAppearance = themeAppearance
        spaces[index].themeOpacity = min(0.9, max(0.3, themeOpacity))
        spaces[index].themeTexture = min(1, max(0, themeTexture))
        if let dataStoreID {
            spaces[index].dataStoreID = dataStoreID
        }

        activeSpaceID = spaces[index].id
        if initialOnboardingStep == .space {
            setInitialOnboardingStep(nextAccountOrTourStep)
        }
        isCreateSpacePresented = false
        recreateWebViewsIfNeeded(
            in: spaces[index].id,
            previousDataStoreID: previousDataStoreID,
            nextDataStoreID: spaces[index].dataStoreID
        )
        repairSessionState()
        updateNavigationState()
        flushSession()
    }

    func completeInitialAccountSetup() {
        guard isInitialAccountSetupPresented,
              CandoaAccountKeychain.accessToken != nil || UserStore.hasStoredAccountChoice else { return }
        reconcileAccountSetup(hasCompletedAccountChoice: true)
    }

    func reconcileAccountSetup(hasCompletedAccountChoice: Bool) {
        guard !Self.isUITesting else { return }
        guard hasCompletedAccountChoice else { return }
        guard isInitialAccountSetupPresented else { return }

        if needsInitialSpaceSetup() {
            setInitialOnboardingStep(.space)
        } else if !UserDefaults.standard.bool(forKey: Self.hasCompletedTourKey) {
            setInitialOnboardingStep(.tour)
        } else {
            setInitialOnboardingStep(nil)
        }
    }

    func completeInitialWelcome() {
        guard initialOnboardingStep == .welcome else { return }
        setInitialOnboardingStep(.importData)
    }

    func completeInitialImport() {
        guard initialOnboardingStep == .importData else { return }
        setInitialOnboardingStep(.space)
    }

    func goBackInInitialOnboarding() {
        switch initialOnboardingStep {
        case .space:
            setInitialOnboardingStep(.importData)
        case .account:
            setInitialOnboardingStep(.space)
        case .welcome, .importData, .tour, .none:
            break
        }
    }

    func importInitialBookmarks(
        fromProfileFolder folderURL: URL,
        source: BrowserImportSource
    ) async throws -> Int {
        guard initialOnboardingStep == .importData else { return 0 }

        let importedBookmarks = try await browserImportService.bookmarks(
            fromProfileFolder: folderURL,
            source: source
        )
        return addInitialBookmarks(
            importedBookmarks,
            rootFolderName: "Imported from \(source.name)"
        )
    }

    func importInitialBookmarks(from source: BrowserImportSource) async throws -> Int {
        guard initialOnboardingStep == .importData else { return 0 }

        let importedBookmarks = try await browserImportService.bookmarks(from: source)
        return addInitialBookmarks(
            importedBookmarks,
            rootFolderName: "Imported from \(source.name)"
        )
    }

    func canImportAutomatically(from source: BrowserImportSource) -> Bool {
        if Self.isUITesting { return true }
        return source != .safari || browserImportService.hasRememberedProfileFolder(for: source)
    }

    private func addInitialBookmarks(
        _ importedBookmarks: [ImportedBrowserBookmark],
        rootFolderName: String
    ) -> Int {
        guard !importedBookmarks.isEmpty else { return 0 }

        let folder = BrowserFolder(
            name: uniqueFolderName(base: rootFolderName, in: activeSpaceID),
            spaceID: activeSpaceID,
            sortOrder: nextFolderSortOrder(spaceID: activeSpaceID)
        )
        folders.append(folder)

        var folderIDsByPath: [[String]: UUID] = [[]: folder.id]
        var nextFolderOrderByParentID: [UUID: Double] = [:]

        func destinationFolderID(for rawPath: [String]) -> UUID {
            let path = rawPath.compactMap { component -> String? in
                let name = normalizedFolderName(component)
                return name.isEmpty ? nil : name
            }
            guard !path.isEmpty else { return folder.id }

            var currentPath: [String] = []
            var parentID = folder.id
            for component in path {
                currentPath.append(component)
                if let existingID = folderIDsByPath[currentPath] {
                    parentID = existingID
                    continue
                }

                let childFolder = BrowserFolder(
                    name: component,
                    spaceID: activeSpaceID,
                    parentFolderID: parentID,
                    sortOrder: nextFolderOrderByParentID[parentID, default: 0]
                )
                nextFolderOrderByParentID[parentID, default: 0] += 1
                folders.append(childFolder)
                folderIDsByPath[currentPath] = childFolder.id
                parentID = childFolder.id
            }
            return parentID
        }

        var nextTabOrderByFolderID: [UUID: Double] = [:]
        let importedTabs = importedBookmarks.map { bookmark in
            let destinationFolderID = destinationFolderID(for: bookmark.folderPath)
            let sortOrder = nextTabOrderByFolderID[destinationFolderID, default: 0]
            nextTabOrderByFolderID[destinationFolderID, default: 0] += 1
            return BrowserTab(
                title: bookmark.title,
                url: bookmark.url,
                faviconSymbol: faviconService.placeholderSymbol(for: bookmark.url),
                isPinned: true,
                folderID: destinationFolderID,
                spaceID: activeSpaceID,
                sortOrder: sortOrder,
                hasBeenActivated: false
            )
        }
        tabs.append(contentsOf: importedTabs)
        flushSession()
        return importedTabs.count
    }

    func completeInitialTour() {
        guard initialOnboardingStep == .tour else { return }
        finishInitialOnboarding()
    }

    func startInitialTour() {
        guard initialOnboardingStep == .tour,
              initialTourTip == nil,
              preparingInitialTourTip == nil
        else { return }
        initialTourTip = .commandBar
    }

    func showQuickTour() {
        // Replaying the tour is intentionally session-only. A person who opens
        // it from Help should not be forced back into onboarding next launch.
        let returnTabID = activeTab?.isWelcomePage == false ? activeTabID : nil
        setInitialOnboardingStep(.tour, persists: false)
        initialTourReturnTabID = returnTabID
    }

    func showNextInitialTourTip() {
        guard let tip = initialTourTip,
              let index = InitialTourTip.allCases.firstIndex(of: tip)
        else { return }

        let nextIndex = InitialTourTip.allCases.index(after: index)
        if nextIndex == InitialTourTip.allCases.endIndex {
            completeInitialTour()
        } else {
            let nextTip = InitialTourTip.allCases[nextIndex]
            if nextTip == .ask {
                initialTourTip = nil
                preparingInitialTourTip = nextTip
            } else {
                initialTourTip = nextTip
            }
        }
    }

    func presentPreparedInitialTourTip(_ tip: InitialTourTip) {
        guard initialOnboardingStep == .tour,
              preparingInitialTourTip == tip
        else { return }
        preparingInitialTourTip = nil
        initialTourTip = tip
    }

    func showPreviousInitialTourTip() {
        guard let tip = initialTourTip,
              let index = InitialTourTip.allCases.firstIndex(of: tip),
              index > InitialTourTip.allCases.startIndex
        else { return }
        initialTourTip = InitialTourTip.allCases[InitialTourTip.allCases.index(before: index)]
    }

    func finishInitialOnboarding() {
        let returnTabID = initialTourReturnTabID
        initialTourReturnTabID = nil
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        UserDefaults.standard.set(true, forKey: Self.hasCompletedTourKey)
        setInitialOnboardingStep(nil)

        let welcomeTabIDs = Set(tabs.filter(\.isWelcomePage).map(\.id))
        let emptyTabIDs = Set(tabs.filter { tab in
            tab.url == nil && !tab.isFavorite && !tab.isPinned
        }.map(\.id))
        for tabID in emptyTabIDs {
            webCoordinator.removeWebView(for: tabID)
            mediaStates[tabID] = nil
        }
        tabs.removeAll { emptyTabIDs.contains($0.id) }

        if let returnTabID, tabs.contains(where: { $0.id == returnTabID }) {
            tabs.removeAll { welcomeTabIDs.contains($0.id) }
            for tabID in welcomeTabIDs {
                webCoordinator.removeWebView(for: tabID)
                mediaStates[tabID] = nil
            }
            switchTab(to: returnTabID)
        } else if let welcomeTabID = tabs.first(where: \.isWelcomePage)?.id {
            // First-run onboarding leaves its single Welcome page in place.
            // It is the initial surface, not a synthetic "New Tab" record,
            // and the first navigation replaces it.
            switchTab(to: welcomeTabID)
        } else if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = visibleTabsForActiveSpace.first?.id
            updateNavigationState()
        }
        flushSession()
    }

    func setInitialOnboardingStep(
        _ step: InitialOnboardingStep?,
        persists: Bool = true
    ) {
        initialOnboardingStep = step
        initialTourTip = nil
        preparingInitialTourTip = nil
        if step == .tour {
            prepareWelcomeTab()
        }
        guard persists else { return }

        if let step {
            UserDefaults.standard.set(step.rawValue, forKey: Self.onboardingStepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.onboardingStepKey)
        }
    }

    private func prepareWelcomeTab() {
        if let existingTab = tabs.first(where: \.isWelcomePage) {
            switchTab(to: existingTab.id)
            return
        }

        let welcomeTab = newTab(url: BrowserInternalPage.welcomeURL)
        if let index = tabs.firstIndex(where: { $0.id == welcomeTab.id }) {
            tabs[index].title = String(localized: "Welcome to Candoa")
            tabs[index].faviconSymbol = "hand.wave"
            tabs[index].isLoading = false
            tabs[index].loadingProgress = 0
        }
        flushSession()
    }

    func needsInitialSpaceSetup() -> Bool {
        spaces.count == 1 && spaces[0].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
