import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InitialOnboardingCanvas: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        switch store.initialOnboardingStep {
        case .welcome:
            WelcomeOnboardingStep(store: store)
        case .account:
            AccountOnboardingStep(store: store)
        case .importData:
            ImportOnboardingStep(store: store)
        case .space:
            SpaceOnboardingStep(store: store)
        case .tour, .none:
            EmptyView()
        }
    }
}

extension InitialTourTip {
    var symbolName: String {
        switch self {
        case .commandBar: "command"
        case .spaces: "square.stack.3d.up"
        case .ask: "sparkles"
        }
    }

    var title: String {
        switch self {
        case .commandBar: String(localized: "Find anything quickly")
        case .spaces: String(localized: "Keep contexts separate")
        case .ask: String(localized: "Understand any page")
        }
    }

    var detail: String {
        switch self {
        case .commandBar:
            String(localized: "Press Command-T to search the web, open a site, or jump to an existing tab.")
        case .spaces:
            String(localized: "Spaces separate work, projects, research, and personal browsing without losing your tabs.")
        case .ask:
            String(localized: "Press Command-E to open Eli and summarize, explain, compare, or identify next steps without leaving the page.")
        }
    }

    var shortcut: String {
        switch self {
        case .commandBar: "⌘T"
        case .spaces: "⌃1–9"
        case .ask: "⌘E"
        }
    }

    var accessibilityShortcutLabel: String {
        switch self {
        case .commandBar: String(localized: "Keyboard shortcut: Command-T")
        case .spaces: String(localized: "Keyboard shortcut: Control-1 through 9")
        case .ask: String(localized: "Keyboard shortcut: Command-E")
        }
    }

    var identifier: String {
        switch self {
        case .commandBar: "command-bar"
        case .spaces: "spaces"
        case .ask: "ask"
        }
    }
}

private struct InitialTourPopover: View {
    @ObservedObject var store: BrowserStore
    let tip: InitialTourTip

    private var isFirstTip: Bool { tip == InitialTourTip.allCases.first }
    private var isLastTip: Bool { tip == InitialTourTip.allCases.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: tip.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CandoaInterfaceStyle.decorativeSymbol)
                    .frame(width: 28, height: 28)

                Text(tip.title)
                    .font(.headline)

                Spacer(minLength: 8)

                Text(tip.shortcut)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(tip.accessibilityShortcutLabel))
            }

            Text(tip.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(String(localized: "Skip Tour")) {
                    store.completeInitialTour()
                }
                .candoaButton(.quiet)

                Spacer()

                if !isFirstTip {
                    Button(String(localized: "Back")) {
                        store.showPreviousInitialTourTip()
                    }
                    .candoaButton(.secondary)
                }

                Button(isLastTip ? String(localized: "Done") : String(localized: "Next")) {
                    store.showNextInitialTourTip()
                }
                .candoaButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tip.title))
        .accessibilityIdentifier("initial-tour-\(tip.identifier)")
    }
}

private struct InitialTourPopoverModifier: ViewModifier {
    @ObservedObject var store: BrowserStore
    let tip: InitialTourTip
    let arrowEdge: Edge

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { store.initialTourTip == tip },
                set: { isPresented in
                    if !isPresented, store.initialTourTip == tip {
                        store.completeInitialTour()
                    }
                }
            ),
            arrowEdge: arrowEdge
        ) {
            InitialTourPopover(store: store, tip: tip)
        }
    }
}

extension View {
    func initialTourPopover(
        _ tip: InitialTourTip,
        store: BrowserStore,
        arrowEdge: Edge
    ) -> some View {
        modifier(InitialTourPopoverModifier(store: store, tip: tip, arrowEdge: arrowEdge))
    }
}

