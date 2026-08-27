import SwiftUI

extension CommandPaletteView {
    internal var paletteSurface: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PaletteIconView(
                    symbolName: leadingSymbolName,
                    isSelected: false,
                    size: 24,
                    faviconData: headerFaviconData,
                    usesCircularFavicon: usesCircularHeaderFavicon,
                    provider: headerIconSearchProvider
                )

                if let selectedSearchProvider {
                    PaletteChip(text: selectedSearchProvider.name, color: selectedSearchProvider.paletteColor)
                }

                searchField
                    .layoutPriority(1)

                if let headerSearchProvider, !isAnchoredAddressPalette {
                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        Text("Search \(headerSearchProvider.name)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("Tab")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                }
            }
            .padding(.horizontal, isAnchoredAddressPalette ? 18 : 16)
            .padding(.vertical, paletteHeaderVerticalPadding)

            Rectangle()
                .fill(InterfaceStyle.popoverBorder)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 7) {
                    ForEach(identifiedVisibleCommands, id: \.id) { entry in
                        let index = entry.index
                        let command = entry.command
                        Button {
                            run(command)
                        } label: {
                            PaletteCommandRow(
                                command: command,
                                isSelected: index == selectedCommandIndex,
                                selectedTint: activeTint
                            )
                        }
                        .buttonTreatment(.content)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            // ScrollView always claims its max height; with few rows
            // that left a dead slab under the results. Size it to the
            // rows instead (Arc's bar hugs its content).
            .frame(height: resultsAreaHeight)
        }
        .frame(height: anchoredPaletteHeight, alignment: .top)
        .background(PaletteBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(InterfaceStyle.popoverBorder, lineWidth: 1)
        }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.24), radius: 46, y: 24)
    }

    /// Rows keyed by their content-derived identity, with a suffix on the
    /// rare collision so ForEach never sees two rows with one key.
    internal var identifiedVisibleCommands: [(id: String, index: Int, command: PaletteCommand)] {
        var seen: [String: Int] = [:]
        return visibleCommands.enumerated().map { index, command in
            let count = seen[command.id, default: 0]
            seen[command.id] = count + 1
            return (id: count == 0 ? command.id : "\(command.id)#\(count)", index: index, command: command)
        }
    }

    internal var visibleCommands: [PaletteCommand] {
        Array(dedupedCommands(filteredCommands).prefix(Self.maxVisibleCommandCount))
    }

    internal var isAddressEditingPalette: Bool {
        store.commandPalettePrefersCurrentTabNavigation
    }

    internal var isSidebarAddressPalette: Bool {
        store.commandPaletteWasOpenedFromSidebarAddress
    }

    internal var isTopAddressPalette: Bool {
        store.commandPaletteWasOpenedFromTopAddressBar
    }

    /// Editing the current address — from the sidebar pill or the "Above the
    /// Page" strip — presents as an anchored dropdown at the window's top,
    /// Arc-style, rather than the centered new-tab bar. The two anchors
    /// share every layout rule except width: the strip's dropdown spans the
    /// window edge to edge the way the strip itself does, while the sidebar
    /// pill's stays sized to its lane.
    internal var isAnchoredAddressPalette: Bool {
        isSidebarAddressPalette || isTopAddressPalette
    }

    internal func paletteWidth(for windowWidth: CGFloat) -> CGFloat {
        if isAnchoredAddressPalette {
            let width = max(0, windowWidth - Self.addressPaletteLeadingInset * 2)
            return isTopAddressPalette ? width : min(width, Self.addressPaletteMaxWidth)
        }

        // Zen's floating urlbar width: min(window width / 1.5, 750)
        // (ZenUIManager.updateTabsToolbar's --zen-urlbar-width).
        return min(windowWidth / 1.5, 750)
    }

    internal func palettePosition(in windowSize: CGSize, width: CGFloat) -> CGPoint {
        if isAnchoredAddressPalette {
            return CGPoint(
                x: Self.addressPaletteLeadingInset + width / 2,
                y: Self.addressPaletteTopInset + anchoredPaletteHeight / 2
            )
        }

        return CGPoint(x: windowSize.width / 2, y: windowSize.height / 2)
    }

    internal var headerIconSearchProvider: SearchProvider? {
        // A chosen site already names itself in the chip beside the field, so
        // the icon stays the plain magnifier of a search box (Arc does the
        // same) rather than repeating the site's mark.
        guard selectedSearchProvider == nil else { return nil }
        // Once the typed address resolves to a known provider, its icon must
        // describe the destination rather than the tab that happened to be
        // active when editing began.
        return headerSearchProvider ?? (isAddressEditingPalette ? provider(for: store.activeTab?.url) : nil)
    }

    internal var headerFaviconData: Data? {
        guard selectedSearchProvider == nil else { return nil }
        return headerSearchProvider == nil && isAddressEditingPalette ? store.activeTab?.faviconData : nil
    }

    internal var usesCircularHeaderFavicon: Bool {
        selectedSearchProvider == nil
            && headerSearchProvider == nil
            && isAddressEditingPalette
            && !isAnchoredAddressPalette
    }

    /// Exact height of the visible rows (46pt rows, 7pt spacing, 11pt
    /// vertical padding), so the results area hugs its content.
    internal var resultsHeight: CGFloat {
        resultsHeight(for: CGFloat(visibleCommands.count))
    }

    /// The palette itself shrinks with its result count, but it sits inside
    /// this fixed-height anchor so typing does not recenter the surface.
    internal var anchoredPaletteHeight: CGFloat {
        if isAnchoredAddressPalette {
            return Self.addressPaletteHeight
        }

        return Self.normalHeaderHeight + Self.dividerHeight + resultsHeight(for: CGFloat(Self.maxVisibleCommandCount))
    }

    internal var paletteHeaderHeight: CGFloat {
        isAnchoredAddressPalette ? Self.addressHeaderHeight : Self.normalHeaderHeight
    }

    internal var paletteHeaderVerticalPadding: CGFloat {
        max(0, (paletteHeaderHeight - 30) / 2)
    }

    internal var resultsAreaHeight: CGFloat {
        if isAnchoredAddressPalette {
            return max(0, anchoredPaletteHeight - paletteHeaderHeight - Self.dividerHeight)
        }

        return resultsHeight
    }

    internal func resultsHeight(for count: CGFloat) -> CGFloat {
        count * Self.commandRowHeight + max(0, count - 1) * Self.commandRowSpacing + Self.resultsVerticalPadding
    }

    /// The same page can surface as several history visits plus an open tab;
    /// Arc shows it once. Tab rows and navigations collapse on their target,
}
