import AppKit
import SwiftUI
import WebKit

/// Safari's Settings > Privacy > Manage Website Data… sheet: every site with
/// stored data, searchable, removable one at a time or all at once. The
/// per-site remove is the cure for a single site wedged by a stale session
/// cookie — clearing just that site signs the user out nowhere else.
struct ManageWebsiteDataSheet: View {
    let onDone: () -> Void

    @State private var entries: [WebsiteDataInventory.WebsiteDataEntry] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selection = Set<String>()
    @State private var isConfirmingRemoveAll = false

    private var filteredEntries: [WebsiteDataInventory.WebsiteDataEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("These websites have stored data that can be used to track your browsing:")
                    .font(.system(size: 13, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 16)

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .accessibilityIdentifier("manage-website-data-search")
            }

            List(selection: $selection) {
                ForEach(filteredEntries) { entry in
                    WebsiteDataRow(entry: entry)
                        .tag(entry.id)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 240)
            .overlay {
                if isLoading {
                    ProgressView()
                } else if entries.isEmpty {
                    Text("No Website Data")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("manage-website-data-list")

            Text("Removing the data may reduce tracking, but may also log you out of websites or change website behavior.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Remove") {
                    removeSelection()
                }
                .buttonTreatment(.secondary)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("manage-website-data-remove")

                Button("Remove All") {
                    isConfirmingRemoveAll = true
                }
                .buttonTreatment(.secondary)
                .disabled(entries.isEmpty)
                .accessibilityIdentifier("manage-website-data-remove-all")

                Spacer(minLength: 0)

                Button("Done", action: onDone)
                    .buttonTreatment(.primary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("manage-website-data-done")
            }
        }
        .padding(20)
        .frame(width: 500, alignment: .leading)
        .background {
            // Sheets close on Escape through the cancel action; Return is
            // taken by Done, so the binding rides an invisible button.
            Button(action: onDone) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .alert(
            Text("Are you sure you want to remove all data stored by websites on your computer?"),
            isPresented: $isConfirmingRemoveAll
        ) {
            Button("Remove Now", role: .destructive) {
                removeAll()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            entries = await WebsiteDataInventory.fetchEntries()
            isLoading = false
        }
    }

    private func removeSelection() {
        let removed = entries.filter { selection.contains($0.id) }
        entries.removeAll { selection.contains($0.id) }
        selection.removeAll()
        Task {
            await WebsiteDataInventory.remove(removed)
        }
    }

    private func removeAll() {
        let removed = entries
        entries.removeAll()
        selection.removeAll()
        Task {
            await WebsiteDataInventory.remove(removed)
        }
    }
}

private struct WebsiteDataRow: View {
    let entry: WebsiteDataInventory.WebsiteDataEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
                .font(.system(size: 13))

            Text(WebsiteDataInventory.typeSummary(for: entry.dataTypes))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Presents the sheet on the Settings window (or whichever window is key),
/// the same way the Clear History prompt drops in.
@MainActor
enum ManageWebsiteDataPrompt {
    static func present() {
        let host = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first { $0.isVisible && $0.canBecomeKey }
        guard let host else { return }

        var controller: NSViewController?
        let dismiss: () -> Void = {
            guard let sheet = controller?.view.window else { return }
            host.endSheet(sheet)
        }

        let hosting = NSHostingController(rootView: ManageWebsiteDataSheet(onDone: dismiss))
        hosting.view.layoutSubtreeIfNeeded()
        controller = hosting

        // A plain window drops from the title bar as a sheet rather than
        // opening as a panel of its own.
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        host.beginSheet(window)
    }
}