struct WelcomeToCandoaPage: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealsContent = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)

                        Text(String(localized: "Welcome to Candoa"))
                            .font(.system(size: 30, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)

                        Text(String(localized: "Your browser is ready. Here are three essentials to help you get started."))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        welcomeFeature(
                            title: String(localized: "Find anything quickly"),
                            detail: String(localized: "Search, open a site, or jump to a tab with Command-T."),
                            symbolName: "command"
                        )
                        welcomeFeature(
                            title: String(localized: "Keep contexts separate"),
                            detail: String(localized: "Use Spaces for work, projects, research, and personal browsing."),
                            symbolName: "square.stack.3d.up"
                        )
                        welcomeFeature(
                            title: String(localized: "Understand any page"),
                            detail: String(localized: "Open Eli with Command-E without changing apps."),
                            symbolName: "sparkles"
                        )
                    }
                }
                .padding(48)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .opacity(revealsContent ? 1 : 0)
                .offset(y: reduceMotion || revealsContent ? 0 : 8)
            }
        }
        .background(CandoaInterfaceStyle.surfaceFill.opacity(0.72))
        .accessibilityIdentifier("welcome-to-candoa-page")
        .onAppear {
            guard !revealsContent else { return }

            if reduceMotion {
                revealsContent = true
                store.startInitialTour()
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    revealsContent = true
                } completion: {
                    store.startInitialTour()
                }
            }
        }
    }

    private func welcomeFeature(
        title: String,
        detail: String,
        symbolName: String
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(CandoaInterfaceStyle.decorativeSymbol)

                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WelcomeOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealsFirstLine = false
    @State private var revealsSecondLine = false
    @State private var revealsAction = false

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("Your browser, organized")
                    .opacity(revealsFirstLine ? 1 : 0)
                    .offset(y: revealsFirstLine ? 0 : 12)

                Text("around your life.")
                    .foregroundStyle(.secondary)
                    .opacity(revealsSecondLine ? 1 : 0)
                    .offset(y: revealsSecondLine ? 0 : 12)
            }
            .font(.system(size: 58, weight: .semibold))
            .tracking(-1.6)
            .multilineTextAlignment(.center)

            VStack {
                Spacer()

                Button {
                    store.completeInitialWelcome()
                } label: {
                    Label("Begin Setup", systemImage: "arrow.right")
                        .frame(minWidth: 116)
                }
                .candoaButton(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .opacity(revealsAction ? 1 : 0)
                .offset(y: revealsAction ? 0 : 8)
                .accessibilityIdentifier("onboarding-get-started")
                .padding(.bottom, 62)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CandoaInterfaceStyle.surfaceFill)
        .accessibilityIdentifier("initial-onboarding-welcome")
        .task {
            guard !revealsAction else { return }
            if reduceMotion {
                revealsFirstLine = true
                revealsSecondLine = true
                revealsAction = true
                return
            }

            withAnimation(.easeOut(duration: 0.20)) {
                revealsFirstLine = true
            }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                revealsSecondLine = true
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                revealsAction = true
            }
        }
    }
}

