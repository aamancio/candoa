import AppKit
import SwiftUI
import UniformTypeIdentifiers

internal struct AppUpdateBanner: View {
    let update: AppUpdate
    let automaticUpdatesEnabled: Binding<Bool>
    let action: () -> Void

    @State private var isHovering = false
    @State private var isUpdatePanelPresented = false
    @State private var hoverPresentationTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Text("New Candoa Version Available")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CandoaChromeStyle.sidebarText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isHovering ? CandoaChromeStyle.updateBannerFillHover : CandoaChromeStyle.updateBannerFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(CandoaChromeStyle.updateBannerStroke, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            hoverPresentationTask?.cancel()

            guard hovering, !isUpdatePanelPresented else { return }
            hoverPresentationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, isHovering else { return }
                isUpdatePanelPresented = true
            }
        }
        .popover(isPresented: $isUpdatePanelPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                Text("New Candoa Version Available")
                    .font(.headline)

                Divider()

                Toggle(
                    "Automatic Updates",
                    isOn: automaticUpdatesEnabled
                )

                Button {
                    isUpdatePanelPresented = false
                    action()
                } label: {
                    Text("Restart and Update")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(14)
            .frame(width: 280)
        }
        .help("Candoa \(update.version) is available")
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .onDisappear {
            hoverPresentationTask?.cancel()
        }
    }
}
internal struct UpsertSpaceSidebarComposer: View {
    @ObservedObject var store: BrowserStore
    let mode: SpaceComposerMode

    @State private var name = ""
    @State private var symbolName = "square.dashed"
    @State private var themeColorHex: String?
    @State private var themeAppearance = BrowserSpace.defaultThemeAppearance
    @State private var themeOpacity = 0.5
    @State private var themeTexture = 0.0
    @State private var dataMode = SpaceDataMode.isolated
    @State private var isIconPickerPresented = false
    @State private var isProfilePickerPresented = false
    @State private var isThemeEditorPresented = false
    @State private var isHoveringPrimaryButton = false
    @FocusState private var isNameFocused: Bool

    private let themeOptions: [(name: String, hex: String)] = [
        ("Neutral", "#F0EAE1"),
        ("Green", "#74E0AA"),
        ("Gold", "#E0A84F"),
        ("Red", "#DA6A72"),
        ("Violet", "#9B7BE5"),
        ("Cyan", "#5CA8D8"),
        ("Pink", "#D17FB3"),
        ("Olive", "#8E9A5B")
    ]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isThemePreviewActive: Bool {
        // The standalone create flow sits directly on the themed browser
        // chrome, so its controls must follow the preview's contrast. Initial
        // onboarding is inside a neutral system surface and keeps semantic
        // macOS label/control colors regardless of the surrounding preview.
        mode == .create && themeColorHex != nil
    }

    private var usesDarkForeground: Bool {
        let previewHexes = store.activeThemeColorHexes
        if !previewHexes.isEmpty {
            return CandoaChromeStyle.prefersDarkForeground(forSpaceHexes: previewHexes)
        }
        guard let themeColorHex else { return false }
        return CandoaChromeStyle.prefersDarkForeground(forSpaceHex: themeColorHex)
    }

    private var foregroundBase: Color {
        usesDarkForeground ? Color.black : Color.white
    }

    private var primaryButtonTintHex: String {
        themeColorHex ?? BrowserSpace.defaultThemeColorHex
    }

    private var primaryButtonUsesDarkForeground: Bool {
        CandoaChromeStyle.prefersDarkForeground(forSpaceHex: primaryButtonTintHex)
    }

    private var primaryButtonForegroundBase: Color {
        primaryButtonUsesDarkForeground ? Color.black : Color.white
    }

    private var usesCandoaPrimary: Bool {
        primaryButtonTintHex.caseInsensitiveCompare(
            BrowserSpace.defaultThemeColorHex
        ) == .orderedSame
    }

