import AppKit
import SwiftUI

extension Notification.Name {
    static let focusHistorySearch = Notification.Name("Candoa.FocusHistorySearch")
}

struct HistoryView: View {
    @StateObject private var store: HistoryStore
    let onOpen: (HistoryVisit) -> Void
    let onOpenInNewTab: (HistoryVisit) -> Void
    let onCopyAddress: (HistoryVisit) -> Void
    let onDismiss: () -> Void

    @State private var tableSelection: Set<HistoryTableNode.ID> = []
    @State private var expandedDates: Set<Date> = []
    @State private var isSearchFocused = false

    init(
        repository: any HistoryRepository,
        spaceID: UUID,
        onOpen: @escaping (HistoryVisit) -> Void,
        onOpenInNewTab: @escaping (HistoryVisit) -> Void,
        onCopyAddress: @escaping (HistoryVisit) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: HistoryStore(repository: repository, spaceID: spaceID))
        self.onOpen = onOpen
        self.onOpenInNewTab = onOpenInNewTab
        self.onCopyAddress = onCopyAddress
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            historyHeader

            if store.visits.isEmpty, !store.isLoading {
                ContentUnavailableView {
                    Label(
                        store.searchText.isEmpty ? "No History" : "No Results",
                        systemImage: store.searchText.isEmpty ? "clock" : "magnifyingglass"
                    )
                } description: {
                    Text(
                        store.searchText.isEmpty
                            ? "Pages you visit will appear here."
                            : "No history matches your search."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyOutline
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            expandedDates = [Calendar.current.startOfDay(for: Date())]
            store.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: PersistenceService.remoteStoreDidChange)) { _ in
            store.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusHistorySearch)) { _ in
            isSearchFocused = true
        }
        .onChange(of: tableSelection) { _, selection in
            store.selection = Set(selection.compactMap(\.visitID))
        }
        .onChange(of: store.selection) { _, selection in
            let visitSelection = Set(selection.map(HistoryTableNode.ID.visit))
            if tableSelection != visitSelection {
                tableSelection = visitSelection
            }
        }
        .onDeleteCommand {
            store.deleteSelection()
        }
        .onExitCommand(perform: onDismiss)
        .alert(
            "History Couldn’t Be Updated",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .accessibilityIdentifier("history-view")
    }

    private var historyHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("History")
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer(minLength: 24)

