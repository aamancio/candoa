import AppKit
import SwiftUI

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
    @FocusState private var isNameFocused: Bool

    private let themeOptions: [(name: String, hex: String)] = [
        ("Blue", BrowserSpace.blueThemeColorHex),
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
        // interface, so its controls must follow the preview's contrast. Initial
        // onboarding is inside a neutral system surface and keeps semantic
        // macOS label/control colors regardless of the surrounding preview.
        mode == .create && themeColorHex != nil
    }

    private var usesDarkForeground: Bool {
        let previewHexes = store.activeThemeColorHexes
        if !previewHexes.isEmpty {
            return CandoaInterfaceStyle.prefersDarkForeground(forSpaceHexes: previewHexes)
        }
        guard let themeColorHex else { return false }
        return CandoaInterfaceStyle.prefersDarkForeground(forSpaceHex: themeColorHex)
    }

    private var foregroundBase: Color {
        usesDarkForeground ? Color.black : Color.white
    }

    private var textColor: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.82 : 0.88) : CandoaInterfaceStyle.sidebarText
    }

    private var secondaryTextColor: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.55 : 0.58) : CandoaInterfaceStyle.sidebarTextSecondary
    }

    private var iconColor: Color {
        isThemePreviewActive ? foregroundBase.opacity(0.42) : CandoaInterfaceStyle.sidebarIcon
    }

    private var inputFill: Color {
        isThemePreviewActive
            ? foregroundBase.opacity(usesDarkForeground ? 0.09 : 0.11)
            : CandoaInterfaceStyle.spaceSetupInputFill
    }

    private var secondaryControlFill: Color {
        isThemePreviewActive
            ? foregroundBase.opacity(usesDarkForeground ? 0.045 : 0.06)
            : CandoaInterfaceStyle.spaceSetupSecondaryFill
    }

    private var controlStroke: Color {
        isThemePreviewActive ? foregroundBase.opacity(0.08) : CandoaInterfaceStyle.spaceSetupControlStroke
    }

    private var pillFill: Color {
        isThemePreviewActive ? foregroundBase.opacity(usesDarkForeground ? 0.08 : 0.10) : CandoaInterfaceStyle.spaceSetupPillFill
    }

    private var themeAppearanceSelection: Binding<SpaceThemeAppearance> {
        Binding {
            themeAppearance
        } set: { newAppearance in
            themeAppearance = newAppearance
            store.previewSpaceThemeAppearance(newAppearance)
        }
    }

    init(store: BrowserStore, mode: SpaceComposerMode = .create) {
        self.store = store
        self.mode = mode
        _name = State(initialValue: mode.defaultName)
        // New Spaces start neutral. A color enters the interface and primary
        // action only after the person explicitly selects a theme.
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
                    .frame(maxWidth: .infinity)
            }
            .candoaButton(.primary)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(trimmedName.isEmpty)
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
                .candoaButton(.quiet)
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

            guard mode != .initial else { return }
            DispatchQueue.main.async {
                isNameFocused = true
            }
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
                        : CandoaInterfaceStyle.sidebarIcon.opacity(0.78)
                )
            }
            .candoaButton(.content)
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
        .background(inputFill)
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
            .candoaButton(.content)
            .popover(isPresented: $isProfilePickerPresented, arrowEdge: .trailing) {
                SpaceProfilePicker(
                    selectedMode: $dataMode,
                    isPresented: $isProfilePickerPresented
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(secondaryControlFill)
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
            .background(secondaryControlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(controlStroke, lineWidth: 1)
            }
        }
        .candoaButton(.content)
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