    private var textColor: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.82 : 0.88) : CandoaChromeStyle.sidebarText
    }

    private var secondaryTextColor: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.55 : 0.58) : CandoaChromeStyle.sidebarTextSecondary
    }

    private var iconColor: Color {
        isThemePreviewActive ? foregroundBase.opacity(0.42) : CandoaChromeStyle.sidebarIcon
    }

    private var controlFill: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.06 : 0.075) : CandoaChromeStyle.spaceSetupControlFill
    }

    private var controlStroke: Color {
        isThemePreviewActive ? foregroundBase.opacity(0.08) : CandoaChromeStyle.spaceSetupControlStroke
    }

    private var pillFill: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.08 : 0.10) : CandoaChromeStyle.spaceSetupPillFill
    }

    private var createButtonTextColor: Color {
        if usesCandoaPrimary {
            return CandoaColor.primaryForeground.opacity(trimmedName.isEmpty ? 0.42 : 0.92)
        }

        if trimmedName.isEmpty {
            return primaryButtonForegroundBase.opacity(primaryButtonUsesDarkForeground ? 0.38 : 0.42)
        }

        return primaryButtonForegroundBase.opacity(primaryButtonUsesDarkForeground ? 0.82 : 0.92)
    }

    private var themeAppearanceSelection: Binding<SpaceThemeAppearance> {
        Binding {
            themeAppearance
        } set: { newAppearance in
            themeAppearance = newAppearance
            store.previewSpaceThemeAppearance(newAppearance)
        }
    }

    private var createButtonBackground: Color {
        if usesCandoaPrimary {
            return (isHoveringPrimaryButton && !trimmedName.isEmpty
                ? CandoaColor.primaryHover
                : CandoaColor.primary)
                .opacity(trimmedName.isEmpty ? 0.52 : 1)
        }

        return Color(spaceHex: primaryButtonTintHex)
            .opacity(trimmedName.isEmpty ? 0.52 : 0.86)
    }

    init(store: BrowserStore, mode: SpaceComposerMode = .create) {
        self.store = store
        self.mode = mode
        _name = State(initialValue: mode.defaultName)
        // New Spaces start neutral. Native macOS accent color remains the
        // primary-action tint instead of washing the browser surface in blue.
        _themeColorHex = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            composerHeader

            nameField

            // Edit keeps the space's existing profile; switching a live
            // space's data store means migrating its web views.
            if mode != .edit {
                profileRow
            }

            themeButton

            Spacer(minLength: 0)

            Button {
                createSpace()
            } label: {
                Text(mode.primaryButtonTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(createButtonTextColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(createButtonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(trimmedName.isEmpty)
            .onHover { isHoveringPrimaryButton = $0 }
            .animation(.easeOut(duration: 0.10), value: isHoveringPrimaryButton)
            .accessibilityIdentifier("space-primary-button")

            if mode != .initial {
                Button("Cancel") {
                    store.clearSpaceThemePreview()
                    if mode == .edit {
                        store.editingSpaceID = nil
                    } else {
                        store.isCreateSpacePresented = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.78 : 0.82) : Color.primary.opacity(0.86))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
        }
        .onAppear {
            if mode == .edit, let space = store.editingSpace {
                name = space.name
                symbolName = space.symbolName
                themeColorHex = space.themeColorHex
                themeAppearance = space.themeAppearance
                themeOpacity = space.themeOpacity
                themeTexture = space.themeTexture
            }
            publishCurrentThemePreview()
        }
        .onChange(of: isIconPickerPresented) { _, isPresented in
            guard !isPresented else { return }

            // AppKit may restore the adjacent text field as first responder
            // when this popover closes. Keep the setup page neutral after an
            // icon choice instead of selecting the default Space name.
            DispatchQueue.main.async {
                isNameFocused = false
            }
        }
        .onDisappear {
            store.clearSpaceThemePreview()
        }
    }

    private var composerHeader: some View {
        Group {
            if mode == .initial {
                EmptyView()
            } else {
                VStack(spacing: 8) {
                    Text(mode.title)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(textColor)

                    Text(mode.subtitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 34)
                .padding(.bottom, 32)
            }
        }
    }

    private var nameField: some View {
        HStack(spacing: 10) {
            Button {
                isIconPickerPresented.toggle()
            } label: {
                SpaceIconPreview(
                    symbolName: symbolName,
                    themeColorHex: themeColorHex,
                    strokeColor: isThemePreviewActive
                        ? foregroundBase.opacity(0.46)
                        : CandoaChromeStyle.sidebarIcon.opacity(0.78)
                )
            }
            .buttonStyle(.plain)
            .help("Change Icon")
            .popover(isPresented: $isIconPickerPresented, arrowEdge: .leading) {
                SpaceIconPicker(
                    selectedSymbolName: $symbolName,
                    isPresented: $isIconPickerPresented,
                    onWillDismiss: {
                        isNameFocused = false
                        NSApp.mainWindow?.makeFirstResponder(nil)
                    }
                )
            }

            TextField("", text: $name, prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .focused($isNameFocused)
                .accessibilityLabel("Space Name")
                .accessibilityIdentifier("space-name-field")
                .overlay(alignment: .leading) {
                    if name.isEmpty {
                        // Manual placeholder: the system prompt ignores custom
                        // colors on macOS and stays scheme-colored, which reads
                        // white on light theme surfaces.
                        Text("Space Name")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(secondaryTextColor)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: name) { _, newValue in
                    let limitedName = BrowserStore.limitedSpaceNameInput(newValue)
                    if limitedName != newValue {
                        name = limitedName
                    }
                }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(controlStroke, lineWidth: 1)
        }
    }

    private var profileRow: some View {
        HStack(spacing: 10) {
            Text("Profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textColor)

            Spacer(minLength: 8)

            Button {
                isProfilePickerPresented.toggle()
            } label: {
                Text(dataMode.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(pillFill)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isProfilePickerPresented, arrowEdge: .trailing) {
                SpaceProfilePicker(
                    selectedMode: $dataMode,
                    isPresented: $isProfilePickerPresented
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(controlStroke, lineWidth: 1)
        }
    }

    private var themeButton: some View {
        Button {
            isThemeEditorPresented.toggle()
        } label: {
            HStack(spacing: 9) {
                Spacer(minLength: 0)

                if let themeColorHex {
                    Circle()
                        .fill(Color(spaceHex: themeColorHex))
                        .frame(width: 10, height: 10)
                }

                Text("Edit Theme")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(textColor)

                Spacer(minLength: 0)
            }
            .frame(height: 40)
            .background(controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(controlStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isThemeEditorPresented, arrowEdge: .trailing) {
            SpaceThemePanel(
                selectedHex: $themeColorHex,
                selectedAppearance: themeAppearanceSelection,
                selectedOpacity: $themeOpacity,
                selectedTexture: $themeTexture,
                themeOptions: themeOptions,
                onThemePreviewChange: { hexes, opacity, texture in
                    store.previewSpaceThemeColors(
                        primaryHex: hexes.first,
                        auxiliaryHexes: Array(hexes.dropFirst())
                    )
                    store.previewSpaceThemeControls(opacity: opacity, texture: texture)
                }
            )
        }
    }

    private func publishCurrentThemePreview() {
        store.previewSpaceThemeAppearance(themeAppearance)
        store.previewSpaceThemeColors(primaryHex: themeColorHex)
        store.previewSpaceThemeControls(opacity: themeOpacity, texture: themeTexture)
    }

    private func createSpace() {
        if mode == .edit {
            if let editingSpaceID = store.editingSpaceID {
                store.updateSpace(
                    editingSpaceID,
                    name: trimmedName,
                    symbolName: symbolName,
                    themeColorHex: themeColorHex,
                    themeAppearance: themeAppearance,
                    themeOpacity: themeOpacity,
                    themeTexture: themeTexture
                )
            }
            store.clearSpaceThemePreview()
            return
        }

        if mode == .initial {
            store.completeInitialSpaceSetup(
                name: trimmedName,
                symbolName: symbolName,
                themeColorHex: themeColorHex,
                themeAppearance: themeAppearance,
                themeOpacity: themeOpacity,
                themeTexture: themeTexture,
                dataStoreID: dataMode.dataStoreID(current: store.activeSpace?.dataStoreID)
            )
            store.clearSpaceThemePreview()
            return
        }

        store.createSpace(
            name: trimmedName,
            symbolName: symbolName,
            themeColorHex: themeColorHex,
            themeAppearance: themeAppearance,
            themeOpacity: themeOpacity,
            themeTexture: themeTexture,
            dataStoreID: dataMode.dataStoreID(current: store.activeSpace?.dataStoreID)
        )
        store.clearSpaceThemePreview()
        store.isCreateSpacePresented = false
        store.openNewTabCommandPalette()
    }

}

internal struct SpaceIconPreview: View {
    let symbolName: String
    let themeColorHex: String?
    var strokeColor: Color = CandoaChromeStyle.sidebarIcon.opacity(0.78)

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
                        .foregroundStyle(Color(spaceHex: themeColorHex ?? "#A8ADB7"))
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
                .buttonStyle(.plain)
                .help("Clear Icon")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CandoaChromeStyle.sidebarIcon)

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
                    .stroke(CandoaChromeStyle.popoverBorder, lineWidth: 1)
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
                        .buttonStyle(.plain)
                        .help(option.title)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 304, height: 340)
        .background(CandoaChromeStyle.popoverBackground)
    }
}

internal struct SpaceIconOptionView: View {
    let option: SpaceIconOption
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? CandoaColor.primary.opacity(0.18) : Color.clear)

            if let emoji = option.emoji {
                Text(emoji)
                    .font(.system(size: 19))
            } else {
                Image(systemName: option.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? CandoaColor.primary : CandoaChromeStyle.sidebarText)
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
                                .foregroundStyle(CandoaChromeStyle.sidebarText)
                                .lineLimit(1)

                            Text(mode.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CandoaChromeStyle.sidebarIcon)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if selectedMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(CandoaColor.primary)
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selectedMode == mode ? Color.primary.opacity(0.07) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(CandoaChromeStyle.popoverBackground)
    }
}

internal struct SpaceThemePanel: View {
    @Binding var selectedHex: String?
    @Binding var selectedAppearance: SpaceThemeAppearance
    @Binding var selectedOpacity: Double
    @Binding var selectedTexture: Double
    let themeOptions: [(name: String, hex: String)]
    let onThemePreviewChange: ([String], Double, Double) -> Void

    @State private var auxiliaryHexes: [String] = []
    @State private var palettePage = 0
    @State private var palettePageDirection = 1
    @State private var usesHarmony = true
    @State private var dotPositions = [ThemeDotPosition(x: 0.57, y: 0.55)]
    @State private var didInitializeDotPositions = false

    private var paletteOptions: [(name: String, hex: String)] {
        themeOptions + [
            ("Mist", "#C8D3E8"),
            ("Mint", "#8BE0C2"),
            ("Amber", "#F0C36D"),
            ("Coral", "#F18A7A"),
            ("Lavender", "#C9A7E8"),
            ("Sky", "#82C4EA"),
            ("Rose", "#E4A4C3"),
            ("Graphite", "#8F96A8")
        ]
    }

    private var visiblePaletteOptions: [(name: String, hex: String)] {
        let pageSize = 8
        let currentPage = min(max(0, palettePage), pageCount - 1)
        let start = min(currentPage * pageSize, max(0, paletteOptions.count - pageSize))
        let end = min(start + pageSize, paletteOptions.count)
        return Array(paletteOptions[start..<end])
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(paletteOptions.count) / 8.0)))
    }

    private var canPagePaletteBackward: Bool {
        palettePage > 0
    }

    private var canPagePaletteForward: Bool {
        palettePage < pageCount - 1
    }

    private var activeHexes: [String] {
        selectedHex.map { [$0] + auxiliaryHexes } ?? []
    }

    private var normalizedOpacity: Double {
        (min(0.9, max(0.3, selectedOpacity)) - 0.3) / 0.6
    }

    private var hasSelectedThemeColor: Bool {
        selectedHex != nil
    }

    private var themeControlAccentHex: String {
        selectedHex ?? "#A8ADB7"
    }

    var body: some View {
        VStack(spacing: 0) {
            themeField

            paletteRow
                .padding(.top, 10)

            lowerControls
                .padding(.top, 12)
        }
        .padding(10)
        .frame(width: 372)
        .onAppear {
            initializeDotPositionsIfNeeded()
            publishThemePreview()
        }
        .onChange(of: selectedHex) { _, _ in
            publishThemePreview()
        }
        .onChange(of: auxiliaryHexes) { _, _ in
            publishThemePreview()
        }
        .onChange(of: selectedOpacity) { _, _ in
            publishThemePreview()
        }
        .onChange(of: selectedTexture) { _, _ in
            publishThemePreview()
        }
    }

    private var themeField: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))

            ThemeColorFieldBackground(
                hexes: activeHexes,
                positions: dotPositions,
                intensity: 0.20 + normalizedOpacity * 0.62
            )
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            DotPattern(opacity: 0.09 + selectedTexture * 0.22, spacing: 6, dotSize: 1.7)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            ThemeColorFieldDots(
                hexes: activeHexes,
                positions: dotPositions,
                onDrag: updateDotPosition
            )

            VStack(spacing: 0) {
                appearanceControls
                    .padding(.top, 12)

                Spacer(minLength: 0)

                fieldActionControls
                    .padding(.bottom, 15)
            }
        }
        .frame(height: 352)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(CandoaChromeStyle.popoverBorder, lineWidth: 1)
        }
    }

    private var appearanceControls: some View {
        HStack(spacing: 18) {
            ForEach(SpaceThemeAppearance.allCases) { option in
                Button {
                    selectedAppearance = option
                } label: {
                    Image(systemName: option.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 32)
                        .foregroundStyle(CandoaChromeStyle.sidebarText)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selectedAppearance == option ? Color.primary.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
    }

    private var fieldActionControls: some View {
        HStack(spacing: 28) {
            ThemeIconButton(systemName: "plus", help: "Add Color") {
                addAuxiliaryColor()
            }
            .disabled(auxiliaryHexes.count >= 2)

            ThemeIconButton(systemName: "minus", help: "Remove Color") {
                removeAuxiliaryColor()
            }
            .disabled(selectedHex == nil && auxiliaryHexes.isEmpty)

            ThemeHarmonyButton(isActive: usesHarmony, isEnabled: activeHexes.count > 1) {
                usesHarmony.toggle()

                // Snap immediately so the toggle gives visible feedback
                // instead of only applying on the next dot drag.
                if usesHarmony, let primary = dotPositions.first, !auxiliaryHexes.isEmpty {
                    withAnimation(.easeOut(duration: 0.22)) {
                        harmonizeAuxiliaryDots(around: primary)
                    }
                    publishThemePreview()
                }
            }
        }
    }

    private var paletteRow: some View {
        HStack(spacing: 9) {
            ThemeIconButton(systemName: "chevron.left", help: "Previous Colors") {
                pagePalette(by: -1)
            }
            .disabled(!canPagePaletteBackward)

            ZStack {
                paletteColorPage
                    .id(palettePage)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: palettePageDirection > 0 ? .trailing : .leading)
                                .combined(with: .opacity),
                            removal: .move(edge: palettePageDirection > 0 ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                    )
            }
            .frame(width: 287, height: 32)
            .clipped()

            ThemeIconButton(systemName: "chevron.right", help: "More Colors") {
                pagePalette(by: 1)
            }
            .disabled(!canPagePaletteForward)
        }
        .frame(height: 32)
    }

    private var paletteColorPage: some View {
        HStack(spacing: 9) {
            ForEach(visiblePaletteOptions, id: \.hex) { option in
                Button {
                    selectPaletteColor(option.hex)
                } label: {
                    Circle()
                        .fill(Color(spaceHex: option.hex))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    selectedHex == option.hex ? Color.white : Color.clear,
                                    lineWidth: 3
                                )
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    selectedHex == option.hex ? CandoaChromeStyle.sidebarText.opacity(0.68) : Color.clear,
                                    lineWidth: 1
                                )
                                .padding(-1)
                        }
                }
                .buttonStyle(.plain)
                .help(option.name)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 287, height: 32, alignment: .leading)
    }

    private var lowerControls: some View {
        HStack(spacing: 18) {
            ThemeWaveSlider(
                value: $selectedOpacity,
                accentHex: themeControlAccentHex,
                isEnabled: hasSelectedThemeColor
            )
                .frame(width: 218, height: 58)

            Spacer(minLength: 0)

            ThemeTextureDial(
                value: $selectedTexture,
                accentHex: themeControlAccentHex,
                isEnabled: hasSelectedThemeColor
            )
                .frame(width: 62, height: 62)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func addAuxiliaryColor() {
        guard auxiliaryHexes.count < 2 else { return }
        let hexes = paletteOptions.map(\.hex)
        guard let firstHex = hexes.first else { return }

        if selectedHex == nil {
            selectedHex = firstHex
            ensureDotPositionCount()
            dotPositions[0] = Self.position(forHex: firstHex)
            publishThemePreview()
            return
        }

        let referenceHex = auxiliaryHexes.last ?? selectedHex ?? firstHex
        let referenceIndex = hexes.firstIndex(of: referenceHex) ?? 0

        for offset in 1...hexes.count {
            let candidate = hexes[(referenceIndex + offset) % hexes.count]
            if candidate != selectedHex, !auxiliaryHexes.contains(candidate) {
                auxiliaryHexes.append(candidate)
                ensureDotPositionCount()
                dotPositions[auxiliaryHexes.count] = suggestedAuxiliaryPosition(at: auxiliaryHexes.count)
                publishThemePreview()
                return
            }
        }
    }

    private func removeAuxiliaryColor() {
        if !auxiliaryHexes.isEmpty {
            auxiliaryHexes.removeLast()
        } else if selectedHex != nil {
            selectedHex = nil
        } else {
            return
        }

        if dotPositions.count > activeHexes.count {
            dotPositions.removeLast(dotPositions.count - activeHexes.count)
        }
        publishThemePreview()
    }

    private func initializeDotPositionsIfNeeded() {
        guard !didInitializeDotPositions else { return }
        didInitializeDotPositions = true
        dotPositions = selectedHex.map { [Self.position(forHex: $0)] } ?? []
        ensureDotPositionCount()
    }

    private func ensureDotPositionCount() {
        while dotPositions.count < activeHexes.count {
            dotPositions.append(suggestedAuxiliaryPosition(at: dotPositions.count))
        }

        if dotPositions.count > activeHexes.count {
            dotPositions.removeLast(dotPositions.count - activeHexes.count)
        }
    }

    private func selectPaletteColor(_ hex: String) {
        selectedHex = hex
        ensureDotPositionCount()
        dotPositions[0] = Self.position(forHex: hex)
        publishThemePreview()
    }

    private func pagePalette(by delta: Int) {
        let nextPage = min(max(0, palettePage + delta), pageCount - 1)
        guard nextPage != palettePage else { return }

        palettePageDirection = delta >= 0 ? 1 : -1
        withAnimation(.easeOut(duration: 0.18)) {
            palettePage = nextPage
        }
    }

    private func updateDotPosition(index: Int, position: ThemeDotPosition) {
        ensureDotPositionCount()
        guard dotPositions.indices.contains(index) else { return }

        dotPositions[index] = position

        if index == 0 {
            selectedHex = Self.hex(for: position)
            if usesHarmony, auxiliaryHexes.count > 0 {
                harmonizeAuxiliaryDots(around: position)
            }
        } else {
            let auxiliaryIndex = index - 1
            if auxiliaryHexes.indices.contains(auxiliaryIndex) {
                auxiliaryHexes[auxiliaryIndex] = Self.hex(for: position)
            }
        }

        publishThemePreview()
    }

    private func harmonizeAuxiliaryDots(around primaryPosition: ThemeDotPosition) {
        let dx = primaryPosition.x - 0.5
        let dy = primaryPosition.y - 0.5
        let primaryAngle = atan2(dy, dx)
        let radius = min(0.38, max(0.18, hypot(dx, dy)))

        for auxiliaryIndex in auxiliaryHexes.indices {
            let dotIndex = auxiliaryIndex + 1
            let offset = auxiliaryIndex == 0 ? 2.12 : -2.12
            let angle = primaryAngle + offset
            let position = ThemeDotPosition(
                x: 0.5 + cos(angle) * radius,
                y: 0.5 + sin(angle) * radius
            ).clampedToUnitCircle()

            dotPositions[dotIndex] = position
            auxiliaryHexes[auxiliaryIndex] = Self.hex(for: position)
        }
    }

    private func publishThemePreview() {
        onThemePreviewChange(activeHexes, selectedOpacity, selectedTexture)
    }

    private func suggestedAuxiliaryPosition(at index: Int) -> ThemeDotPosition {
        let primary = dotPositions.first ?? ThemeDotPosition(x: 0.57, y: 0.55)
        let dx = primary.x - 0.5
        let dy = primary.y - 0.5
        let primaryAngle = atan2(dy, dx)
        let radius = min(0.38, max(0.22, hypot(dx, dy)))
        let offset = index == 1 ? 2.12 : -2.12

        return ThemeDotPosition(
            x: 0.5 + cos(primaryAngle + offset) * radius,
            y: 0.5 + sin(primaryAngle + offset) * radius
        ).clampedToUnitCircle()
    }

    private static func position(forHex hex: String) -> ThemeDotPosition {
        guard let components = rgbComponents(from: hex) else {
            return ThemeDotPosition(x: 0.57, y: 0.55)
        }

        let color = NSColor(
            calibratedRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let radius = min(0.40, max(0.16, saturation * 0.40))
        let angle = hue * .pi * 2
        return ThemeDotPosition(
            x: 0.5 + cos(angle) * radius,
            y: 0.5 + sin(angle) * radius
        ).clampedToUnitCircle()
    }

    private static func hex(for position: ThemeDotPosition) -> String {
        let dx = position.x - 0.5
        let dy = position.y - 0.5
        var hue = atan2(dy, dx) / (.pi * 2)
        if hue < 0 {
            hue += 1
        }

        let distance = min(1, hypot(dx, dy) / 0.42)
        let saturation = min(0.96, max(0.34, distance))
        let brightness = min(0.98, max(0.46, 1.04 - position.y * 0.56))

        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        guard let rgbColor = color.usingColorSpace(.sRGB) else {
            return BrowserSpace.defaultThemeColorHex
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func rgbComponents(from hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }

        return (
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0
        )
    }
}

internal struct ThemeDotPosition: Equatable {
    var x: CGFloat
    var y: CGFloat

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    func clampedToUnitCircle() -> ThemeDotPosition {
        let dx = x - 0.5
        let dy = y - 0.5
        let radius = hypot(dx, dy)
        guard radius > 0.42 else {
            return ThemeDotPosition(
                x: min(0.92, max(0.08, x)),
                y: min(0.92, max(0.08, y))
            )
        }

        let scale = 0.42 / radius
        return ThemeDotPosition(
            x: min(0.92, max(0.08, 0.5 + dx * scale)),
            y: min(0.92, max(0.08, 0.5 + dy * scale))
        )
    }

    static func clamped(from point: CGPoint, in size: CGSize) -> ThemeDotPosition {
        let safeWidth = max(1, size.width)
        let safeHeight = max(1, size.height)
        let center = CGPoint(x: safeWidth / 2, y: safeHeight / 2)
        let fieldRadius = min(safeWidth, safeHeight) * 0.42
        var clampedPoint = point

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance > fieldRadius {
            let scale = fieldRadius / distance
            clampedPoint = CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        }

        return ThemeDotPosition(
            x: min(0.92, max(0.08, clampedPoint.x / safeWidth)),
            y: min(0.92, max(0.08, clampedPoint.y / safeHeight))
        )
    }
}

internal struct ThemeColorFieldBackground: View {
    let hexes: [String]
    let positions: [ThemeDotPosition]
    let intensity: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(hexes.enumerated()), id: \.offset) { index, hex in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(spaceHex: hex).opacity(intensity),
                                    Color(spaceHex: hex).opacity(intensity * 0.30),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 125
                            )
                        )
                        .frame(width: 260, height: 260)
                        .position(position(for: index, in: proxy.size))
                        .blur(radius: 14)
                }

                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.08),
                        Color.primary.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        guard positions.indices.contains(index) else {
            return CGPoint(x: size.width * 0.57, y: size.height * 0.55)
        }

        return positions[index].point(in: size)
    }
}

