import AppKit
import AuthenticationServices
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
                    .foregroundStyle(CandoaColor.primary)
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
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                if !isFirstTip {
                    Button(String(localized: "Back")) {
                        store.showPreviousInitialTourTip()
                    }
                }

                Button(isLastTip ? String(localized: "Done") : String(localized: "Next")) {
                    store.showNextInitialTourTip()
                }
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
        .background(CandoaChromeStyle.surfaceFill.opacity(0.72))
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
                    .foregroundStyle(CandoaColor.primary)

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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .opacity(revealsAction ? 1 : 0)
                .offset(y: revealsAction ? 0 : 8)
                .accessibilityIdentifier("onboarding-get-started")
                .padding(.bottom, 62)
            }
        }
        .background(CandoaChromeStyle.surfaceFill)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        OnboardingSurface(step: .account, onBack: store.goBackInInitialOnboarding) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "person.crop.circle.badge.checkmark",
                    title: "Finish setting up Candoa",
                    detail: "Continue with Apple to enter Candoa."
                )

                Spacer(minLength: 24)

                Group {
#if DEBUG
                    if userStore.isWorking {
                        Button {} label: {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityIdentifier("onboarding-apple-sign-in-progress")

                                Text("Signing in…")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.black)
                        .controlSize(.large)
                        .disabled(true)
                        .accessibilityLabel("Signing in…")
                        .accessibilityIdentifier("onboarding-apple-sign-in")
                    } else {
                        OnboardingSignInWithAppleButton(
                            isEnabled: true,
                            configure: userStore.configure,
                            completion: userStore.completeAppleSignIn
                        )
                        .accessibilityIdentifier("onboarding-apple-sign-in")
                    }
#else
                    Button("Continue") {
                        store.skipInitialAccountSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
#endif
                }
                .frame(height: 44)

                if let errorMessage = userStore.errorMessage, !userStore.isWorking {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(CandoaColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

#if !DEBUG
                Text("Account sign-in is not available in this direct-download build yet. You can use Candoa without an account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
#endif
            }
        } preview: {
            OnboardingAccountPreview()
        }
        .onChange(of: userStore.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                store.completeInitialAccountSetup()
            }
        }
        .accessibilityValue(userStore.isWorking ? "signing-in" : "idle")
        .accessibilityIdentifier("account-onboarding")
    }
}

private struct OnboardingSignInWithAppleButton: NSViewRepresentable {
    let isEnabled: Bool
    let configure: (ASAuthorizationAppleIDRequest) -> Void
    let completion: (Result<ASAuthorization, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configure: configure, completion: completion)
    }

    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .black)
        button.target = context.coordinator
        button.action = #selector(Coordinator.signIn)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject, ASAuthorizationControllerDelegate,
        ASAuthorizationControllerPresentationContextProviding {
        weak var button: ASAuthorizationAppleIDButton?

        private let configure: (ASAuthorizationAppleIDRequest) -> Void
        private let completion: (Result<ASAuthorization, Error>) -> Void
        private var authorizationController: ASAuthorizationController?

        init(
            configure: @escaping (ASAuthorizationAppleIDRequest) -> Void,
            completion: @escaping (Result<ASAuthorization, Error>) -> Void
        ) {
            self.configure = configure
            self.completion = completion
        }

        @objc func signIn() {
            let request = ASAuthorizationAppleIDProvider().createRequest()
            configure(request)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            authorizationController = controller
            controller.performRequests()
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            authorizationController = nil
            completion(.success(authorization))
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithError error: Error
        ) {
            authorizationController = nil
            completion(.failure(error))
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            button?.window ?? NSApp.keyWindow ?? NSWindow()
        }
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting)
                .accessibilityIdentifier("onboarding-import-bookmarks")

                Button {
                    store.completeInitialImport()
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.large)
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
            .background(CandoaChromeStyle.surfaceFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CandoaChromeStyle.surfaceBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 30, y: 14)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(CandoaChromeStyle.surfaceFill.opacity(0.72))
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
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
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
            .background(CandoaChromeStyle.sidebarControlFill.opacity(0.50))
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
                .foregroundStyle(CandoaColor.primary)

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

private struct OnboardingAccountPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Get answers and take action")
                    .font(.system(size: 20, weight: .semibold))

                Text("Ask about the page, draft a reply, or get help with a page action.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Subscription Settings", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text("$19.99/mo")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text("Your plan renews August 3. Manage or cancel it from your account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
            .padding(16)
            .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CandoaChromeStyle.surfaceBorder, lineWidth: 1)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CandoaColor.primary)

                Text("How do I cancel this subscription?")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CandoaColor.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 11) {
                Label("Eli", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CandoaColor.primary)

                stepRow("Open Account Settings", number: 1)
                stepRow("Choose Billing", number: 2)
                stepRow("Select Cancel Subscription", number: 3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CandoaChromeStyle.surfaceBorder, lineWidth: 1)
            }
        }
        .frame(maxWidth: 440)
    }

    private func stepRow(_ title: String, number: Int) -> some View {
        Label(title, systemImage: "\(number).circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .symbolRenderingMode(.hierarchical)
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
                    .stroke(CandoaChromeStyle.surfaceBorder, lineWidth: 1)
            }
        }
    }
}