private struct AccountOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @EnvironmentObject private var userStore: UserStore

    var body: some View {
        AccountOnboardingSurface(onBack: store.goBackInInitialOnboarding) {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(CandoaInterfaceStyle.decorativeSymbol)

                VStack(spacing: 10) {
                    Text("Keep your account with you")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.4)
                        .multilineTextAlignment(.center)

                    Text("Create a passkey to use your Candoa account on your other devices. No password or email required.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    userStore.createPasskey()
                } label: {
                    if userStore.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create a Passkey")
                    }
                }
                .candoaButton(.primary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
                .disabled(userStore.isWorking)
                .accessibilityIdentifier("onboarding-create-passkey")

                HStack(spacing: 16) {
                    Button("Sign In") {
                        userStore.signInWithPasskey()
                    }
                    .candoaButton(.secondary)
                    .controlSize(.large)
                    .tint(Color(nsColor: .secondaryLabelColor))
                    .disabled(userStore.isWorking)
                    .accessibilityIdentifier("onboarding-sign-in-passkey")

                    Button("Not Now") {
                        userStore.continueOnThisMac()
                    }
                    .candoaButton(.quiet)
                    .controlSize(.large)
                    .disabled(userStore.isWorking)
                    .accessibilityIdentifier("onboarding-not-now")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage = userStore.errorMessage, !userStore.isWorking {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(CandoaColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("You can skip this and add a passkey later in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 310)
        }
        .onChange(of: userStore.hasCompletedAccountChoice) { _, hasCompletedAccountChoice in
            if hasCompletedAccountChoice {
                store.completeInitialAccountSetup()
            }
        }
        .accessibilityValue(userStore.isWorking ? "signing-in" : "idle")
        .accessibilityIdentifier("account-onboarding")
    }
}

private struct AccountOnboardingSurface<Content: View>: View {
    let onBack: () -> Void
    @ViewBuilder let content: Content

    init(
        onBack: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(560, max(440, proxy.size.width - 64))
            let cardHeight = min(580, max(500, proxy.size.height - 64))

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .candoaButton(.quiet)
                    .font(.system(size: 12, weight: .semibold))
                    .help("Back")
                    .accessibilityIdentifier("onboarding-back")

                    Spacer()

                    Text("3 of 3")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 44)
            }
            .padding(38)
            .frame(width: cardWidth, height: cardHeight)
            .background(CandoaInterfaceStyle.surfaceFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 30, y: 14)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(CandoaInterfaceStyle.surfaceFill.opacity(0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("initial-onboarding-account")
        .accessibilityValue("Step 3 of 3")
    }
}

private struct ImportOnboardingStep: View {
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
                    title: "Start with what matters",
                    detail: "Bring your bookmarks from Safari, Chrome, Arc, or Firefox so your essential sites are ready on day one."
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
                .candoaButton(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting)
                .accessibilityIdentifier("onboarding-import-bookmarks")

                Button(String(localized: "Skip")) {
                    store.completeInitialImport()
                }
                .candoaButton(.quiet)
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
            Text(errorMessage ?? "Candoa couldn’t access \(selectedSource.name)’s default profile. You can choose another profile manually.")
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
        let message = "Imported \(count) bookmark\(count == 1 ? "" : "s")."
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

private struct SpaceOnboardingStep: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        OnboardingSurface(step: .space, onBack: store.goBackInInitialOnboarding) {
            UpsertSpaceSidebarComposer(store: store, mode: .initial)
                .frame(maxWidth: 360)
        } preview: {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "square.stack.3d.up",
                    title: "Give everything its place",
                    detail: "Keep work, personal browsing, and projects separate so you can switch context without losing your place."
                )

                Spacer(minLength: 24)

                Text("Start with one Space. Add more anytime as your workflow grows.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 430, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct OnboardingSurface<Leading: View, Preview: View>: View {
    let step: InitialOnboardingStep
    let onBack: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let preview: Preview

    init(
        step: InitialOnboardingStep,
        onBack: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder preview: () -> Preview
    ) {
        self.step = step
        self.onBack = onBack
        self.leading = leading()
        self.preview = preview()
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(720, proxy.size.width - 64)
            let availableHeight = max(480, proxy.size.height - 64)
            let cardWidth = min(1080, availableWidth)
            let cardHeight = min(680, availableHeight)
            let leadingWidth = min(430, max(330, cardWidth * 0.40))

            HStack(spacing: 0) {
                setupRail(width: leadingWidth)
                previewRail
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(CandoaInterfaceStyle.surfaceFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 30, y: 14)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(CandoaInterfaceStyle.surfaceFill.opacity(0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("initial-onboarding-\(step.rawValue)")
        .accessibilityValue("Step \(step.position) of \(step.count)")
    }

    private func setupRail(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            setupProgressLabel
                .padding(.bottom, 34)

            leading
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(38)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .leading)
    }

    private var setupProgressLabel: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .candoaButton(.quiet)
                .font(.system(size: 12, weight: .semibold))
                .help("Back")
                .accessibilityIdentifier("onboarding-back")
            } else {
                Text("Set up your workflow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(step.position) of \(step.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private var previewRail: some View {
        preview
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CandoaInterfaceStyle.sidebarControlFill.opacity(0.50))
    }
}

private struct OnboardingPageHeader: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(CandoaInterfaceStyle.decorativeSymbol)

            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.4)

            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .stroke(CandoaInterfaceStyle.surfaceBorder, lineWidth: 1)
            }
        }
    }
}