internal struct ThemeColorFieldDots: View {
    let hexes: [String]
    let positions: [ThemeDotPosition]
    let onDrag: (Int, ThemeDotPosition) -> Void

    private static let coordinateSpaceName = "CandoaThemeColorField"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(hexes.enumerated()), id: \.offset) { index, hex in
                    Circle()
                        .fill(Color(spaceHex: hex))
                        .frame(width: index == 0 ? 40 : 22, height: index == 0 ? 40 : 22)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(index == 0 ? 0.95 : 0.86), lineWidth: index == 0 ? 5 : 3)
                        }
                        .shadow(color: Color.black.opacity(0.20), radius: 8, x: 0, y: 4)
                        .scaleEffect(positions.indices.contains(index) ? 1 : 0.001)
                        .position(position(for: index, in: proxy.size))
                        .contentShape(Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                                .onChanged { gesture in
                                    onDrag(
                                        index,
                                        ThemeDotPosition.clamped(from: gesture.location, in: proxy.size)
                                    )
                                }
                        )
                        .help(index == 0 ? "Drag to change Space color" : "Drag to adjust theme color")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: Self.coordinateSpaceName)
        }
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        guard positions.indices.contains(index) else {
            return CGPoint(x: size.width * 0.57, y: size.height * 0.55)
        }

        return positions[index].point(in: size)
    }
}

