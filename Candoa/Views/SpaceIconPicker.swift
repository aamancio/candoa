import SwiftUI

internal struct SpaceIconPreview: View {
    let symbolName: String
    let themeColorHex: String?
    var strokeColor: Color = CandoaInterfaceStyle.sidebarIcon.opacity(0.78)

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
                        .foregroundStyle(CandoaThemeStyle.identityColor(for: themeColorHex))
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
        SpaceIconOption(symbolName: "sparkle", title: "Sparkle"),
        SpaceIconOption(symbolName: "sparkles", title: "Sparkles"),
        SpaceIconOption(symbolName: "circle.grid.2x2", title: "Grid"),
        SpaceIconOption(symbolName: "square.grid.2x2", title: "Squares"),
        SpaceIconOption(symbolName: "circle", title: "Circle"),
        SpaceIconOption(symbolName: "square", title: "Square"),
        SpaceIconOption(symbolName: "triangle", title: "Triangle"),
        SpaceIconOption(symbolName: "diamond", title: "Diamond"),
        SpaceIconOption(symbolName: "star", title: "Star"),
        SpaceIconOption(symbolName: "star.fill", title: "Filled Star"),
        SpaceIconOption(symbolName: "moon.stars", title: "Night"),
        SpaceIconOption(symbolName: "moon", title: "Moon"),
        SpaceIconOption(symbolName: "sun.max", title: "Day"),
        SpaceIconOption(symbolName: "cloud", title: "Cloud"),
        SpaceIconOption(symbolName: "cloud.sun", title: "Weather"),
        SpaceIconOption(symbolName: "bolt", title: "Fast"),
        SpaceIconOption(symbolName: "leaf", title: "Leaf"),
        SpaceIconOption(symbolName: "tree", title: "Tree"),
        SpaceIconOption(symbolName: "flame", title: "Focus"),
        SpaceIconOption(symbolName: "drop", title: "Drop"),
        SpaceIconOption(symbolName: "heart", title: "Heart"),
        SpaceIconOption(symbolName: "flag", title: "Flag"),
        SpaceIconOption(symbolName: "bookmark", title: "Bookmark"),
        SpaceIconOption(symbolName: "tag", title: "Tag"),
        SpaceIconOption(symbolName: "pin", title: "Pin"),
        SpaceIconOption(symbolName: "location", title: "Location"),
        SpaceIconOption(symbolName: "shield", title: "Shield"),
        SpaceIconOption(symbolName: "lock", title: "Lock"),
        SpaceIconOption(symbolName: "key", title: "Key"),
        SpaceIconOption(symbolName: "circle.hexagongrid", title: "Network"),
        SpaceIconOption(symbolName: "wand.and.stars", title: "Magic"),
        SpaceIconOption(symbolName: "lightbulb", title: "Idea"),
        SpaceIconOption(symbolName: "scope", title: "Scope"),
        SpaceIconOption(symbolName: "target", title: "Target"),
        SpaceIconOption(symbolName: "checkmark.circle", title: "Check"),
        SpaceIconOption(symbolName: "plus.circle", title: "Plus"),
        SpaceIconOption(symbolName: "minus.circle", title: "Minus"),
        SpaceIconOption(symbolName: "xmark.circle", title: "Close")
    ]
    private let iconOptions = [
        SpaceIconOption(symbolName: "house", title: "Home"),
        SpaceIconOption(symbolName: "building.2", title: "Office"),
        SpaceIconOption(symbolName: "briefcase", title: "Work"),
        SpaceIconOption(symbolName: "laptopcomputer", title: "Laptop"),
        SpaceIconOption(symbolName: "desktopcomputer", title: "Desktop"),
        SpaceIconOption(symbolName: "graduationcap", title: "Study"),
        SpaceIconOption(symbolName: "paintpalette", title: "Creative"),
        SpaceIconOption(symbolName: "terminal", title: "Code"),
        SpaceIconOption(symbolName: "keyboard", title: "Keyboard"),
        SpaceIconOption(symbolName: "book.closed", title: "Reading"),
        SpaceIconOption(symbolName: "pencil", title: "Writing"),
        SpaceIconOption(symbolName: "calendar", title: "Calendar"),
        SpaceIconOption(symbolName: "clock", title: "Clock"),
        SpaceIconOption(symbolName: "alarm", title: "Alarm"),
        SpaceIconOption(symbolName: "envelope", title: "Mail"),
        SpaceIconOption(symbolName: "message", title: "Messages"),
        SpaceIconOption(symbolName: "phone", title: "Phone"),
        SpaceIconOption(symbolName: "music.note", title: "Music"),
        SpaceIconOption(symbolName: "headphones", title: "Audio"),
        SpaceIconOption(symbolName: "film", title: "Video"),
        SpaceIconOption(symbolName: "cart", title: "Shopping"),
        SpaceIconOption(symbolName: "bag", title: "Bag"),
        SpaceIconOption(symbolName: "creditcard", title: "Banking"),
        SpaceIconOption(symbolName: "dollarsign.circle", title: "Money"),
        SpaceIconOption(symbolName: "chart.bar", title: "Charts"),
        SpaceIconOption(symbolName: "chart.pie", title: "Analytics"),
        SpaceIconOption(symbolName: "airplane", title: "Travel"),
        SpaceIconOption(symbolName: "car", title: "Car"),
        SpaceIconOption(symbolName: "bicycle", title: "Bike"),
        SpaceIconOption(symbolName: "figure.walk", title: "Walking"),
        SpaceIconOption(symbolName: "fork.knife", title: "Food"),
        SpaceIconOption(symbolName: "cup.and.saucer", title: "Coffee"),
        SpaceIconOption(symbolName: "gift", title: "Gift"),
        SpaceIconOption(symbolName: "shippingbox", title: "Package"),
        SpaceIconOption(symbolName: "camera", title: "Photos"),
        SpaceIconOption(symbolName: "photo", title: "Gallery"),
        SpaceIconOption(symbolName: "lock", title: "Private"),
        SpaceIconOption(symbolName: "hammer", title: "Build"),
        SpaceIconOption(symbolName: "wrench.and.screwdriver", title: "Tools"),
        SpaceIconOption(symbolName: "gearshape", title: "Settings"),
        SpaceIconOption(symbolName: "gamecontroller", title: "Games"),
        SpaceIconOption(symbolName: "folder", title: "Folder"),
        SpaceIconOption(symbolName: "doc.text", title: "Documents"),
        SpaceIconOption(symbolName: "tray", title: "Inbox"),
        SpaceIconOption(symbolName: "paperplane", title: "Send"),
        SpaceIconOption(symbolName: "globe", title: "Web"),
        SpaceIconOption(symbolName: "person", title: "Person"),
        SpaceIconOption(symbolName: "person.2", title: "People"),
        SpaceIconOption(symbolName: "link", title: "Link"),
        SpaceIconOption(symbolName: "eye", title: "Watch")
    ]
    private let emojiOptions = [
        SpaceIconOption(emoji: "😀", title: "Smile"),
        SpaceIconOption(emoji: "😄", title: "Happy"),
        SpaceIconOption(emoji: "😎", title: "Cool"),
        SpaceIconOption(emoji: "🤓", title: "Study"),
        SpaceIconOption(emoji: "🥳", title: "Celebrate"),
        SpaceIconOption(emoji: "🤫", title: "Quiet"),
        SpaceIconOption(emoji: "🧠", title: "Thinking"),
        SpaceIconOption(emoji: "👀", title: "Watch"),
        SpaceIconOption(emoji: "💼", title: "Work"),
        SpaceIconOption(emoji: "🏠", title: "Home"),
        SpaceIconOption(emoji: "🏦", title: "Banking"),
        SpaceIconOption(emoji: "🛒", title: "Shopping"),
        SpaceIconOption(emoji: "🎓", title: "School"),
        SpaceIconOption(emoji: "🎨", title: "Creative"),
        SpaceIconOption(emoji: "📚", title: "Reading"),
        SpaceIconOption(emoji: "🧪", title: "Research"),
        SpaceIconOption(emoji: "💻", title: "Computer"),
        SpaceIconOption(emoji: "⌨️", title: "Keyboard"),
        SpaceIconOption(emoji: "📱", title: "Phone"),
        SpaceIconOption(emoji: "📷", title: "Camera"),
        SpaceIconOption(emoji: "🎵", title: "Music"),
        SpaceIconOption(emoji: "🎮", title: "Games"),
        SpaceIconOption(emoji: "✈️", title: "Travel"),
        SpaceIconOption(emoji: "🚗", title: "Car"),
        SpaceIconOption(emoji: "☕️", title: "Coffee"),
        SpaceIconOption(emoji: "🍽️", title: "Food"),
        SpaceIconOption(emoji: "🏋️", title: "Fitness"),
        SpaceIconOption(emoji: "🧘", title: "Calm"),
        SpaceIconOption(emoji: "🌱", title: "Growth"),
        SpaceIconOption(emoji: "🔥", title: "Focus"),
        SpaceIconOption(emoji: "⚡️", title: "Fast"),
        SpaceIconOption(emoji: "🌙", title: "Night"),
        SpaceIconOption(emoji: "☀️", title: "Day"),
        SpaceIconOption(emoji: "⭐️", title: "Star"),
        SpaceIconOption(emoji: "💎", title: "Diamond"),
        SpaceIconOption(emoji: "❤️", title: "Heart"),
        SpaceIconOption(emoji: "🔒", title: "Private"),
        SpaceIconOption(emoji: "🔑", title: "Key"),
        SpaceIconOption(emoji: "🧰", title: "Tools"),
        SpaceIconOption(emoji: "📦", title: "Package"),
        SpaceIconOption(emoji: "📈", title: "Growth Chart"),
        SpaceIconOption(emoji: "💸", title: "Money"),
        SpaceIconOption(emoji: "🧾", title: "Receipts"),
        SpaceIconOption(emoji: "📝", title: "Notes"),
        SpaceIconOption(emoji: "✅", title: "Done"),
        SpaceIconOption(emoji: "🚀", title: "Launch"),
        SpaceIconOption(emoji: "🧭", title: "Navigate"),
        SpaceIconOption(emoji: "🌍", title: "World")
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
                .candoaButton(.content)
                .help("Clear Icon")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)

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
                    .stroke(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
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
                        .candoaButton(.content)
                        .help(option.title)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 304, height: 340)
        .background(CandoaInterfaceStyle.popoverBackground)
    }
}

internal struct SpaceIconOptionView: View {
    let option: SpaceIconOption
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? CandoaColor.accent.opacity(0.18) : Color.clear)

            if let emoji = option.emoji {
                Text(emoji)
                    .font(.system(size: 19))
            } else {
                Image(systemName: option.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? CandoaColor.accent : CandoaInterfaceStyle.sidebarText)
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
                                .foregroundStyle(CandoaInterfaceStyle.sidebarText)
                                .lineLimit(1)

                            Text(mode.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if selectedMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(CandoaColor.accent)
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .candoaButton(.content)
                .background(selectedMode == mode ? Color.primary.opacity(0.07) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(CandoaInterfaceStyle.popoverBackground)
    }
}
