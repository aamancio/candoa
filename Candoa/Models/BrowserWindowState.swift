import Foundation

struct BrowserFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var spaceID: UUID
    var parentFolderID: UUID?
    var sortOrder: Double
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        name: String = "New Folder",
        spaceID: UUID,
        parentFolderID: UUID? = nil,
        sortOrder: Double = 0,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.spaceID = spaceID
        self.parentFolderID = parentFolderID
        self.sortOrder = sortOrder
        self.isExpanded = isExpanded
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case spaceID
        case parentFolderID
        case sortOrder
        case isExpanded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "New Folder"
        spaceID = try container.decode(UUID.self, forKey: .spaceID)
        parentFolderID = try container.decodeIfPresent(UUID.self, forKey: .parentFolderID)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    }
}

struct BrowserWindowState: Codable, Equatable {
    var spaces: [BrowserSpace]
    var folders: [BrowserFolder]
    var tabs: [BrowserTab]
    var activeSpaceID: UUID
    var activeTabID: UUID?
    var splitTabIDs: [UUID]
    var splitPaneRatios: [Double]
    /// Raw `SplitViewLayout` value; stored as a string so older snapshots
    /// (and unknown future layouts) degrade to the horizontal default.
    var splitLayout: String
    var isSplitViewEnabled: Bool

    init(
        spaces: [BrowserSpace],
        folders: [BrowserFolder] = [],
        tabs: [BrowserTab],
        activeSpaceID: UUID,
        activeTabID: UUID?,
        splitTabIDs: [UUID] = [],
        splitPaneRatios: [Double] = [],
        splitLayout: String = "horizontal",
        isSplitViewEnabled: Bool = false
    ) {
        self.spaces = spaces
        self.folders = folders
        self.tabs = tabs
        self.activeSpaceID = activeSpaceID
        self.activeTabID = activeTabID
        self.splitTabIDs = splitTabIDs
        self.splitPaneRatios = splitPaneRatios
        self.splitLayout = splitLayout
        self.isSplitViewEnabled = isSplitViewEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case spaces
        case folders
        case tabs
        case activeSpaceID
        case activeTabID
        case splitTabIDs
        case splitPaneRatios
        case splitLayout
        case isSplitViewEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try container.decodeIfPresent([BrowserSpace].self, forKey: .spaces) ?? []
        folders = try container.decodeIfPresent([BrowserFolder].self, forKey: .folders) ?? []
        tabs = try container.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? []
        activeSpaceID = try container.decodeIfPresent(UUID.self, forKey: .activeSpaceID) ?? spaces.first?.id ?? UUID()
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        splitTabIDs = try container.decodeIfPresent([UUID].self, forKey: .splitTabIDs) ?? []
        splitPaneRatios = try container.decodeIfPresent([Double].self, forKey: .splitPaneRatios) ?? []
        splitLayout = try container.decodeIfPresent(String.self, forKey: .splitLayout) ?? "horizontal"
        isSplitViewEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSplitViewEnabled) ?? false
    }
}