internal struct ThemeIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CandoaChromeStyle.sidebarText.opacity(isEnabled ? 0.92 : 0.34))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

internal struct ThemeHarmonyButton: View {
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var didPushNotAllowedCursor = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(CandoaChromeStyle.sidebarText.opacity(isEnabled ? (isActive ? 0.94 : 0.54) : 0.30))
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive && isEnabled ? Color.primary.opacity(0.13) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isEnabled ? "Auto-arrange colors" : "Add another color to use harmony")
        .onHover { hovering in
            isHovering = hovering
            updateCursor()
        }
        .onChange(of: isEnabled) { _, _ in
            updateCursor()
        }
        .onDisappear {
            popNotAllowedCursorIfNeeded()
        }
    }

    private func updateCursor() {
        guard isHovering, !isEnabled else {
            popNotAllowedCursorIfNeeded()
            return
        }

        guard !didPushNotAllowedCursor else { return }
        NSCursor.operationNotAllowed.push()
        didPushNotAllowedCursor = true
    }

    private func popNotAllowedCursorIfNeeded() {
        guard didPushNotAllowedCursor else { return }
        NSCursor.pop()
        didPushNotAllowedCursor = false
    }
}

internal struct ThemeWaveSlider: View {
    @Binding var value: Double
    let accentHex: String
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var handleColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private let range = 0.3...0.9

