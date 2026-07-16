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

struct InitialOnboardingTourOverlay: View {
    @ObservedObject var store: BrowserStore
    @State private var tipIndex = 0

    private let tips = [
        OnboardingTip(
            symbolName: "command",
            title: "Find anything, fast",
            detail: "Press Command-T to search the web, open a site, or jump into a new tab from one place.",
            shortcut: "⌘T",
            anchor: .topLeading
        ),
        OnboardingTip(
            symbolName: "square.stack.3d.up",
            title: "Switch context, keep your place",
            detail: "Spaces separate work, projects, and personal browsing—each with its own tabs and session.",
            shortcut: "⌃1–9",
            anchor: .bottomLeading
        ),
        OnboardingTip(
            symbolName: "sparkles",
            title: "Get help without leaving the page",
            detail: "Use Candoa Ask to summarize, explain, compare, or pull out the next steps.",
            shortcut: "⌘E",
            anchor: .topTrailing
        )
    ]

    var body: some View {
        GeometryReader { proxy in
            let tip = tips[tipIndex]

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: tip.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(CandoaColor.primary)
                        .frame(width: 28, height: 28)

                    Text(tip.title)
                        .font(.system(size: 16, weight: .semibold))

                    Spacer(minLength: 8)

                    Text(tip.shortcut)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Text(tip.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Skip Tour") {
                        store.completeInitialTour()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if tipIndex > 0 {
                        Button("Back") {
                            withAnimation(.easeOut(duration: 0.16)) {
                                tipIndex -= 1
                            }
                        }
                    }

                    Button(tipIndex == tips.count - 1 ? "Done" : "Next") {
                        if tipIndex == tips.count - 1 {
                            store.completeInitialTour()
                        } else {
                            withAnimation(.easeOut(duration: 0.16)) {
                                tipIndex += 1
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CandoaChromeStyle.popoverBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.14), radius: 18, y: 7)
            .position(position(for: tip.anchor, in: proxy.size))
            .transition(.opacity.combined(with: .move(edge: transitionEdge(for: tip.anchor))))
            .id(tipIndex)
        }
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityIdentifier("initial-onboarding-tour")
    }

    private func position(for anchor: OnboardingTip.Anchor, in size: CGSize) -> CGPoint {
        switch anchor {
        case .topLeading:
            return CGPoint(x: CandoaChromeStyle.sidebarWidth + 188, y: 116)
        case .bottomLeading:
            return CGPoint(x: CandoaChromeStyle.sidebarWidth + 188, y: max(120, size.height - 116))
        case .topTrailing:
            return CGPoint(x: max(CandoaChromeStyle.sidebarWidth + 188, size.width - 188), y: 116)
        }
    }

    private func transitionEdge(for anchor: OnboardingTip.Anchor) -> Edge {
        switch anchor {
        case .topLeading, .bottomLeading:
            return .leading
        case .topTrailing:
            return .trailing
        }
    }
}

private struct OnboardingTip {
    enum Anchor {
        case topLeading
        case bottomLeading
        case topTrailing
    }

    let symbolName: String
    let title: String
    let detail: String
    let shortcut: String
    let anchor: Anchor
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
    @StateObject private var accountController = CandoaAccountController()

    var body: some View {
        OnboardingSurface(step: .account, onBack: store.goBackInInitialOnboarding) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "person.crop.circle.badge.checkmark",
                    title: "Finish setting up Candoa",
                    detail: "Continue with Apple to enter Candoa."
                )

                Spacer(minLength: 24)

                OnboardingSignInWithAppleButton(
                    isEnabled: !accountController.isWorking,
                    configure: accountController.configure,
                    completion: accountController.completeAppleSignIn
                )
                .frame(height: 44)
                .accessibilityIdentifier("onboarding-apple-sign-in")

                if accountController.isWorking {
                    ProgressView("Signing in…")
                        .controlSize(.small)
                } else if let errorMessage = accountController.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(CandoaColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } preview: {
            OnboardingAccountPreview()
        }
        .onChange(of: accountController.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                store.completeInitialAccountSetup()
            }
        }
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
    @State private var isFileImporterPresented = false
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var importFailed = false

    var body: some View {
        OnboardingSurface(step: .importData) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "arrow.down.doc",
                    title: "Start with what matters",
                    detail: "Bring your bookmarks from Safari, Chrome, Arc, or Firefox so your essential sites are ready on day one."
                )

                Spacer(minLength: 24)

                if isImporting {
                    ProgressView("Importing…")
                        .controlSize(.small)
                } else if let importMessage {
                    Label(
                        importMessage,
                        systemImage: importFailed ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(importFailed ? AnyShapeStyle(CandoaColor.danger) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                }

                if importMessage != nil, !importFailed {
                    Button {
                        store.completeInitialImport()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Import Again…", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .controlSize(.large)
                    .disabled(isImporting)
                    .accessibilityIdentifier("onboarding-import-bookmarks")
                } else {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Import My Bookmarks…", systemImage: "doc.badge.plus")
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
            }
        } preview: {
            OnboardingImportPreview()
        }
        .onAppear {
            guard importMessage == nil, let count = store.initialImportedBookmarkCount else { return }
            importMessage = importedBookmarksMessage(count: count)
            importFailed = false
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.html],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let fileURL = urls.first else {
                if case .failure(let error) = result {
                    importFailed = true
                    importMessage = error.localizedDescription
                }
                return
            }

            isImporting = true
            importMessage = nil
            importFailed = false
            Task {
                do {
                    let count = try await store.importInitialBookmarks(from: fileURL)
                    importMessage = importedBookmarksMessage(count: count)
                } catch {
                    importFailed = true
                    importMessage = error.localizedDescription
                }
                isImporting = false
            }
        }
    }

    private func importedBookmarksMessage(count: Int) -> String {
        "Imported \(count) bookmark\(count == 1 ? "" : "s"). They’re ready in your sidebar."
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
                Text("From a long page to a clear next step")
                    .font(.system(size: 20, weight: .semibold))

                Text("Candoa Ask works beside the page, so you can understand it and move forward without changing apps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Project Brief", systemImage: "doc.text")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text("8 min read")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text("The launch plan covers the revised timeline, owners, open decisions, and the work needed before the next review.")
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

                Text("Summarize this and give me the next steps.")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CandoaColor.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 11) {
                Label("Candoa Ask", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CandoaColor.primary)

                outcomeRow("Launch moves to September 12")
                outcomeRow("Maya owns the revised brief")
                outcomeRow("Review the final plan on Friday")
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

    private func outcomeRow(_ title: String) -> some View {
        Label(title, systemImage: "checkmark.circle.fill")
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

                Label("Ready in Candoa", systemImage: "folder.fill")
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
