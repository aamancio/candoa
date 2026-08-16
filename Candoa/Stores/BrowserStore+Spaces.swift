import Foundation

extension BrowserStore {
    var activeThemeColorHexes: [String] {
        if isSpaceThemeColorPreviewActive {
            guard let spaceThemeColorHexPreview else { return [] }
            return [spaceThemeColorHexPreview] + spaceThemeAuxiliaryHexPreviews
        }

        guard !isSpaceSetupPresented else { return [] }
        return activeSpace?.themePaletteHexes ?? []
    }

    var activeThemeOpacity: Double {
        if let spaceThemeOpacityPreview {
            return spaceThemeOpacityPreview
        }

        guard !isSpaceSetupPresented else { return 0.5 }
        return activeSpace?.themeOpacity ?? 0.5
    }

    var activeThemeTexture: Double {
        if let spaceThemeTexturePreview {
            return spaceThemeTexturePreview
        }

        guard !isSpaceSetupPresented else { return 0 }
        return activeSpace?.themeTexture ?? 0
    }

    var activeThemeIntensityMultiplier: Double {
        Self.themeIntensityMultiplier(forOpacity: activeThemeOpacity)
    }

    static func themeIntensityMultiplier(forOpacity opacity: Double) -> Double {
        let normalizedOpacity = (opacity - 0.3) / 0.6
        return min(1.45, max(0.25, 0.25 + normalizedOpacity * 1.2))
    }

    func beginSpaceCreation() {
        // Private windows have no Spaces to manage — their single space is
        // an unnamed ephemeral container, never presented as a Space.
        guard !isPrivate, !isInitialOnboardingPresented else { return }
        dismissCommandPalette()
        editingSpaceID = nil
        isCreateSpacePresented = true
    }

    func beginSpaceEditing(_ id: UUID) {
        guard !isPrivate, !isInitialOnboardingPresented, spaces.contains(where: { $0.id == id }) else { return }
        dismissCommandPalette()
        isCreateSpacePresented = false
        switchSpace(to: id)
        editingSpaceID = id
    }

    @discardableResult
    func dataStoreID(for spaceID: UUID) -> UUID {
        spaces.first(where: { $0.id == spaceID })?.dataStoreID ?? spaceID
    }

    static func limitedSpaceNameInput(_ name: String) -> String {
        String(name.prefix(spaceNameCharacterLimit))
    }

