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

    var editingSpace: BrowserSpace? {
        guard let editingSpaceID else { return nil }
        return spaces.first { $0.id == editingSpaceID }
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
            setInitialOnboardingStep(CandoaAccountKeychain.accessToken == nil ? .account : .tour)
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
        guard isInitialAccountSetupPresented, CandoaAccountKeychain.accessToken != nil else { return }

        if needsInitialSpaceSetup() {
            setInitialOnboardingStep(.space)
        } else {
            setInitialOnboardingStep(.tour)
        }
    }

    func completeInitialWelcome() {
        guard initialOnboardingStep == .welcome else { return }
        setInitialOnboardingStep(.importData)
    }

    func completeInitialImport() {
        guard initialOnboardingStep == .importData else { return }
        if needsInitialSpaceSetup() {
            setInitialOnboardingStep(.space)
        } else {
            setInitialOnboardingStep(CandoaAccountKeychain.accessToken == nil ? .account : .tour)
        }
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

    func importInitialBookmarks(from fileURL: URL) async throws -> Int {
        guard initialOnboardingStep == .importData else { return 0 }

        let importedBookmarks = try await browserImportService.bookmarks(from: fileURL)
        return addInitialBookmarks(importedBookmarks, rootFolderName: "Imported Bookmarks")
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
        initialImportedBookmarkCount = importedTabs.count
        flushSession()
        return importedTabs.count
    }

    func completeInitialTour() {
        guard initialOnboardingStep == .tour else { return }
        finishInitialOnboarding()
    }

    func finishInitialOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        UserDefaults.standard.set(true, forKey: Self.hasCompletedTourKey)
        setInitialOnboardingStep(nil)
        flushSession()
        openNewTabCommandPalette()
    }

    func setInitialOnboardingStep(
        _ step: InitialOnboardingStep?,
        persists: Bool = true
    ) {
        initialOnboardingStep = step
        guard persists else { return }

        if let step {
            UserDefaults.standard.set(step.rawValue, forKey: Self.onboardingStepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.onboardingStepKey)
        }
    }

    func needsInitialSpaceSetup() -> Bool {
        spaces.count == 1 && spaces[0].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
