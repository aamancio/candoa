import AppKit
import UniformTypeIdentifiers

// File menu document workflows: open a chosen local file in a tab, save the
// active page as a web archive, export it as a PDF. Access always flows
// through the user's explicit panel choice (or the UI-testing bypass);
// nothing retains security-scoped bookmarks or page snapshots afterward.
extension BrowserStore {
    private static let openableLocalFileTypes: [UTType] = [
        .html, .webArchive, .plainText, .image, .pdf,
    ]

    func openLocalFileViaPanel() {
        // NSOpenPanel runs out of process and the sandboxed test runner
        // cannot create files, so the seam writes its own fixture and opens
        // it as if the person had chosen it.
        if Self.isUITesting,
           ProcessInfo.processInfo
               .environment["CANDOA_UI_TESTING_OPEN_FILE_FIXTURE"] == "1" {
            let fixtureURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("candoa-e2e-local-page.html")
            let fixtureHTML = """
            <!doctype html><meta charset="utf-8"><title>Local Fixture File</title>
            <h1 style="font-size:60px">Local file content</h1>
            """
            try? fixtureHTML.write(to: fixtureURL, atomically: true, encoding: .utf8)
            openLocalFile(fixtureURL)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openableLocalFileTypes
        presentPanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openLocalFile(url)
        }
    }

    private func openLocalFile(_ url: URL) {
        _ = newTab(url: url)
    }

    func saveActiveTabAsWebArchive() {
        exportActiveTab(as: .webArchive, pathExtension: "webarchive") {
            [weak self] tabID, completion in
            self?.webCoordinator.createWebArchiveData(for: tabID, completion: completion)
        }
    }

    func exportActiveTabAsPDF() {
        exportActiveTab(as: .pdf, pathExtension: "pdf") { [weak self] tabID, completion in
            self?.webCoordinator.createPDFData(for: tabID, completion: completion)
        }
    }

    private func exportActiveTab(
        as contentType: UTType,
        pathExtension: String,
        produce: @escaping (UUID, @escaping @MainActor (Result<Data, any Error>) -> Void) -> Void
    ) {
        guard canPrintActiveTab, let tab = activeTab, let url = tab.url else { return }
        let suggestedName = Self.exportFileName(for: tab.title, url: url)
            .appending(".")
            .appending(pathExtension)

        chooseExportDestination(
            suggestedName: suggestedName,
            contentType: contentType
        ) { [weak self] destination in
            guard let self, let destination else { return }
            // The completion is @MainActor by type, so no re-dispatch hop.
            produce(tab.id) { [weak self] result in
                self?.finishExport(of: result, to: destination)
            }
        }
    }

    private func finishExport(of result: Result<Data, any Error>, to destination: URL) {
        do {
            try result.get().write(to: destination, options: .atomic)
            downloadsStore.recordCompletedSave(at: destination)
            presentCopiedURLToast(title: String(localized: "Saved"), url: destination)
        } catch {
            downloadsStore.recordFailedSave(
                filename: destination.lastPathComponent,
                reason: error.localizedDescription
            )
            NSSound.beep()
        }
    }

    /// The save panel grants write access to exactly the chosen destination;
    /// the grant is not persisted. Overwrite confirmation is the panel's own.
    private func chooseExportDestination(
        suggestedName: String,
        contentType: UTType,
        completion: @escaping (URL?) -> Void
    ) {
        if Self.isUITesting,
           ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_EXPORT_TO_DOWNLOADS"] == "1" {
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first
            completion(downloads?.appendingPathComponent(suggestedName))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        presentPanel(panel) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    private func presentPanel(
        _ panel: NSSavePanel,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private static func exportFileName(for title: String, url: URL) -> String {
        let trimmedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return url.host(percentEncoded: false)?
            .replacingOccurrences(of: ":", with: "-") ?? "Page"
    }
}
