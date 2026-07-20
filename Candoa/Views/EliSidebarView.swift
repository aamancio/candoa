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
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
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
    @State private var lastSubmittedPageContext: CandoaAIPageContext?
    @State private var pendingBrowserControl: PendingBrowserControl?
    @State private var pendingSensitiveAgentAction: PendingSensitiveAgentAction?
    @State private var suggestedPageAction: SuggestedPageAction?
    @State private var browserAgentTask: Task<Void, Never>?
    @State private var isResolvingPageAction = false
    @State private var attachmentPreviewData: [UUID: Data] = [:]
    @State private var presentedImagePreview: AISidebarImagePreview?
    @State private var isTourPreviewSession = false
    @State private var isRefreshingEliAccess = true
    @FocusState private var isPromptFocused: Bool

    private var activePageTitle: String {
        let title = store.activeTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Current Page" : title
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

    private var availableTabMentions: [BrowserTab] {
        let query = trimmedMentionQuery
        let tabs = store.visibleTabsForActiveSpace
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
                    detail: "\(host) - History",
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
                title: "Upload file from computer",
                detail: "Text files",
                symbolName: "doc.badge.plus",
                faviconData: nil,
                action: .uploadFile
            )
        ]
    }

    private var mentionOptions: [AISidebarMentionOption] {
        tabMentionOptions + fileMentionOptions
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

    private var panelBackgroundColor: Color {
        guard let appearance = NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        ) else {
            return CandoaInterfaceStyle.windowBackground
        }

        var resolvedColor = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
                ?? NSColor.windowBackgroundColor
        }
        return Color(nsColor: resolvedColor)
    }

    private var hasPersonalEliAccess: Bool {
        CandoaEliPreferences.usesPersonalOpenAIKey && CandoaEliKeychain.hasAPIKey
    }

    private var hasEliAccess: Bool {
        hasPersonalEliAccess || userStore.hasActiveSubscription || isEliControlUITest
    }

    private var isEliControlUITest: Bool {
        BrowserStore.isUITesting
            && [
                "ask-contextual-purchase", "ask-contextual-followup",
                "ask-contextual-unsafe-followup", "ask-agent-navigation",
                "ask-agent-normalized-navigation", "ask-agent-selection",
                "ask-model-selector-context", "ask-live-model-selector-context"
            ].contains(
                ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"]
            )
    }

    private var showsTourPreview: Bool {
        isTourPreviewSession || store.initialOnboardingStep == .tour
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if showsTourPreview {
                Spacer(minLength: 44)
                EliTourPreviewView(accentColor: eliAccentColor)
                Spacer(minLength: 44)
            } else if messages.isEmpty {
                Spacer(minLength: 60)
                emptyState
                Spacer(minLength: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach($messages) { $message in
                                AISidebarMessageRow(
                                    message: $message
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

            if !showsTourPreview {
                composer
            }
        }
        .background(panelBackgroundColor)
        .onAppear {
            configureUITestingConversationIfNeeded()
            if store.initialOnboardingStep == .tour {
                isTourPreviewSession = true
            }
            uiTestingState = uiTestingAgentState
            DispatchQueue.main.async {
                if !showsTourPreview {
                    isPromptFocused = true
                }
            }
        }
        .task {
            guard !showsTourPreview else { return }
            if hasPersonalEliAccess || isEliControlUITest {
                isRefreshingEliAccess = false
                return
            }
            await userStore.refresh()
            isRefreshingEliAccess = false
        }
        .onDisappear {
            isTourPreviewSession = false
            uiTestingState = ""
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
            guard phase == .active, !hasEliAccess else { return }
            isRefreshingEliAccess = true
            Task {
                await userStore.refresh()
                isRefreshingEliAccess = false
            }
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
            "Let Eli take control of this browser tab?",
            isPresented: Binding(
                get: { pendingBrowserControl != nil },
                set: { if !$0 { clearPendingControlPermission() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Allow for Session") { approvePendingControl() }
            Button("Cancel", role: .cancel) { clearPendingControlPermission() }
        } message: {
            Text("Eli can control browser tabs until you quit Candoa. Sensitive actions still require confirmation.")
                .accessibilityIdentifier("eli-page-action-permission-message")
        }
        .confirmationDialog(
            "Confirm this action?",
            isPresented: Binding(
                get: { pendingSensitiveAgentAction != nil },
                set: { if !$0 { stopPendingSensitiveAgentAction() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) { approveSensitiveAgentAction() }
            Button("Stop", role: .cancel) { stopPendingSensitiveAgentAction() }
        } message: {
            if let pendingSensitiveAgentAction {
                Text(CandoaBrowserAgentPolicy.sensitiveConfirmationMessage(for: pendingSensitiveAgentAction.action))
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
                prompt = ""
                mentionedContext = []
                attachmentPreviewData = [:]
                presentedImagePreview = nil
                messages = []
                includesCurrentPageContext = true
                lastSubmittedPageContext = nil
                cancelStream()
            }

            Spacer()

            AISidebarTopBarIconButton(
                symbolName: "xmark",
                helpText: "Close Eli Sidebar",
                iconSize: 18
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
                .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)

            Text("Ask about this page or another tab")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarText)

            Text("Type @ to mention a tab")
                .font(.system(size: 12.5))
                .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)

            VStack(spacing: 6) {
                AISidebarExamplePromptButton(
                    title: "Summarize this page",
                    symbolName: "text.alignleft"
                ) {
                    submitPrompt("Summarize this page")
                }
                .accessibilityIdentifier("agent-example-summarize")

                AISidebarExamplePromptButton(
                    title: "Explain the key points",
                    symbolName: "list.bullet"
                ) {
                    submitPrompt("Explain the key points")
                }
                .accessibilityIdentifier("agent-example-explain")

                AISidebarExamplePromptButton(
                    title: "Compare with another tab",
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

    private var eliAccentColor: Color {
        guard let hex = store.activeThemeColorHexes.first else {
            return CandoaColor.primary
        }
        return Color(spaceHex: hex)
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
        .padding(.horizontal, 12)
        .padding(.top, hasContext ? 12 : 9)
        .padding(.bottom, hasContext ? 10 : 9)
        .background {
            RoundedRectangle(cornerRadius: hasContext ? 16 : 14, style: .continuous)
                .fill(CandoaInterfaceStyle.sidebarControlFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: hasContext ? 16 : 14, style: .continuous)
                .stroke(CandoaInterfaceStyle.sidebarControlStroke, lineWidth: 1)
        }
    }

    private var speechStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speechController.displayText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)
                .lineLimit(1)
                .padding(.leading, 4)

            HStack(spacing: 9) {
                Button {
                    speechController.cancelListening()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(!speechController.isListening)
                .help("Cancel Dictation")

                AISidebarSpeechWaveformView()
                    .frame(height: 18)

                Text(speechController.elapsedText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CandoaInterfaceStyle.sidebarIcon)
                    .frame(width: 38, alignment: .trailing)

                Button {
                    commitSpeechTranscript()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(speechController.isListening ? CandoaInterfaceStyle.sidebarTextSecondary : CandoaInterfaceStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
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
        VStack(alignment: .leading, spacing: 7) {
            Text("TABS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)
                .padding(.horizontal, 10)

            ForEach(Array(tabMentionOptions.enumerated()), id: \.element.id) { index, option in
                mentionButton(
                    option: option,
                    isSelected: index == selectedMentionIndex
                )
            }

            if !fileMentionOptions.isEmpty {
                Divider()

                Text("FILES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)
                    .padding(.horizontal, 10)

                ForEach(Array(fileMentionOptions.enumerated()), id: \.element.id) { index, option in
                    mentionButton(
                        option: option,
                        isSelected: tabMentionOptions.count + index == selectedMentionIndex
                    )
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CandoaInterfaceStyle.popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
        }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 16, y: 8)
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
        guard CandoaEliPromptPolicy.canSubmit(submittedPrompt, hasConversation: !messages.isEmpty) else { return }

        if !hasEliAccess {
            refreshEliAccessThenSubmit(submittedPrompt)
            return
        }

        if let purchaseIntent = CandoaPurchaseNavigationIntent.parse(submittedPrompt) {
            preparePurchaseNavigation(purchaseIntent, submittedPrompt: submittedPrompt)
            return
        }

        if let agentIntent = CandoaBrowserAgentIntent.parse(submittedPrompt) {
            prepareBrowserAgent(agentIntent, submittedPrompt: submittedPrompt)
            return
        }

        if let suggestion = suggestedPageAction,
           suggestion.tabID == store.activeTabID,
           suggestion.pageURL == store.activeTab?.url?.absoluteString,
           CandoaContextualActionFollowUp.isApproval(submittedPrompt) {
            suggestedPageAction = nil
            preparePageAction(suggestion.action, submittedPrompt: submittedPrompt)
            return
        }

        if let followUpAction = CandoaContextualActionFollowUp.parse(
            submittedPrompt,
            recentTurns: recentTurns()
        ) {
            preparePageAction(followUpAction, submittedPrompt: submittedPrompt)
            return
        }

        if let action = CandoaPageActionProposal.parse(submittedPrompt) {
            preparePageAction(action, submittedPrompt: submittedPrompt)
            return
        }

        prompt = ""
        cancelStream()

        let submittedContextChips = contextChips.map {
            AISidebarContextChip(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                symbolName: $0.symbolName,
                faviconData: $0.faviconData,
                previewImageData: $0.previewImageData,
                isRemovable: false
            )
        }
        let contextMentions = mentionedContext
        let normalizedSubmittedPrompt = CandoaEliPromptPolicy.normalizedText(submittedPrompt)
        let existingRecentTurns = recentTurns()
        let shouldRefreshCurrentPageContext = CandoaEliDrafts.asksAboutVisibleControl(
            normalizedSubmittedPrompt,
            recentTurns: existingRecentTurns
        )
        let includesCurrentPage = includesCurrentPageContext || shouldRefreshCurrentPageContext
        let currentPageTabID = includesCurrentPage ? store.activeTabID : nil
        let inheritedPageContext = lastSubmittedPageContext
        let shouldUseCurrentContextOnly = !submittedContextChips.isEmpty
            && CandoaEliDrafts.referencesCurrentPage(normalizedSubmittedPrompt)
        let recentTurns = shouldUseCurrentContextOnly ? [] : existingRecentTurns

        messages.append(AISidebarMessage(
            role: .user,
            text: submittedPrompt,
            isStreaming: false,
            contextChips: submittedContextChips
        ))

        let responseID = UUID()
        messages.append(AISidebarMessage(id: responseID, role: .assistant, text: "", isStreaming: true))

        mentionedContext = []
        attachmentPreviewData = [:]
        presentedImagePreview = nil
        includesCurrentPageContext = false
        isMentionMenuPresented = false

        streamTask = Task {
            let submittedPageContext = await combinedContext(
                for: contextMentions,
                currentPageTabID: currentPageTabID
            )
            let pageContext = submittedPageContext.hasAttachedContext
                ? submittedPageContext
                : inheritedPageContext ?? submittedPageContext

            if submittedPageContext.hasAttachedContext {
                await MainActor.run {
                    lastSubmittedPageContext = submittedPageContext
                }
            }

            if let result = CandoaEliDrafts.priceComparisonResult(
                for: submittedPrompt,
                context: pageContext
            ) {
                await MainActor.run {
                    guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
                    messages[index].text = result.answer
                    messages[index].isStreaming = false
                    suggestedPageAction = result.suggestedAction.map {
                        SuggestedPageAction(
                            action: $0,
                            tabID: currentPageTabID,
                            pageURL: pageContext.url
                        )
                    }
                    streamTask = nil
                }
                return
            }
            let remoteContext = CandoaEliContextCompactor.compactedContextIfNeeded(
                from: pageContext,
                prompt: submittedPrompt
            ) ?? pageContext
            await streamRemoteAIResponse(
                prompt: submittedPrompt,
                context: remoteContext,
                recentTurns: recentTurns,
                responseID: responseID
            )
        }
    }

    private func preparePurchaseNavigation(
        _ intent: CandoaPurchaseNavigationIntent,
        submittedPrompt: String
    ) {
        prompt = ""
        messages.append(AISidebarMessage(role: .user, text: submittedPrompt, isStreaming: false))
        let tabID = store.activeTabID
        isResolvingPageAction = true

        Task {
            let candidates = await store.pagePurchaseCandidates(for: tabID)
            let resolvedAction = CandoaContextualNavigationResolver.resolve(
                intent,
                candidates: candidates,
                currentPageURL: store.activeTab?.url?.absoluteString
            )

            await MainActor.run {
                isResolvingPageAction = false
                guard let resolvedAction else {
                    messages.append(AISidebarMessage(
                        role: .assistant,
                        text: "I couldn’t verify a visible computer price and buying link on this page. I won’t guess a product or destination.",
                        isStreaming: false
                    ))
                    return
                }
                presentPageAction(resolvedAction, in: tabID)
            }
        }
    }

    private func configureUITestingConversationIfNeeded() {
        guard BrowserStore.isUITesting, messages.isEmpty else { return }

        switch ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_FIXTURE"] {
        case "ask-agent-selection":
            messages = [
                AISidebarMessage(
                    role: .user,
                    text: "whats the cheapest computer",
                    isStreaming: false
                ),
                AISidebarMessage(
                    role: .assistant,
                    text: "The 13-inch model is the cheapest option shown at $1199.",
                    isStreaming: false
                )
            ]
            suggestedPageAction = SuggestedPageAction(
                action: CandoaPageActionProposal(kind: .select, target: "13-inch", value: nil),
                tabID: store.activeTabID,
                pageURL: store.activeTab?.url?.absoluteString
            )
        case "ask-contextual-followup":
            messages = [
                AISidebarMessage(
                    role: .user,
                    text: "which computer is the cheapest?",
                    isStreaming: false
                ),
                AISidebarMessage(
                    role: .assistant,
                    text: "The cheapest listed computer is the MacBook Air.",
                    isStreaming: false
                )
            ]
        case "ask-contextual-unsafe-followup":
            messages = [
                AISidebarMessage(
                    role: .user,
                    text: "what savings are on this page?",
                    isStreaming: false
                ),
                AISidebarMessage(
                    role: .assistant,
                    text: "You can buy a Mac or iPad with education savings and get a gift card.",
                    isStreaming: false
                ),
                AISidebarMessage(
                    role: .user,
                    text: "which one is the most powerful?",
                    isStreaming: false
                ),
                AISidebarMessage(
                    role: .assistant,
                    text: "The most powerful option appears to be the MacBook Air with the M5 chip.",
                    isStreaming: false
                )
            ]
        default:
            break
        }
    }

    private func preparePageAction(_ action: CandoaPageActionProposal, submittedPrompt: String) {
        prompt = ""
        messages.append(AISidebarMessage(role: .user, text: submittedPrompt, isStreaming: false))

        guard action.needsVisibleLinkResolution else {
            presentPageAction(action, in: store.activeTabID)
            return
        }

        let tabID = store.activeTabID
        let activeURL = store.activeTab?.url?.absoluteString
        let cachedContext = lastSubmittedPageContext?.url == activeURL ? lastSubmittedPageContext : nil
        let conversation = recentTurns()
        isResolvingPageAction = true

        Task {
            let pageContext = if let cachedContext {
                cachedContext
            } else {
                await store.aiPageContext(for: tabID)
            }
            let resolvedAction = CandoaContextualNavigationResolver.resolve(
                action,
                recentTurns: conversation,
                pageContext: pageContext
            )

            await MainActor.run {
                isResolvingPageAction = false
                guard let resolvedAction else {
                    messages.append(AISidebarMessage(
                        role: .assistant,
                        text: "I couldn’t identify one exact link on this page from our conversation. Tell me the product or destination name, and I’ll confirm it before navigating.",
                        isStreaming: false
                    ))
                    return
                }
                presentPageAction(resolvedAction, in: tabID)
            }
        }
    }

    private func presentPageAction(_ action: CandoaPageActionProposal, in tabID: UUID?) {
        if store.hasGrantedEliBrowserControlForSession {
            performApprovedPageAction(action, in: tabID)
            return
        }
        messages.append(AISidebarMessage(
            role: .assistant,
            text: "I can take control of this browser tab to complete your request. Please confirm first.",
            isStreaming: false
        ))
        pendingBrowserControl = .action(action, tabID: tabID)
    }

    private func prepareBrowserAgent(
        _ intent: CandoaBrowserAgentIntent,
        submittedPrompt: String
    ) {
        prompt = ""
        cancelStream()
        messages.append(AISidebarMessage(role: .user, text: submittedPrompt, isStreaming: false))
        if store.hasGrantedEliBrowserControlForSession {
            startBrowserAgent(goal: intent.goal, tabID: store.activeTabID)
            return
        }
        messages.append(AISidebarMessage(
            role: .assistant,
            text: "I can take control of this browser tab to complete your request. Please confirm first.",
            isStreaming: false
        ))
        pendingBrowserControl = .agent(goal: intent.goal, tabID: store.activeTabID)
    }

    private func refreshEliAccessThenSubmit(_ submittedPrompt: String) {
        isRefreshingEliAccess = true

        Task {
            await userStore.refresh()
            isRefreshingEliAccess = false

            if hasEliAccess {
                submitPrompt(submittedPrompt)
                return
            }

            prompt = ""
            cancelStream()

            let submittedContextChips = contextChips.map {
                AISidebarContextChip(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    symbolName: $0.symbolName,
                    faviconData: $0.faviconData,
                    previewImageData: $0.previewImageData,
                    isRemovable: false
                )
            }

            messages.append(AISidebarMessage(
                role: .user,
                text: submittedPrompt,
                isStreaming: false,
                contextChips: submittedContextChips
            ))
            messages.append(AISidebarMessage(
                role: .assistant,
                text: "Eli is available with Candoa Pro.",
                isStreaming: false,
                action: .subscribe
            ))

            mentionedContext = []
            attachmentPreviewData = [:]
            presentedImagePreview = nil
            includesCurrentPageContext = false
            isMentionMenuPresented = false
        }
    }

    private func beginComparisonPrompt() {
        prompt = "Compare this with @"
        selectedMentionIndex = 0
        isMentionMenuPresented = true
        isPromptFocused = true
    }

    private func approvePendingControl() {
        store.hasGrantedEliBrowserControlForSession = true
        guard let pendingBrowserControl else { return }
        clearPendingControlPermission()
        switch pendingBrowserControl {
        case let .action(action, tabID):
            performApprovedPageAction(action, in: tabID)
        case let .agent(goal, tabID):
            startBrowserAgent(goal: goal, tabID: tabID)
        }
    }

    private func performApprovedPageAction(_ action: CandoaPageActionProposal, in tabID: UUID?) {
        Task {
            let result = await store.performAIPageAction(action, in: tabID)
            await MainActor.run {
                messages.append(AISidebarMessage(role: .assistant, text: result, isStreaming: false))
            }
        }
    }

    private func clearPendingControlPermission() {
        pendingBrowserControl = nil
    }

    private func startBrowserAgent(goal: String, tabID: UUID?) {
        guard let tabID else {
            messages.append(AISidebarMessage(
                role: .assistant,
                text: "That browser tab is no longer open.",
                isStreaming: false
            ))
            return
        }
        let responseID = UUID()
        messages.append(AISidebarMessage(id: responseID, role: .assistant, text: "", isStreaming: true))
        isResolvingPageAction = true
        launchBrowserAgent(BrowserAgentRunState(
            goal: goal,
            tabID: tabID,
            history: [],
            stepCount: 0,
            responseID: responseID
        ))
    }

    private func launchBrowserAgent(
        _ initialState: BrowserAgentRunState,
        approvedAction: CandoaPageActionProposal? = nil
    ) {
        browserAgentTask?.cancel()
        browserAgentTask = Task {
            var state = initialState

            if let approvedAction {
                guard let page = await store.browserAgentPage(for: state.tabID) else {
                    finishBrowserAgent(state, message: "That browser tab is no longer available.")
                    return
                }
                let result = await store.performAIPageAction(approvedAction, in: state.tabID)
                let historyItem = CandoaBrowserAgentHistoryItem(
                    kind: approvedAction.kind,
                    target: approvedAction.target,
                    result: result
                )
                state.history.append(historyItem)
                state.stepCount += 1
                await store.waitForBrowserAgentPageSettled(in: state.tabID, previousURL: page.url)
            }

            do {
                while state.stepCount < CandoaBrowserAgentPolicy.maximumSteps {
                    try Task.checkCancellation()
                    guard store.activeTabID == state.tabID else {
                        finishBrowserAgent(state, message: "I stopped because you switched to another tab.")
                        return
                    }
                    guard let page = await store.browserAgentPage(for: state.tabID) else {
                        finishBrowserAgent(state, message: "That browser tab is no longer available.")
                        return
                    }

                    let decision = try await store.nextBrowserAgentStep(
                        goal: state.goal,
                        page: page,
                        history: state.history
                    )
                    switch decision.status {
                    case .complete:
                        finishBrowserAgent(
                            state,
                            message: decision.message.isEmpty ? "Done." : decision.message
                        )
                        return
                    case .blocked:
                        finishBrowserAgent(
                            state,
                            message: decision.message.isEmpty
                                ? "I need your help before I can continue."
                                : decision.message
                        )
                        return
                    case .act:
                        guard let proposedAction = decision.action else {
                            finishBrowserAgent(
                                state,
                                message: "I stopped because the proposed control was not verified on this page."
                            )
                            return
                        }
                        guard let action = CandoaBrowserAgentPolicy.validatedAction(decision, on: page) else {
                            let rejection = CandoaBrowserAgentHistoryItem(
                                kind: proposedAction.kind,
                                target: proposedAction.target,
                                result: "Candoa rejected this proposal because it was not grounded in the current page snapshot. Choose a listed control or a valid scroll direction."
                            )
                            state.history.append(rejection)
                            state.stepCount += 1
                            continue
                        }
                        if CandoaBrowserAgentPolicy.requiresSensitiveConfirmation(action, goal: state.goal) {
                            pendingSensitiveAgentAction = PendingSensitiveAgentAction(action: action, state: state)
                            browserAgentTask = nil
                            return
                        }

                        let result = await store.performAIPageAction(action, in: state.tabID)
                        let historyItem = CandoaBrowserAgentHistoryItem(
                            kind: action.kind,
                            target: action.target,
                            result: result
                        )
                        state.history.append(historyItem)
                        state.stepCount += 1
                        await store.waitForBrowserAgentPageSettled(in: state.tabID, previousURL: page.url)
                    }
                }

                finishBrowserAgent(
                    state,
                    message: "I stopped after several steps without being able to verify completion."
                )
            } catch is CancellationError {
                return
            } catch {
                Self.eliLogger.error("Browser agent failed: \(error.localizedDescription, privacy: .public)")
                finishBrowserAgent(state, message: error.localizedDescription)
            }
        }
    }

    private func approveSensitiveAgentAction() {
        guard let pending = pendingSensitiveAgentAction else { return }
        pendingSensitiveAgentAction = nil
        launchBrowserAgent(pending.state, approvedAction: pending.action)
    }

    private func stopPendingSensitiveAgentAction() {
        guard let pending = pendingSensitiveAgentAction else { return }
        pendingSensitiveAgentAction = nil
        finishBrowserAgent(pending.state, message: "I stopped before making that change.")
    }

    private func finishBrowserAgent(_ state: BrowserAgentRunState, message: String) {
        if let index = messages.firstIndex(where: { $0.id == state.responseID }) {
            messages[index].text = message
            messages[index].isStreaming = false
        }
        isResolvingPageAction = false
        browserAgentTask = nil
    }

    private func streamRemoteAIResponse(
        prompt: String,
        context: CandoaAIPageContext,
        recentTurns: [CandoaAIConversationTurn],
        responseID: UUID
    ) async {
        do {
            var response = ""
            var displayedCharacterCount = 0
            for try await fragment in CandoaRemoteEliService.streamResponse(
                to: prompt,
                context: context,
                recentTurns: recentTurns
            ) {
                guard !Task.isCancelled else { return }
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
                guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
                messages[index].text = response
                messages[index].isStreaming = false
                streamTask = nil
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

        if errorDescription.contains("api key") {
            message = "Add an OpenAI API key in Settings before using your own key."
        } else if errorDescription.contains("authentication")
            || errorDescription.contains("session")
            || errorDescription.contains("current plan") {
            message = "Eli requires a signed-in Candoa account with an active Candoa subscription. Sign in or subscribe to continue."
        } else {
            message = "Eli is temporarily unavailable. Please try again later."
        }

        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].text = message
        messages[index].isStreaming = false
        streamTask = nil
    }

    private func combinedContext(
        for mentions: [AISidebarContextMention],
        currentPageTabID: UUID?
    ) async -> CandoaAIPageContext {
        let currentContext = currentPageTabID != nil
            ? await store.aiPageContext(for: currentPageTabID)
            : CandoaAIPageContext(title: nil, url: nil, text: nil)
        var sections: [String] = []

        if currentPageTabID != nil, !mentions.isEmpty {
            sections.append(contextSection(title: "Current page", context: currentContext))
        }

        for mention in mentions {
            switch mention {
            case .tab(let tabID):
                guard tabID != currentPageTabID else { continue }
                let tabContext = await store.aiPageContext(for: tabID)
                sections.append(contextSection(title: "Mentioned tab", context: tabContext))
            case .history(let historyContext):
                sections.append(
                    """
                    History page:
                    Title: \(historyContext.title)
                    URL: \(historyContext.url.absoluteString)
                    """
                )
            case .file(let fileContext):
                sections.append("Uploaded file: \(fileContext.name)\n\(fileContext.text)")
            }
        }

        let combinedText = sections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return CandoaAIPageContext(
            title: currentContext.title,
            url: currentContext.url,
            text: combinedText.isEmpty ? currentContext.text : combinedText
        )
    }

    private func contextSection(title: String, context: CandoaAIPageContext) -> String {
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
                subtitle: "Uploaded file",
                symbolName: fileContext.previewImageData == nil ? "doc.text" : "photo",
                faviconData: nil,
                previewImageData: fileContext.previewImageData,
                isRemovable: true
            )
        }
    }

    private func normalizedMentionURLKey(_ url: URL) -> String {
        var key = url.absoluteString.lowercased()
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
        addImageAttachment(pastedImage, name: "Pasted Image")
    }

    private var canPasteImage: Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSImage.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        )
    }

    private func addImageAttachment(_ image: NSImage, name: String) {
        let recognizedText = CandoaImageTextRecognizer.recognizedText(in: image)?
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

    private func recentTurns() -> [CandoaAIConversationTurn] {
        let turns: [CandoaAIConversationTurn] = messages.compactMap { message in
            guard message.action == nil else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CandoaAIConversationTurn(role: message.role.conversationRole, text: text)
        }
        return Array(turns.suffix(6))
    }

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        browserAgentTask?.cancel()
        browserAgentTask = nil
        pendingSensitiveAgentAction = nil
        clearPendingControlPermission()
        isResolvingPageAction = false

        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
    }
}
