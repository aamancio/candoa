import AppKit
import SwiftUI

struct TabSwitcherOverlay: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        if !store.tabSwitcherTabs.isEmpty {
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
                // Opacity only — a scale-in reads as motion the user has to
                // wait out, which made Control-Tab feel slower than the
                // instant switch underneath it.
                .transition(.opacity)
        }
    }

    private var panel: some View {
        GeometryReader { proxy in
            let layout = gridLayout(for: proxy.size.width)

            ZStack {
                VStack(alignment: .trailing, spacing: 8) {
                    Group {
                        if store.tabSwitcherTabs.count <= layout.columns.count {
                            HStack(spacing: TabSwitcherMetrics.columnSpacing) {
                                previewCards(for: store.tabSwitcherTabs, cardWidth: layout.cardWidth)
                            }
                        } else {
                            LazyVGrid(columns: layout.columns, alignment: .leading, spacing: TabSwitcherMetrics.rowSpacing) {
                                previewCards(for: store.tabSwitcherTabs, cardWidth: layout.cardWidth)
                            }
                        }
                    }
                    .frame(width: layout.contentWidth, alignment: .leading)
                    // Delete: the closed card shrinks away in place, its
                    // neighbors slide over, and the backfilled tab arrives
                    // from the tail — so the queue visibly moves up rather
                    // than a card being swapped.
                    .animation(.easeOut(duration: 0.15), value: store.tabSwitcherTabs.map(\.id))

                    if store.tabSwitcherTabCount > store.tabSwitcherTabs.count {
                        // Once the strip backfills, its length can no longer
                        // show that Delete really closed something; the count
                        // ticking down does.
                        Text("\(store.tabSwitcherTabCount) tabs")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.easeOut(duration: 0.15), value: store.tabSwitcherTabCount)
                            .accessibilityIdentifier("tab-switcher-count")
                    }
                }
                .padding(TabSwitcherMetrics.panelPadding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(InterfaceStyle.popoverBorder, lineWidth: 1)
                }
                .shadow(color: Color(nsColor: .shadowColor).opacity(0.24), radius: 26, y: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func previewCards(for tabs: [BrowserTab], cardWidth: CGFloat) -> some View {
        ForEach(tabs) { tab in
            TabSwitcherPreviewCard(
                tab: tab,
                snapshot: store.tabSwitcherSnapshots[tab.id],
                isSelected: tab.id == store.tabSwitcherSelectedTabID,
                cardWidth: cardWidth
            )
            .transition(
                .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.8).combined(with: .opacity)
                )
            )
        }
    }

    private func gridLayout(for availableWidth: CGFloat) -> TabSwitcherGridLayout {
        let tabCount = max(store.tabSwitcherTabs.count, 1)
        let oneRowCardWidth = availableCardWidth(
            availableWidth: availableWidth,
            columns: tabCount
        )
        let columnCount = oneRowCardWidth >= TabSwitcherMetrics.minimumCardWidth
            ? tabCount
            : min(tabCount, TabSwitcherMetrics.compactColumnLimit)
        let cardWidth = min(
            TabSwitcherMetrics.maximumCardWidth,
            max(
                TabSwitcherMetrics.minimumCardWidth,
                availableCardWidth(availableWidth: availableWidth, columns: columnCount)
            )
        )

        return TabSwitcherGridLayout(
            cardWidth: cardWidth,
            columns: Array(
                repeating: GridItem(.fixed(cardWidth), spacing: TabSwitcherMetrics.columnSpacing),
                count: columnCount
            )
        )
    }

    private func availableCardWidth(availableWidth: CGFloat, columns: Int) -> CGFloat {
        let horizontalPadding = TabSwitcherMetrics.panelPadding * 2
        let interItemSpacing = TabSwitcherMetrics.columnSpacing * CGFloat(max(columns - 1, 0))
        let windowMargin = TabSwitcherMetrics.windowEdgeMargin * 2
        return (availableWidth - horizontalPadding - interItemSpacing - windowMargin) / CGFloat(columns)
    }

}

private struct TabSwitcherGridLayout {
    let cardWidth: CGFloat
    let columns: [GridItem]

    var contentWidth: CGFloat {
        cardWidth * CGFloat(columns.count)
            + TabSwitcherMetrics.columnSpacing * CGFloat(max(columns.count - 1, 0))
    }
}

private enum TabSwitcherMetrics {
    // A four-tab switcher is the common case. Give it enough visual weight to
    // read as a window switcher rather than a compact menu. Six cards fit one
    // row down to ~870pt of window; narrower than that the grid folds to two
    // rows of three rather than five-plus-one.
    static let minimumCardWidth: CGFloat = 124
    static let maximumCardWidth: CGFloat = 200
    static let compactColumnLimit = 3
    static let columnSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 12
    static let panelPadding: CGFloat = 16
    static let windowEdgeMargin: CGFloat = 20
    static let previewAspectRatio: CGFloat = 0.62
}

private struct TabSwitcherPreviewCard: View {
    let tab: BrowserTab
    let snapshot: NSImage?
    let isSelected: Bool
    let cardWidth: CGFloat

    private var previewHeight: CGFloat {
        max(66, cardWidth * TabSwitcherMetrics.previewAspectRatio)
    }

    private var contentWidth: CGFloat {
        max(1, cardWidth - 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview

            HStack(spacing: 6) {
                favicon

                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(8)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? AppColor.accent.opacity(0.20) : InterfaceStyle.surfaceFill.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? AppColor.accent.opacity(0.92) : InterfaceStyle.surfaceBorder.opacity(0.72),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var preview: some View {
        let windowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return ZStack {
            if let snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                fallbackPreview
            }
        }
        .frame(width: contentWidth, height: previewHeight)
        .clipShape(windowShape)
        .overlay {
            windowShape.stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
        }
    }

    private var fallbackPreview: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 7) {
                favicon
                    .font(.system(size: 20))

                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 100)
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private var favicon: some View {
        if let data = tab.faviconData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: tab.faviconSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}