    private var normalizedValue: Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let progress = normalizedValue
            let handleX = CGFloat(progress) * max(1, size.width - 26) + 13
            let handleWidth = CGFloat(14 + progress * 10)
            let handleHeight = CGFloat(42 + progress * 12)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? 0.09 : 0.05))
                    .frame(height: 16)
                    .padding(.horizontal, 1)

                ThemeWaveShape(progress: progress)
                    .stroke(Color.primary.opacity(isEnabled ? 0.28 : 0.16), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .frame(height: 32)
                    .padding(.horizontal, 1)

                ThemeWaveShape(progress: progress)
                    .trim(from: 0, to: progress)
                    .stroke(
                        isEnabled
                            ? Color(spaceHex: accentHex).opacity(0.38 + progress * 0.46)
                            : Color.primary.opacity(0.12),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                    )
                    .frame(height: 32)
                    .padding(.horizontal, 1)

                Capsule(style: .continuous)
                    .fill(handleColor.opacity(isEnabled ? 1 : 0.28))
                    .frame(width: handleWidth, height: handleHeight)
                    .shadow(color: Color.black.opacity(isEnabled ? 0.22 : 0), radius: 6, x: 0, y: 3)
                    .position(x: handleX, y: size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let progress = min(1, max(0, gesture.location.x / max(1, size.width)))
                        value = range.lowerBound + progress * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}

internal struct ThemeWaveShape: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amplitude = rect.height * (0.18 + CGFloat(progress) * 0.20)
        let midY = rect.midY
        let wavelength = max(34, rect.width / 5.5)

        path.move(to: CGPoint(x: rect.minX, y: midY))

        var x = rect.minX
        while x <= rect.maxX {
            let normalized = (x - rect.minX) / wavelength
            let y = midY + sin(normalized * .pi * 2) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 3
        }

        return path
    }
}

