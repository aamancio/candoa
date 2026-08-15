import AppKit
import SwiftUI
import UniformTypeIdentifiers

internal struct ImportOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @State private var selectedSource: BrowserImportSource = .safari
    @State private var isProfileFolderImporterPresented = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        OnboardingSurface(step: .importData) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "arrow.down.doc",
                    title: String(localized: "Start with what matters"),
                    detail: String(localized: "Bring your bookmarks from Safari, Chrome, Arc, or Firefox so your essential sites are ready on day one.")
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Import from:")
                        .font(.system(size: 13, weight: .medium))

                    Picker("Import from:", selection: $selectedSource) {
                        ForEach(BrowserImportSource.allCases) { source in
                            Label {
                                Text(source.name)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            } icon: {
                                Image(nsImage: applicationIcon(for: source))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                            }
                            .tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .controlSize(.small)
                    .accessibilityIdentifier("migration-browser-picker")
                }

                Spacer(minLength: 16)

                Button {
                    importFromSelectedBrowser()
                } label: {
                    HStack(spacing: 8) {
                        if isImporting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing from \(selectedSource.name)…")
                        } else {
                            Label("Import from \(selectedSource.name)…", systemImage: "doc.badge.plus")
                        }
                    }
                        .frame(maxWidth: .infinity)
                }
                .buttonTreatment(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting)
                .accessibilityIdentifier("onboarding-import-bookmarks")

                Button(String(localized: "Skip")) {
                    store.completeInitialImport()
                }
                .buttonTreatment(.quiet)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        } preview: {
            OnboardingImportPreview()
        }
        .fileImporter(
            isPresented: $isProfileFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleProfileFolderSelection
        )
        .fileDialogDefaultDirectory(selectedSource.suggestedProfileFolderURL)
        .alert("Couldn’t Import Bookmarks", isPresented: errorIsPresented) {
            Button("Choose Profile…") {
                isProfileFolderImporterPresented = true
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? String(localized: "Candoa couldn’t access \(selectedSource.name)’s default profile. You can choose another profile manually."))
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func applicationIcon(for source: BrowserImportSource) -> NSImage {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: source.bundleIdentifier
        ) else {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: source.name) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private func handleProfileFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let folderURL = urls.first else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return
        }

        runImport {
            try await store.importInitialBookmarks(
                fromProfileFolder: folderURL,
                source: selectedSource
            )
        }
    }

    private func importFromSelectedBrowser() {
        if !store.canImportAutomatically(from: selectedSource) {
            isProfileFolderImporterPresented = true
            return
        }
        runImport {
            try await store.importInitialBookmarks(from: selectedSource)
        }
    }

    private func runImport(_ operation: @escaping @MainActor () async throws -> Int) {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let minimumFeedbackDuration: Duration = .milliseconds(900)
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let count = try await operation()
                let elapsed = startedAt.duration(to: clock.now)
                if elapsed < minimumFeedbackDuration {
                    try? await Task.sleep(for: minimumFeedbackDuration - elapsed)
                }
                announceImportedBookmarks(count)
                store.completeInitialImport()
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func announceImportedBookmarks(_ count: Int) {
        let message = String(localized: "Imported \(count) bookmarks.")
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}

private struct OnboardingImportPreview: View {
    private struct BrowserSource: Identifiable {
        let name: String
        let bundleIdentifier: String

        var id: String { bundleIdentifier }

        var icon: NSImage {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return NSImage(systemSymbolName: "globe", accessibilityDescription: name) ?? NSImage()
            }
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
    }

    private let browsers = [
        BrowserSource(name: "Safari", bundleIdentifier: "com.apple.Safari"),
        BrowserSource(name: "Chrome", bundleIdentifier: "com.google.Chrome"),
        BrowserSource(name: "Arc", bundleIdentifier: "company.thebrowser.Browser"),
        BrowserSource(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Text("Your go-to sites")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(browsers) { browser in
                        HStack(spacing: 7) {
                            Image(nsImage: browser.icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)

                            Text(browser.name)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(.background.opacity(0.54), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            Image(systemName: "arrow.down")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)

                Label("Bookmarks ready in Candoa", systemImage: "bookmark.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
            }
        }
    }
}
