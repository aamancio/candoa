import Foundation

enum WebsiteAppearance: String, CaseIterable, Hashable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .dark
    }
}

enum SpaceThemeAppearance: String, CaseIterable, Codable, Hashable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic:
            return "sparkles"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.fill"
        }
    }
}

struct BrowserSpace: Identifiable, Codable, Hashable {
    /// Emoji icons are stored in `symbolName` behind this prefix to keep the
    /// persisted field a single string alongside SF Symbol names.
    static let emojiSymbolPrefix = "emoji:"

    /// A Space with no icon of its own. Surfaces draw nothing for it rather
    /// than the dashed placeholder the picker shows while choosing.
    static let noIconSymbolName = "square.dashed"

    /// Apple's system-blue reference used when persisting an explicitly
    /// selected blue Space theme. The default theme has no color value.
    static let blueThemeColorHex = AppColor.blueThemeHex

    /// The interface follows the macOS system appearance by default — the native
    /// behavior used by Safari, Finder, and other platform apps. Website
    /// appearance is configured independently in General settings.
    static let defaultThemeAppearance = SpaceThemeAppearance.automatic

    /// The theme editor supports one primary plus up to two auxiliary colors.
    static let maximumAuxiliaryThemeColorCount = 2

    var id: UUID
    var name: String
    var symbolName: String
    var themeColorHex: String?
    var themeAuxiliaryColorHexes: [String]
    var themeAppearance: SpaceThemeAppearance
    var themeOpacity: Double
    var themeTexture: Double
    var dataStoreID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "sparkle",
        themeColorHex: String? = nil,
        themeAuxiliaryColorHexes: [String] = [],
        themeAppearance: SpaceThemeAppearance = .automatic,
        themeOpacity: Double = 0.5,
        themeTexture: Double = 0,
        dataStoreID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.themeColorHex = themeColorHex
        self.themeAuxiliaryColorHexes = Self.normalizedAuxiliaryThemeColorHexes(
            themeAuxiliaryColorHexes,
            primaryHex: themeColorHex
        )
        self.themeAppearance = themeAppearance
        self.themeOpacity = min(0.9, max(0.3, themeOpacity))
        self.themeTexture = min(1, max(0, themeTexture))
        self.dataStoreID = dataStoreID ?? id
        self.createdAt = createdAt
    }

    /// The full ordered palette the Space's theme renders from: the primary
    /// color followed by the auxiliary colors. Empty when the Space is
    /// unthemed.
    var themePaletteHexes: [String] {
        themeColorHex.map { [$0] + themeAuxiliaryColorHexes } ?? []
    }

    /// Auxiliary colors only exist alongside a primary color and are capped at
    /// the editor's limit. Legacy single-color Spaces normalize to an empty
    /// list.
    static func normalizedAuxiliaryThemeColorHexes(
        _ hexes: [String],
        primaryHex: String?
    ) -> [String] {
        guard primaryHex != nil else { return [] }
        return Array(hexes.filter { !$0.isEmpty }.prefix(maximumAuxiliaryThemeColorCount))
    }

    var iconEmoji: String? {
        guard symbolName.hasPrefix(Self.emojiSymbolPrefix) else { return nil }
        return String(symbolName.dropFirst(Self.emojiSymbolPrefix.count))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName
        case themeColorHex
        case themeAuxiliaryColorHexes
        case themeAppearance
        case themeOpacity
        case themeTexture
        case dataStoreID
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Space"
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "sparkle"
        themeColorHex = try container.decodeIfPresent(String.self, forKey: .themeColorHex)
        themeAuxiliaryColorHexes = Self.normalizedAuxiliaryThemeColorHexes(
            try container.decodeIfPresent([String].self, forKey: .themeAuxiliaryColorHexes) ?? [],
            primaryHex: themeColorHex
        )
        themeAppearance = try container.decodeIfPresent(SpaceThemeAppearance.self, forKey: .themeAppearance) ?? .automatic
        themeOpacity = min(0.9, max(0.3, try container.decodeIfPresent(Double.self, forKey: .themeOpacity) ?? 0.5))
        themeTexture = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .themeTexture) ?? 0))
        dataStoreID = try container.decodeIfPresent(UUID.self, forKey: .dataStoreID) ?? id
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