    static func normalizedSpaceName(_ name: String) -> String {
        limitedSpaceNameInput(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func createSpace(
        name: String? = nil,
        symbolName: String? = nil,
        themeColorHex: String? = nil,
        themeAuxiliaryColorHexes: [String] = [],
        themeAppearance: SpaceThemeAppearance = .automatic,
        themeOpacity: Double = 0.5,
        themeTexture: Double = 0,
        dataStoreID: UUID? = nil
    ) -> BrowserSpace {
        let spaceNumber = spaces.count + 1
        let paletteIndex = spaces.count % spaceSymbols.count
        let resolvedName = name
            .map(Self.normalizedSpaceName)
            .flatMap { $0.isEmpty ? nil : $0 }

        let space = BrowserSpace(
            name: resolvedName ?? "Space \(spaceNumber)",
            symbolName: symbolName ?? spaceSymbols[paletteIndex],
            themeColorHex: themeColorHex,
            themeAuxiliaryColorHexes: themeAuxiliaryColorHexes,
            themeAppearance: themeAppearance,
            themeOpacity: themeOpacity,
            themeTexture: themeTexture,
            dataStoreID: dataStoreID ?? UUID()
        )
        spaces.append(space)
        switchSpace(to: space.id)
        flushSession()
        return space
    }

    func renameSpace(_ id: UUID, to name: String) {
        let normalizedName = Self.normalizedSpaceName(name)
        guard !normalizedName.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = normalizedName
        flushSession()
    }

    func updateSpace(
        _ id: UUID,
        name: String,
        symbolName: String,
        themeColorHex: String?,
        themeAuxiliaryColorHexes: [String] = [],
        themeAppearance: SpaceThemeAppearance,
        themeOpacity: Double,
        themeTexture: Double
    ) {
        let normalizedName = Self.normalizedSpaceName(name)
        guard !normalizedName.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return }

        spaces[index].name = normalizedName
        spaces[index].symbolName = symbolName
        spaces[index].themeColorHex = themeColorHex
        spaces[index].themeAuxiliaryColorHexes = BrowserSpace.normalizedAuxiliaryThemeColorHexes(
            themeAuxiliaryColorHexes,
            primaryHex: themeColorHex
        )
        spaces[index].themeAppearance = themeAppearance
        spaces[index].themeOpacity = min(0.9, max(0.3, themeOpacity))
        spaces[index].themeTexture = min(1, max(0, themeTexture))

        editingSpaceID = nil
        updateNavigationState()
        flushSession()
    }

    func updateSpaceTheme(_ id: UUID, colorHex: String?) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].themeColorHex = colorHex
        spaces[index].themeAuxiliaryColorHexes = []
        flushSession()
    }

    func updateSpaceThemeControls(_ id: UUID, opacity: Double, texture: Double) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].themeOpacity = min(0.9, max(0.3, opacity))
        spaces[index].themeTexture = min(1, max(0, texture))
        flushSession()
    }

    func updateSpaceThemeAppearance(_ id: UUID, appearance: SpaceThemeAppearance) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].themeAppearance = appearance
        flushSession()
    }

    func previewSpaceThemeAppearance(_ appearance: SpaceThemeAppearance) {
        guard spaceThemeAppearancePreview != appearance else { return }
        spaceThemeAppearancePreview = appearance
    }

    func previewSpaceThemeColors(primaryHex: String?, auxiliaryHexes: [String] = []) {
        let normalizedAuxiliaryHexes = primaryHex == nil ? [] : auxiliaryHexes
        guard
            !isSpaceThemeColorPreviewActive ||
            spaceThemeColorHexPreview != primaryHex ||
            spaceThemeAuxiliaryHexPreviews != normalizedAuxiliaryHexes
        else { return }

        if !isSpaceThemeColorPreviewActive {
            isSpaceThemeColorPreviewActive = true
        }
        if spaceThemeColorHexPreview != primaryHex {
            spaceThemeColorHexPreview = primaryHex
        }
        if spaceThemeAuxiliaryHexPreviews != normalizedAuxiliaryHexes {
            spaceThemeAuxiliaryHexPreviews = normalizedAuxiliaryHexes
        }
    }

    func previewSpaceThemeControls(opacity: Double, texture: Double) {
        let clampedOpacity = min(0.9, max(0.3, opacity))
        let clampedTexture = min(1, max(0, texture))
        if spaceThemeOpacityPreview != clampedOpacity {
            spaceThemeOpacityPreview = clampedOpacity
        }
        if spaceThemeTexturePreview != clampedTexture {
            spaceThemeTexturePreview = clampedTexture
        }
    }

    func clearSpaceThemePreview() {
        spaceThemeAppearancePreview = nil
        isSpaceThemeColorPreviewActive = false
        spaceThemeColorHexPreview = nil
        spaceThemeAuxiliaryHexPreviews = []
        spaceThemeOpacityPreview = nil
        spaceThemeTexturePreview = nil
    }

    func clearSpaceThemeAppearancePreview() {
        clearSpaceThemePreview()
    }

    func cycleSpaceIcon(_ id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let currentSymbolIndex = spaceSymbols.firstIndex(of: spaces[index].symbolName) ?? -1
        let nextSymbolIndex = (currentSymbolIndex + 1 + spaceSymbols.count) % spaceSymbols.count
        spaces[index].symbolName = spaceSymbols[nextSymbolIndex]
        flushSession()
    }

    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let deletedSpaceIndex = spaces.firstIndex(where: { $0.id == id }) else { return }

        if editingSpaceID == id {
            editingSpaceID = nil
        }

        // Favorites are global — deleting the Space a favorite was recorded
        // under must not remove it from the shared grid. Re-home those
        // favorites to a surviving Space (their web views belong to the
        // deleted Space's data store, so they reload on next activation).
        if let survivorSpaceID = spaces.first(where: { $0.id != id })?.id {
            for index in tabs.indices where tabs[index].spaceID == id && tabs[index].isFavorite {
                tabs[index].spaceID = survivorSpaceID
                tabs[index].folderID = nil
                webCoordinator.removeWebView(for: tabs[index].id)
            }
        }

        let removedTabIDs = tabs.filter { $0.spaceID == id }.map(\.id)
        tabs.removeAll { $0.spaceID == id }
        folders.removeAll { $0.spaceID == id }
        removedTabIDs.forEach { webCoordinator.removeWebView(for: $0) }

        spaces.remove(at: deletedSpaceIndex)

        if activeSpaceID == id {
            let replacementIndex = min(deletedSpaceIndex, spaces.count - 1)
            activeSpaceID = spaces[replacementIndex].id
            activeTabID = visibleTabsForActiveSpace.first?.id
        } else if removedTabIDs.contains(where: { $0 == activeTabID }) {
            activeTabID = visibleTabsForActiveSpace.first?.id
        }

        if !Set(splitTabIDs).isDisjoint(with: removedTabIDs) {
            splitTabIDs = []
            splitPaneRatios = []
            isSplitViewEnabled = false
        }
        suspendedSplitStatesBySpace[id] = nil
        if let editingFolderID, !folders.contains(where: { $0.id == editingFolderID }) {
            self.editingFolderID = nil
        }

        repairSessionState()
        updateNavigationState()
        flushSession()
    }

    func moveSpace(_ id: UUID, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + offset
        guard spaces.indices.contains(targetIndex) else { return }
        spaces.swapAt(index, targetIndex)
        flushSession()
    }

    func moveTab(_ tabID: UUID, toSpace targetSpaceID: UUID) {
        guard
            spaces.contains(where: { $0.id == targetSpaceID }),
            let tabIndex = tabs.firstIndex(where: { $0.id == tabID })
        else {
            return
        }

        let sourceSpaceID = tabs[tabIndex].spaceID
        guard sourceSpaceID != targetSpaceID else { return }

        let sourceDataStoreID = dataStoreID(for: sourceSpaceID)
        let targetDataStoreID = dataStoreID(for: targetSpaceID)
        tabs[tabIndex].spaceID = targetSpaceID
        tabs[tabIndex].folderID = nil
        tabs[tabIndex].sortOrder = nextSortOrder(
            spaceID: targetSpaceID,
            isFavorite: tabs[tabIndex].isFavorite,
            isPinned: tabs[tabIndex].isPinned,
            folderID: nil
        )

        if sourceDataStoreID != targetDataStoreID {
            webCoordinator.removeWebView(for: tabID)
        }

        if activeTabID == tabID {
            switchTab(to: tabID)
            if let movedTab = tabs.first(where: { $0.id == tabID }) {
                webCoordinator.ensureLoaded(movedTab)
            }
        } else if splitTabIDs.contains(tabID) {
            let previousIDs = splitTabIDs
            let previousRatios = splitPaneRatios
            splitTabIDs.removeAll { $0 == tabID }
            isSplitViewEnabled = splitTabIDs.count >= 2
            if isSplitViewEnabled {
                splitPaneRatios = Self.paneRatios(
                    for: splitTabIDs,
                    carriedFrom: previousIDs,
                    previousRatios: previousRatios
                )
            } else {
                splitTabIDs = []
                splitPaneRatios = []
            }
            updateNavigationState()
        }

        normalizeSortOrder()
        flushSession()
    }

    func switchSpace(offset: Int) {
        guard !spaces.isEmpty, let currentIndex = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        let nextIndex = (currentIndex + offset + spaces.count) % spaces.count
        requestSpaceSelection(spaces[nextIndex].id)
    }

    /// Switches Spaces the way clicking one in the sidebar does, animation
    /// included. The sidebar fulfils the request; if it cannot animate right
    /// now it falls back to switching outright, so the Space always changes.
    func requestSpaceSelection(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }), id != activeSpaceID else { return }
        spaceSelectionRequest = SpaceSelectionRequest(spaceID: id)
    }

    // MARK: - Pinned area collapse

    private static let collapsedPinnedSpacesKey = "Candoa.CollapsedPinnedSpaces"

    static func loadCollapsedPinnedSpaceIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: collapsedPinnedSpacesKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func saveCollapsedPinnedSpaceIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: collapsedPinnedSpacesKey)
    }

    func isPinnedAreaCollapsed(in spaceID: UUID) -> Bool {
        collapsedPinnedSpaceIDs.contains(spaceID)
    }

    func togglePinnedAreaCollapsed(in spaceID: UUID) {
        if collapsedPinnedSpaceIDs.contains(spaceID) {
            collapsedPinnedSpaceIDs.remove(spaceID)
        } else {
            collapsedPinnedSpaceIDs.insert(spaceID)
        }
    }
}
