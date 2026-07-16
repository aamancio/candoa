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

                if let headerSearchProvider, !isSidebarAddressPalette {
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
            .padding(.horizontal, isSidebarAddressPalette ? 18 : 16)
            .padding(.vertical, paletteHeaderVerticalPadding)

            Rectangle()
                .fill(CandoaChromeStyle.popoverBorder)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 7) {
                    ForEach(Array(visibleCommands.enumerated()), id: \.element.id) { index, command in
                        Button {
                            run(command)
                        } label: {
                            PaletteCommandRow(
                                command: command,
                                isSelected: index == selectedCommandIndex,
                                selectedTint: activeTint
                            )
                        }
                        .buttonStyle(.plain)
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
                .strokeBorder(
                    isSearchFocused ? CandoaColor.focusRing : CandoaChromeStyle.popoverBorder,
                    lineWidth: isSearchFocused ? 1.25 : 1
                )
        }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.24), radius: 46, y: 24)
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

    internal func paletteWidth(for windowWidth: CGFloat) -> CGFloat {
        if isSidebarAddressPalette {
            return min(max(0, windowWidth - Self.addressPaletteLeadingInset * 2), Self.addressPaletteMaxWidth)
        }

        // Zen's floating urlbar width: min(window width / 1.5, 750)
        // (ZenUIManager.updateTabsToolbar's --zen-urlbar-width).
        return min(windowWidth / 1.5, 750)
    }

    internal func palettePosition(in windowSize: CGSize, width: CGFloat) -> CGPoint {
        if isSidebarAddressPalette {
            return CGPoint(
                x: Self.addressPaletteLeadingInset + width / 2,
                y: Self.addressPaletteTopInset + anchoredPaletteHeight / 2
            )
        }

        return CGPoint(x: windowSize.width / 2, y: windowSize.height / 2)
    }

    internal var headerIconSearchProvider: SearchProvider? {
        // Once the typed address resolves to a known provider, its icon must
        // describe the destination rather than the tab that happened to be
        // active when editing began.
        headerSearchProvider ?? (isAddressEditingPalette ? provider(for: store.activeTab?.url) : nil)
    }

    internal var headerFaviconData: Data? {
        headerSearchProvider == nil && isAddressEditingPalette ? store.activeTab?.faviconData : nil
    }

    internal var usesCircularHeaderFavicon: Bool {
        headerSearchProvider == nil && isAddressEditingPalette && !isSidebarAddressPalette
    }

    /// Exact height of the visible rows (46pt rows, 7pt spacing, 11pt
    /// vertical padding), so the results area hugs its content.
    internal var resultsHeight: CGFloat {
        resultsHeight(for: CGFloat(visibleCommands.count))
    }

    /// The palette itself shrinks with its result count, but it sits inside
    /// this fixed-height anchor so typing does not recenter the surface.
    internal var anchoredPaletteHeight: CGFloat {
        if isSidebarAddressPalette {
            return Self.addressPaletteHeight
        }

        return Self.normalHeaderHeight + Self.dividerHeight + resultsHeight(for: CGFloat(Self.maxVisibleCommandCount))
    }

    internal var paletteHeaderHeight: CGFloat {
        isSidebarAddressPalette ? Self.addressHeaderHeight : Self.normalHeaderHeight
    }

    internal var paletteHeaderVerticalPadding: CGFloat {
        max(0, (paletteHeaderHeight - 30) / 2)
    }

    internal var resultsAreaHeight: CGFloat {
        if isSidebarAddressPalette {
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
