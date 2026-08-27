import AppKit
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var store: BrowserStore
    @State internal var query = ""
    @State internal var selectedSearchProvider: SearchProvider?
    @State internal var selectedCommandIndex = 0
    @State internal var suppressesAutocomplete = false
    @State internal var fieldFocusRequestID = UUID()
    @FocusState internal var isSearchFocused: Bool
    @Environment(\.colorScheme) internal var colorScheme
    @AppStorage(SettingsOption.defaultSearchProvider) internal var defaultSearchProvider = NavigationService.searchProviders.first?.id ?? "google"

    /// The shared Candoa primary used by search focus and default selections.
    static var paletteTint: Color { AppColor.accent }
    internal static let maxVisibleCommandCount = 6
    internal static let commandRowHeight: CGFloat = 46
    internal static let commandRowSpacing: CGFloat = 7
    internal static let resultsVerticalPadding: CGFloat = 22
    internal static let normalHeaderHeight: CGFloat = 70
    internal static let addressHeaderHeight: CGFloat = 62
    internal static let dividerHeight: CGFloat = 1
    internal static let addressPaletteLeadingInset: CGFloat = 5
    internal static let addressPaletteTopInset: CGFloat = 44
    internal static let addressPaletteHeight: CGFloat = 333
    internal static let addressPaletteMaxWidth: CGFloat = 440

    internal var activeTint: Color {
        return selectedSearchProvider?.paletteColor ?? Self.paletteTint
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .shadowColor)
                .opacity(colorScheme == .dark ? 0.12 : 0.06)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissPalette()
                }

            GeometryReader { proxy in
                let width = paletteWidth(for: proxy.size.width)

                paletteSurface
                    .frame(width: width, height: anchoredPaletteHeight, alignment: .top)
                    .position(palettePosition(in: proxy.size, width: width))
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(
            CommandPaletteKeyMonitor(
                isProviderChipDeletable: selectedSearchProvider != nil && query.isEmpty,
                onDeleteProviderChip: deleteSelectedSearchProvider,
                onMoveSelection: moveSelection,
                onCancel: { dismissPalette() }
            )
        )
        .onAppear {
            query = store.commandPaletteInitialText
            selectedSearchProvider = nil
            selectedCommandIndex = 0
            suppressesAutocomplete = false
            fieldFocusRequestID = UUID()
            focusSearchField()
        }
        .onExitCommand {
            dismissPalette()
        }
        .onChange(of: fieldFocusRequestID) { _, _ in
            focusSearchField()
        }
        .onChange(of: query) { previousQuery, newQuery in
            // Deleting has to be able to reach the text: completing again on
            // every keystroke would hand the deleted characters straight back
            // as a longer highlight, so the palette leaves the query alone
            // until typing resumes — the way Safari's address field does.
            suppressesAutocomplete = newQuery.count < previousQuery.count
            selectedCommandIndex = 0
            store.setUITestingCommandPaletteQuery(query)
        }
        .onChange(of: selectedSearchProvider) { _, _ in
            selectedCommandIndex = 0
        }
    }
}
