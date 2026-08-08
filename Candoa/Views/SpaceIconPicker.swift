import SwiftUI

internal struct SpaceIconPreview: View {
    let symbolName: String
    let themeColorHex: String?
    var strokeColor: Color = InterfaceStyle.sidebarIcon.opacity(0.78)

    var body: some View {
        ZStack {
            if symbolName == "square.dashed" {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        strokeColor,
                        style: StrokeStyle(lineWidth: 1.6, dash: [5, 4])
                    )
            }

            if symbolName != "square.dashed" {
                if let emoji = SpaceIconOption.emoji(from: symbolName) {
                    Text(emoji)
                        .font(.system(size: 16))
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(ThemeStyle.identityColor(for: themeColorHex))
                }
            }
        }
        .frame(width: 26, height: 26)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

internal struct SpaceIconPicker: View {
    @Binding var selectedSymbolName: String
    @Binding var isPresented: Bool
    let onWillDismiss: () -> Void

    @State private var query = ""
    @State private var mode = SpaceIconPickerMode.emojis

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 10), count: 6)
    private let symbolOptions = [
        SpaceIconOption(symbolName: "sparkle", title: String(localized: "Sparkle")),
        SpaceIconOption(symbolName: "sparkles", title: String(localized: "Sparkles")),
        SpaceIconOption(symbolName: "circle.grid.2x2", title: String(localized: "Grid")),
        SpaceIconOption(symbolName: "square.grid.2x2", title: String(localized: "Squares")),
        SpaceIconOption(symbolName: "circle", title: String(localized: "Circle")),
        SpaceIconOption(symbolName: "square", title: String(localized: "Square")),
        SpaceIconOption(symbolName: "triangle", title: String(localized: "Triangle")),
        SpaceIconOption(symbolName: "diamond", title: String(localized: "Diamond")),
        SpaceIconOption(symbolName: "star", title: String(localized: "Star")),
        SpaceIconOption(symbolName: "star.fill", title: String(localized: "Filled Star")),
        SpaceIconOption(symbolName: "moon.stars", title: String(localized: "Night")),
        SpaceIconOption(symbolName: "moon", title: String(localized: "Moon")),
        SpaceIconOption(symbolName: "sun.max", title: String(localized: "Day")),
        SpaceIconOption(symbolName: "cloud", title: String(localized: "Cloud")),
        SpaceIconOption(symbolName: "cloud.sun", title: String(localized: "Weather")),
        SpaceIconOption(symbolName: "bolt", title: String(localized: "Fast")),
        SpaceIconOption(symbolName: "leaf", title: String(localized: "Leaf")),
        SpaceIconOption(symbolName: "tree", title: String(localized: "Tree")),
        SpaceIconOption(symbolName: "flame", title: String(localized: "Focus")),
        SpaceIconOption(symbolName: "drop", title: String(localized: "Drop")),
        SpaceIconOption(symbolName: "heart", title: String(localized: "Heart")),
        SpaceIconOption(symbolName: "flag", title: String(localized: "Flag")),
        SpaceIconOption(symbolName: "bookmark", title: String(localized: "Bookmark")),
        SpaceIconOption(symbolName: "tag", title: String(localized: "Tag")),
        SpaceIconOption(symbolName: "pin", title: String(localized: "Pin")),
        SpaceIconOption(symbolName: "location", title: String(localized: "Location")),
        SpaceIconOption(symbolName: "shield", title: String(localized: "Shield")),
        SpaceIconOption(symbolName: "lock", title: String(localized: "Lock")),
        SpaceIconOption(symbolName: "key", title: String(localized: "Key")),
        SpaceIconOption(symbolName: "circle.hexagongrid", title: String(localized: "Network")),
        SpaceIconOption(symbolName: "wand.and.stars", title: String(localized: "Magic")),
        SpaceIconOption(symbolName: "lightbulb", title: String(localized: "Idea")),
        SpaceIconOption(symbolName: "scope", title: String(localized: "Scope")),
        SpaceIconOption(symbolName: "target", title: String(localized: "Target")),
        SpaceIconOption(symbolName: "checkmark.circle", title: String(localized: "Check")),
        SpaceIconOption(symbolName: "plus.circle", title: String(localized: "Plus")),
        SpaceIconOption(symbolName: "minus.circle", title: String(localized: "Minus")),
        SpaceIconOption(symbolName: "xmark.circle", title: String(localized: "Close"))
    ]
    private let iconOptions = [
        SpaceIconOption(symbolName: "house", title: String(localized: "Home")),
        SpaceIconOption(symbolName: "building.2", title: String(localized: "Office")),
        SpaceIconOption(symbolName: "briefcase", title: String(localized: "Work")),
        SpaceIconOption(symbolName: "laptopcomputer", title: String(localized: "Laptop")),
        SpaceIconOption(symbolName: "desktopcomputer", title: String(localized: "Desktop")),
        SpaceIconOption(symbolName: "graduationcap", title: String(localized: "Study")),
        SpaceIconOption(symbolName: "paintpalette", title: String(localized: "Creative")),
        SpaceIconOption(symbolName: "terminal", title: String(localized: "Code")),
        SpaceIconOption(symbolName: "keyboard", title: String(localized: "Keyboard")),
        SpaceIconOption(symbolName: "book.closed", title: String(localized: "Reading")),
        SpaceIconOption(symbolName: "pencil", title: String(localized: "Writing")),
        SpaceIconOption(symbolName: "calendar", title: String(localized: "Calendar")),
        SpaceIconOption(symbolName: "clock", title: String(localized: "Clock")),
        SpaceIconOption(symbolName: "alarm", title: String(localized: "Alarm")),
        SpaceIconOption(symbolName: "envelope", title: String(localized: "Mail")),
        SpaceIconOption(symbolName: "message", title: String(localized: "Messages")),
        SpaceIconOption(symbolName: "phone", title: String(localized: "Phone")),
        SpaceIconOption(symbolName: "music.note", title: String(localized: "Music")),
        SpaceIconOption(symbolName: "headphones", title: String(localized: "Audio")),
        SpaceIconOption(symbolName: "film", title: String(localized: "Video")),
        SpaceIconOption(symbolName: "cart", title: String(localized: "Shopping")),
        SpaceIconOption(symbolName: "bag", title: String(localized: "Bag")),
        SpaceIconOption(symbolName: "creditcard", title: String(localized: "Banking")),
        SpaceIconOption(symbolName: "dollarsign.circle", title: String(localized: "Money")),
        SpaceIconOption(symbolName: "chart.bar", title: String(localized: "Charts")),
        SpaceIconOption(symbolName: "chart.pie", title: String(localized: "Analytics")),
        SpaceIconOption(symbolName: "airplane", title: String(localized: "Travel")),
        SpaceIconOption(symbolName: "car", title: String(localized: "Car")),
        SpaceIconOption(symbolName: "bicycle", title: String(localized: "Bike")),
        SpaceIconOption(symbolName: "figure.walk", title: String(localized: "Walking")),
        SpaceIconOption(symbolName: "fork.knife", title: String(localized: "Food")),
        SpaceIconOption(symbolName: "cup.and.saucer", title: String(localized: "Coffee")),
        SpaceIconOption(symbolName: "gift", title: String(localized: "Gift")),
        SpaceIconOption(symbolName: "shippingbox", title: String(localized: "Package")),
        SpaceIconOption(symbolName: "camera", title: String(localized: "Photos")),
        SpaceIconOption(symbolName: "photo", title: String(localized: "Gallery")),
        SpaceIconOption(symbolName: "lock", title: String(localized: "Private")),
        SpaceIconOption(symbolName: "hammer", title: String(localized: "Build")),
        SpaceIconOption(symbolName: "wrench.and.screwdriver", title: String(localized: "Tools")),
        SpaceIconOption(symbolName: "gearshape", title: String(localized: "Settings")),
        SpaceIconOption(symbolName: "gamecontroller", title: String(localized: "Games")),
        SpaceIconOption(symbolName: "folder", title: String(localized: "Folder")),
        SpaceIconOption(symbolName: "doc.text", title: String(localized: "Documents")),
        SpaceIconOption(symbolName: "tray", title: String(localized: "Inbox")),
        SpaceIconOption(symbolName: "paperplane", title: String(localized: "Send")),
        SpaceIconOption(symbolName: "globe", title: String(localized: "Web")),
        SpaceIconOption(symbolName: "person", title: String(localized: "Person")),
        SpaceIconOption(symbolName: "person.2", title: String(localized: "People")),
        SpaceIconOption(symbolName: "link", title: String(localized: "Link")),
        SpaceIconOption(symbolName: "eye", title: String(localized: "Watch"))
    ]
    private let emojiOptions = [
        SpaceIconOption(emoji: "😀", title: String(localized: "Smile")),
        SpaceIconOption(emoji: "😄", title: String(localized: "Happy")),
        SpaceIconOption(emoji: "😎", title: String(localized: "Cool")),
        SpaceIconOption(emoji: "🤓", title: String(localized: "Study")),
        SpaceIconOption(emoji: "🥳", title: String(localized: "Celebrate")),
        SpaceIconOption(emoji: "🤫", title: String(localized: "Quiet")),
        SpaceIconOption(emoji: "🧠", title: String(localized: "Thinking")),
        SpaceIconOption(emoji: "👀", title: String(localized: "Watch")),
        SpaceIconOption(emoji: "💼", title: String(localized: "Work")),
        SpaceIconOption(emoji: "🏠", title: String(localized: "Home")),
        SpaceIconOption(emoji: "🏦", title: String(localized: "Banking")),
        SpaceIconOption(emoji: "🛒", title: String(localized: "Shopping")),
        SpaceIconOption(emoji: "🎓", title: String(localized: "School")),
        SpaceIconOption(emoji: "🎨", title: String(localized: "Creative")),
        SpaceIconOption(emoji: "📚", title: String(localized: "Reading")),
        SpaceIconOption(emoji: "🧪", title: String(localized: "Research")),
        SpaceIconOption(emoji: "💻", title: String(localized: "Computer")),
        SpaceIconOption(emoji: "⌨️", title: String(localized: "Keyboard")),
        SpaceIconOption(emoji: "📱", title: String(localized: "Phone")),
        SpaceIconOption(emoji: "📷", title: String(localized: "Camera")),
        SpaceIconOption(emoji: "🎵", title: String(localized: "Music")),
        SpaceIconOption(emoji: "🎮", title: String(localized: "Games")),
        SpaceIconOption(emoji: "✈️", title: String(localized: "Travel")),
        SpaceIconOption(emoji: "🚗", title: String(localized: "Car")),
        SpaceIconOption(emoji: "☕️", title: String(localized: "Coffee")),
        SpaceIconOption(emoji: "🍽️", title: String(localized: "Food")),
        SpaceIconOption(emoji: "🏋️", title: String(localized: "Fitness")),
        SpaceIconOption(emoji: "🧘", title: String(localized: "Calm")),
        SpaceIconOption(emoji: "🌱", title: String(localized: "Growth")),
        SpaceIconOption(emoji: "🔥", title: String(localized: "Focus")),
        SpaceIconOption(emoji: "⚡️", title: String(localized: "Fast")),
        SpaceIconOption(emoji: "🌙", title: String(localized: "Night")),
        SpaceIconOption(emoji: "☀️", title: String(localized: "Day")),
        SpaceIconOption(emoji: "⭐️", title: String(localized: "Star")),
        SpaceIconOption(emoji: "💎", title: String(localized: "Diamond")),
        SpaceIconOption(emoji: "❤️", title: String(localized: "Heart")),
        SpaceIconOption(emoji: "🔒", title: String(localized: "Private")),
        SpaceIconOption(emoji: "🔑", title: String(localized: "Key")),
        SpaceIconOption(emoji: "🧰", title: String(localized: "Tools")),
        SpaceIconOption(emoji: "📦", title: String(localized: "Package")),
        SpaceIconOption(emoji: "📈", title: String(localized: "Growth Chart")),
        SpaceIconOption(emoji: "💸", title: String(localized: "Money")),
        SpaceIconOption(emoji: "🧾", title: String(localized: "Receipts")),
        SpaceIconOption(emoji: "📝", title: String(localized: "Notes")),
        SpaceIconOption(emoji: "✅", title: String(localized: "Done")),
        SpaceIconOption(emoji: "🚀", title: String(localized: "Launch")),
        SpaceIconOption(emoji: "🧭", title: String(localized: "Navigate")),
        SpaceIconOption(emoji: "🌍", title: String(localized: "World"))
    ]

    private var filteredOptions: [SpaceIconOption] {
        let options: [SpaceIconOption]
        switch mode {
        case .emojis:
            options = emojiOptions
        case .symbols:
            options = symbolOptions
        case .icons:
            options = iconOptions
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.symbolName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Icon Type", selection: $mode) {
                    ForEach(SpaceIconPickerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 216)

                Spacer()

                Button {
                    onWillDismiss()
                    selectedSymbolName = "square.dashed"
                    isPresented = false
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonTreatment(.content)
                .help("Clear Icon")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(InterfaceStyle.sidebarIcon)

                TextField(mode.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(InterfaceStyle.popoverBorder, lineWidth: 1)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredOptions) { option in
                        Button {
                            onWillDismiss()
                            selectedSymbolName = option.symbolName
                            isPresented = false
                        } label: {
                            SpaceIconOptionView(
                                option: option,
                                isSelected: selectedSymbolName == option.symbolName
                            )
                        }
                        .buttonTreatment(.content)
                        .help(option.title)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 304, height: 340)
        .background(InterfaceStyle.popoverBackground)
    }
}

internal struct SpaceIconOptionView: View {
    let option: SpaceIconOption
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AppColor.accent.opacity(0.18) : Color.clear)

            if let emoji = option.emoji {
                Text(emoji)
                    .font(.system(size: 19))
            } else {
                Image(systemName: option.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? AppColor.accent : InterfaceStyle.sidebarText)
            }
        }
        .frame(width: 34, height: 34)
    }
}

internal struct SpaceProfilePicker: View {
    @Binding var selectedMode: SpaceDataMode
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(SpaceDataMode.allCases) { mode in
                Button {
                    selectedMode = mode
                    isPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(mode.tint)
                            .frame(width: 21)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(InterfaceStyle.sidebarText)
                                .lineLimit(1)

                            Text(mode.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(InterfaceStyle.sidebarIcon)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if selectedMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppColor.accent)
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonTreatment(.content)
                .background(selectedMode == mode ? Color.primary.opacity(0.07) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(InterfaceStyle.popoverBackground)
    }
}
