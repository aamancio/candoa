import Foundation

enum BrowserInternalPage {
    static let welcomeURL = URL(string: "candoa://welcome")!
}

struct BrowserTab: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: URL?
    var faviconSymbol: String
    var faviconData: Data?
    var favoriteTitle: String?
    var favoriteURL: URL?
    var favoriteFaviconSymbol: String?
    var favoriteFaviconData: Data?
    var isLoading: Bool
    var loadingProgress: Double
    var isFavorite: Bool
    var isPinned: Bool
    var folderID: UUID?
    var spaceID: UUID
    var sortOrder: Double
    var lastAccessedAt: Date
    /// Saved tabs should not participate in recent-tab switching until the
    /// user has actually opened them.
    var hasBeenActivated: Bool

    init(
        id: UUID = UUID(),
        title: String = BrowserDefaults.newTabTitle,
        url: URL? = nil,
        faviconSymbol: String = "globe",
        faviconData: Data? = nil,
        favoriteTitle: String? = nil,
        favoriteURL: URL? = nil,
        favoriteFaviconSymbol: String? = nil,
        favoriteFaviconData: Data? = nil,
        isLoading: Bool = false,
        loadingProgress: Double = 0,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        folderID: UUID? = nil,
        spaceID: UUID,
        sortOrder: Double = 0,
        lastAccessedAt: Date = Date(),
        hasBeenActivated: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.faviconSymbol = faviconSymbol
        self.faviconData = faviconData
        self.favoriteTitle = favoriteTitle
        self.favoriteURL = favoriteURL
        self.favoriteFaviconSymbol = favoriteFaviconSymbol
        self.favoriteFaviconData = favoriteFaviconData
        self.isLoading = isLoading
        self.loadingProgress = loadingProgress
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.folderID = folderID
        self.spaceID = spaceID
        self.sortOrder = sortOrder
        self.lastAccessedAt = lastAccessedAt
        self.hasBeenActivated = hasBeenActivated ?? !isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case faviconSymbol
        case faviconData
        case favoriteTitle
        case favoriteURL
        case favoriteFaviconSymbol
        case favoriteFaviconData
        case isLoading
        case loadingProgress
        case isFavorite
        case isPinned
        case folderID
        case spaceID
        case sortOrder
        case lastAccessedAt
        case hasBeenActivated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? BrowserDefaults.newTabTitle
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        faviconSymbol = try container.decodeIfPresent(String.self, forKey: .faviconSymbol) ?? "globe"
        faviconData = try container.decodeIfPresent(Data.self, forKey: .faviconData)
        favoriteTitle = try container.decodeIfPresent(String.self, forKey: .favoriteTitle)
        favoriteURL = try container.decodeIfPresent(URL.self, forKey: .favoriteURL)
        favoriteFaviconSymbol = try container.decodeIfPresent(String.self, forKey: .favoriteFaviconSymbol)
        favoriteFaviconData = try container.decodeIfPresent(Data.self, forKey: .favoriteFaviconData)
        isLoading = false
        loadingProgress = try container.decodeIfPresent(Double.self, forKey: .loadingProgress) ?? 0
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        spaceID = try container.decode(UUID.self, forKey: .spaceID)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt) ?? Date()
        hasBeenActivated = try container.decodeIfPresent(Bool.self, forKey: .hasBeenActivated) ?? !isFavorite
    }

    var favoriteDisplayTitle: String {
        favoriteTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? favoriteTitle!
            : title
    }

    var favoriteDisplayFaviconSymbol: String {
        favoriteFaviconSymbol ?? faviconSymbol
    }

    var favoriteDisplayFaviconData: Data? {
        favoriteFaviconData ?? faviconData
    }
}

extension BrowserTab {
    var isWelcomePage: Bool {
        url == BrowserInternalPage.welcomeURL
    }
}