internal struct ThemeTextureDial: View {
    @Binding var value: Double
    let accentHex: String
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragValue: Double?

    private var handleColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private let textureStepCount = 16
    private var maxTextureStep: Int {
        textureStepCount - 1
    }

    private var clampedValue: Double {
        min(1, max(0, value))
    }

    private var displayedValue: Double {
        dragValue ?? clampedValue
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side * 0.35
            let activeValue = displayedValue
            let activeStep = textureStep(for: activeValue)

            ZStack {
                ForEach(0..<textureStepCount, id: \.self) { index in
                    let isActive = isEnabled && activeValue > 0 && index <= activeStep
                    Circle()
                        .fill(isActive ? Color(spaceHex: accentHex).opacity(0.74) : Color.primary.opacity(index % 4 == 0 ? 0.30 : 0.20))
                        .frame(width: index % 4 == 0 ? 5 : 4, height: index % 4 == 0 ? 5 : 4)
                        .position(point(forStep: index, radius: radius, in: proxy.size))
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(spaceHex: accentHex).opacity(isEnabled ? 0.28 : 0.04),
                                Color.primary.opacity(isEnabled ? 0.10 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        DotPattern(
                            opacity: isEnabled ? 0.03 + activeValue * 0.20 : 0.035,
                            spacing: 4,
                            dotSize: 1.1
                        )
                        .clipShape(Circle())
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    }
                    .frame(width: side * 0.64, height: side * 0.64)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                Capsule(style: .continuous)
                    .fill(handleColor.opacity(isEnabled ? 1 : 0.34))
                    .frame(width: 7, height: 18)
                    .rotationEffect(.degrees(rotationDegrees(forStep: activeStep)))
                    .position(point(forStep: activeStep, radius: radius, in: proxy.size))
                    .shadow(color: Color.black.opacity(isEnabled ? 0.18 : 0), radius: 3, x: 0, y: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let nextValue = steppedValue(for: dialValue(for: gesture.location, in: proxy.size))
                        if textureStep(for: displayedValue) != textureStep(for: nextValue) {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        setValueWithoutAnimation(nextValue)
                    }
                    .onEnded { _ in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            dragValue = nil
                        }
                    }
            )
        }
    }

