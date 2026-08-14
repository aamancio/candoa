import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct EliSidebarView: View {
    private static let eliLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Candoa",
        category: "Eli"
    )

    @ObservedObject var store: BrowserStore
    @Binding var uiTestingState: String
    @Binding var messages: [AISidebarMessage]
    @Binding var pendingSubscriptionSubmission: EliSubmission?
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var userStore: UserStore
    @StateObject private var speechController = AISidebarSpeechController()
    @State private var prompt = ""
    @State private var mentionedContext: [AISidebarContextMention] = []
    @State private var isMentionMenuPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectedMentionIndex = 0
    @State private var streamTask: Task<Void, Never>?
    @State private var includesCurrentPageContext = true
    @State private var lastSubmittedPageContext: AIPageContext?
    @State private var pendingSensitiveAgentAction: PendingSensitiveAgentAction?
    /// A run paused on a wait-for-user handoff (an ad, a sign-in, a CAPTCHA).
    /// The cloud workflow stays alive until Continue resumes it or Stop (or
    /// sidebar teardown) rejects it.
    @State private var waitingAgentRun: BrowserAgentRunState?
    @State private var browserAgentTask: Task<Void, Never>?
    @State private var isResolvingPageAction = false
    @State private var attachmentPreviewData: [UUID: Data] = [:]
    @State private var presentedImagePreview: AISidebarImagePreview?
    @State private var isRefreshingEliAccess = true
    @State private var isMemoryPopoverPresented = false
    @FocusState private var isPromptFocused: Bool

    private var activePageTitle: String {
        let title = store.activeTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? String(localized: "Current Page") : title
    }

    private var activePageSubtitle: String {
        store.activeTab?.url?.host(percentEncoded: false) ?? ""
    }

    private var mentionQuery: String? {
        let text = prompt as NSString
        let selectedRange = NSApp.keyWindow?.firstResponder
            .flatMap { $0 as? NSTextView }?
            .selectedRange() ?? NSRange(location: text.length, length: 0)
        let cursorLocation = min(selectedRange.location, text.length)
        let prefix = text.substring(to: cursorLocation)
        guard let atRange = prefix.range(of: "@", options: .backwards) else { return nil }
        let token = String(prefix[atRange.upperBound...])
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return token
    }

    /// Tabs already represented by a context chip: explicit tab mentions plus
    /// the active tab while the "current page" chip is attached.
    private var attachedTabIDs: Set<UUID> {
        var ids = Set(mentionedContext.compactMap { mention -> UUID? in
            guard case .tab(let tabID) = mention else { return nil }
            return tabID
        })
        if includesCurrentPageContext, let activeTabID = store.activeTabID {
            ids.insert(activeTabID)
        }
        return ids
    }

    private var unattachedOpenTabs: [BrowserTab] {
        let attached = attachedTabIDs
        return store.visibleTabsForActiveSpace.filter { !attached.contains($0.id) }
    }

    private var availableTabMentions: [BrowserTab] {
        let query = trimmedMentionQuery
        let tabs = unattachedOpenTabs
        guard !query.isEmpty else { return tabs }
        return tabs.filter { tab in
            tab.title.localizedCaseInsensitiveContains(query) ||
                (tab.url?.host(percentEncoded: false)?.localizedCaseInsensitiveContains(query) ?? false) ||
                (tab.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var trimmedMentionQuery: String {
        mentionQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var tabMentionOptions: [AISidebarMentionOption] {
        let tabOptions = availableTabMentions.prefix(6).map { tab in
            AISidebarMentionOption(
                id: "tab-\(tab.id.uuidString)",
                title: tab.title,
                detail: tab.url?.host(percentEncoded: false),
                symbolName: tab.faviconSymbol,
                faviconData: tab.faviconData,
                action: .mention(.tab(tab.id))
            )
        }

        return tabOptions + historyMentionOptions
    }

    private var historyMentionOptions: [AISidebarMentionOption] {
        guard !trimmedMentionQuery.isEmpty else { return [] }

        let openTabURLKeys = Set(store.visibleTabsForActiveSpace.compactMap {
            $0.url.map { normalizedMentionURLKey($0) }
        })

        return store.recentHistory(matching: trimmedMentionQuery, limit: 6)
            .filter { !openTabURLKeys.contains(normalizedMentionURLKey($0.url)) }
            .map { visit in
                let title = visit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = visit.url.host(percentEncoded: false) ?? visit.url.absoluteString
                return AISidebarMentionOption(
                    id: "history-\(visit.id.uuidString)",
                    title: title.isEmpty ? host : title,
                    detail: String(localized: "\(host) - History"),
                    symbolName: FaviconService.shared.placeholderSymbol(for: visit.url),
                    faviconData: nil,
                    action: .mention(
                        .history(
                            AISidebarHistoryContext(
                                id: visit.id,
                                title: title.isEmpty ? host : title,
                                url: visit.url
                            )
                        )
                    )
                )
            }
    }

    private var fileMentionOptions: [AISidebarMentionOption] {
        guard trimmedMentionQuery.isEmpty else { return [] }
        return [
            AISidebarMentionOption(
                id: "upload-file",
                title: String(localized: "Upload file from computer"),
                detail: String(localized: "Text files"),
                symbolName: "doc.badge.plus",
                faviconData: nil,
                action: .uploadFile
            )
        ]
    }

    private var allOpenTabsMentionOptions: [AISidebarMentionOption] {
        let count = unattachedOpenTabs.count
        guard count >= 2 else { return [] }
        return [
            AISidebarMentionOption(
                id: "all-open-tabs",
                title: String(localized: "All open tabs"),
                detail: "(\(count))",
                symbolName: "macwindow.on.rectangle",
                faviconData: nil,
                action: .mentionAllOpenTabs
            )
        ]
    }

    private var mentionOptions: [AISidebarMentionOption] {
        tabMentionOptions + allOpenTabsMentionOptions + fileMentionOptions
    }

    private var contextChips: [AISidebarContextChip] {
        let currentChip = includesCurrentPageContext ? [
            AISidebarContextChip(
                id: "current",
                title: activePageTitle,
                subtitle: activePageSubtitle,
                symbolName: store.activeTab?.faviconSymbol ?? "safari",
                faviconData: store.activeTab?.faviconData,
                previewImageData: nil,
                isRemovable: true
            )
        ] : []

        return currentChip + mentionedContext.map { chip(for: $0) }
    }

    private var hasPersonalEliAccess: Bool {
        EliPreferences.hasDirectEliAccess
    }

    private var hasEliAccess: Bool {
        hasPersonalEliAccess || userStore.hasActiveSubscription || isEliControlUITest
    }

    private var isEliControlUITest: Bool {
        BrowserStore.isUITesting
            && [
                "ask-agent-navigation", "ask-agent-normalized-navigation", "ask-agent-selection",
                "ask-agent-mentioned-tab", "ask-agent-waiting"
            ].contains(
                ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"]
            )
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if messages.isEmpty {
                    VStack(spacing: 0) {
                        Spacer(minLength: 60)
                        emptyState
                        Spacer(minLength: 60)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach($messages) { $message in
                                    AISidebarMessageRow(
                                        message: $message,
                                        onWaitingContinue: { continueWaitingAgentRun() },
                                        onWaitingStop: { stopWaitingAgentRun() }
                                    )
                                    .padding(.bottom, spacingAfterMessage(message))
                                    .id(message.id)
                                }
                            }
                            .padding(14)
                        }
                        .onChange(of: messages) { _, updatedMessages in
                            guard let lastID = updatedMessages.last?.id else { return }
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            // The top bar must be the scroll view's safe-area inset, not a
            // VStack sibling: with the window's unified toolbar, SwiftUI
            // extends the scroll view's AppKit surface up into the title-bar
            // strip, and a sibling top bar there never receives clicks.
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }

            composer
        }
        .onAppear {
            uiTestingState = uiTestingAgentState
            removeSubscriptionGateIfActive()
            resumePendingSubscriptionSubmissionIfNeeded()
            DispatchQueue.main.async {
                isPromptFocused = true
            }
        }
        .task {
            if hasPersonalEliAccess || isEliControlUITest {
                isRefreshingEliAccess = false
                return
            }
            await userStore.refresh()
            isRefreshingEliAccess = false
        }
        .onDisappear {
            uiTestingState = ""
            updateSpaceMemoryFromConversation()
            cancelStream()
            speechController.cancelListening()
        }
        .onChange(of: uiTestingAgentState) { _, state in
            uiTestingState = state
        }
        .onChange(of: store.activeTabID) {
            includesCurrentPageContext = true
        }
        .onChange(of: store.activeTab?.url) {
            includesCurrentPageContext = true
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  !hasEliAccess,
                  !userStore.isAwaitingSubscriptionActivation else { return }
            isRefreshingEliAccess = true
            Task {
                await userStore.refresh()
                isRefreshingEliAccess = false
            }
        }
        .onChange(of: userStore.hasActiveSubscription) { _, hasActiveSubscription in
            guard hasActiveSubscription else { return }
            removeSubscriptionGateIfActive()
            resumePendingSubscriptionSubmissionIfNeeded()
        }
        .onChange(of: userStore.signOutGeneration) { _, generation in
            guard generation > 0, !hasPersonalEliAccess else { return }
            resetHostedEliAfterSignOut()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.text, .plainText, .json, .sourceCode, .image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(item: $presentedImagePreview) { preview in
            AISidebarImagePreviewSheet(preview: preview) {
                presentedImagePreview = nil
            }
        }
        .confirmationDialog(
            "Confirm this action?",
            isPresented: Binding(
                get: { pendingSensitiveAgentAction != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    // SwiftUI writes false for every dismissal — Esc, window or
                    // scene churn — before any dialog button action runs. Defer
                    // one beat so an explicit button can resolve the pending
                    // action first; whatever is still pending afterwards was
                    // dismissed without a decision and must be treated as a
                    // deny, or the parked run would strand isResolvingPageAction
                    // and block every future submission.
                    DispatchQueue.main.async {
                        stopPendingSensitiveAgentAction()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) { approveSensitiveAgentAction() }
            Button("Stop", role: .cancel) { stopPendingSensitiveAgentAction() }
        } message: {
            if let pendingSensitiveAgentAction {
                Text(BrowserAgentPolicy.sensitiveConfirmationMessage(for: pendingSensitiveAgentAction.action))
                    .accessibilityIdentifier("eli-sensitive-action-message")
            }
        }
        .accessibilityIdentifier("agent-sidebar")
    }

    private func spacingAfterMessage(_ message: AISidebarMessage) -> CGFloat {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return 0 }
        let nextIndex = messages.index(after: index)
        guard nextIndex < messages.endIndex else { return 0 }
        return messages[nextIndex].role == message.role ? 3 : 13
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            AISidebarTopBarIconButton(
                symbolName: "square.and.pencil",
                helpText: "New Eli Conversation"
            ) {
                updateSpaceMemoryFromConversation()
                prompt = ""
                mentionedContext = []
                attachmentPreviewData = [:]
                presentedImagePreview = nil
                messages = []
                pendingSubscriptionSubmission = nil
                includesCurrentPageContext = true
                lastSubmittedPageContext = nil
                cancelStream()
            }

            AISidebarTopBarIconButton(
                symbolName: "brain",
                helpText: "Eli Memory"
            ) {
                isMemoryPopoverPresented = true
            }
            .popover(isPresented: $isMemoryPopoverPresented, arrowEdge: .bottom) {
                EliMemoryPopoverView(store: store)
            }

            Spacer()

            AISidebarTopBarIconButton(
                symbolName: "xmark",
                helpText: "Close Eli Sidebar",
                iconSize: 18,
                shortcut: .toggleAISidebar
            ) {
                onClose()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .initialTourPopover(.ask, store: store, arrowEdge: .trailing)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "at")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(InterfaceStyle.sidebarIcon)

            Text("Ask about this page or another tab")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InterfaceStyle.sidebarText)

            Text("Type @ to mention a tab")
                .font(.system(size: 12.5))
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)

            VStack(spacing: 6) {
                AISidebarExamplePromptButton(
                    title: String(localized: "Summarize this page"),
                    symbolName: "text.alignleft"
                ) {
                    submitPrompt("Summarize this page")
                }
                .accessibilityIdentifier("agent-example-summarize")

                AISidebarExamplePromptButton(
                    title: String(localized: "Explain the key points"),
                    symbolName: "list.bullet"
                ) {
                    submitPrompt("Explain the key points")
                }
                .accessibilityIdentifier("agent-example-explain")

                AISidebarExamplePromptButton(
                    title: String(localized: "Compare with another tab"),
                    symbolName: "square.on.square"
                ) {
                    beginComparisonPrompt()
                }
                .accessibilityIdentifier("agent-example-compare")
            }
            .frame(maxWidth: 260)
            .padding(.top, 8)
            .disabled(isRefreshingEliAccess)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("agent-empty-state")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if isMentionMenuPresented {
                mentionMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            inputSurface
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var inputSurface: some View {
        let hasContext = !contextChips.isEmpty

        return VStack(alignment: .leading, spacing: hasContext ? 12 : 0) {
            if hasContext {
                contextTagRow
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Tell Eli what to do...", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 14))
                    .focused($isPromptFocused)
                    .accessibilityIdentifier("agent-input-field")
                    .onSubmit {
                        if !performSelectedMention() {
                            submitPrompt()
                        }
                    }
                    .onChange(of: prompt) { _, _ in
                        syncMentionMenu()
                    }
                    .onKeyPress(.downArrow) {
                        guard isMentionMenuPresented else { return .ignored }
                        moveMentionSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard isMentionMenuPresented else { return .ignored }
                        moveMentionSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress("v", phases: .down) { keyPress in
                        guard keyPress.modifiers.contains(.command), canPasteImage else {
                            return .ignored
                        }
                        handleImagePaste()
                        return .handled
                    }
                    .overlay(alignment: .leading) {
                        if isMentionMenuPresented, prompt == "@" {
                            HStack(spacing: 3) {
                                Text(verbatim: "@")
                                    .hidden()
                                Text("Type to filter")
                                    .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                            }
                            .font(.system(size: 14))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }

                AISidebarComposerIconButton(symbolName: "plus", helpText: "Add Context") {
                    showMentionMenuFromButton()
                }

                AISidebarComposerIconButton(
                    symbolName: "mic",
                    helpText: speechController.isListening ? "Stop Listening" : "Dictate"
                ) {
                    handleMicButton()
                }

                AISidebarComposerSendButton(
                    isEnabled: !isRefreshingEliAccess
                        && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    submitPrompt()
                }
                .accessibilityIdentifier("agent-send-button")
            }

            if speechController.isListening || speechController.statusMessage != nil {
                speechStatusRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, hasContext ? 12 : 9)
        .padding(.bottom, hasContext ? 10 : 9)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(InterfaceStyle.sidebarControlFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InterfaceStyle.sidebarControlStroke, lineWidth: 1)
        }
    }

    private var speechStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speechController.displayText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                .lineLimit(1)
                .padding(.leading, 4)

            HStack(spacing: 9) {
                Button {
                    speechController.cancelListening()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(InterfaceStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                }
                .buttonTreatment(.chrome)
                .disabled(!speechController.isListening)
                .help("Cancel Dictation")

                AISidebarSpeechWaveformView()
                    .frame(height: 18)

                Text(speechController.elapsedText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(InterfaceStyle.sidebarIcon)
                    .frame(width: 38, alignment: .trailing)

                Button {
                    commitSpeechTranscript()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(speechController.isListening ? InterfaceStyle.sidebarTextSecondary : InterfaceStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                }
                .buttonTreatment(.chrome)
                .disabled(!speechController.isListening)
                .help("Stop Dictation")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var contextTagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(contextChips) { chip in
                    AISidebarContextChipView(
                        chip: chip,
                        onPreview: chip.previewImageData == nil ? nil : {
                            presentImagePreview(for: chip)
                        },
                        onRemove: {
                            removeMention(chip.id)
                        }
                    )
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
    }

    private var mentionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !tabMentionOptions.isEmpty {
                mentionSectionHeader("TABS")
            }

            ForEach(Array(tabMentionOptions.enumerated()), id: \.element.id) { index, option in
                mentionButton(
                    option: option,
                    isSelected: index == selectedMentionIndex
                )
            }

            if let allOpenTabsOption = allOpenTabsMentionOptions.first {
                Divider()
                    .padding(.vertical, 3)

                mentionButton(
                    option: allOpenTabsOption,
                    isSelected: tabMentionOptions.count == selectedMentionIndex
                )
            }

            if !fileMentionOptions.isEmpty {
                Divider()
                    .padding(.vertical, 3)

                mentionSectionHeader("FILES")

                ForEach(Array(fileMentionOptions.enumerated()), id: \.element.id) { index, option in
                    mentionButton(
                        option: option,
                        isSelected: tabMentionOptions.count
                            + allOpenTabsMentionOptions.count
                            + index == selectedMentionIndex
                    )
                }
            }
        }
        .padding(6)
        .frame(minWidth: 260, maxWidth: 340, alignment: .leading)
        .background(InterfaceStyle.popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(InterfaceStyle.popoverBorder, lineWidth: 1)
        }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 16, y: 8)
    }

    private func mentionSectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private func mentionButton(
        option: AISidebarMentionOption,
        isSelected: Bool
    ) -> some View {
        AISidebarMentionButton(
            title: option.title,
            detail: option.detail,
            symbolName: option.symbolName,
            faviconData: option.faviconData,
            isSelected: isSelected,
            action: {
                runMentionOption(option)
            }
        )
    }

    private var uiTestingAgentState: String {
        let composerChipText = contextChips
            .map { "\($0.title)|\($0.subtitle)" }
            .joined(separator: ",")
        let lastUserText = messages.last { $0.role == .user }?.text ?? ""
        let lastAssistantText = messages.last { $0.role == .assistant }?.text ?? ""
        let messageText = messages.enumerated()
            .map { index, message in
                let role = message.role == .user ? "user" : "assistant"
                let feedback = switch message.feedback {
                case .positive: "positive"
                case .negative: "negative"
                case nil: "none"
                }
                let sentChipText = message.contextChips
                    .map { "\($0.title)|\($0.subtitle)" }
                    .joined(separator: ",")
                return "\(index):\(role):feedback=\(feedback):chips=[\(sentChipText)]:text=\(message.text)"
            }
            .joined(separator: "||")

        return "composerChips=[\(composerChipText)];lastUser=[\(lastUserText)];lastAssistant=[\(lastAssistantText)];messages=[\(messageText)]"
    }

    private func submitPrompt(_ promptOverride: String? = nil) {
        let submittedPrompt = (promptOverride ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRefreshingEliAccess, !isResolvingPageAction else { return }
        // A new request supersedes a run that was waiting on the user: end it
        // cleanly so its card can't outlive the conversation turn it paused.
        if waitingAgentRun != nil {
            stopWaitingAgentRun()
        }
        guard EliPromptPolicy.canSubmit(submittedPrompt, hasConversation: !messages.isEmpty) else { return }

        let submission = makeSubmission(prompt: submittedPrompt)
        if !hasEliAccess {
            refreshEliAccessThenSubmit(submission)
            return
        }

        startSubmission(submission, appendingUserMessage: true)
    }

    private func makeSubmission(prompt submittedPrompt: String) -> EliSubmission {
        EliSubmission(
            prompt: submittedPrompt,
            contextChips: contextChips.map {
                AISidebarContextChip(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    symbolName: $0.symbolName,
                    faviconData: $0.faviconData,
                    previewImageData: $0.previewImageData,
                    isRemovable: false
                )
            },
            contextMentions: mentionedContext,
            recentTurns: recentTurns(),
            currentPageTabID: includesCurrentPageContext ? store.activeTabID : nil,
            browserControlTabID: store.activeTabID,
            mentionedTabs: mentionedContext.compactMap { mention in
                guard case .tab(let tabID) = mention,
                      let url = store.tabs.first(where: { $0.id == tabID })?.url else { return nil }
                return EliMentionedTab(id: tabID, url: url.absoluteString)
            },
            inheritedPageContext: lastSubmittedPageContext
        )
    }

    private func startSubmission(
        _ submission: EliSubmission,
        appendingUserMessage: Bool
    ) {
        prompt = ""
        cancelStream()

        if appendingUserMessage {
            messages.append(AISidebarMessage(
                role: .user,
                text: submission.prompt,
                isStreaming: false,
                contextChips: submission.contextChips
            ))
        }

        let responseID = UUID()
        messages.append(AISidebarMessage(id: responseID, role: .assistant, text: "", isStreaming: true))

        mentionedContext = []
        attachmentPreviewData = [:]
        presentedImagePreview = nil
        includesCurrentPageContext = false
        isMentionMenuPresented = false

        streamTask = Task {
            let submittedContext = await combinedContext(
                for: submission.contextMentions,
                currentPageTabID: submission.currentPageTabID
            )
            let submittedPageContext = submittedContext.pageContext
            let pageContext = submittedPageContext.hasAttachedContext
                ? submittedPageContext
                : submission.inheritedPageContext ?? submittedPageContext

            if submittedPageContext.hasAttachedContext {
                await MainActor.run {
                    lastSubmittedPageContext = submittedPageContext
                }
            }

            let remoteContext = EliContextCompactor.compactedContextIfNeeded(
                from: pageContext,
                prompt: submission.prompt
            ) ?? pageContext
            // Memory joins after compaction and inheritance so it neither
            // counts as "attached context" for the inherit-last-page rule nor
            // gets rewritten by the compactor.
            let memorySection = store.activeSpaceMemorySection()
            await streamRemoteAIResponse(
                prompt: submission.prompt,
                context: SpaceMemoryPolicy.contextByPrependingMemory(memorySection, to: remoteContext),
                recentTurns: submission.recentTurns,
                responseID: responseID,
                browserControlTabID: submission.browserControlTabID,
                mentionedTabs: submission.mentionedTabs,
                agentAttachedContext: SpaceMemoryPolicy.agentContextByPrependingMemory(
                    memorySection,
                    to: submittedContext.agentAttachedContext
                )
            )
        }
    }

    private func refreshEliAccessThenSubmit(_ submission: EliSubmission) {
        isRefreshingEliAccess = true

        Task {
            if userStore.isAwaitingSubscriptionActivation {
                await userStore.reconcilePendingSubscriptionIfNeeded()
            } else {
                await userStore.refresh()
            }
            isRefreshingEliAccess = false

            if hasEliAccess {
                startSubmission(submission, appendingUserMessage: true)
                return
            }

            prompt = ""
            cancelStream()

            messages.append(AISidebarMessage(
                role: .user,
                text: submission.prompt,
                isStreaming: false,
                contextChips: submission.contextChips
            ))
            messages.append(AISidebarMessage(
                role: .assistant,
                text: "",
                isStreaming: false,
                action: .subscribe
            ))
            pendingSubscriptionSubmission = submission

            mentionedContext = []
            attachmentPreviewData = [:]
            presentedImagePreview = nil
            includesCurrentPageContext = false
            isMentionMenuPresented = false
        }
    }

    private func removeSubscriptionGateIfActive() {
        guard userStore.hasActiveSubscription else { return }
        messages.removeAll { $0.action == .subscribe }
    }

    private func resumePendingSubscriptionSubmissionIfNeeded() {
        guard hasEliAccess, let submission = pendingSubscriptionSubmission else { return }
        pendingSubscriptionSubmission = nil
        startSubmission(submission, appendingUserMessage: false)
    }

    private func beginComparisonPrompt() {
        prompt = "Compare this with @"
        selectedMentionIndex = 0
        isMentionMenuPresented = true
        isPromptFocused = true
    }

    /// Resolves which tab a browser-control request runs in. Without a
    /// targetTabURL the task targets the current page (the tab that was
    /// active at submission). With one, the URL must resolve to a tab the
    /// user attached via a mention — or, failing that, an open tab in the
    /// active Space; an unresolvable URL ends the run visibly rather than
    /// silently acting on the wrong tab.
    private func startBrowserAgentResolvingTargetTab(
        goal: String,
        targetTabURL: String?,
        currentPageTabID: UUID?,
        mentionedTabs: [EliMentionedTab],
        attachedContext: String?,
        reusing responseID: UUID
    ) {
        guard let targetTabURL else {
            startBrowserAgent(
                goal: goal,
                tabID: currentPageTabID,
                attachedContext: attachedContext,
                reusing: responseID
            )
            return
        }

        guard let resolvedTabID = resolveBrowserAgentTargetTab(
            url: targetTabURL,
            mentionedTabs: mentionedTabs
        ) else {
            startBrowserAgent(goal: goal, tabID: nil, attachedContext: attachedContext, reusing: responseID)
            return
        }

        // Activate the target so the user watches the run where it happens —
        // and so a hibernated tab's web view wakes before the first snapshot.
        let needsActivation = store.activeTabID != resolvedTabID
        if needsActivation {
            store.switchTab(to: resolvedTabID)
        }
        startBrowserAgent(
            goal: goal,
            tabID: resolvedTabID,
            attachedContext: attachedContext,
            wakesTab: needsActivation,
            reusing: responseID
        )
    }

    private func resolveBrowserAgentTargetTab(
        url: String,
        mentionedTabs: [EliMentionedTab]
    ) -> UUID? {
        let key = normalizedMentionURLKey(url)
        if let mentioned = mentionedTabs.first(where: { normalizedMentionURLKey($0.url) == key }),
           store.tabs.contains(where: { $0.id == mentioned.id }) {
            return mentioned.id
        }
        return store.visibleTabsForActiveSpace.first { tab in
            tab.url.map { normalizedMentionURLKey($0.absoluteString) } == key
        }?.id
    }

    /// Starts a browser-agent run immediately: the user's request is the
    /// consent for reversible browsing, so there is no per-task permission
    /// dialog. Consequential actions are still confirmed individually via
    /// `pendingSensitiveAgentAction` during the run.
    private func startBrowserAgent(
        goal: String,
        tabID: UUID?,
        attachedContext: String?,
        wakesTab: Bool = false,
        reusing responseID: UUID
    ) {
        // The run must start (or fail visibly) even when the streaming message
        // is gone — e.g. the conversation was reset while the request was in
        // flight — so behavior never hinges on a messages lookup.
        if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].text = ""
            messages[index].isStreaming = true
            messages[index].transientStatus = String(localized: "Looking at this page…")
        } else {
            messages.append(AISidebarMessage(
                id: responseID,
                role: .assistant,
                text: "",
                isStreaming: true,
                transientStatus: String(localized: "Looking at this page…")
            ))
        }
        guard let tabID else {
            finishBrowserAgentMessage(responseID, message: String(localized: "That browser tab is no longer open."))
            return
        }
        isResolvingPageAction = true
        let state = BrowserAgentRunState(
            runID: UUID(),
            goal: goal,
            tabID: tabID,
            responseID: responseID
        )
        browserAgentTask?.cancel()
        browserAgentTask = Task {
            do {
                if wakesTab {
                    await store.wakeBrowserAgentTab(state.tabID)
                }
                guard let page = await store.browserAgentPage(for: state.tabID) else {
                    finishBrowserAgent(state, message: String(localized: "That browser tab is no longer available."))
                    return
                }
                let response = try await store.startBrowserAgentRun(
                    runID: state.runID,
                    goal: state.goal,
                    page: page,
                    attachedContext: attachedContext
                )
                try await continueBrowserAgent(response, page: page, state: state)
            } catch is CancellationError {
                return
            } catch {
                Self.eliLogger.error("Browser agent failed: \(error.localizedDescription, privacy: .public)")
                finishBrowserAgent(state, message: error.localizedDescription)
            }
        }
    }

    private func continueBrowserAgent(
        _ response: BrowserAgentRunResponse,
        page: BrowserAgentPage,
        state: BrowserAgentRunState
    ) async throws {
        try Task.checkCancellation()
        guard store.activeTabID == state.tabID else {
            finishBrowserAgent(state, message: String(localized: "I stopped because you switched to another tab."))
            return
        }

        switch response.status {
        case .complete:
            finishBrowserAgent(state, message: response.message.isEmpty ? String(localized: "Done.") : response.message)
        case .waiting:
            let reason = response.message.isEmpty
                ? String(localized: "I need you to handle something in this tab, then continue.")
                : response.message
            if let index = messages.firstIndex(where: { $0.id == state.responseID }) {
                messages[index].text = ""
                messages[index].isStreaming = false
                messages[index].transientStatus = nil
                messages[index].action = .waitingForUser(reason: reason)
            }
            waitingAgentRun = state
            browserAgentTask = nil
            // The user may keep chatting (or take their time with the ad);
            // only a live Continue re-enters the resolving state.
            isResolvingPageAction = false
        case .blocked:
            finishBrowserAgent(
                state,
                message: response.message.isEmpty
                    ? String(localized: "I need your help before I can continue.")
                    : response.message
            )
        case .action:
            guard let pendingAction = response.action,
                  let action = pendingAction.validatedAction(on: page) else {
                updateBrowserAgentStatus(state, text: String(localized: "Refreshing the page controls…"))
                let outcome = BrowserAgentActionOutcome(
                    status: .failed,
                    result: "Candoa rejected the action because its page reference was stale or unverified.",
                    page: page
                )
                let next = try await store.resumeBrowserAgentRun(
                    runID: state.runID,
                    goal: state.goal,
                    outcome: outcome
                )
                try await continueBrowserAgent(next, page: page, state: state)
                return
            }

            updateBrowserAgentStatus(state, text: browserAgentStatus(for: pendingAction))

            if BrowserAgentPolicy.requiresNativeApproval(for: pendingAction, on: page) {
                pendingSensitiveAgentAction = PendingSensitiveAgentAction(
                    action: action,
                    state: state,
                    previousURL: page.url
                )
                browserAgentTask = nil
                return
            }
            try await executeBrowserAgentAction(action, previousURL: page.url, state: state)
        }
    }

    private func executeBrowserAgentAction(
        _ action: PageActionProposal,
        previousURL: String,
        state: BrowserAgentRunState
    ) async throws {
        let result = await store.performAIPageAction(action, in: state.tabID)
        updateBrowserAgentStatus(state, text: String(localized: "Checking the result…"))
        await store.waitForBrowserAgentPageSettled(in: state.tabID, previousURL: previousURL)
        guard let page = await store.browserAgentPage(for: state.tabID) else {
            finishBrowserAgent(state, message: String(localized: "That browser tab is no longer available."))
            return
        }
        let response = try await store.resumeBrowserAgentRun(
            runID: state.runID,
            goal: state.goal,
            outcome: BrowserAgentActionOutcome(
                status: result.status == .executed ? .executed : .failed,
                result: result.message,
                page: page
            )
        )
        try await continueBrowserAgent(response, page: page, state: state)
    }

    private func approveSensitiveAgentAction() {
        guard let pending = pendingSensitiveAgentAction else { return }
        pendingSensitiveAgentAction = nil
        browserAgentTask = Task {
            do {
                try await executeBrowserAgentAction(
                    pending.action,
                    previousURL: pending.previousURL,
                    state: pending.state
                )
            } catch is CancellationError {
                return
            } catch {
                Self.eliLogger.error("Browser agent failed: \(error.localizedDescription, privacy: .public)")
                finishBrowserAgent(pending.state, message: error.localizedDescription)
            }
        }
    }

    /// The user cleared the obstacle (skipped the ad, signed in) and pressed
    /// Continue: snapshot the run's tab fresh and resume the paused workflow.
    private func continueWaitingAgentRun() {
        guard let state = waitingAgentRun else { return }
        waitingAgentRun = nil
        if let index = messages.firstIndex(where: { $0.id == state.responseID }) {
            messages[index].action = nil
            messages[index].isStreaming = true
            messages[index].transientStatus = String(localized: "Continuing…")
        }
        isResolvingPageAction = true
        browserAgentTask?.cancel()
        browserAgentTask = Task {
            do {
                // The user may have wandered to another tab while waiting;
                // the run belongs to its tab, so bring it back first.
                if store.activeTabID != state.tabID {
                    store.switchTab(to: state.tabID)
                    await store.wakeBrowserAgentTab(state.tabID)
                }
                guard let page = await store.browserAgentPage(for: state.tabID) else {
                    finishBrowserAgent(state, message: String(localized: "That browser tab is no longer open."))
                    return
                }
                let next = try await store.resumeBrowserAgentRun(
                    runID: state.runID,
                    goal: state.goal,
                    outcome: BrowserAgentActionOutcome(
                        status: .resumed,
                        result: "The user handled it and asked me to continue.",
                        page: page
                    )
                )
                try await continueBrowserAgent(next, page: page, state: state)
            } catch is CancellationError {
            } catch {
                Self.eliLogger.error("Browser agent resume failed: \(error.localizedDescription, privacy: .public)")
                finishBrowserAgent(state, message: error.localizedDescription)
            }
        }
    }

    /// Ends a waiting run without resuming it: finalize the card immediately
    /// and tell the workflow in the background, mirroring `cancelStream()`'s
    /// handling of a pending sensitive action.
    private func stopWaitingAgentRun() {
        guard let state = waitingAgentRun else { return }
        waitingAgentRun = nil
        finishBrowserAgent(state, message: String(localized: "Okay, I stopped there."))
        Task {
            _ = try? await store.resumeBrowserAgentRun(
                runID: state.runID,
                goal: state.goal,
                outcome: BrowserAgentActionOutcome(
                    status: .rejected,
                    result: "The user chose not to continue the paused task.",
                    page: nil
                )
            )
        }
    }

    /// Denies the parked sensitive action: ends the cloud workflow with
    /// `.rejected` and finalizes the run's status message. This is the single
    /// path for every non-approval outcome — the Stop button, Esc, and any
    /// other dialog dismissal all land here.
    private func stopPendingSensitiveAgentAction() {
        guard let pending = pendingSensitiveAgentAction else { return }
        pendingSensitiveAgentAction = nil
        browserAgentTask?.cancel()
        browserAgentTask = Task {
            do {
                let response = try await store.resumeBrowserAgentRun(
                    runID: pending.state.runID,
                    goal: pending.state.goal,
                    outcome: BrowserAgentActionOutcome(
                        status: .rejected,
                        result: "The user did not approve this action.",
                        page: nil
                    )
                )
                finishBrowserAgent(
                    pending.state,
                    message: response.message.isEmpty
                        ? String(localized: "I stopped before making that change.")
                        : response.message
                )
            } catch {
                finishBrowserAgent(pending.state, message: String(localized: "I stopped before making that change."))
            }
        }
    }

    private func finishBrowserAgent(_ state: BrowserAgentRunState, message: String) {
        finishBrowserAgentMessage(state.responseID, message: message)
    }

    private func finishBrowserAgentMessage(_ responseID: UUID, message: String) {
        if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].text = message
            messages[index].isStreaming = false
            messages[index].transientStatus = nil
            // A finished run can never leave an interactive waiting card behind.
            messages[index].action = nil
        }
        isResolvingPageAction = false
        browserAgentTask = nil
    }

    private func updateBrowserAgentStatus(_ state: BrowserAgentRunState, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == state.responseID }),
              messages[index].isStreaming else { return }
        messages[index].transientStatus = text
    }

    private func browserAgentStatus(for action: BrowserAgentAction) -> String {
        let message = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }

        switch action.kind {
        case .navigate:
            // Direct URL navigation carries no control label; show the URL.
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(localized: "Opening \(label.isEmpty ? (action.url ?? action.target) : label)…")
        case .click:
            return String(localized: "Using \(action.label)…")
        case .select:
            let choice = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return choice.isEmpty
                ? String(localized: "Selecting \(action.label)…")
                : String(localized: "Selecting \(choice)…")
        case .fill:
            return String(localized: "Entering information in \(action.label)…")
        case .scroll:
            return String(localized: "Scrolling the page…")
        }
    }

    private func streamRemoteAIResponse(
        prompt: String,
        context: AIPageContext,
        recentTurns: [AIConversationTurn],
        responseID: UUID,
        browserControlTabID: UUID?,
        mentionedTabs: [EliMentionedTab],
        agentAttachedContext: String?
    ) async {
        do {
            var response = ""
            var displayedCharacterCount = 0
            for try await event in RemoteEliService.streamResponse(
                to: prompt,
                context: context,
                recentTurns: recentTurns
            ) {
                guard !Task.isCancelled else { return }
                if case let .browserControl(goal, targetTabURL) = event {
                    await MainActor.run {
                        streamTask = nil
                        startBrowserAgentResolvingTargetTab(
                            goal: goal,
                            targetTabURL: targetTabURL,
                            currentPageTabID: browserControlTabID,
                            mentionedTabs: mentionedTabs,
                            attachedContext: agentAttachedContext,
                            reusing: responseID
                        )
                    }
                    return
                }
                guard case let .textDelta(fragment) = event else { continue }
                response += fragment
                let shouldDisplayImmediately = displayedCharacterCount == 0
                guard shouldDisplayImmediately || response.count - displayedCharacterCount >= 24 else {
                    continue
                }

                await MainActor.run {
                    guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
                    messages[index].text = response
                }
                displayedCharacterCount = response.count
            }

            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showAgentUnavailableMessage(into: responseID)
                return
            }

            await MainActor.run {
                // State transitions come before the message lookup so they
                // still happen when the conversation was reset mid-stream.
                streamTask = nil
                guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
                messages[index].text = response
                messages[index].isStreaming = false
            }
            return
        } catch is CancellationError {
            return
        } catch {
            Self.eliLogger.error("Eli remote service request failed: \(error.localizedDescription, privacy: .public)")
            showAgentUnavailableMessage(for: error, into: responseID)
        }
    }

    @MainActor
    private func showAgentUnavailableMessage(
        for error: Error? = nil,
        into responseID: UUID
    ) {
        let errorDescription = error?.localizedDescription.lowercased() ?? ""
        let message: String

        if case .sessionExpired? = error as? RemoteEliError {
            message = String(localized: "Your Candoa session has expired. Sign in again to continue.")
        } else if case .missingPersonalKey(let provider)? = error as? RemoteEliError {
            // The English article depends on the provider name, so the OpenAI
            // wording is its own localizable string.
            message = provider == .openai
                ? String(localized: "Add an OpenAI API key in Settings before using your own key.")
                : String(localized: "Add a \(provider.displayName) API key in Settings before using your own key.")
        } else if errorDescription.contains("model is unavailable") {
            message = String(localized: "This model isn't available on your current plan. Choose another model in Candoa Settings.")
        } else if errorDescription.contains("api key") {
            message = String(localized: "Add an API key in Settings before using your own key.")
        } else if errorDescription.contains("authentication")
            || errorDescription.contains("session")
            || errorDescription.contains("current plan") {
            message = String(localized: "Eli requires an active Candoa subscription. Subscribe or restore your plan to continue.")
        } else {
            message = String(localized: "Eli is temporarily unavailable. Please try again later.")
        }

        // State transitions come before the message lookup so they still
        // happen when the conversation was reset mid-stream.
        streamTask = nil
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].text = message
        messages[index].isStreaming = false
    }

    /// The context Ask sees plus the browser agent's carry-along subset,
    /// built in one pass so each mentioned tab's page is captured only once.
    private struct SubmittedEliContext {
        let pageContext: AIPageContext
        /// Only the mentioned-tab and uploaded-file sections — the current
        /// page is excluded because a browser-agent run observes it live.
        /// Nil when the submission attached neither.
        let agentAttachedContext: String?
    }

    private func combinedContext(
        for mentions: [AISidebarContextMention],
        currentPageTabID: UUID?
    ) async -> SubmittedEliContext {
        let currentContext = currentPageTabID != nil
            ? await store.aiPageContext(for: currentPageTabID)
            : AIPageContext(title: nil, url: nil, text: nil)
        var sections: [String] = []
        var agentSections: [String] = []

        if currentPageTabID != nil, !mentions.isEmpty {
            sections.append(contextSection(title: "Current page", context: currentContext))
        }

        for mention in mentions {
            switch mention {
            case .tab(let tabID):
                guard tabID != currentPageTabID else { continue }
                let tabContext = await store.aiPageContext(for: tabID)
                let section = contextSection(title: "Mentioned tab", context: tabContext)
                sections.append(section)
                agentSections.append(section)
            case .history(let historyContext):
                sections.append(
                    """
                    History page:
                    Title: \(historyContext.title)
                    URL: \(historyContext.url.absoluteString)
                    """
                )
            case .file(let fileContext):
                let section = "Uploaded file: \(fileContext.name)\n\(fileContext.text)"
                sections.append(section)
                agentSections.append(section)
            }
        }

        let combinedText = sections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return SubmittedEliContext(
            pageContext: AIPageContext(
                title: currentContext.title,
                url: currentContext.url,
                text: combinedText.isEmpty ? currentContext.text : combinedText
            ),
            agentAttachedContext: agentAttachedContext(from: agentSections)
        )
    }

    /// Joins the agent's carry-along sections the way `combinedContext` joins
    /// Ask's, truncated to 20,000 characters to stay safely under the agent
    /// start request's 24,000-character server limit.
    private func agentAttachedContext(from sections: [String]) -> String? {
        let joined = sections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(20_000))
    }

    private func contextSection(title: String, context: AIPageContext) -> String {
        var lines = ["\(title):"]
        if let pageTitle = context.title, !pageTitle.isEmpty {
            lines.append("Title: \(pageTitle)")
        }
        if let url = context.url, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let text = context.text, !text.isEmpty {
            lines.append("Text excerpt:\n\(text)")
        }
        return lines.joined(separator: "\n")
    }

    private func syncMentionMenu() {
        isMentionMenuPresented = mentionQuery != nil
        selectedMentionIndex = 0
    }

    private func showMentionMenuFromButton() {
        if mentionQuery == nil {
            prompt += prompt.hasSuffix(" ") || prompt.isEmpty ? "@" : " @"
        }
        isMentionMenuPresented = true
        selectedMentionIndex = 0
        isPromptFocused = true
    }

    private func moveMentionSelection(by delta: Int) {
        let count = mentionOptions.count
        guard count > 0 else { return }
        selectedMentionIndex = ((selectedMentionIndex + delta) % count + count) % count
    }

    private func performSelectedMention() -> Bool {
        guard isMentionMenuPresented, mentionOptions.indices.contains(selectedMentionIndex) else {
            return false
        }

        runMentionOption(mentionOptions[selectedMentionIndex])
        return true
    }

    private func runMentionOption(_ option: AISidebarMentionOption) {
        switch option.action {
        case .mention(let mention):
            addMention(mention)
        case .mentionAllOpenTabs:
            let newMentions = unattachedOpenTabs.map { AISidebarContextMention.tab($0.id) }
            mentionedContext.append(contentsOf: newMentions)
            clearMentionToken()
            isMentionMenuPresented = false
            isPromptFocused = true
        case .uploadFile:
            clearMentionToken()
            isMentionMenuPresented = false
            isFileImporterPresented = true
        }
    }

    private func handleMicButton() {
        if speechController.isListening {
            commitSpeechTranscript()
            return
        }

        Task {
            await speechController.startListening()
        }
    }

    private func commitSpeechTranscript() {
        let transcript = speechController.stopListening()
        guard !transcript.isEmpty else { return }

        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = transcript
        } else {
            prompt += prompt.hasSuffix(" ") ? transcript : " \(transcript)"
        }
        isPromptFocused = true
    }

    private func addMention(_ mention: AISidebarContextMention) {
        guard !mentionedContext.contains(mention) else {
            clearMentionToken()
            isMentionMenuPresented = false
            return
        }

        mentionedContext.append(mention)
        clearMentionToken()
        isMentionMenuPresented = false
        isPromptFocused = true
    }

    private func removeMention(_ chipID: String) {
        if chipID == "current" {
            includesCurrentPageContext = false
            return
        }

        let removedFileIDs = mentionedContext.compactMap { mention -> UUID? in
            guard chip(for: mention).id == chipID, case .file(let fileContext) = mention else {
                return nil
            }
            return fileContext.id
        }
        mentionedContext.removeAll { chip(for: $0).id == chipID }
        for fileID in removedFileIDs {
            attachmentPreviewData[fileID] = nil
        }
    }

    private func presentImagePreview(for chip: AISidebarContextChip) {
        guard
            case .file(let fileContext) = mentionedContext.first(where: { self.chip(for: $0).id == chip.id }),
            let imageData = attachmentPreviewData[fileContext.id] ?? fileContext.previewImageData
        else {
            return
        }

        presentedImagePreview = AISidebarImagePreview(
            title: fileContext.name,
            imageData: imageData
        )
    }

    private func chip(for mention: AISidebarContextMention) -> AISidebarContextChip {
        switch mention {
        case .tab(let id):
            let tab = store.tabs.first { $0.id == id }
            let tabTitle = tab?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return AISidebarContextChip(
                id: "tab-\(id.uuidString)",
                title: tabTitle?.isEmpty == false ? tabTitle! : "Mentioned tab",
                subtitle: tab?.url?.host(percentEncoded: false) ?? "",
                symbolName: tab?.faviconSymbol ?? "macwindow",
                faviconData: tab?.faviconData,
                previewImageData: nil,
                isRemovable: true
            )
        case .history(let historyContext):
            return AISidebarContextChip(
                id: "history-\(historyContext.id.uuidString)",
                title: historyContext.title,
                subtitle: historyContext.url.host(percentEncoded: false) ?? "History",
                symbolName: FaviconService.shared.placeholderSymbol(for: historyContext.url),
                faviconData: nil,
                previewImageData: nil,
                isRemovable: true
            )
        case .file(let fileContext):
            return AISidebarContextChip(
                id: "file-\(fileContext.id.uuidString)",
                title: fileContext.name,
                subtitle: String(localized: "Uploaded file"),
                symbolName: fileContext.previewImageData == nil ? "doc.text" : "photo",
                faviconData: nil,
                previewImageData: fileContext.previewImageData,
                isRemovable: true
            )
        }
    }

    private func normalizedMentionURLKey(_ url: URL) -> String {
        normalizedMentionURLKey(url.absoluteString)
    }

    private func normalizedMentionURLKey(_ urlString: String) -> String {
        var key = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }

    private func clearMentionToken() {
        guard mentionQuery != nil else { return }
        let text = prompt as NSString
        let selectedRange = NSApp.keyWindow?.firstResponder
            .flatMap { $0 as? NSTextView }?
            .selectedRange() ?? NSRange(location: text.length, length: 0)
        let cursorLocation = min(selectedRange.location, text.length)
        let prefix = text.substring(to: cursorLocation)
        guard prefix.range(of: "@", options: .backwards) != nil else { return }

        let nsAtLocation = (prefix as NSString).range(of: "@", options: .backwards).location
        let replacementRange = NSRange(location: nsAtLocation, length: cursorLocation - nsAtLocation)
        prompt = text.replacingCharacters(in: replacementRange, with: "")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if contentType?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url) else { return }
            addImageAttachment(image, name: url.lastPathComponent)
            return
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let trimmed = contents
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(trimmed.prefix(8000))
        guard !excerpt.isEmpty else { return }

        addMention(.file(AISidebarFileContext(name: url.lastPathComponent, text: excerpt)))
    }

    private func handleImagePaste() {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        let pastedImage = NSPasteboard.general
            .readObjects(forClasses: [NSImage.self], options: options)?
            .compactMap { $0 as? NSImage }
            .first

        guard let pastedImage else { return }
        addImageAttachment(pastedImage, name: String(localized: "Pasted Image"))
    }

    private var canPasteImage: Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSImage.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        )
    }

    private func addImageAttachment(_ image: NSImage, name: String) {
        let recognizedText = ImageTextRecognizer.recognizedText(in: image)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentText = recognizedText.flatMap { text in
            text.isEmpty ? nil : "Uploaded image OCR text:\n\(text)"
        } ?? "Uploaded image with no recognized text."

        let fileContext = AISidebarFileContext(
            name: name,
            text: attachmentText,
            previewImageData: attachmentThumbnailData(for: image)
        )
        if let imageData = attachmentPreviewData(for: image) {
            attachmentPreviewData[fileContext.id] = imageData
        }
        addMention(.file(fileContext))
    }

    private func attachmentPreviewData(for image: NSImage) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let maximumDimension: CGFloat = 1_600
        let scale = min(1, maximumDimension / max(sourceSize.width, sourceSize.height))
        let targetSize = NSSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )
        let preview = NSImage(size: targetSize)
        preview.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        preview.unlockFocus()

        guard
            let tiffData = preview.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    private func attachmentThumbnailData(for image: NSImage) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let maximumDimension: CGFloat = 96
        let scale = min(1, maximumDimension / max(sourceSize.width, sourceSize.height))
        let targetSize = NSSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()

        guard
            let tiffData = thumbnail.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    private func recentTurns() -> [AIConversationTurn] {
        let turns: [AIConversationTurn] = messages.compactMap { message in
            guard message.action == nil else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AIConversationTurn(role: message.role.conversationRole, text: text)
        }
        return Array(turns.suffix(6))
    }

    /// The full finished conversation, unlike `recentTurns()`'s request
    /// window — memory extraction reads everything that was said.
    private func conversationTurns() -> [AIConversationTurn] {
        messages.compactMap { message in
            guard message.action == nil, !message.isStreaming else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AIConversationTurn(role: message.role.conversationRole, text: text)
        }
    }

    /// A conversation "ends" when the user starts a new one or closes the
    /// sidebar; that is when its durable facts get distilled into the active
    /// Space's memory.
    private func updateSpaceMemoryFromConversation() {
        guard hasEliAccess else { return }
        store.updateSpaceMemory(fromConversation: conversationTurns())
    }

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        browserAgentTask?.cancel()
        browserAgentTask = nil
        if waitingAgentRun != nil {
            // Sidebar teardown or a new conversation while a run is waiting on
            // the user: same contract as a pending sensitive action — finalize
            // now, tell the workflow in the background.
            stopWaitingAgentRun()
        }
        if let pending = pendingSensitiveAgentAction {
            pendingSensitiveAgentAction = nil
            // Finalize the status message inline — the sidebar may be
            // disappearing, so nothing after an await can be relied on —
            // and end the cloud workflow cleanly in the background.
            finishBrowserAgent(pending.state, message: String(localized: "I stopped before making that change."))
            Task {
                _ = try? await store.resumeBrowserAgentRun(
                    runID: pending.state.runID,
                    goal: pending.state.goal,
                    outcome: BrowserAgentActionOutcome(
                        status: .rejected,
                        result: "The user did not approve this action.",
                        page: nil
                    )
                )
            }
        }
        isResolvingPageAction = false

        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].transientStatus = nil
        }
    }

    private func resetHostedEliAfterSignOut() {
        cancelStream()
        speechController.cancelListening()
        prompt = ""
        mentionedContext = []
        attachmentPreviewData = [:]
        presentedImagePreview = nil
        isFileImporterPresented = false
        includesCurrentPageContext = true
        lastSubmittedPageContext = nil
        isMentionMenuPresented = false
        isRefreshingEliAccess = false
    }
}