            Button("Clear History…") {
                presentClearHistoryAlert()
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .disabled(store.isLoading || !store.hasHistory)

            HistorySearchField(
                text: $store.searchText,
                isFocused: $isSearchFocused
            )
                .frame(width: 180)
                .accessibilityLabel("Search History")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var historyOutline: some View {
        VStack(spacing: 0) {
            Table(of: HistoryTableNode.self, selection: $tableSelection) {
                TableColumn("Website") { node in
                    websiteCell(for: node)
                }
                .width(min: 260, ideal: 560)

                TableColumn("Address") { node in
                    addressCell(for: node)
                }
                .width(min: 240, ideal: 760)
            } rows: {
                if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(historySections) { section in
                        DisclosureTableRow(
                            HistoryTableNode(section: section),
                            isExpanded: expansionBinding(for: section.date)
                        ) {
                            ForEach(section.visits.map(HistoryTableNode.init(visit:))) { node in
                                TableRow(node)
                            }
                        }
                    }
                } else {
                    ForEach(store.visits.map(HistoryTableNode.init(visit:))) { node in
                        TableRow(node)
                    }
                }
            }
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: HistoryTableNode.ID.self) { selection in
                historyContextMenu(for: selection)
            } primaryAction: { selection in
                guard let visit = selectedVisits(for: selection).first else { return }
                onOpen(visit)
            }

            if store.canLoadMore || store.isLoading {
                HStack {
                    Spacer()
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Load More") {
                            store.loadMore()
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func websiteCell(for node: HistoryTableNode) -> some View {
        switch node.content {
        case .day(_, let title, _):
            Label(title, systemImage: "clock")
                .fontWeight(.semibold)
        case .visit(let visit):
            Label(visit.title, systemImage: "globe")
                .lineLimit(1)
                .accessibilityLabel("\(visit.title), \(visit.url.absoluteString)")
                .accessibilityValue(visit.visitedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    @ViewBuilder
    private func addressCell(for node: HistoryTableNode) -> some View {
        switch node.content {
        case .day(_, _, let count):
            Text(count == 1 ? "1 item" : "\(count) items")
        case .visit(let visit):
            Text(visit.url.absoluteString)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func historyContextMenu(for selection: Set<HistoryTableNode.ID>) -> some View {
        let visits = selectedVisits(for: selection)

        if let visit = visits.first {
            Button("Open") {
                onOpen(visit)
            }
            Button("Open in New Tab") {
                onOpenInNewTab(visit)
            }
            Button("Copy Address") {
                onCopyAddress(visit)
            }
            Divider()
        }

        Button(visits.count == 1 ? "Delete" : "Delete \(visits.count) Items", role: .destructive) {
            store.selection = Set(visits.map(\.id))
            store.deleteSelection()
        }
        .disabled(visits.isEmpty)
    }

    private var historySections: [HistorySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.visits) { visit in
            calendar.startOfDay(for: visit.visitedAt)
        }

        return grouped.keys.sorted(by: >).map { date in
            HistorySection(
                date: date,
                title: sectionTitle(for: date, calendar: calendar),
                visits: grouped[date] ?? []
            )
        }
    }

    private func expansionBinding(for date: Date) -> Binding<Bool> {
        Binding(
            get: { expandedDates.contains(date) },
            set: { isExpanded in
                if isExpanded {
                    expandedDates.insert(date)
                } else {
                    expandedDates.remove(date)
                }
            }
        )
    }

    private func selectedVisits(for selection: Set<HistoryTableNode.ID>) -> [HistoryVisit] {
        let selectedIDs = Set(selection.compactMap(\.visitID))
        return store.visits.filter { selectedIDs.contains($0.id) }
    }

    private func sectionTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Last Visited Today"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    private func presentClearHistoryAlert() {
        let ranges = HistoryClearRange.allCases
        let rangePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 210, height: 26), pullsDown: false)
        rangePicker.addItems(withTitles: ranges.map(\.title))
        rangePicker.selectItem(at: 0)

        let clearLabel = NSTextField(labelWithString: "Clear")
        let accessory = NSStackView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 26)
        )
        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 8
        accessory.addArrangedSubview(clearLabel)
        accessory.addArrangedSubview(rangePicker)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "Clearing history will remove visited pages from this Space."
        alert.informativeText = "History in other Spaces will not be affected. This action cannot be undone."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let selectedIndex = max(rangePicker.indexOfSelectedItem, 0)
            store.clear(ranges[selectedIndex])
        }

        if let window = NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

}

private struct HistorySection: Identifiable {
    let date: Date
    let title: String
    let visits: [HistoryVisit]

    var id: Date { date }
}

private struct HistoryTableNode: Identifiable {
    enum ID: Hashable {
        case day(Date)
        case visit(UUID)

        var visitID: UUID? {
            guard case .visit(let id) = self else { return nil }
            return id
        }
    }

    enum Content {
        case day(Date, String, Int)
        case visit(HistoryVisit)
    }

    let id: ID
    let content: Content
    init(section: HistorySection) {
        id = .day(section.date)
        content = .day(section.date, section.title, section.visits.count)
    }

    init(visit: HistoryVisit) {
        id = .visit(visit.id)
        content = .visit(visit)
    }
}

private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        guard isFocused, searchField.window?.firstResponder !== searchField.currentEditor() else {
            return
        }

        DispatchQueue.main.async {
            searchField.window?.makeFirstResponder(searchField)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text = searchField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused = false
        }
    }
}