    private func point(forStep step: Int, radius: CGFloat, in size: CGSize) -> CGPoint {
        let angle = angle(forStep: step)
        return CGPoint(
            x: size.width / 2 + sin(angle) * radius,
            y: size.height / 2 - cos(angle) * radius
        )
    }

    private func dialValue(for location: CGPoint, in size: CGSize) -> Double {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = normalizedAngle(atan2(location.y - center.y, location.x - center.x) + (.pi / 2))
        return Double(angle / (.pi * 2))
    }

    private func angle(forStep step: Int) -> CGFloat {
        CGFloat(min(maxTextureStep, max(0, step))) / CGFloat(textureStepCount) * .pi * 2
    }

    private func rotationDegrees(forStep step: Int) -> Double {
        Double(min(maxTextureStep, max(0, step))) / Double(textureStepCount) * 360
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        positiveModulo(angle, .pi * 2)
    }

    private func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private func steppedValue(for value: Double) -> Double {
        Double(textureStep(for: value)) / Double(maxTextureStep)
    }

    private func textureStep(for value: Double) -> Int {
        min(maxTextureStep, max(0, Int((min(1, max(0, value)) * Double(maxTextureStep)).rounded())))
    }

    private func setValueWithoutAnimation(_ nextValue: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragValue = nextValue
            value = nextValue
        }
    }
}

