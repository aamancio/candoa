import SwiftUI

struct HistoryView: View {
    @StateObject private var store: HistoryStore
    let spaces: [BrowserSpace]
    let onOpen: (HistoryVisit) -> Void
    let onDismiss: () -> Void

    @State private var pendingClearRange: HistoryClearRange?

    init(
        repository: any HistoryRepository,
        spaces: [BrowserSpace],
        onOpen: @escaping (HistoryVisit) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: HistoryStore(repository: repository))
        self.spaces = spaces
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            historyContent
                .navigationTitle("History")
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search History")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDismiss)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        manageHistoryMenu
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 500, idealHeight: 620)
        .task {
            store.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: PersistenceService.remoteStoreDidChange)) { _ in
            store.reload()
        }
        .onDeleteCommand {
            store.deleteSelection()
        }
        .confirmationDialog(
            pendingClearRange.map { "Clear \($0.title)?" } ?? "Clear History?",
            isPresented: Binding(
                get: { pendingClearRange != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingClearRange = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pendingClearRange {
                Button("Clear \(pendingClearRange.title)", role: .destructive) {
                    store.clear(pendingClearRange)
                    self.pendingClearRange = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingClearRange = nil
            }
        } message: {
            Text("This removes the selected browsing history from Candoa and cannot be undone.")
        }
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

    @ViewBuilder
    private var historyContent: some View {
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
        } else {
            List(selection: $store.selection) {
                ForEach(historySections) { section in
                    Section(section.title) {
                        ForEach(section.visits) { visit in
                            HistoryVisitRow(
                                visit: visit,
                                spaceName: spaceName(for: visit.spaceID)
                            )
                            .tag(visit.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                onOpen(visit)
                            }
                            .contextMenu {
                                Button("Open") {
                                    onOpen(visit)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    store.delete(visit)
                                }
                            }
                            .accessibilityAction(named: "Open") {
                                onOpen(visit)
                            }
                        }
                    }
                }

                if store.canLoadMore {
                    Button("Load More") {
                        store.loadMore()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(store.isLoading)
                }

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
        }
    }

    private var spacePicker: some View {
        Picker("Space", selection: $store.selectedSpaceID) {
            Text("All Spaces").tag(Optional<UUID>.none)
            Divider()
            ForEach(spaces) { space in
                Text(displayName(for: space)).tag(Optional(space.id))
            }
        }
        .pickerStyle(.menu)
        .help("Filter history by Space")
    }

    private var manageHistoryMenu: some View {
        Menu {
            spacePicker

            Divider()

            Button("Delete Selected", role: .destructive) {
                store.deleteSelection()
            }
            .disabled(store.selection.isEmpty)

            Divider()

            Menu("Clear History") {
                ForEach(HistoryClearRange.allCases) { range in
                    Button(range.title) {
                        pendingClearRange = range
                    }
                }
            }
        } label: {
            Label("Manage", systemImage: "ellipsis.circle")
        }
        .disabled(store.isLoading)
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

    private func sectionTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    private func spaceName(for id: UUID) -> String? {
        spaces.first(where: { $0.id == id }).map(displayName)
    }

    private func displayName(for space: BrowserSpace) -> String {
        let trimmedName = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Space" : trimmedName
    }
}

private struct HistorySection: Identifiable {
    let date: Date
    let title: String
    let visits: [HistoryVisit]

    var id: Date { date }
}

private struct HistoryVisitRow: View {
    let visit: HistoryVisit
    let spaceName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(visit.title)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(visit.url.host(percentEncoded: false) ?? visit.url.absoluteString)
                        .lineLimit(1)
                    if let spaceName {
                        Text("·")
                        Text(spaceName)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Text(visit.visitedAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(visit.title), \(visit.url.host(percentEncoded: false) ?? visit.url.absoluteString)")
        .accessibilityValue(visit.visitedAt.formatted(date: .abbreviated, time: .shortened))
    }
}