internal struct DotPattern: View {
    var opacity: Double = 0.11
    var spacing: CGFloat = 8
    var dotSize: CGFloat = 2

    var body: some View {
        let clampedOpacity = min(1, max(0, opacity))

        if clampedOpacity > 0 {
            DotPatternCanvas(spacing: spacing, dotSize: dotSize)
                .equatable()
                .opacity(clampedOpacity)
        }
    }
}

internal struct DotPatternCanvas: View, Equatable {
    var spacing: CGFloat
    var dotSize: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard spacing > 0, dotSize > 0 else { return }

            var dots = Path()
            var x: CGFloat = 6
            while x < size.width {
                var y: CGFloat = 6
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
                    y += spacing
                }
                x += spacing
            }

            context.fill(dots, with: .color(Color.primary))
        }
    }
}

internal struct SpaceIconOption: Identifiable {
    let symbolName: String
    let title: String

    init(symbolName: String, title: String) {
        self.symbolName = symbolName
        self.title = title
    }

    init(emoji: String, title: String) {
        self.symbolName = Self.emojiPrefix + emoji
        self.title = title
    }

    var id: String { symbolName }

    var emoji: String? {
        Self.emoji(from: symbolName)
    }

    static func emoji(from symbolName: String) -> String? {
        guard symbolName.hasPrefix(emojiPrefix) else { return nil }
        return String(symbolName.dropFirst(emojiPrefix.count))
    }

    private static let emojiPrefix = BrowserSpace.emojiSymbolPrefix
}

internal enum SpaceIconPickerMode: String, CaseIterable, Identifiable {
    case emojis
    case symbols
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emojis:
            return "Emojis"
        case .symbols:
            return "Symbols"
        case .icons:
            return "Icons"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .emojis:
            return "Search emojis"
        case .symbols, .icons:
            return "Search icons"
        }
    }
}

internal enum SpaceComposerMode: Equatable {
    case create
    case initial
    case edit

    var defaultName: String {
        switch self {
        case .initial:
            return "Personal"
        case .create, .edit:
            return ""
        }
    }

    var title: String {
        switch self {
        case .create, .initial:
            return "Create a Space"
        case .edit:
            return "Edit Space"
        }
    }

    var subtitle: String {
        switch self {
        case .create, .initial:
            return "Spaces organize your tabs and sessions."
        case .edit:
            return "Update this Space's name, icon, and theme."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .create, .initial:
            return BrowserCommandTitles.createSpace
        case .edit:
            return "Save Changes"
        }
    }
}

internal enum SpaceDataMode: String, CaseIterable, Identifiable {
    case isolated
    case shareCurrent
    case personal
    case work
    case banking
    case shopping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolated:
            return "Default"
        case .shareCurrent:
            return "Current"
        case .personal:
            return "Personal"
        case .work:
            return "Work"
        case .banking:
            return "Banking"
        case .shopping:
            return "Shopping"
        }
    }

    var detail: String {
        switch self {
        case .isolated:
            return "Separate browsing session"
        case .shareCurrent:
            return "Share active Space session"
        case .personal:
            return "Shared personal profile"
        case .work:
            return "Shared work profile"
        case .banking:
            return "Shared finance profile"
        case .shopping:
            return "Shared shopping profile"
        }
    }

    var symbolName: String {
        switch self {
        case .isolated:
            return "person.crop.circle"
        case .shareCurrent:
            return "link"
        case .personal:
            return "person.crop.circle.fill"
        case .work:
            return "briefcase.fill"
        case .banking:
            return "dollarsign.circle.fill"
        case .shopping:
            return "cart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .isolated:
            return .blue
        case .shareCurrent:
            return .green
        case .personal:
            return .cyan
        case .work:
            return .orange
        case .banking:
            return Color(red: 0.39, green: 0.82, blue: 0.18)
        case .shopping:
            return .pink
        }
    }

    func dataStoreID(current: UUID?) -> UUID {
        switch self {
        case .isolated:
            return UUID()
        case .shareCurrent:
            return current ?? UUID()
        case .personal:
            return UUID(uuidString: "69E60654-3E84-4761-87DA-B13A2C7195E3")!
        case .work:
            return UUID(uuidString: "3ED24A8B-6573-46BE-9059-8E8E331F0143")!
        case .banking:
            return UUID(uuidString: "28166B44-6387-4216-9EAE-39A569C6014D")!
        case .shopping:
            return UUID(uuidString: "72BC27D2-3D02-459A-A0AF-98036B15CF13")!
        }
    }
}
